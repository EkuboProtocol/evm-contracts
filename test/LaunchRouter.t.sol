// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Vm} from "forge-std/Vm.sol";
import {ScheduledLaunchTest} from "./extensions/ScheduledLaunch.t.sol";
import {TestToken} from "./TestToken.sol";
import {LaunchRouter} from "../src/LaunchRouter.sol";
import {ScheduledLaunch} from "../src/extensions/ScheduledLaunch.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "../src/types/swapParameters.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {computeFee} from "../src/math/fee.sol";

contract LaunchRouterTest is ScheduledLaunchTest {
    using CoreLib for *;

    LaunchRouter launchRouter;
    address constant PAYER = address(0xCAFE);
    address constant RECIPIENT = address(0xBEEF);
    address constant OWNER = address(0xFA11005);

    event LaunchRouted(PoolId indexed poolId, address indexed payer, address indexed recipient);
    event LaunchSwapped(
        PoolId indexed poolId, address indexed locker, int128 delta0, int128 delta1, uint128 feeAmount, bool feeIsToken1
    );

    function setUp() public virtual override {
        super.setUp();
        launchRouter = new LaunchRouter(core, extension);
        _fundPayer(LOW_QUOTE);
        _fundPayer(HIGH_QUOTE);
        vm.deal(PAYER, 1_000 ether);
    }

    function _fundPayer(address token) internal {
        TestToken(token).transfer(PAYER, 1_000_000e18);
        vm.prank(PAYER);
        TestToken(token).approve(address(launchRouter), type(uint256).max);
    }

    function _quoteToken(bool tokenIs0) internal pure returns (address) {
        return tokenIs0 ? HIGH_QUOTE : LOW_QUOTE;
    }

    function _routerCreate(address quote, uint128 quoteAmount, uint256 value)
        internal
        returns (PoolKey memory key, address token)
    {
        ScheduledLaunch.LaunchConfig memory config = _config(quote);
        config.owner = OWNER;
        config.quoteAmount = quoteAmount;
        vm.prank(PAYER);
        (key, token) = launchRouter.create{value: value}(config, block.timestamp);
        vm.prank(PAYER);
        MintableERC20(token).approve(address(launchRouter), type(uint256).max);
    }

    function _buyParams(bool tokenIs0, int128 amount) internal pure returns (SwapParameters) {
        // Exact input of the quote token; the price limit sits inside the launch range.
        return createSwapParameters(tickToSqrtRatio(tokenIs0 ? int32(50_000) : int32(-50_000)), amount, tokenIs0, 0);
    }

    function _assertRouterEmpty(PoolKey memory key) internal view {
        assertEq(address(launchRouter).balance, 0, "router ETH");
        if (key.token0 != address(0)) assertEq(MintableERC20(key.token0).balanceOf(address(launchRouter)), 0);
        assertEq(MintableERC20(key.token1).balanceOf(address(launchRouter)), 0);
    }

    function testFuzz_createRecordsPayerAndBeneficiary(bool tokenIs0) public {
        uint256 quoteBefore = TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER);
        ScheduledLaunch.LaunchConfig memory config = _config(_quoteToken(tokenIs0));
        config.owner = OWNER;
        config.quoteAmount = 7e18;
        vm.expectEmit(false, true, true, false, address(launchRouter));
        emit LaunchRouted(PoolId.wrap(0), PAYER, OWNER);
        vm.prank(PAYER);
        (PoolKey memory key, address token) = launchRouter.create(config, block.timestamp);
        assertEq(token, extension.getLaunch(key.toPoolId()).token);
        assertEq(token == key.token0, tokenIs0);
        assertEq(extension.getLaunch(key.toPoolId()).owner, OWNER);
        assertEq(TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER), quoteBefore - 7e18);
        (uint128 r0, uint128 r1) = _balances(address(extension), key, PoolId.unwrap(key.toPoolId()));
        assertEq(tokenIs0 ? r1 : r0, 7e18);
        _assertRouterEmpty(key);
    }

    function test_createNativeQuoteRefundsSurplus() public {
        uint256 before = PAYER.balance;
        (PoolKey memory key,) = _routerCreate(address(0), 1 ether, 3 ether);
        assertEq(PAYER.balance, before - 1 ether);
        assertEq(key.token0, address(0));
        (uint128 r0, uint128 r1) = _balances(address(extension), key, PoolId.unwrap(key.toPoolId()));
        assertEq(r0, 1 ether);
        assertEq(r1, SUPPLY);
        _assertRouterEmpty(key);
    }

    function testFuzz_swapPaysFromSenderAndDeliversToRecipient(bool tokenIs0) public {
        (PoolKey memory key, address token) = _routerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        SwapParameters params = _buyParams(tokenIs0, 1_000e18);
        uint256 quoteBefore = TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER);

        vm.expectEmit(true, true, true, true, address(launchRouter));
        emit LaunchRouted(key.toPoolId(), PAYER, RECIPIENT);
        vm.prank(PAYER);
        PoolBalanceUpdate update = launchRouter.swap(key, params, 1, RECIPIENT, block.timestamp);

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
        _assertRouterEmpty(key);
    }

    function testFuzz_launchSwappedCarriesLockerAndFee(bool tokenIs0) public {
        (PoolKey memory key,) = _routerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        SwapParameters params = _buyParams(tokenIs0, 1_000e18);
        (PoolBalanceUpdate quoted,) = launchRouter.quote(key, params);
        int128 out = tokenIs0 ? quoted.delta0() : quoted.delta1();
        uint64 feeRate = extension.feeAt(key.toPoolId());
        // Gross output g satisfies g - computeFee(g) == -out; recover the fee from the ledger after.
        vm.recordLogs();
        vm.prank(PAYER);
        launchRouter.swap(key, params, 1, RECIPIENT, block.timestamp);
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
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(launchRouter));
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
        (PoolKey memory key,) = _routerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        vm.prank(PAYER);
        launchRouter.swap(key, _buyParams(tokenIs0, 1_000e18), 1, RECIPIENT, block.timestamp);
        vm.warp(START + 200);
        vm.recordLogs();
        extension.advance(key);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 swapped = keccak256("LaunchSwapped(bytes32,address,int128,int128,uint128,bool)");
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != swapped);
        }
    }

    function testFuzz_quoteMatchesSwap(bool tokenIs0, bool exactOut, uint96 amount) public {
        (PoolKey memory key,) = _routerCreate(_quoteToken(tokenIs0), 0, 0);
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
        (PoolBalanceUpdate quoted, uint64 fee) = launchRouter.quote(key, params);
        assertEq(fee, extension.feeAt(key.toPoolId()));
        vm.prank(PAYER);
        PoolBalanceUpdate update = launchRouter.swap(key, params, type(int256).min + 1, RECIPIENT, block.timestamp);
        assertEq(PoolBalanceUpdate.unwrap(update), PoolBalanceUpdate.unwrap(quoted));
    }

    function testFuzz_exactInputSlippageOnFeeInclusiveOutput(bool tokenIs0) public {
        (PoolKey memory key,) = _routerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        SwapParameters params = _buyParams(tokenIs0, 1_000e18);
        (PoolBalanceUpdate quoted,) = launchRouter.quote(key, params);
        int256 out = -int256(tokenIs0 ? quoted.delta0() : quoted.delta1());
        vm.prank(PAYER);
        vm.expectRevert(abi.encodeWithSelector(LaunchRouter.SlippageCheckFailed.selector, out + 1, out));
        launchRouter.swap(key, params, out + 1, RECIPIENT, block.timestamp);
        vm.prank(PAYER);
        launchRouter.swap(key, params, out, RECIPIENT, block.timestamp);
    }

    function testFuzz_exactOutputSlippageOnFeeInclusiveInput(bool tokenIs0) public {
        (PoolKey memory key,) = _routerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        SwapParameters params = createSwapParameters(
            tickToSqrtRatio(tokenIs0 ? int32(50_000) : int32(-50_000)), -int128(100e18), !tokenIs0, 0
        );
        (PoolBalanceUpdate quoted,) = launchRouter.quote(key, params);
        int256 maxIn = int256(tokenIs0 ? quoted.delta1() : quoted.delta0());
        // The fee is charged on the input side for exact output, so maxIn includes it.
        (uint128 feeBefore0, uint128 feeBefore1) = _fees(key);
        assertEq(feeBefore0 + feeBefore1, 0);
        vm.prank(PAYER);
        vm.expectRevert(abi.encodeWithSelector(LaunchRouter.SlippageCheckFailed.selector, -(maxIn - 1), -maxIn));
        launchRouter.swap(key, params, -(maxIn - 1), RECIPIENT, block.timestamp);
        vm.prank(PAYER);
        launchRouter.swap(key, params, -maxIn, RECIPIENT, block.timestamp);
        assertEq(MintableERC20(tokenIs0 ? key.token0 : key.token1).balanceOf(RECIPIENT), 100e18);
        (uint128 fee0, uint128 fee1) = _fees(key);
        assertGt(tokenIs0 ? fee1 : fee0, 0);
    }

    function testFuzz_exactOutputMustFill(bool tokenIs0) public {
        (PoolKey memory key,) = _routerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        // Only 10% of supply is released; asking for more fills partially at the top of the range.
        SwapParameters params = createSwapParameters(SqrtRatio.wrap(0), -int128(SUPPLY / 5), !tokenIs0, 0);
        vm.prank(PAYER);
        vm.expectRevert(LaunchRouter.PartialSwapsDisallowed.selector);
        launchRouter.swap(key, params, type(int256).min + 1, RECIPIENT, block.timestamp);
    }

    function testFuzz_exactInputPartialFillStopsAtRangeTop(bool tokenIs0) public {
        (PoolKey memory key, address token) = _routerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        SwapParameters params = createSwapParameters(SqrtRatio.wrap(0), int128(900_000e18), tokenIs0, 0);
        vm.prank(PAYER);
        PoolBalanceUpdate update = launchRouter.swap(key, params, 1, RECIPIENT, block.timestamp);
        int128 paid = tokenIs0 ? update.delta1() : update.delta0();
        assertLt(paid, 900_000e18);
        assertEq(
            SqrtRatio.unwrap(core.poolState(key.toPoolId()).sqrtRatio()),
            SqrtRatio.unwrap(tickToSqrtRatio(tokenIs0 ? int32(100_000) : int32(-100_000)))
        );
        (uint128 fee0, uint128 fee1) = _fees(key);
        assertLe(MintableERC20(token).balanceOf(RECIPIENT) + (tokenIs0 ? fee0 : fee1), SUPPLY / 10);
    }

    function test_nativeQuoteBuyAndSellRefundsSurplus() public {
        (PoolKey memory key, address token) = _routerCreate(address(0), 0, 0);
        assertEq(key.token0, address(0));
        vm.warp(START + 100);
        SwapParameters buy = createSwapParameters(tickToSqrtRatio(-50_000), int128(2 ether), false, 0);
        (PoolBalanceUpdate quoted, uint64 fee) = launchRouter.quote(key, buy);
        assertEq(fee, extension.feeAt(key.toPoolId()));
        int256 out = -int256(quoted.delta1());
        uint256 ethBefore = PAYER.balance;
        vm.prank(PAYER);
        PoolBalanceUpdate update = launchRouter.swap{value: 5 ether}(key, buy, out, RECIPIENT, block.timestamp);
        assertEq(update.delta0(), 2 ether);
        assertEq(PAYER.balance, ethBefore - 2 ether, "surplus refunded");
        assertEq(MintableERC20(token).balanceOf(RECIPIENT), uint256(out));
        _assertRouterEmpty(key);

        // Sell launch tokens for ETH to an explicit recipient.
        vm.prank(RECIPIENT);
        MintableERC20(token).transfer(PAYER, uint256(out));
        SwapParameters sell = createSwapParameters(SqrtRatio.wrap(0), int128(int256(out) / 2), true, 0);
        (quoted,) = launchRouter.quote(key, sell);
        uint256 recipientEth = RECIPIENT.balance;
        vm.prank(PAYER);
        launchRouter.swap(key, sell, -int256(quoted.delta0()), RECIPIENT, block.timestamp);
        assertEq(RECIPIENT.balance - recipientEth, uint128(-quoted.delta0()));
        _assertRouterEmpty(key);
    }

    function test_nativeQuoteBuyRevertsWhenUnderpaid() public {
        (PoolKey memory key,) = _routerCreate(address(0), 0, 0);
        vm.warp(START + 100);
        SwapParameters buy = createSwapParameters(tickToSqrtRatio(-50_000), int128(2 ether), false, 0);
        vm.prank(PAYER);
        vm.expectRevert();
        launchRouter.swap{value: 1 ether}(key, buy, 1, RECIPIENT, block.timestamp);
    }

    function testFuzz_deadlineRejected(bool tokenIs0) public {
        (PoolKey memory key,) = _routerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        uint256 deadline = block.timestamp - 1;
        vm.startPrank(PAYER);
        vm.expectRevert(abi.encodeWithSelector(LaunchRouter.DeadlineExpired.selector, deadline));
        launchRouter.swap(key, _buyParams(tokenIs0, 1e18), 1, RECIPIENT, deadline);
        ScheduledLaunch.LaunchConfig memory config = _config(_quoteToken(tokenIs0));
        config.startTime = uint64(block.timestamp + 10);
        config.endTime = uint64(block.timestamp + 1000);
        vm.expectRevert(abi.encodeWithSelector(LaunchRouter.DeadlineExpired.selector, deadline));
        launchRouter.create(config, deadline);
        vm.expectRevert(abi.encodeWithSelector(LaunchRouter.DeadlineExpired.selector, deadline));
        launchRouter.fund(key.toPoolId(), 0, 1, deadline);
        vm.stopPrank();
    }

    function testFuzz_zeroRecipientRejected(bool tokenIs0) public {
        (PoolKey memory key,) = _routerCreate(_quoteToken(tokenIs0), 0, 0);
        vm.warp(START + 100);
        vm.prank(PAYER);
        vm.expectRevert(LaunchRouter.InvalidRecipient.selector);
        launchRouter.swap(key, _buyParams(tokenIs0, 1e18), 1, address(0), block.timestamp);
    }

    function testFuzz_fundUnblocksMigration(bool tokenIs0) public {
        (PoolKey memory key,) = _routerCreate(_quoteToken(tokenIs0), 0, 0);
        _finish(key);
        assertEq(_locked(key), 0);
        uint256 quoteBefore = TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER);
        vm.expectEmit(true, true, true, true, address(launchRouter));
        emit LaunchRouted(key.toPoolId(), PAYER, address(vault));
        vm.prank(PAYER);
        launchRouter.fund(key.toPoolId(), tokenIs0 ? 0 : 1e18, tokenIs0 ? 1e18 : 0, block.timestamp);
        assertEq(TestToken(_quoteToken(tokenIs0)).balanceOf(PAYER), quoteBefore - 1e18);
        vault.migrate(key.toPoolId());
        assertGt(_locked(key), 0);
        _assertRouterEmpty(key);
    }
}
