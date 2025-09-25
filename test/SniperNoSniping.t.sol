// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.30;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {BaseOrdersTest} from "./Orders.t.sol";
import {createPositionId} from "../src/types/positionId.sol";
import {Delta, RouteNode} from "../src/Router.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS, MAX_TICK_SPACING} from "../src/math/constants.sol";
import {MAX_SQRT_RATIO} from "../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {OrderKey} from "../src/types/orderKey.sol";
import {
    getNextLaunchTime,
    SniperNoSniping,
    sniperNoSnipingCallPoints,
    roundDownToNearest
} from "../src/SniperNoSniping.sol";
import {SimpleToken} from "../src/SimpleToken.sol";
import {computeFee} from "../src/math/fee.sol";
import {isTimeValid} from "../src/math/time.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";

contract SniperNoSnipingTest is BaseOrdersTest {
    using CoreLib for *;

    SniperNoSniping snos;

    function setUp() public virtual override {
        BaseOrdersTest.setUp();
        address deployAddress = address(uint160(sniperNoSnipingCallPoints().toUint8()) << 152);
        uint256 orderDurationMagnitude = 4;
        uint128 tokenTotalSupply = 1_000_000e18;
        uint64 poolFee = uint64((uint256(1) << 64) / 100);
        uint32 tickSpacing = 1000;
        deployCodeTo(
            "SniperNoSniping.sol",
            abi.encode(core, twamm, orderDurationMagnitude, tokenTotalSupply, poolFee, tickSpacing),
            deployAddress
        );
        snos = SniperNoSniping(payable(deployAddress));
    }

    function test_get_next_launch_time_invariants(uint256 orderDurationMagnitude, uint256 time) public {
        uint256 orderDuration = 16 ** bound(orderDurationMagnitude, 1, 6);
        uint256 minLeadTime = orderDuration / 2;

        time = bound(time, 0, type(uint256).max - type(uint32).max);

        vm.warp(time);

        (uint256 startTime, uint256 endTime) = getNextLaunchTime(orderDuration, minLeadTime);

        assertNotEq(startTime, 0);
        assertNotEq(endTime, 0);
        assertGt(endTime, startTime);

        assertGe(startTime, time + minLeadTime);
        assertLe(startTime, time + minLeadTime + orderDuration);
        assertEq(endTime - startTime, orderDuration, "order duration is exact");
        assertTrue(isTimeValid(time, startTime), "start time is valid");
        assertTrue(isTimeValid(time, endTime), "end time is valid");
    }

    function test_launch_gas() public {
        snos.launch({creator: address(this), salt: bytes32(0), symbol: "ABC", name: "ABC Token"});
        vm.snapshotGasLastCall("SniperNoSniping#launch");
    }

    // function test_launch_create_order_gas() public {
    //     snos.launch{value: 100}({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});
    //     vm.snapshotGasLastCall("SniperNoSniping#launch_with_buy");
    // }

    // function test_launch_no_bid() public {
    //     vm.expectEmit(address(snos));
    //     emit SniperNoSniping.Launched(
    //         snos.getExpectedTokenAddress(address(this), bytes32(0), "ABC", "ABC Token"),
    //         address(this),
    //         4096,
    //         8192,
    //         "ABC",
    //         "ABC Token"
    //     );
    //     SimpleToken token = snos.launch({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});

    //     assertEq(token.symbol(), "ABC");
    //     assertEq(token.name(), "ABC Token");

    //     (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) =
    //         core.poolState(snos.getLaunchPool(token).toPoolId()).parse();
    //     assertEq(sqrtRatio.toFixed(), 1 << 128);
    //     assertEq(tick, 0);
    //     assertEq(liquidity, 0);

    //     (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount) =
    //         snos.executeVirtualOrdersAndGetSaleStatus(token);

    //     assertEq(saleRate, (uint256(snos.TOKEN_TOTAL_SUPPLY()) << 32) / snos.ORDER_DURATION());
    //     assertEq(remainingSellAmount, uint256(snos.TOKEN_TOTAL_SUPPLY()));
    //     assertEq(purchasedAmount, 0);
    //     assertEq(amountSold, 0);

    //     // (uint64 endTime, address creator, int32 saleEndTick) = snos.tokenInfos(token);
    //     // assertEq(endTime, 8192);
    //     // assertEq(creator, address(this));
    //     // assertEq(saleEndTick, 0);
    // }

    // function test_launch_with_bid() public {
    //     vm.expectEmit(address(snos));
    //     emit SniperNoSniping.Launched(
    //         snos.getExpectedTokenAddress(address(this), bytes32(0), "ABC", "ABC Token"),
    //         address(this),
    //         4096,
    //         8192,
    //         "ABC",
    //         "ABC Token"
    //     );
    //     SimpleToken token = snos.launch{value: 1e18}({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});

    //     assertEq(token.symbol(), "ABC");
    //     assertEq(token.name(), "ABC Token");

    //     (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) =
    //         core.poolState(snos.getLaunchPool(token).toPoolId()).parse();
    //     assertEq(sqrtRatio.toFixed(), 1 << 128);
    //     assertEq(tick, 0);
    //     assertEq(liquidity, 0);

    //     vm.warp(4096 + 4096);

    //     (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount) =
    //         snos.executeVirtualOrdersAndGetSaleStatus(token);

    //     assertEq(saleRate, (uint256(snos.TOKEN_TOTAL_SUPPLY()) << 32) / 4096);
    //     assertEq(remainingSellAmount, 0);
    //     assertEq(purchasedAmount, 1e18);
    //     assertEq(amountSold, uint256(snos.TOKEN_TOTAL_SUPPLY()));
    // }

    // function test_launch_reverts_if_reuse_salt() public {
    //     snos.launch({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});
    //     vm.expectRevert();
    //     snos.launch({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});
    // }

    // function test_graduate_reverts_if_no_bid() public {
    //     SimpleToken token = snos.launch({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});
    //     vm.warp(4096 + 4096);
    //     vm.expectRevert(SniperNoSniping.NoProceeds.selector);
    //     snos.graduate(token);
    // }

    // function test_graduate_reverts_if_too_soon() public {
    //     SimpleToken token = snos.launch({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});
    //     vm.warp(4096 + 4095);
    //     vm.expectRevert(SniperNoSniping.SaleStillOngoing.selector);
    //     snos.graduate(token);
    // }

    // function test_graduate_reverts_if_called_twice() public {
    //     SimpleToken token = snos.launch({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});

    //     orders.mintAndIncreaseSellAmount{value: 10000}(
    //         OrderKey({
    //             sellToken: NATIVE_TOKEN_ADDRESS,
    //             buyToken: address(token),
    //             fee: snos.POOL_FEE(),
    //             startTime: 4096,
    //             endTime: 4096 + 4096
    //         }),
    //         10000,
    //         type(uint112).max
    //     );

    //     vm.warp(4096 + 4096);

    //     snos.graduate(token);
    //     vm.expectRevert(SniperNoSniping.NoProceeds.selector);
    //     snos.graduate(token);
    // }

    // function test_graduate_pool_already_initialized_no_liquidity(int32 initializedTick, uint80 buyAmount) public {
    //     buyAmount = uint80(bound(buyAmount, 2, type(uint80).max));
    //     initializedTick = int32(bound(initializedTick, MIN_TICK, MAX_TICK));

    //     SimpleToken token = snos.launch({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});

    //     orders.mintAndIncreaseSellAmount{value: buyAmount}(
    //         OrderKey({
    //             sellToken: NATIVE_TOKEN_ADDRESS,
    //             buyToken: address(token),
    //             fee: snos.POOL_FEE(),
    //             startTime: 4096,
    //             endTime: 4096 + 4096
    //         }),
    //         buyAmount,
    //         type(uint112).max
    //     );

    //     positions.maybeInitializePool(snos.getGraduationPool(token), initializedTick);

    //     vm.warp(4096 + 4096);

    //     snos.graduate(token);

    //     // saleEndTick is what we consider the average sale price after it finishes
    //     (,, int32 saleEndTick) = snos.tokenInfos(token);

    //     (SqrtRatio sqrtRatio, int32 tick,) = core.poolState(snos.getGraduationPool(token).toPoolId()).parse();

    //     // price must be _higher_ i.e. token / eth is less than the sale end tick
    //     assertLe(sqrtRatio.toFixed(), tickToSqrtRatio(saleEndTick).toFixed());
    //     assertLe(tick, saleEndTick);

    //     (uint128 principal0, uint128 principal1, uint128 fees0, uint128 fees1) =
    //         snos.getGraduationPositionFeesAndLiquidity(token);
    //     assertGe(principal0, buyAmount - 2);
    //     assertEq(principal1, 0);
    //     assertEq(fees0, 0);
    //     assertEq(fees1, 0);
    // }

    // function test_graduate_pool_already_initialized_with_liquidity(int32 initializedTick, uint80 buyAmount) public {
    //     buyAmount = uint80(bound(buyAmount, 1e18, type(uint80).max));
    //     initializedTick = int32(bound(initializedTick, MIN_TICK / 2, MAX_TICK / 2));

    //     SimpleToken token = snos.launch({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});

    //     (uint256 id,) = orders.mintAndIncreaseSellAmount{value: buyAmount}(
    //         OrderKey({
    //             sellToken: NATIVE_TOKEN_ADDRESS,
    //             buyToken: address(token),
    //             fee: snos.POOL_FEE(),
    //             startTime: 4096,
    //             endTime: 4096 + 4096
    //         }),
    //         buyAmount,
    //         type(uint112).max
    //     );

    //     // half way point
    //     vm.warp(4096 + 2048);

    //     uint128 tokenPurchased = orders.collectProceeds(
    //         id,
    //         OrderKey({
    //             sellToken: NATIVE_TOKEN_ADDRESS,
    //             buyToken: address(token),
    //             fee: snos.POOL_FEE(),
    //             startTime: 4096,
    //             endTime: 4096 + 4096
    //         })
    //     );

    //     positions.maybeInitializePool(snos.getGraduationPool(token), initializedTick);

    //     int32 s = int32(snos.GRADUATION_POOL_TICK_SPACING());
    //     positions.mintAndDeposit(
    //         snos.getGraduationPool(token),
    //         snos.MIN_USABLE_TICK(),
    //         (((initializedTick - (s - 1)) / s) * s),
    //         0,
    //         tokenPurchased,
    //         1
    //     );

    //     vm.warp(4096 + 4096);

    //     snos.graduate(token);

    //     // saleEndTick is what we consider the average sale price after it finishes
    //     (,, int32 saleEndTick) = snos.tokenInfos(token);

    //     (SqrtRatio sqrtRatio, int32 tick,) = core.poolState(snos.getGraduationPool(token).toPoolId()).parse();

    //     // price must be _higher_ i.e. token / eth is less than the sale end tick
    //     assertLe(sqrtRatio.toFixed(), tickToSqrtRatio(saleEndTick).toFixed());
    //     assertLe(tick, saleEndTick);

    //     (uint128 principal0, uint128 principal1, uint128 fees0, uint128 fees1) =
    //         snos.getGraduationPositionFeesAndLiquidity(token);
    //     assertGe(principal0, 0);
    //     assertGe(principal1, 0);
    //     assertEq(fees0, 0);
    //     assertEq(fees1, 0);
    // }

    // function test_graduate_sell_after_launch_for_almost_all_proceeds(uint112 buyAmount) public {
    //     buyAmount = uint112(bound(buyAmount, 1e9, 1e23));

    //     SimpleToken token = snos.launch({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});

    //     (uint256 id,) = orders.mintAndIncreaseSellAmount{value: buyAmount}(
    //         OrderKey({
    //             sellToken: NATIVE_TOKEN_ADDRESS,
    //             buyToken: address(token),
    //             fee: snos.POOL_FEE(),
    //             startTime: 4096,
    //             endTime: 4096 + 4096
    //         }),
    //         buyAmount,
    //         type(uint112).max
    //     );

    //     vm.warp(4096 + 4096);

    //     snos.graduate(token);

    //     uint128 boughtAmount = orders.collectProceeds(
    //         id,
    //         OrderKey({
    //             sellToken: NATIVE_TOKEN_ADDRESS,
    //             buyToken: address(token),
    //             fee: snos.POOL_FEE(),
    //             startTime: 4096,
    //             endTime: 4096 + 4096
    //         })
    //     );

    //     assertApproxEqAbs(boughtAmount, 1e18, 1);

    //     (int128 delta0, int128 delta1) =
    //         router.swap(snos.getGraduationPool(token), true, int128(boughtAmount), MAX_SQRT_RATIO, 0);
    //     // pay at most fee x 9/8 on the redemption
    //     assertGe(uint128(-delta0), buyAmount - computeFee(buyAmount, snos.POOL_FEE() * 9 / 8));
    //     assertEq(delta1, int128(boughtAmount));
    // }

    // function test_tick_round_down(int32 tick, uint32 tickSpacing) public pure {
    //     tick = int32(bound(tick, MIN_TICK, MAX_TICK));
    //     tickSpacing = uint32(bound(tickSpacing, 1, MAX_TICK_SPACING));

    //     int32 rounded = roundDownToNearest(tick, int32(tickSpacing));
    //     assertLe(rounded, tick);
    //     assertGt(rounded, tick - int32(tickSpacing));
    // }

    // function test_tick_round_down_negative() public pure {
    //     assertEq(roundDownToNearest(-1, 1000), -1000);
    //     assertEq(roundDownToNearest(-999, 1000), -1000);
    //     assertEq(roundDownToNearest(-1000, 1000), -1000);
    //     assertEq(roundDownToNearest(-1001, 1000), -2000);
    //     assertEq(roundDownToNearest(-1500, 1000), -2000);
    //     assertEq(roundDownToNearest(-1999, 1000), -2000);
    //     assertEq(roundDownToNearest(-2000, 1000), -2000);
    //     assertEq(roundDownToNearest(-2001, 1000), -3000);
    // }

    // function test_tick_round_down_non_negative() public pure {
    //     assertEq(roundDownToNearest(0, 1000), 0);
    //     assertEq(roundDownToNearest(999, 1000), 0);
    //     assertEq(roundDownToNearest(1000, 1000), 1000);
    //     assertEq(roundDownToNearest(1500, 1000), 1000);
    //     assertEq(roundDownToNearest(1999, 1000), 1000);
    //     assertEq(roundDownToNearest(2000, 1000), 2000);
    //     assertEq(roundDownToNearest(2001, 1000), 2000);
    // }

    // function test_graduate_gas() public {
    //     SimpleToken token = snos.launch({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});

    //     orders.mintAndIncreaseSellAmount{value: 10000}(
    //         OrderKey({
    //             sellToken: NATIVE_TOKEN_ADDRESS,
    //             buyToken: address(token),
    //             fee: snos.POOL_FEE(),
    //             startTime: 4096,
    //             endTime: 4096 + 4096
    //         }),
    //         10000,
    //         type(uint112).max
    //     );

    //     vm.warp(4096 + 4096);

    //     snos.graduate(token);
    //     vm.snapshotGasLastCall("SniperNoSniping#graduate");
    // }

    // function test_collect_gas_no_fees() public {
    //     SimpleToken token = snos.launch({salt: bytes32(0), symbol: "ABC", name: "ABC Token"});

    //     orders.mintAndIncreaseSellAmount{value: 10000}(
    //         OrderKey({
    //             sellToken: NATIVE_TOKEN_ADDRESS,
    //             buyToken: address(token),
    //             fee: snos.POOL_FEE(),
    //             startTime: 4096,
    //             endTime: 4096 + 4096
    //         }),
    //         10000,
    //         type(uint112).max
    //     );

    //     vm.warp(4096 + 4096);

    //     snos.graduate(token);

    //     vm.warp(4096 + 4096 + 4096);

    //     snos.collect(token, address(0x1234));
    //     vm.snapshotGasLastCall("SniperNoSniping#collect");
    // }
}
