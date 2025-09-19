// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {PoolKey} from "../../src/types/poolKey.sol";
import {FULL_RANGE_ONLY_TICK_SPACING} from "../../src/math/constants.sol";
import {FullTest} from "../FullTest.sol";
import {ITWAMM, TWAMM, orderKeyToPoolKey, twammCallPoints} from "../../src/extensions/TWAMM.sol";
import {OrderKey} from "../../src/interfaces/extensions/ITWAMM.sol";
import {Core} from "../../src/Core.sol";
import {FeesPerLiquidity} from "../../src/types/feesPerLiquidity.sol";
import {TWAMMLib} from "../../src/libraries/TWAMMLib.sol";
import {Test} from "forge-std/Test.sol";
import {searchForNextInitializedTime, flipTime} from "../../src/math/timeBitmap.sol";
import {Bitmap} from "../../src/types/bitmap.sol";
import {MAX_ABS_VALUE_SALE_RATE_DELTA} from "../../src/math/time.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

abstract contract BaseTWAMMTest is FullTest {
    TWAMM internal twamm;

    function setUp() public virtual override {
        FullTest.setUp();
        address deployAddress = address(uint160(twammCallPoints().toUint8()) << 152);
        deployCodeTo("TWAMM.sol", abi.encode(core), deployAddress);
        twamm = TWAMM(deployAddress);
    }

    function boundTime(uint256 time, uint32 offset) internal pure returns (uint256) {
        return ((bound(time, offset, type(uint256).max - type(uint32).max - (2 * uint256(offset))) / 16) * 16) + offset;
    }

    function createTwammPool(uint64 fee, int32 tick) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(address(token0), address(token1), tick, fee, FULL_RANGE_ONLY_TICK_SPACING, address(twamm));
    }

    function coolAllContracts() internal virtual override {
        FullTest.coolAllContracts();
        vm.cool(address(twamm));
    }
}

