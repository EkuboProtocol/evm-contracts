// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {BaseOrdersTest} from "./Orders.t.sol";
import {Delta, RouteNode, TokenAmount} from "../src/Router.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {
    MIN_TICK,
    MAX_TICK,
    FULL_RANGE_ONLY_TICK_SPACING,
    NATIVE_TOKEN_ADDRESS,
    MAX_TICK_SPACING
} from "../src/math/constants.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../src/types/sqrtRatio.sol";
import {Positions} from "../src/Positions.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {nextValidTime} from "../src/math/time.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {TWAMMLib} from "../src/libraries/TWAMMLib.sol";
import {FeeAccumulatingExtension} from "./SolvencyInvariantTest.t.sol";
import {byteToCallPoints} from "../src/types/callPoints.sol";
import {Orders} from "../src/Orders.sol";
import {BaseTWAMMTest} from "./extensions/TWAMM.t.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";
import {TWAMM, OrderKey} from "../src/extensions/TWAMM.sol";
import {SniperNoSniping, roundDownToNearest} from "../src/SniperNoSniping.sol";
import {LibString} from "solady/utils/LibString.sol";
import {SNOSToken} from "../src/SNOSToken.sol";
import {computeFee} from "../src/math/fee.sol";

contract SniperNoSnipingTest is BaseOrdersTest {
    using CoreLib for *;

    SniperNoSniping snos;

    function setUp() public virtual override {
        BaseOrdersTest.setUp();
        snos = new SniperNoSniping(
            router, positions, orders, 4096, 3600, 1_000_000e18, uint64((uint256(1) << 64) / 100), 1000
        );
    }

    function test_launch_gas() public {
        snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });
        vm.snapshotGasLastCall("SniperNoSniping#launch");
    }

    function test_launch() public {
        vm.expectEmit(address(snos));
        emit SniperNoSniping.Launched(
            snos.getExpectedTokenAddress(
                address(this), bytes32(0), LibString.packOne("ABC"), LibString.packOne("ABC Token")
            ),
            address(this),
            4096,
            8192
        );
        SNOSToken token = snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });

        assertEq(token.symbol(), "ABC");
        assertEq(token.name(), "ABC Token");

        (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity) = core.poolState(snos.getLaunchPool(token).toPoolId());
        assertEq(sqrtRatio.toFixed(), 1 << 128);
        assertEq(tick, 0);
        assertEq(liquidity, 0);

        (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount) =
            snos.executeVirtualOrdersAndGetSaleStatus(token);

        assertEq(saleRate, (uint256(snos.tokenTotalSupply()) << 32) / 4096);
        assertEq(remainingSellAmount, uint256(snos.tokenTotalSupply()));
        assertEq(purchasedAmount, 0);
        assertEq(amountSold, 0);

        (uint64 endTime, address creator, int32 saleEndTick) = snos.tokenInfos(token);
        assertEq(endTime, 8192);
        assertEq(creator, address(this));
        assertEq(saleEndTick, 0);
    }

    function test_launch_reverts_if_too_soon() public {
        vm.expectRevert(SniperNoSniping.StartTimeTooSoon.selector);
        snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 16
        });
    }

    function test_launch_reverts_if_reuse_salt() public {
        snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });
        vm.expectRevert();
        snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });
    }

    function test_launch_reverts_if_too_far_in_future() public {
        vm.expectRevert();
        snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: type(uint64).max
        });
    }

    function test_graduate_reverts_if_no_bid() public {
        SNOSToken token = snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });
        vm.warp(4096 + 4096);
        vm.expectRevert(SniperNoSniping.NoProceeds.selector);
        snos.graduate(token);
    }

    function test_graduate_reverts_if_too_soon() public {
        SNOSToken token = snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });
        vm.warp(4096 + 4095);
        vm.expectRevert(SniperNoSniping.SaleStillOngoing.selector);
        snos.graduate(token);
    }

    function test_graduate_reverts_if_called_twice() public {
        SNOSToken token = snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });

        orders.mintAndIncreaseSellAmount{value: 10000}(
            OrderKey({
                sellToken: NATIVE_TOKEN_ADDRESS,
                buyToken: address(token),
                fee: snos.fee(),
                startTime: 4096,
                endTime: 4096 + 4096
            }),
            10000,
            type(uint112).max
        );

        vm.warp(4096 + 4096);

        snos.graduate(token);
        vm.expectRevert(SniperNoSniping.NoProceeds.selector);
        snos.graduate(token);
    }

    function test_graduate_pool_already_initialized_no_liquidity(int32 initializedTick, uint80 buyAmount) public {
        buyAmount = uint80(bound(buyAmount, 2, type(uint80).max));
        initializedTick = int32(bound(initializedTick, MIN_TICK, MAX_TICK));

        SNOSToken token = snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });

        orders.mintAndIncreaseSellAmount{value: buyAmount}(
            OrderKey({
                sellToken: NATIVE_TOKEN_ADDRESS,
                buyToken: address(token),
                fee: snos.fee(),
                startTime: 4096,
                endTime: 4096 + 4096
            }),
            buyAmount,
            type(uint112).max
        );

        positions.maybeInitializePool(snos.getGraduationPool(token), initializedTick);

        vm.warp(4096 + 4096);

        snos.graduate(token);

        // saleEndTick is what we consider the average sale price after it finishes
        (,, int32 saleEndTick) = snos.tokenInfos(token);

        (SqrtRatio sqrtRatio, int32 tick,) = core.poolState(snos.getGraduationPool(token).toPoolId());

        // price must be _higher_ i.e. token / eth is less than the sale end tick
        assertLe(sqrtRatio.toFixed(), tickToSqrtRatio(saleEndTick).toFixed());
        assertLe(tick, saleEndTick);

        (uint128 principal0, uint128 principal1, uint128 fees0, uint128 fees1) =
            snos.getGraduationPositionFeesAndLiquidity(token);
        assertGe(principal0, buyAmount - 2);
        assertEq(principal1, 0);
        assertEq(fees0, 0);
        assertEq(fees1, 0);
    }

    function test_graduate_pool_already_initialized_with_liquidity(int32 initializedTick, uint80 buyAmount) public {
        buyAmount = uint80(bound(buyAmount, 1e18, type(uint80).max));
        initializedTick = int32(bound(initializedTick, MIN_TICK / 2, MAX_TICK / 2));

        SNOSToken token = snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });

        (uint256 id,) = orders.mintAndIncreaseSellAmount{value: buyAmount}(
            OrderKey({
                sellToken: NATIVE_TOKEN_ADDRESS,
                buyToken: address(token),
                fee: snos.fee(),
                startTime: 4096,
                endTime: 4096 + 4096
            }),
            buyAmount,
            type(uint112).max
        );

        // half way point
        vm.warp(4096 + 2048);

        uint128 tokenPurchased = orders.collectProceeds(
            id,
            OrderKey({
                sellToken: NATIVE_TOKEN_ADDRESS,
                buyToken: address(token),
                fee: snos.fee(),
                startTime: 4096,
                endTime: 4096 + 4096
            })
        );

        positions.maybeInitializePool(snos.getGraduationPool(token), initializedTick);

        int32 s = int32(snos.tickSpacing());
        positions.mintAndDeposit(
            snos.getGraduationPool(token),
            Bounds(snos.minUsableTick(), (((initializedTick - (s - 1)) / s) * s)),
            0,
            tokenPurchased,
            1
        );

        vm.warp(4096 + 4096);

        snos.graduate(token);

        // saleEndTick is what we consider the average sale price after it finishes
        (,, int32 saleEndTick) = snos.tokenInfos(token);

        (SqrtRatio sqrtRatio, int32 tick,) = core.poolState(snos.getGraduationPool(token).toPoolId());

        // price must be _higher_ i.e. token / eth is less than the sale end tick
        assertLe(sqrtRatio.toFixed(), tickToSqrtRatio(saleEndTick).toFixed());
        assertLe(tick, saleEndTick);

        (uint128 principal0, uint128 principal1, uint128 fees0, uint128 fees1) =
            snos.getGraduationPositionFeesAndLiquidity(token);
        assertGe(principal0, 0);
        assertGe(principal1, 0);
        assertEq(fees0, 0);
        assertEq(fees1, 0);
    }

    function test_graduate_sell_after_launch_for_almost_all_proceeds(uint112 buyAmount) public {
        buyAmount = uint112(bound(buyAmount, 1e9, 1e23));

        SNOSToken token = snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });

        (uint256 id,) = orders.mintAndIncreaseSellAmount{value: buyAmount}(
            OrderKey({
                sellToken: NATIVE_TOKEN_ADDRESS,
                buyToken: address(token),
                fee: snos.fee(),
                startTime: 4096,
                endTime: 4096 + 4096
            }),
            buyAmount,
            type(uint112).max
        );

        // half way point
        vm.warp(4096 + 4096);

        snos.graduate(token);

        uint128 proceeds = orders.collectProceeds(
            id,
            OrderKey({
                sellToken: NATIVE_TOKEN_ADDRESS,
                buyToken: address(token),
                fee: snos.fee(),
                startTime: 4096,
                endTime: 4096 + 4096
            })
        );

        assertApproxEqAbs(proceeds, 1e24, 1);

        (int128 delta0, int128 delta1) =
            router.swap(snos.getGraduationPool(token), true, int128(proceeds), MAX_SQRT_RATIO, 0);
        // pay at most fee x 2 on the redemption
        assertGe(uint128(-delta0), buyAmount - computeFee(buyAmount, snos.fee() * 2));
        assertEq(delta1, int128(proceeds));
    }

    function test_tick_round_down(int32 tick, uint32 tickSpacing) public pure {
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        tickSpacing = uint32(bound(tickSpacing, 1, MAX_TICK_SPACING));

        int32 rounded = roundDownToNearest(tick, int32(tickSpacing));
        assertLe(rounded, tick);
        assertGt(rounded, tick - int32(tickSpacing));
    }

    function test_tick_round_down_negative() public pure {
        assertEq(roundDownToNearest(-1, 1000), -1000);
        assertEq(roundDownToNearest(-999, 1000), -1000);
        assertEq(roundDownToNearest(-1000, 1000), -1000);
        assertEq(roundDownToNearest(-1001, 1000), -2000);
        assertEq(roundDownToNearest(-1500, 1000), -2000);
        assertEq(roundDownToNearest(-1999, 1000), -2000);
        assertEq(roundDownToNearest(-2000, 1000), -2000);
        assertEq(roundDownToNearest(-2001, 1000), -3000);
    }

    function test_tick_round_down_non_negative() public pure {
        assertEq(roundDownToNearest(0, 1000), 0);
        assertEq(roundDownToNearest(999, 1000), 0);
        assertEq(roundDownToNearest(1000, 1000), 1000);
        assertEq(roundDownToNearest(1500, 1000), 1000);
        assertEq(roundDownToNearest(1999, 1000), 1000);
        assertEq(roundDownToNearest(2000, 1000), 2000);
        assertEq(roundDownToNearest(2001, 1000), 2000);
    }

    function test_graduate_gas() public {
        SNOSToken token = snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });

        orders.mintAndIncreaseSellAmount{value: 10000}(
            OrderKey({
                sellToken: NATIVE_TOKEN_ADDRESS,
                buyToken: address(token),
                fee: snos.fee(),
                startTime: 4096,
                endTime: 4096 + 4096
            }),
            10000,
            type(uint112).max
        );

        vm.warp(4096 + 4096);

        snos.graduate(token);
        vm.snapshotGasLastCall("SniperNoSniping#graduate");
    }

    function test_collect_gas_no_fees() public {
        SNOSToken token = snos.launch({
            salt: bytes32(0),
            symbol: LibString.packOne("ABC"),
            name: LibString.packOne("ABC Token"),
            startTime: 4096
        });

        orders.mintAndIncreaseSellAmount{value: 10000}(
            OrderKey({
                sellToken: NATIVE_TOKEN_ADDRESS,
                buyToken: address(token),
                fee: snos.fee(),
                startTime: 4096,
                endTime: 4096 + 4096
            }),
            10000,
            type(uint112).max
        );

        vm.warp(4096 + 4096);

        snos.graduate(token);

        vm.warp(4096 + 4096 + 4096);

        snos.collect(token, address(0x1234));
        vm.snapshotGasLastCall("SniperNoSniping#collect");
    }

    receive() external payable {}
}
