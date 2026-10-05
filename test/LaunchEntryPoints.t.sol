// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// Launch entry points with no launch-specific router: create and fund are direct payable calls paid by
// msg.sender, and swaps use the unmodified Router's forwarded path with the standard payload.

import {Vm} from "forge-std/Vm.sol";
import {ScheduledLaunchTest} from "./extensions/ScheduledLaunch.t.sol";
import {TestToken} from "./TestToken.sol";
import {ScheduledLaunch} from "../src/extensions/ScheduledLaunch.sol";
import {LockedLaunchLiquidity} from "../src/LockedLaunchLiquidity.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {BaseRouter} from "../src/base/BaseRouter.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolState} from "../src/types/poolState.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "../src/types/swapParameters.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {computeFee} from "../src/math/fee.sol";

/// @dev The Yul router's `forwarded` hop: forwards abi.encode(poolKey, params) to the extension named in the
/// pool config and reads only the first returned word as the PoolBalanceUpdate.
contract ForwardedHop is BaseLocker {
    using FlashAccountantLib for *;
    using CoreLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function swap(PoolKey memory key, SwapParameters params) external returns (PoolBalanceUpdate update) {
        return abi.decode(lock(abi.encode(key, params, msg.sender)), (PoolBalanceUpdate));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory key, SwapParameters params, address payer) =
            abi.decode(data, (PoolKey, SwapParameters, address));
        bytes memory result = ACCOUNTANT.forward(key.config.extension(), abi.encode(key, params));
        PoolBalanceUpdate update;
        assembly ("memory-safe") {
            update := mload(add(result, 32))
        }
        _settle(payer, key.token0, update.delta0());
        _settle(payer, key.token1, update.delta1());
        return abi.encode(update);
    }

    function _settle(address payer, address token, int128 delta) private {
        if (delta < 0) ACCOUNTANT.withdraw(token, payer, uint128(-delta));
        else if (delta > 0) ACCOUNTANT.payFrom(payer, token, uint128(delta));
    }
}

/// @dev Forwards an arbitrary payload to a forwardee and settles nothing.
contract RawForwarder is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function forward(address to, bytes memory payload) external returns (bytes memory) {
        return lock(abi.encode(to, payload));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address to, bytes memory payload) = abi.decode(data, (address, bytes));
        return ACCOUNTANT.forward(to, payload);
    }
}