contract TWAMMTest is BaseTWAMMTest {
    using TWAMMLib for *;

    function test_createPool_fails_not_full_range() public {
        vm.expectRevert(ITWAMM.TickSpacingMustBeMaximum.selector);
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

    constructor() TWAMM(new Core()) {}

    function _registerInConstructor() internal pure override returns (bool) {
        return false;
    }

    function test_orderKeyToPoolKey(OrderKey memory orderKey, address twamm) public pure {
        PoolKey memory pk = orderKeyToPoolKey(orderKey, twamm);
        if (orderKey.sellToken > orderKey.buyToken) {
            assertEq(pk.token0, orderKey.buyToken);
            assertEq(pk.token1, orderKey.sellToken);
        } else {
            assertEq(pk.token0, orderKey.sellToken);
            assertEq(pk.token1, orderKey.buyToken);
        }
        assertEq(pk.fee(), orderKey.fee);
        assertEq(pk.tickSpacing(), 0);
        assertEq(pk.extension(), twamm);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_addConstrainSaleRateDelta_overflows() public {
        vm.expectRevert();
        _addConstrainSaleRateDelta(1, type(int256).max);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_addConstrainSaleRateDelta_underflows() public {
        vm.expectRevert();
        _addConstrainSaleRateDelta(-1, type(int256).min);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_addConstrainSaleRateDelta(int112 saleRateDelta, int256 saleRateDeltaChange) public {
        // prevents running into arithmetic overflow/underflow errors
        saleRateDeltaChange =
            bound(saleRateDeltaChange, type(int256).min - type(int112).min, type(int256).max - type(int112).max);

        int256 result = int256(saleRateDelta) + saleRateDeltaChange;
        if (FixedPointMathLib.abs(result) > MAX_ABS_VALUE_SALE_RATE_DELTA) {
            vm.expectRevert(MaxSaleRateDeltaPerTime.selector);
        }

        assertEq(_addConstrainSaleRateDelta(saleRateDelta, saleRateDeltaChange), result);
    }

    function testgetRewardRateInside_token0() public {
        bytes32 poolId = bytes32(0);

        vm.warp(99);
        assertEq(getRewardRateInside(poolId, 100, 200, false), 0);

        vm.warp(150);
        assertEq(getRewardRateInside(poolId, 100, 200, false), 0);

        poolRewardRates[poolId] = FeesPerLiquidity(100, 75);
        assertEq(getRewardRateInside(poolId, 100, 200, false), 100);

        poolRewardRates[poolId] = FeesPerLiquidity(300, 450);
        poolRewardRatesBefore[poolId][200] = FeesPerLiquidity(150, 150);
        vm.warp(250);
        assertEq(getRewardRateInside(poolId, 100, 200, false), 150);

        poolRewardRatesBefore[poolId][100] = FeesPerLiquidity(50, 100);
        assertEq(getRewardRateInside(poolId, 100, 200, false), 100);
    }

    function testgetRewardRateInside_at_end_time() public {
        bytes32 poolId = bytes32(0);

        poolRewardRatesBefore[poolId][100] = FeesPerLiquidity(25, 30);
        poolRewardRatesBefore[poolId][200] = FeesPerLiquidity(50, 75);
        vm.warp(200);
        assertEq(getRewardRateInside(poolId, 100, 200, false), 25);
        assertEq(getRewardRateInside(poolId, 100, 200, true), 45);
    }

    function testgetRewardRateInside_token1() public {
        bytes32 poolId = bytes32(0);

        vm.warp(99);
        assertEq(getRewardRateInside(poolId, 100, 200, true), 0);

        vm.warp(150);
        assertEq(getRewardRateInside(poolId, 100, 200, true), 0);

        poolRewardRates[poolId] = FeesPerLiquidity(100, 75);
        assertEq(getRewardRateInside(poolId, 100, 200, true), 75);

        poolRewardRates[poolId] = FeesPerLiquidity(300, 450);
        poolRewardRatesBefore[poolId][200] = FeesPerLiquidity(150, 160);
        vm.warp(250);
        assertEq(getRewardRateInside(poolId, 100, 200, true), 160);

        poolRewardRatesBefore[poolId][100] = FeesPerLiquidity(50, 100);
        assertEq(getRewardRateInside(poolId, 100, 200, true), 60);
    }

    function test_updateTime_flips_time() public {
        bytes32 poolId = bytes32(0);

        _updateTime({poolId: poolId, time: 96, saleRateDelta: 100, isToken1: false, numOrdersChange: 1});

        assertEq(poolTimeInfos[poolId][96].numOrders, 1);
        assertEq(poolTimeInfos[poolId][96].saleRateDeltaToken0, 100);
        assertEq(poolTimeInfos[poolId][96].saleRateDeltaToken1, 0);

        (uint256 time, bool initialized) = poolInitializedTimesBitmap[poolId].searchForNextInitializedTime({
            lastVirtualOrderExecutionTime: 0,
            fromTime: 30,
            untilTime: 1000
        });
        assertEq(time, 96);
        assertEq(initialized, true);

        _updateTime({poolId: poolId, time: 96, saleRateDelta: -100, isToken1: false, numOrdersChange: -1});

        (time, initialized) = poolInitializedTimesBitmap[poolId].searchForNextInitializedTime({
            lastVirtualOrderExecutionTime: 0,
            fromTime: 30,
            untilTime: 1000
        });
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

        (uint256 time, bool initialized) = poolInitializedTimesBitmap[poolId].searchForNextInitializedTime({
            lastVirtualOrderExecutionTime: 0,
            fromTime: 30,
            untilTime: 1000
        });
        assertEq(time, 96);
        assertEq(initialized, true);

        _updateTime({poolId: poolId, time: 96, saleRateDelta: -100, isToken1: false, numOrdersChange: -1});

        (time, initialized) = poolInitializedTimesBitmap[poolId].searchForNextInitializedTime({
            lastVirtualOrderExecutionTime: 0,
            fromTime: 30,
            untilTime: 1000
        });
        assertEq(time, 96);
        assertEq(initialized, true);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_updateTime_reverts_if_max_num_orders_exceeded() public {
        bytes32 poolId = bytes32(0);

        poolTimeInfos[poolId][96].numOrders = type(uint32).max;
        vm.expectRevert(ITWAMM.TimeNumOrdersOverflow.selector);
        _updateTime({poolId: poolId, time: 96, saleRateDelta: 100, isToken1: false, numOrdersChange: 1});
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function test_updateTime_reverts_if_subtract_orders_from_zero() public {
        bytes32 poolId = bytes32(0);

        vm.expectRevert(ITWAMM.TimeNumOrdersOverflow.selector);
        _updateTime({poolId: poolId, time: 96, saleRateDelta: 100, isToken1: false, numOrdersChange: -1});
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

        (uint256 nextTime, bool initialized) = poolInitializedTimesBitmap[poolId].searchForNextInitializedTime({
            lastVirtualOrderExecutionTime: time,
            fromTime: time - 15,
            untilTime: time + 15
        });
        assertEq(nextTime, time);
        assertEq(initialized, true);
    }
}
