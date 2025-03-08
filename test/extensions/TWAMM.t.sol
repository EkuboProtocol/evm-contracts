// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {UpdatePositionParameters} from "../../src/interfaces/ICore.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {PoolKey, toConfig} from "../../src/types/poolKey.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, SqrtRatio, toSqrtRatio} from "../../src/types/sqrtRatio.sol";
import {
    MIN_TICK,
    MAX_TICK,
    MAX_TICK_SPACING,
    FULL_RANGE_ONLY_TICK_SPACING,
    NATIVE_TOKEN_ADDRESS
} from "../../src/math/constants.sol";
import {FullTest} from "../FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../../src/Router.sol";
import {TWAMM, twammCallPoints} from "../../src/extensions/TWAMM.sol";
import {Core} from "../../src/Core.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {TestToken} from "../TestToken.sol";
import {amount0Delta, amount1Delta} from "../../src/math/delta.sol";
import {liquidityDeltaToAmountDelta} from "../../src/math/liquidity.sol";
import {FeesPerLiquidity} from "../../src/types/feesPerLiquidity.sol";
import {TWAMMLib} from "../../src/libraries/TWAMMLib.sol";
import {Test} from "forge-std/Test.sol";
import {searchForNextInitializedTime, flipTime} from "../../src/math/timeBitmap.sol";
import {Bitmap} from "../../src/math/bitmap.sol";
import {MAX_ABS_VALUE_SALE_RATE_DELTA} from "../../src/math/time.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

abstract contract BaseTWAMMTest is FullTest {
    TWAMM internal twamm;

    uint256 positionId;

    function setUp() public virtual override {
        FullTest.setUp();
        address deployAddress = address(uint160(twammCallPoints().toUint8()) << 152);
        deployCodeTo("TWAMM.sol", abi.encode(core), deployAddress);
        twamm = TWAMM(deployAddress);
        positionId = positions.mint();
    }

    function advanceTime(uint32 by) internal returns (uint256 next) {
        next = vm.getBlockTimestamp() + by;
        vm.warp(next);
    }

    function createTwammPool(uint64 fee, int32 tick) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(address(token0), address(token1), tick, fee, FULL_RANGE_ONLY_TICK_SPACING, address(twamm));
    }
}

contract TWAMMTest is BaseTWAMMTest {
    using TWAMMLib for *;

    function test_createPool_fails_not_full_range() public {
        vm.expectRevert(TWAMM.TickSpacingMustBeMaximum.selector);
        createPool(address(token0), address(token1), 0, 0, 1, address(twamm));
    }

    function test_createPool(uint256 time) public {
        vm.warp(time);
        PoolKey memory key = createTwammPool(100, 0);
        (uint32 lvoe, uint112 srt0, uint112 srt1) = twamm.poolState(key.toPoolId());
        assertEq(lvoe, uint32(time));
        assertEq(srt0, 0);
        assertEq(srt1, 0);
    }
}