contract LaunchEntryPointsTest is ScheduledLaunchTest {
    using CoreLib for *;

    address constant PAYER = address(0xCAFE);
    address constant RECIPIENT = address(0xBEEF);
    address constant OWNER = address(0xFA11005);

    event LaunchCreated(
        PoolId indexed poolId,
        address indexed token,
        address indexed owner,
        address payer,
        ScheduledLaunch.LaunchConfig config
    );
    event LaunchSwapped(
        PoolId indexed poolId, address indexed locker, int128 delta0, int128 delta1, uint128 feeAmount, bool feeIsToken1
    );
    event PrincipalReceived(PoolId indexed launchId, address indexed from, uint128 amount0, uint128 amount1);

    function setUp() public virtual override {
        super.setUp();
        _fundPayer(LOW_QUOTE);
        _fundPayer(HIGH_QUOTE);
        vm.deal(PAYER, 1_000 ether);
    }

    function _fundPayer(address token) internal {
        TestToken(token).transfer(PAYER, 1_000_000e18);
        _approvePayer(token);
    }

    function _approvePayer(address token) internal {
        vm.startPrank(PAYER);
        MintableERC20(token).approve(address(extension), type(uint256).max);
        MintableERC20(token).approve(address(vault), type(uint256).max);
        MintableERC20(token).approve(address(forwardingRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _quoteToken(bool tokenIs0) internal pure returns (address) {
        return tokenIs0 ? HIGH_QUOTE : LOW_QUOTE;
    }

    function _payerConfig(address quote, uint128 quoteAmount, int32 migrationTick)
        internal
        view
        returns (ScheduledLaunch.LaunchConfig memory config)
    {
        config = _migrateNear(_config(quote), migrationTick);
        config.owner = OWNER;
        config.quoteAmount = quoteAmount;
    }

    function _payerCreate(address quote, uint128 quoteAmount, uint256 value)
        internal
        returns (PoolKey memory key, address token)
    {
        return _payerCreate(quote, quoteAmount, value, 0);
    }

    function _payerCreate(address quote, uint128 quoteAmount, uint256 value, int32 migrationTick)
        internal
        returns (PoolKey memory key, address token)
    {
        vm.prank(PAYER);
        (key, token) = extension.create{value: value}(_payerConfig(quote, quoteAmount, migrationTick));
        _approvePayer(token);
    }

    function _buyParams(bool tokenIs0, int128 amount) internal pure returns (SwapParameters) {
        // Exact input of the quote token; the price limit sits inside the launch range.
        return createSwapParameters(tickToSqrtRatio(tokenIs0 ? int32(50_000) : int32(-50_000)), amount, tokenIs0, 0);
    }

    function _routerSwap(PoolKey memory key, SwapParameters params, int256 threshold, address recipient)
        internal
        returns (PoolBalanceUpdate)
    {
        vm.prank(PAYER);
        return forwardingRouter.swap(key, params, threshold, recipient);
    }

    function _quote(PoolKey memory key, SwapParameters params) internal returns (PoolBalanceUpdate, PoolState) {
        return
            forwardingRouter.quote(key, params.isToken1(), params.amount(), params.sqrtRatioLimit(), params.skipAhead());
    }

    function _assertHoldsNothing(PoolKey memory key) internal view {
        assertEq(address(extension).balance, 0, "extension ETH");
        assertEq(address(vault).balance, 0, "vault ETH");
        assertEq(address(forwardingRouter).balance, 0, "router ETH");
        for (uint256 i; i < 2; i++) {
            address token = i == 0 ? key.token0 : key.token1;
            if (token == address(0)) continue;
            assertEq(MintableERC20(token).balanceOf(address(extension)), 0, "extension token");
            assertEq(MintableERC20(token).balanceOf(address(vault)), 0, "vault token");
            assertEq(MintableERC20(token).balanceOf(address(forwardingRouter)), 0, "router token");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Direct creation.
    // ---------------------------------------------------------------------------------------------

    function testFuzz_createPaysFromSenderAndRecordsPayer(bool tokenIs0) public {
        address quote = _quoteToken(tokenIs0);
        uint256 quoteBefore = TestToken(quote).balanceOf(PAYER);
        ScheduledLaunch.LaunchConfig memory config = _payerConfig(quote, 7e18, 0);
        vm.expectEmit(false, false, true, true, address(extension));
        emit LaunchCreated(PoolId.wrap(0), address(0), OWNER, PAYER, config);
        vm.prank(PAYER);
        (PoolKey memory key, address token) = extension.create(config);
        assertEq(token, extension.getLaunch(key.toPoolId()).token);
        assertEq(token == key.token0, tokenIs0);
        assertEq(extension.getLaunch(key.toPoolId()).owner, OWNER);
        assertEq(TestToken(quote).balanceOf(PAYER), quoteBefore - 7e18);
        (uint128 r0, uint128 r1) = _balances(address(extension), key, PoolId.unwrap(key.toPoolId()));
        assertEq(tokenIs0 ? r1 : r0, 7e18);
        assertEq(tokenIs0 ? r0 : r1, SUPPLY);
        _assertHoldsNothing(key);
    }

    function test_createNativeQuoteRequiresExactValue() public {
        ScheduledLaunch.LaunchConfig memory config = _payerConfig(address(0), 1 ether, 0);
        for (uint256 i; i < 3; i++) {
            if (i == 1) continue;
            vm.prank(PAYER);
            vm.expectRevert(ScheduledLaunch.InvalidPayment.selector);
            extension.create{value: i * 1 ether}(config);
        }
        uint256 before = PAYER.balance;
        (PoolKey memory key,) = _payerCreate(address(0), 1 ether, 1 ether);
        assertEq(PAYER.balance, before - 1 ether);
        assertEq(key.token0, address(0));
        (uint128 r0, uint128 r1) = _balances(address(extension), key, PoolId.unwrap(key.toPoolId()));
        assertEq(r0, 1 ether);
        assertEq(r1, SUPPLY);
        _assertHoldsNothing(key);
    }

    function testFuzz_createErc20QuoteRejectsValue(bool tokenIs0, uint128 quoteAmount) public {
        ScheduledLaunch.LaunchConfig memory config = _payerConfig(_quoteToken(tokenIs0), quoteAmount % 1e24, 0);
        vm.prank(PAYER);
        vm.expectRevert(ScheduledLaunch.InvalidPayment.selector);
        extension.create{value: 1}(config);
    }

    function testFuzz_createWithoutAllowanceReverts(bool tokenIs0) public {
        address quote = _quoteToken(tokenIs0);
        vm.prank(PAYER);
        TestToken(quote).approve(address(extension), 1e18 - 1);
        vm.prank(PAYER);
        vm.expectRevert();
        extension.create(_payerConfig(quote, 1e18, 0));
    }

    /// The forward channel is swap-only: the old creation payload and any non-swap data revert.
    function testFuzz_forwardChannelIsSwapOnly(bool tokenIs0) public {
        RawForwarder forwarder = new RawForwarder(core);
        vm.expectRevert();
        forwarder.forward(address(extension), abi.encode(uint8(0), _config(_quoteToken(tokenIs0))));
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.expectRevert();
        forwarder.forward(address(vault), abi.encode(uint8(1), key.toPoolId(), uint128(1), uint128(0)));
        bytes memory registration = abi.encode(
            LockedLaunchLiquidity.Registration(
                key.toPoolId(), OWNER, extension.terminalPool(key), SqrtRatio.wrap(0), SqrtRatio.wrap(0), 0, 0
            )
        );
        vm.expectRevert(LockedLaunchLiquidity.ExtensionOnly.selector);
        forwarder.forward(address(vault), registration);
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps through the unmodified Router and a generic forwarded hop.
    // ---------------------------------------------------------------------------------------------

    function testFuzz_routerSwapPaysFromSenderAndDeliversToRecipient(bool tokenIs0) public {
        (PoolKey memory key, address token) = _payerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        uint256 quoteBefore = TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER);
        PoolBalanceUpdate update = _routerSwap(key, _buyParams(tokenIs0, 1_000e18), 1, RECIPIENT);

        int128 tokenDelta = tokenIs0 ? update.delta0() : update.delta1();
        int128 quoteDelta = tokenIs0 ? update.delta1() : update.delta0();
        assertEq(quoteDelta, 1_000e18);
        assertLt(tokenDelta, 0);
        assertEq(MintableERC20(token).balanceOf(RECIPIENT), uint128(-tokenDelta));
        assertEq(MintableERC20(token).balanceOf(PAYER), 0);
        assertEq(TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER), quoteBefore - 1_000e18);
        // Fee-inclusive output: the creator fee was already taken from the gross Core output.
        (uint128 fee0, uint128 fee1) = _fees(key);
        uint128 fee = tokenIs0 ? fee0 : fee1;
        assertEq(fee, computeFee(uint128(-tokenDelta) + fee, extension.feeAt(key.toPoolId())));
        _assertHoldsNothing(key);
    }

    /// The Yul router's hop reads only the first returned word and takes the forwardee from the pool config.
    function testFuzz_genericForwardedHopMatchesRouter(bool tokenIs0, bool sell) public {
        (PoolKey memory key, address token) = _payerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        _routerSwap(key, _buyParams(tokenIs0, 10_000e18), 1, PAYER);
        SwapParameters params = sell
            ? createSwapParameters(
                SqrtRatio.wrap(0), int128(uint128(MintableERC20(token).balanceOf(PAYER) / 2)), !tokenIs0, 0
            )
            : _buyParams(tokenIs0, 1_000e18);
        (PoolBalanceUpdate quoted,) = _quote(key, params);
        ForwardedHop hop = new ForwardedHop(core);
        vm.startPrank(PAYER);
        MintableERC20(key.token0).approve(address(hop), type(uint256).max);
        MintableERC20(key.token1).approve(address(hop), type(uint256).max);
        PoolBalanceUpdate update = hop.swap(key, params);
        vm.stopPrank();
        assertEq(PoolBalanceUpdate.unwrap(update), PoolBalanceUpdate.unwrap(quoted));
        _assertHoldsNothing(key);
    }

    function testFuzz_launchSwappedCarriesLockerAndFee(bool tokenIs0) public {
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        SwapParameters params = _buyParams(tokenIs0, 1_000e18);
        (PoolBalanceUpdate quoted,) = _quote(key, params);
        int128 out = tokenIs0 ? quoted.delta0() : quoted.delta1();
        uint64 feeRate = extension.feeAt(key.toPoolId());
        vm.recordLogs();
        _routerSwap(key, params, 1, RECIPIENT);
        (uint128 fee0, uint128 fee1) = _fees(key);
        uint128 fee = tokenIs0 ? fee0 : fee1;
        assertEq(fee, computeFee(uint128(-out) + fee, feeRate));

        bytes32 swapped = keccak256("LaunchSwapped(bytes32,address,int128,int128,uint128,bool)");
        uint256 count;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(extension) || logs[i].topics[0] != swapped) continue;
            count++;
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toPoolId()));
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(forwardingRouter));
            (int128 d0, int128 d1, uint128 feeAmount, bool feeIsToken1) =
                abi.decode(logs[i].data, (int128, int128, uint128, bool));
            assertEq(d0, quoted.delta0());
            assertEq(d1, quoted.delta1());
            assertEq(feeAmount, fee);
            assertEq(feeIsToken1, !tokenIs0);
        }
        assertEq(count, 1, "one LaunchSwapped per external swap");
    }

    function testFuzz_internalReleaseEmitsNoLaunchSwapped(bool tokenIs0) public {
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        _routerSwap(key, _buyParams(tokenIs0, 1_000e18), 1, RECIPIENT);
        vm.warp(START + 200);
        vm.recordLogs();
        extension.advance(key);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapped = keccak256("LaunchSwapped(bytes32,address,int128,int128,uint128,bool)");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != swapped);
        }
    }

    function testFuzz_routerQuoteMatchesSwap(bool tokenIs0, bool exactOut, uint96 amount) public {
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 300);
        amount = uint96(bound(amount, 1e12, 10_000e18));
        // Exact-out names the launch token output; exact-in names the quote input.
        SwapParameters params = exactOut
            ? createSwapParameters(
                tickToSqrtRatio(tokenIs0 ? int32(50_000) : int32(-50_000)),
                -int128(uint128(amount)) / 1000,
                !tokenIs0,
                0
            )
            : _buyParams(tokenIs0, int128(uint128(amount)));
        (PoolBalanceUpdate quoted, PoolState stateAfter) = _quote(key, params);
        PoolBalanceUpdate update = _routerSwap(key, params, type(int256).min + 1, RECIPIENT);
        assertEq(PoolBalanceUpdate.unwrap(update), PoolBalanceUpdate.unwrap(quoted));
        assertEq(PoolState.unwrap(core.poolState(key.toPoolId())), PoolState.unwrap(stateAfter));
    }

    function testFuzz_exactInputSlippageOnFeeInclusiveOutput(bool tokenIs0) public {
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        SwapParameters params = _buyParams(tokenIs0, 1_000e18);
        (PoolBalanceUpdate quoted,) = _quote(key, params);
        int256 out = -int256(tokenIs0 ? quoted.delta0() : quoted.delta1());
        vm.prank(PAYER);
        vm.expectRevert(abi.encodeWithSelector(BaseRouter.SlippageCheckFailed.selector, out + 1, out));
        forwardingRouter.swap(key, params, out + 1, RECIPIENT);
        _routerSwap(key, params, out, RECIPIENT);
    }

    function testFuzz_exactOutputSlippageOnFeeInclusiveInput(bool tokenIs0) public {
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        SwapParameters params = createSwapParameters(
            tickToSqrtRatio(tokenIs0 ? int32(50_000) : int32(-50_000)), -int128(100e18), !tokenIs0, 0
        );
        (PoolBalanceUpdate quoted,) = _quote(key, params);
        int256 maxIn = int256(tokenIs0 ? quoted.delta1() : quoted.delta0());
        // The fee is charged on the input side for exact output, so maxIn includes it.
        vm.prank(PAYER);
        vm.expectRevert(abi.encodeWithSelector(BaseRouter.SlippageCheckFailed.selector, -(maxIn - 1), -maxIn));
        forwardingRouter.swap(key, params, -(maxIn - 1), RECIPIENT);
        _routerSwap(key, params, -maxIn, RECIPIENT);
        assertEq(MintableERC20(tokenIs0 ? key.token0 : key.token1).balanceOf(RECIPIENT), 100e18);
        (uint128 fee0, uint128 fee1) = _fees(key);
        assertGt(tokenIs0 ? fee1 : fee0, 0);
    }

    function testFuzz_exactOutputMustFill(bool tokenIs0) public {
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        // Only 10% of supply is released; asking for more fills partially at the top of the range.
        SwapParameters params = createSwapParameters(SqrtRatio.wrap(0), -int128(SUPPLY / 5), !tokenIs0, 0);
        vm.prank(PAYER);
        vm.expectRevert(BaseRouter.PartialSwapsDisallowed.selector);
        forwardingRouter.swap(key, params, type(int256).min + 1, RECIPIENT);
    }

    /// A buy past the range top fills partially. Router.swap rejects it; swapAllowPartialFill settles the fill.
    function testFuzz_exactInputPartialFillStopsAtRangeTop(bool tokenIs0) public {
        (PoolKey memory key, address token) = _payerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        SwapParameters params = createSwapParameters(SqrtRatio.wrap(0), int128(900_000e18), tokenIs0, 0);
        vm.prank(PAYER);
        vm.expectRevert(BaseRouter.PartialSwapsDisallowed.selector);
        forwardingRouter.swap(key, params, 1, RECIPIENT);
        uint256 quoteBefore = TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER);
        vm.prank(PAYER);
        PoolBalanceUpdate update = forwardingRouter.swapAllowPartialFill(key, params, RECIPIENT);
        int128 paid = tokenIs0 ? update.delta1() : update.delta0();
        assertLt(paid, 900_000e18);
        assertEq(TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER), quoteBefore - uint128(paid));
        assertEq(
            SqrtRatio.unwrap(core.poolState(key.toPoolId()).sqrtRatio()),
            SqrtRatio.unwrap(tickToSqrtRatio(tokenIs0 ? int32(100_000) : int32(-100_000)))
        );
        (uint128 fee0, uint128 fee1) = _fees(key);
        assertLe(MintableERC20(token).balanceOf(RECIPIENT) + (tokenIs0 ? fee0 : fee1), SUPPLY / 10);
        _assertHoldsNothing(key);
    }

    function test_nativeQuoteBuyAndSell() public {
        (PoolKey memory key, address token) = _payerCreate(address(0), 0, 0);
        assertEq(key.token0, address(0));
        vm.warp(START + 100);
        SwapParameters buy = createSwapParameters(tickToSqrtRatio(-50_000), int128(2 ether), false, 0);
        (PoolBalanceUpdate quoted,) = _quote(key, buy);
        int256 out = -int256(quoted.delta1());
        uint256 ethBefore = PAYER.balance;
        vm.prank(PAYER);
        PoolBalanceUpdate update = forwardingRouter.swap{value: 2 ether}(key, buy, out, RECIPIENT);
        assertEq(update.delta0(), 2 ether);
        assertEq(PAYER.balance, ethBefore - 2 ether);
        assertEq(MintableERC20(token).balanceOf(RECIPIENT), uint256(out));
        _assertHoldsNothing(key);

        // Sell launch tokens for ETH to an explicit recipient.
        vm.prank(RECIPIENT);
        MintableERC20(token).transfer(PAYER, uint256(out));
        SwapParameters sell = createSwapParameters(SqrtRatio.wrap(0), int128(int256(out) / 2), true, 0);
        (quoted,) = _quote(key, sell);
        uint256 recipientEth = RECIPIENT.balance;
        _routerSwap(key, sell, -int256(quoted.delta0()), RECIPIENT);
        assertEq(RECIPIENT.balance - recipientEth, uint128(-quoted.delta0()));
        _assertHoldsNothing(key);
    }

    function test_nativeQuoteBuyRevertsWhenUnderpaid() public {
        (PoolKey memory key,) = _payerCreate(address(0), 0, 0);
        vm.warp(START + 100);
        SwapParameters buy = createSwapParameters(tickToSqrtRatio(-50_000), int128(2 ether), false, 0);
        vm.prank(PAYER);
        vm.expectRevert();
        forwardingRouter.swap{value: 1 ether}(key, buy, 1, RECIPIENT);
    }

    // ---------------------------------------------------------------------------------------------
    // Direct funding.
    // ---------------------------------------------------------------------------------------------

    function testFuzz_fundPaysFromSenderAndUnblocksMigration(bool tokenIs0) public {
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0), 0, 0, QUOTE_1E18_TICK);
        _finish(key);
        assertEq(_locked(key), 0);
        uint256 quoteBefore = TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER);
        (uint128 a0, uint128 a1) = (tokenIs0 ? 0 : 1e18, tokenIs0 ? 1e18 : 0);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrincipalReceived(key.toPoolId(), PAYER, a0, a1);
        vm.prank(PAYER);
        vault.fund(key.toPoolId(), a0, a1);
        assertEq(TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER), quoteBefore - 1e18);
        vault.migrate(key.toPoolId());
        assertGt(_locked(key), 0);
        _assertHoldsNothing(key);
    }

    function test_fundNativeRequiresExactValue() public {
        (PoolKey memory key,) = _payerCreate(address(0), 0, 0, QUOTE_1E18_TICK);
        _finish(key);
        PoolId id = key.toPoolId();
        vm.startPrank(PAYER);
        vm.expectRevert(LockedLaunchLiquidity.InvalidPayment.selector);
        vault.fund{value: 1 ether - 1}(id, 1 ether, 0);
        vm.expectRevert(LockedLaunchLiquidity.InvalidPayment.selector);
        vault.fund{value: 1}(id, 0, 1e18);
        uint256 before = PAYER.balance;
        vault.fund{value: 1 ether}(id, 1 ether, 0);
        vm.stopPrank();
        assertEq(PAYER.balance, before - 1 ether);
        (uint128 v0,) = _balances(address(vault), key, PoolId.unwrap(id));
        assertEq(v0, 1 ether);
        vault.migrate(id);
        assertGt(_locked(key), 0);
        _assertHoldsNothing(key);
    }

    function testFuzz_fundRequiresMigratedLaunch(bool tokenIs0) public {
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.prank(PAYER);
        vm.expectRevert(LockedLaunchLiquidity.UnknownLaunch.selector);
        vault.fund(key.toPoolId(), 1e18, 1e18);
    }
}
