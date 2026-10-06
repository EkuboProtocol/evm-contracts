// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// Launch entry points. Every token-moving action is a Core.forward settled by the forwarding locker: create,
// fund and fee claims through LaunchRouter or any locker's own forwards, and swaps through the unmodified
// Router's forwarded path with the standard payload. Neither launch contract ever holds tokens.

import {Vm} from "forge-std/Vm.sol";
import {ScheduledLaunchTest} from "./extensions/ScheduledLaunch.t.sol";
import {TestToken} from "./TestToken.sol";
import {ScheduledLaunch} from "../src/extensions/ScheduledLaunch.sol";
import {LockedLaunchLiquidity} from "../src/LockedLaunchLiquidity.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {IFlashAccountant} from "../src/interfaces/IFlashAccountant.sol";
import {LAUNCH_CREATE, LAUNCH_FUND, LAUNCH_CLAIM_FEES} from "../src/interfaces/extensions/IScheduledLaunch.sol";
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

/// @dev A contract that is its own launch owner: creates by a direct LAUNCH_CREATE forward and claims both fee
/// ledgers by its own forwards, withdrawing to a recipient.
contract SelfOwnedLauncher is BaseLocker {
    using FlashAccountantLib for *;

    ScheduledLaunch immutable EXTENSION;

    constructor(ICore core, ScheduledLaunch extension) BaseLocker(core) {
        EXTENSION = extension;
    }

    function create(ScheduledLaunch.LaunchConfig memory config) external returns (PoolKey memory key, address token) {
        config.owner = address(this);
        (key, token) = abi.decode(lock(abi.encode(true, abi.encode(config))), (PoolKey, address));
    }

    function claim(PoolKey memory key, bool locked, address recipient) external returns (uint128, uint128) {
        return abi.decode(lock(abi.encode(false, abi.encode(key, locked, recipient))), (uint128, uint128));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (bool isCreate, bytes memory args) = abi.decode(data, (bool, bytes));
        if (isCreate) {
            return ACCOUNTANT.forward(
                address(EXTENSION), abi.encode(LAUNCH_CREATE, abi.decode(args, (ScheduledLaunch.LaunchConfig)))
            );
        }
        (PoolKey memory key, bool locked, address recipient) = abi.decode(args, (PoolKey, bool, address));
        (uint128 a0, uint128 a1) = abi.decode(
            ACCOUNTANT.forward(address(EXTENSION), abi.encode(LAUNCH_CLAIM_FEES, key, recipient)), (uint128, uint128)
        );
        if (locked) {
            (uint128 b0, uint128 b1) = abi.decode(
                ACCOUNTANT.forward(
                    address(EXTENSION.LIQUIDITY()), abi.encode(LAUNCH_CLAIM_FEES, key.toPoolId(), recipient)
                ),
                (uint128, uint128)
            );
            (a0, a1) = (a0 + b0, a1 + b1);
        }
        ACCOUNTANT.withdrawTwo(key.token0, key.token1, recipient, a0, a1);
        return abi.encode(a0, a1);
    }
}