// Note the inheritance order matters because Test contains storage variables
contract TWAMMInternalMethodsTests is TWAMM, Test {
    using {searchForNextInitializedTime, flipTime} for mapping(uint256 word => Bitmap bitmap);

    constructor() TWAMM(new Core(address(0xdeadbeef))) {}

    function _registerInConstructor() internal pure override returns (bool) {
        return false;
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_addConstrainSaleRateDelta(int112 saleRateDelta, int112 saleRateDeltaChange) public {
        int256 result = int256(saleRateDelta) + saleRateDeltaChange;
        if (FixedPointMathLib.abs(result) > MAX_ABS_VALUE_SALE_RATE_DELTA) {
            vm.expectRevert(MaxSaleRateDeltaPerTime.selector);
        }
        assertEq(_addConstrainSaleRateDelta(saleRateDelta, saleRateDeltaChange), result);
    }

    function test_getRewardRateInside_token0() public {
        bytes32 poolId = bytes32(0);

        vm.warp(99);
        assertEq(_getRewardRateInside(poolId, 100, 200, false), 0);

        vm.warp(150);
        assertEq(_getRewardRateInside(poolId, 100, 200, false), 0);

        poolRewardRates[poolId] = FeesPerLiquidity(100, 75);
        assertEq(_getRewardRateInside(poolId, 100, 200, false), 100);

        poolRewardRates[poolId] = FeesPerLiquidity(300, 450);
        poolRewardRatesBefore[poolId][200] = FeesPerLiquidity(150, 150);
        vm.warp(250);
        assertEq(_getRewardRateInside(poolId, 100, 200, false), 150);

        poolRewardRatesBefore[poolId][100] = FeesPerLiquidity(50, 100);
        assertEq(_getRewardRateInside(poolId, 100, 200, false), 100);
    }

    function test_getRewardRateInside_at_end_time() public {
        bytes32 poolId = bytes32(0);

        poolRewardRatesBefore[poolId][100] = FeesPerLiquidity(25, 30);
        poolRewardRatesBefore[poolId][200] = FeesPerLiquidity(50, 75);
        vm.warp(200);
        assertEq(_getRewardRateInside(poolId, 100, 200, false), 25);
        assertEq(_getRewardRateInside(poolId, 100, 200, true), 45);
    }

    function test_getRewardRateInside_token1() public {
        bytes32 poolId = bytes32(0);

        vm.warp(99);
        assertEq(_getRewardRateInside(poolId, 100, 200, true), 0);

        vm.warp(150);
        assertEq(_getRewardRateInside(poolId, 100, 200, true), 0);

        poolRewardRates[poolId] = FeesPerLiquidity(100, 75);
        assertEq(_getRewardRateInside(poolId, 100, 200, true), 75);

        poolRewardRates[poolId] = FeesPerLiquidity(300, 450);
        poolRewardRatesBefore[poolId][200] = FeesPerLiquidity(150, 160);
        vm.warp(250);
        assertEq(_getRewardRateInside(poolId, 100, 200, true), 160);

        poolRewardRatesBefore[poolId][100] = FeesPerLiquidity(50, 100);
        assertEq(_getRewardRateInside(poolId, 100, 200, true), 60);
    }

    function test_updateTime_flips_time() public {
        bytes32 poolId = bytes32(0);

        _updateTime({poolId: poolId, time: 96, saleRateDelta: 100, isToken1: false, numOrdersChange: 1});

        assertEq(poolTimeInfos[poolId][96].numOrders, 1);
        assertEq(poolTimeInfos[poolId][96].saleRateDeltaToken0, 100);
        assertEq(poolTimeInfos[poolId][96].saleRateDeltaToken1, 0);

        (uint32 time, bool initialized) = poolInitializedTimesBitmap[poolId].searchForNextInitializedTime(30, 1000);
        assertEq(time, 96);
        assertEq(initialized, true);

        _updateTime({poolId: poolId, time: 96, saleRateDelta: -100, isToken1: false, numOrdersChange: -1});

        (time, initialized) = poolInitializedTimesBitmap[poolId].searchForNextInitializedTime(30, 1000);
        assertEq(time, 1000);
        assertEq(initialized, false);
    }

    function test_updateTime_flips_time_two_orders_one_removed() public {
        bytes32 poolId = bytes32(0);

        _updateTime({poolId: poolId, time: 96, saleRateDelta: 100, isToken1: false, numOrdersChange: 1});
        _updateTime({poolId: poolId, time: 96, saleRateDelta: 55, isToken1: true, numOrdersChange: 1});

        assertEq(poolTimeInfos[poolId][96].numOrders, 2);
        assertEq(poolTimeInfos[poolId][96].saleRateDeltaToken0, 100);
        assertEq(poolTimeInfos[poolId][96].saleRateDeltaToken1, 55);

        (uint32 time, bool initialized) = poolInitializedTimesBitmap[poolId].searchForNextInitializedTime(30, 1000);
        assertEq(time, 96);
        assertEq(initialized, true);

        _updateTime({poolId: poolId, time: 96, saleRateDelta: -100, isToken1: false, numOrdersChange: -1});

        (time, initialized) = poolInitializedTimesBitmap[poolId].searchForNextInitializedTime(30, 1000);
        assertEq(time, 96);
        assertEq(initialized, true);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_updateTime_reverts_if_max_num_orders_exceeded() public {
        bytes32 poolId = bytes32(0);

        poolTimeInfos[poolId][96].numOrders = type(uint32).max;
        vm.expectRevert(TWAMM.TimeNumOrdersOverflow.selector);
        _updateTime({poolId: poolId, time: 96, saleRateDelta: 100, isToken1: false, numOrdersChange: 1});
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_updateTime_reverts_if_max_sale_rate_delta_exceeded() public {
        bytes32 poolId = bytes32(0);

        poolTimeInfos[poolId][96].saleRateDeltaToken0 = type(int112).max;
        vm.expectRevert();
        _updateTime({poolId: poolId, time: 96, saleRateDelta: 1, isToken1: false, numOrdersChange: 0});

        poolTimeInfos[poolId][96].saleRateDeltaToken1 = type(int112).max;
        vm.expectRevert();
        _updateTime({poolId: poolId, time: 96, saleRateDelta: 1, isToken1: true, numOrdersChange: 0});

        poolTimeInfos[poolId][96].saleRateDeltaToken0 = type(int112).min;
        vm.expectRevert();
        _updateTime({poolId: poolId, time: 96, saleRateDelta: -1, isToken1: false, numOrdersChange: 0});

        poolTimeInfos[poolId][96].saleRateDeltaToken1 = type(int112).min;
        vm.expectRevert();
        _updateTime({poolId: poolId, time: 96, saleRateDelta: -1, isToken1: true, numOrdersChange: 0});
    }

    function test_updateTime_flip_time_overflows_uint32() public {
        bytes32 poolId = bytes32(0);

        uint256 time = uint256(type(uint32).max) + 17;
        assert(time % 16 == 0);

        _updateTime({poolId: poolId, time: time, saleRateDelta: 1, isToken1: false, numOrdersChange: 1});

        (uint32 nextTime, bool initialized) =
            poolInitializedTimesBitmap[poolId].searchForNextInitializedTime(uint32(time - 15), uint32(time + 15));
        assertEq(nextTime, uint32(time));
        assertEq(initialized, true);
    }
}