contract LaunchEntryPointsTest is ScheduledLaunchTest {
    using CoreLib for *;

    address constant PAYER = address(0xCAFE);
    address constant RECIPIENT = address(0xBEEF);
    address constant OWNER = address(0xFA11005);

    event LaunchCreated(
        PoolId indexed poolId, address indexed token, address indexed owner, ScheduledLaunch.LaunchConfig config
    );
    event LaunchCreatedBy(PoolId indexed launchId, address indexed creator);
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
        MintableERC20(token).approve(address(launchRouter), type(uint256).max);
        MintableERC20(token).approve(address(forwardingRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _quoteToken(bool tokenIs0) internal pure returns (address) {
        return tokenIs0 ? HIGH_QUOTE : LOW_QUOTE;
    }

    function _payerConfig(address quote, int32 migrationTick)
        internal
        view
        returns (ScheduledLaunch.LaunchConfig memory config)
    {
        config = _migrateNear(_config(quote), migrationTick);
    }

    function _payerCreate(address quote) internal returns (PoolKey memory key, address token) {
        return _payerCreate(quote, 0);
    }

    /// @dev PAYER creates through LaunchRouter and so is the launch's creator.
    function _payerCreate(address quote, int32 migrationTick) internal returns (PoolKey memory key, address token) {
        vm.prank(PAYER);
        (key, token) = launchRouter.create(_payerConfig(quote, migrationTick));
        _track(token);
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
        address[4] memory holders =
            [address(extension), address(vault), address(launchRouter), address(forwardingRouter)];
        for (uint256 h; h < holders.length; h++) {
            assertEq(holders[h].balance, 0, "holds ETH");
            for (uint256 i; i < 2; i++) {
                address token = i == 0 ? key.token0 : key.token1;
                if (token != address(0)) assertEq(MintableERC20(token).balanceOf(holders[h]), 0, "holds token");
            }
        }
        _assertNoCustody();
    }

    // ---------------------------------------------------------------------------------------------
    // Creation through LaunchRouter and direct forwards.
    // ---------------------------------------------------------------------------------------------

    /// Creation takes no payment and no allowance: the supply is minted to Core and saved in one forward.
    function testFuzz_routerCreateRecordsRouterOwnerAndCreator(bool tokenIs0) public {
        address quote = _quoteToken(tokenIs0);
        vm.startPrank(PAYER);
        TestToken(quote).approve(address(launchRouter), 0);
        vm.stopPrank();
        uint256 quoteBefore = TestToken(quote).balanceOf(PAYER);
        uint256 coreBefore = TestToken(quote).balanceOf(address(core));
        ScheduledLaunch.LaunchConfig memory config = _payerConfig(quote, 0);
        config.owner = OWNER;
        ScheduledLaunch.LaunchConfig memory recorded = _payerConfig(quote, 0);
        recorded.owner = address(launchRouter);
        vm.expectEmit(false, false, true, true, address(extension));
        emit LaunchCreated(PoolId.wrap(0), address(0), address(launchRouter), recorded);
        vm.prank(PAYER);
        (PoolKey memory key, address token) = launchRouter.create(config);
        _track(token);
        assertEq(token, extension.getLaunch(key.toPoolId()).token);
        assertEq(token == key.token0, tokenIs0);
        assertEq(extension.getLaunch(key.toPoolId()).owner, address(launchRouter));
        assertEq(launchRouter.creator(key.toPoolId()), PAYER);
        assertEq(TestToken(quote).balanceOf(PAYER), quoteBefore);
        assertEq(TestToken(quote).balanceOf(address(core)), coreBefore);
        assertEq(MintableERC20(token).balanceOf(address(core)), SUPPLY);
        (uint128 r0, uint128 r1) = _balances(address(extension), key, PoolId.unwrap(key.toPoolId()));
        assertEq(tokenIs0 ? r1 : r0, 0);
        assertEq(tokenIs0 ? r0 : r1, SUPPLY);
        _assertHoldsNothing(key);
    }

    function test_routerCreateEmitsCreator() public {
        vm.expectEmit(false, true, false, false, address(launchRouter));
        emit LaunchCreatedBy(PoolId.wrap(0), PAYER);
        _payerCreate(LOW_QUOTE);
    }

    /// Native quote launches create without value; create is not payable.
    function test_nativeQuoteCreateTakesNoValue() public {
        uint256 before = PAYER.balance;
        (PoolKey memory key,) = _payerCreate(address(0));
        assertEq(PAYER.balance, before);
        assertEq(key.token0, address(0));
        (uint128 r0, uint128 r1) = _balances(address(extension), key, PoolId.unwrap(key.toPoolId()));
        assertEq(r0, 0);
        assertEq(r1, SUPPLY);
        vm.prank(PAYER);
        (bool ok,) =
            address(launchRouter).call{value: 1}(abi.encodeCall(LaunchRouter.create, (_payerConfig(address(0), 0))));
        assertFalse(ok);
        _assertHoldsNothing(key);
    }

    /// A contract that is its own owner creates by a direct LAUNCH_CREATE forward and claims both fee ledgers
    /// by its own forwards. LaunchRouter has no claim on it.
    function testFuzz_selfOwnedForwardCreateClaimsFees(bool tokenIs0) public {
        SelfOwnedLauncher launcher = new SelfOwnedLauncher(core, extension);
        ScheduledLaunch.LaunchConfig memory config = _payerConfig(_quoteToken(tokenIs0), SMALL_BUY_TICK);
        (PoolKey memory key, address token) = launcher.create(config);
        _track(token);
        _approvePayer(token);
        assertEq(extension.getLaunch(key.toPoolId()).owner, address(launcher));
        assertEq(launchRouter.creator(key.toPoolId()), address(0));
        vm.warp(START + 100);
        _routerSwap(key, _buyParams(tokenIs0, 10_000e18), 1, PAYER);
        (uint128 fee0, uint128 fee1) = _fees(key);
        assertGt(tokenIs0 ? fee0 : fee1, 0);
        vm.expectRevert(LaunchRouter.CreatorOnly.selector);
        launchRouter.claimFees(key, RECIPIENT);
        (uint128 a0, uint128 a1) = launcher.claim(key, false, RECIPIENT);
        assertEq(a0, fee0);
        assertEq(a1, fee1);
        assertEq(MintableERC20(token).balanceOf(RECIPIENT), tokenIs0 ? fee0 : fee1);
        _finish(key);
        assertGt(_locked(key), 0);
        assertEq(vault.getTerminal(key.toPoolId()).owner, address(launcher));
        router.swapAllowPartialFill(extension.terminalPool(key), tokenIs0, int128(100e18), SqrtRatio.wrap(0), 0);
        uint256 before = TestToken(_quoteToken(tokenIs0)).balanceOf(RECIPIENT);
        (a0, a1) = launcher.claim(key, true, RECIPIENT);
        assertGt(tokenIs0 ? a1 : a0, 0);
        assertEq(TestToken(_quoteToken(tokenIs0)).balanceOf(RECIPIENT) - before, tokenIs0 ? a1 : a0);
        _assertHoldsNothing(key);
    }

    /// Fee claims are owner-forward only on both contracts; fund leaves its debt with the forwarding locker;
    /// principal registration is extension-only; the pre-revision uint8-tagged creation payload is rejected.
    function testFuzz_forwardDispatch(bool tokenIs0) public {
        RawForwarder forwarder = new RawForwarder(core);
        vm.expectRevert();
        forwarder.forward(address(extension), abi.encode(uint8(0), _config(_quoteToken(tokenIs0))));
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0), QUOTE_1E18_TICK);
        vm.expectRevert(ScheduledLaunch.OwnerOnly.selector);
        forwarder.forward(address(extension), abi.encode(LAUNCH_CLAIM_FEES, key, address(forwarder)));
        vm.expectRevert(LockedLaunchLiquidity.UnknownLaunch.selector);
        forwarder.forward(address(vault), abi.encode(LAUNCH_FUND, key.toPoolId(), uint128(1), uint128(0)));
        _finish(key);
        vm.expectRevert(LockedLaunchLiquidity.OwnerOnly.selector);
        forwarder.forward(address(vault), abi.encode(LAUNCH_CLAIM_FEES, key.toPoolId(), address(forwarder)));
        // The forwarder settles nothing, so the saved principal is its unpaid debt.
        vm.expectRevert(abi.encodeWithSelector(IFlashAccountant.DebtsNotZeroed.selector, 0));
        forwarder.forward(address(vault), abi.encode(LAUNCH_FUND, key.toPoolId(), uint128(1), uint128(1)));
        bytes memory registration = abi.encode(
            LockedLaunchLiquidity.Registration(
                key.toPoolId(), OWNER, extension.terminalPool(key), SqrtRatio.wrap(0), SqrtRatio.wrap(0), 0, 0
            )
        );
        vm.expectRevert(LockedLaunchLiquidity.ExtensionOnly.selector);
        forwarder.forward(address(vault), registration);
        _assertHoldsNothing(key);
    }

    /// A direct LAUNCH_CREATE forward nets to zero debt for the forwarding locker, whatever owner it names.
    function testFuzz_directCreateForwardSettlesNothing(bool tokenIs0) public {
        RawForwarder forwarder = new RawForwarder(core);
        ScheduledLaunch.LaunchConfig memory config = _config(_quoteToken(tokenIs0));
        config.owner = OWNER;
        (PoolKey memory key, address token) =
            abi.decode(forwarder.forward(address(extension), abi.encode(LAUNCH_CREATE, config)), (PoolKey, address));
        _track(token);
        assertEq(extension.getLaunch(key.toPoolId()).owner, OWNER);
        assertEq(MintableERC20(token).balanceOf(address(core)), SUPPLY);
        assertEq(MintableERC20(token).balanceOf(address(forwarder)), 0);
        _assertHoldsNothing(key);
    }

    // ---------------------------------------------------------------------------------------------
    // Swaps through the unmodified Router and a generic forwarded hop.
    // ---------------------------------------------------------------------------------------------

    function testFuzz_routerSwapPaysFromSenderAndDeliversToRecipient(bool tokenIs0) public {
        (PoolKey memory key, address token) = _payerCreate(_quoteToken(tokenIs0));
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
        (PoolKey memory key, address token) = _payerCreate(_quoteToken(tokenIs0));
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
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0));
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
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0));
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
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0));
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
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0));
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
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0));
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
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0));
        vm.warp(START + 100);
        // Only 10% of supply is released; asking for more fills partially at the top of the range.
        SwapParameters params = createSwapParameters(SqrtRatio.wrap(0), -int128(SUPPLY / 5), !tokenIs0, 0);
        vm.prank(PAYER);
        vm.expectRevert(BaseRouter.PartialSwapsDisallowed.selector);
        forwardingRouter.swap(key, params, type(int256).min + 1, RECIPIENT);
    }

    /// A buy past the range top fills partially. Router.swap rejects it; swapAllowPartialFill settles the fill.
    function testFuzz_exactInputPartialFillStopsAtRangeTop(bool tokenIs0) public {
        (PoolKey memory key, address token) = _payerCreate(_quoteToken(tokenIs0));
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
        (PoolKey memory key, address token) = _payerCreate(address(0));
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
        (PoolKey memory key,) = _payerCreate(address(0));
        vm.warp(START + 100);
        SwapParameters buy = createSwapParameters(tickToSqrtRatio(-50_000), int128(2 ether), false, 0);
        vm.prank(PAYER);
        vm.expectRevert();
        forwardingRouter.swap{value: 1 ether}(key, buy, 1, RECIPIENT);
    }

    // ---------------------------------------------------------------------------------------------
    // Funding and fee claims through LaunchRouter.
    // ---------------------------------------------------------------------------------------------

    function testFuzz_fundPaysFromSenderAndUnblocksMigration(bool tokenIs0) public {
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0), QUOTE_1E18_TICK);
        _finish(key);
        assertEq(_locked(key), 0);
        uint256 quoteBefore = TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER);
        (uint128 a0, uint128 a1) = (tokenIs0 ? 0 : 1e18, tokenIs0 ? 1e18 : 0);
        vm.expectEmit(true, true, true, true, address(vault));
        emit PrincipalReceived(key.toPoolId(), address(launchRouter), a0, a1);
        vm.prank(PAYER);
        launchRouter.fund(key.toPoolId(), a0, a1);
        assertEq(TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER), quoteBefore - 1e18);
        vault.migrate(key.toPoolId());
        assertGt(_locked(key), 0);
        _assertHoldsNothing(key);
    }

    function test_fundNativeRequiresExactValue() public {
        (PoolKey memory key,) = _payerCreate(address(0), QUOTE_1E18_TICK);
        _finish(key);
        PoolId id = key.toPoolId();
        vm.startPrank(PAYER);
        vm.expectRevert(LaunchRouter.InvalidPayment.selector);
        launchRouter.fund{value: 1 ether - 1}(id, 1 ether, 0);
        vm.expectRevert(LaunchRouter.InvalidPayment.selector);
        launchRouter.fund{value: 1 ether + 1}(id, 1 ether, 0);
        vm.expectRevert(LaunchRouter.InvalidPayment.selector);
        launchRouter.fund{value: 1}(id, 0, 1e18);
        uint256 before = PAYER.balance;
        launchRouter.fund{value: 1 ether}(id, 1 ether, 0);
        vm.stopPrank();
        assertEq(PAYER.balance, before - 1 ether);
        (uint128 v0,) = _balances(address(vault), key, PoolId.unwrap(id));
        assertEq(v0, 1 ether);
        vault.migrate(id);
        assertGt(_locked(key), 0);
        _assertHoldsNothing(key);
    }

    function testFuzz_fundErc20RejectsValue(bool tokenIs0) public {
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0), QUOTE_1E18_TICK);
        _finish(key);
        vm.prank(PAYER);
        vm.expectRevert(LaunchRouter.InvalidPayment.selector);
        launchRouter.fund{value: 1}(key.toPoolId(), tokenIs0 ? 0 : 1e18, tokenIs0 ? 1e18 : 0);
        _assertHoldsNothing(key);
    }

    function testFuzz_fundRequiresMigratedLaunch(bool tokenIs0) public {
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0));
        vm.prank(PAYER);
        vm.expectRevert(LockedLaunchLiquidity.UnknownLaunch.selector);
        launchRouter.fund(key.toPoolId(), 1e18, 1e18);
    }

    function testFuzz_nonCreatorClaimFeesReverts(bool tokenIs0) public {
        (PoolKey memory key,) = _payerCreate(_quoteToken(tokenIs0));
        vm.warp(START + 100);
        _routerSwap(key, _buyParams(tokenIs0, 1_000e18), 1, RECIPIENT);
        address[3] memory others = [OWNER, address(this), RECIPIENT];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(LaunchRouter.CreatorOnly.selector);
            launchRouter.claimFees(key, others[i]);
        }
        vm.prank(PAYER);
        vm.expectRevert(LaunchRouter.InvalidRecipient.selector);
        launchRouter.claimFees(key, address(0));
        (uint128 fee0, uint128 fee1) = _fees(key);
        vm.prank(PAYER);
        (uint128 a0, uint128 a1) = launchRouter.claimFees(key, RECIPIENT);
        assertEq(a0, fee0);
        assertEq(a1, fee1);
        _assertHoldsNothing(key);
    }
}
