// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {UpdatePositionParameters} from "../../src/interfaces/ICore.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {PoolKey, toConfig} from "../../src/types/poolKey.sol";
import {PositionKey, Bounds} from "../../src/types/positionKey.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
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
import {MEVResist, mevResistCallPoints} from "../../src/extensions/MEVResist.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {ExposedStorageLib} from "../../src/libraries/ExposedStorageLib.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {TestToken} from "../TestToken.sol";
import {amount0Delta, amount1Delta} from "../../src/math/delta.sol";
import {liquidityDeltaToAmountDelta} from "../../src/math/liquidity.sol";
import {FullRangeOnlyPool} from "../../src/types/positionKey.sol";
import {MEVResistRouter} from "../../src/MEVResistRouter.sol";
import {Vm} from "forge-std/Vm.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

abstract contract BaseMEVResistTest is FullTest {
    MEVResist internal mevResist;

    function setUp() public virtual override {
        FullTest.setUp();
        address deployAddress = address(uint160(mevResistCallPoints().toUint8()) << 152);
        deployCodeTo("MEVResist.sol", abi.encode(core), deployAddress);
        mevResist = MEVResist(deployAddress);
        router = new MEVResistRouter(core, address(mevResist));
    }

    function createMEVResistPool(uint64 fee, uint32 tickSpacing, int32 tick)
        internal
        returns (PoolKey memory poolKey)
    {
        poolKey = createPool(address(token0), address(token1), tick, fee, tickSpacing, address(mevResist));
    }
}

contract MEVResistTest is BaseMEVResistTest {
    using CoreLib for *;
    using ExposedStorageLib for *;

    function test_isRegistered() public view {
        assertTrue(core.isExtensionRegistered(address(mevResist)));
    }

    function getPoolState(bytes32 poolId) private view returns (uint32 lastUpdateTime, int32 tickLast) {
        bytes32 v = mevResist.sload(poolId);
        assembly ("memory-safe") {
            lastUpdateTime := shr(224, v)
            tickLast := signextend(31, shr(192, v))
        }
    }

    function test_pool_initialization_success(uint256 time, uint64 fee, uint32 tickSpacing, int32 tick, uint32 warp)
        public
    {
        vm.warp(time);
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        fee = uint64(bound(fee, 1, type(uint64).max));
        tickSpacing = uint32(bound(tickSpacing, 1, MAX_TICK_SPACING));

        PoolKey memory poolKey = createMEVResistPool({fee: fee, tickSpacing: tickSpacing, tick: tick});

        (uint32 lastUpdateTime, int32 tickLast) = getPoolState(poolKey.toPoolId());
        assertEq(lastUpdateTime, uint32(vm.getBlockTimestamp()));
        assertEq(tickLast, tick);

        unchecked {
            vm.warp(time + uint256(warp));
        }
        mevResist.accumulatePoolFees(poolKey);
        (lastUpdateTime, tickLast) = getPoolState(poolKey.toPoolId());
        assertEq(lastUpdateTime, uint32(vm.getBlockTimestamp()));
        assertEq(tickLast, tick);
    }

    function test_accumulate_fees_for_any_pool(uint256 time, PoolKey memory poolKey) public {
        // note that you can accumulate fees for any pool at any time, but it is no-op if the pool does not exist
        vm.warp(time);
        mevResist.accumulatePoolFees(poolKey);
        (uint32 lastUpdateTime, int32 tickLast) = getPoolState(poolKey.toPoolId());
        assertEq(lastUpdateTime, uint32(vm.getBlockTimestamp()));
        assertEq(tickLast, 0);
    }

    function test_pool_initialization_validation() public {
        vm.expectRevert(MEVResist.ConcentratedLiquidityPoolsOnly.selector);
        createMEVResistPool({fee: 1, tickSpacing: FULL_RANGE_ONLY_TICK_SPACING, tick: 0});

        vm.expectRevert(MEVResist.NonzeroFeesOnly.selector);
        createMEVResistPool({fee: 0, tickSpacing: 1, tick: 0});
    }

    function test_swap_input_token0_no_movement() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, Bounds(-100_000, 100_000), 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: 100_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        vm.snapshotGasLastCall("input_token0_no_movement");

        assertEq(delta0, 100_000);
        assertEq(delta1, -98_049);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, -9634);
    }

    function test_swap_output_token0_no_movement() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, Bounds(-100_000, 100_000), 1_000_000, 1_000_000);

        token1.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: -100_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        vm.snapshotGasLastCall("output_token0_no_movement");

        assertEq(delta0, -100_000);
        assertEq(delta1, 102_001);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, 9777);
    }

    function test_swap_input_token1_no_movement() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, Bounds(-100_000, 100_000), 1_000_000, 1_000_000);

        token1.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: true,
            amount: 100_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        vm.snapshotGasLastCall("input_token1_no_movement");

        assertEq(delta0, -98_049);
        assertEq(delta1, 100_000);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, 9633);
    }

    function test_swap_output_token1_no_movement() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, Bounds(-100_000, 100_000), 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: true,
            amount: -100_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        vm.snapshotGasLastCall("output_token1_no_movement");

        assertEq(delta0, 102_001);
        assertEq(delta1, -100_000);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, -9778);
    }

    /// now tests with movement more than one tick spacing

    function test_swap_input_token0_move_tick_spacings() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, Bounds(-100_000, 100_000), 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: 500_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        vm.snapshotGasLastCall("input_token0_move_tick_spacings");

        assertEq(delta0, 500_000);
        assertEq(delta1, -471_801);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, -47710);
    }

    function test_swap_output_token0_move_tick_spacings() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, Bounds(-100_000, 100_000), 1_000_000, 1_000_000);

        token1.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: -500_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        vm.snapshotGasLastCall("output_token0_move_tick_spacings");

        assertEq(delta0, -500_000);
        assertEq(delta1, 530_648);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, 49375);
    }

    function test_swap_input_token1_move_tick_spacings() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, Bounds(-100_000, 100_000), 1_000_000, 1_000_000);

        token1.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: true,
            amount: 500_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        vm.snapshotGasLastCall("input_token1_move_tick_spacings");

        assertEq(delta0, -471_801);
        assertEq(delta1, 500_000);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, 47709);
    }

    function test_swap_output_token1_move_tick_spacings() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, Bounds(-100_000, 100_000), 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: true,
            amount: -500_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        vm.snapshotGasLastCall("output_token1_move_tick_spacings");

        assertEq(delta0, 530_648);
        assertEq(delta1, -500_000);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, -49376);
    }

    function test_extra_fees_are_accumulated_in_next_block() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        Bounds memory bounds = Bounds(-100_000, 100_000);
        (uint256 id,) = createPosition(poolKey, bounds, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);
        router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: 500_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        (uint128 amount0, uint128 amount1) = positions.collectFees(id, poolKey, bounds);
        assertEq(amount0, 4999);
        assertEq(amount1, 0);

        advanceTime(1);
        (amount0, amount1) = positions.collectFees(id, poolKey, bounds);
        assertEq(amount0, 0);
        assertEq(amount1, 11529);

        advanceTime(1);
        (amount0, amount1) = positions.collectFees(id, poolKey, bounds);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    function test_swap_initial_tick_far_from_zero_no_additional_fees() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 700_000});
        createPosition(poolKey, Bounds(600_000, 800_000), 1_000_000, 2_000_000);

        token0.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: 100_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        vm.snapshotGasLastCall("initial_tick_far_from_zero_no_additional_fees");

        assertEq(delta0, 100_000);
        assertEq(delta1, -197_432);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, 690_300);
    }

    function test_swap_initial_tick_far_from_zero_no_additional_fees_output() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 700_000});
        createPosition(poolKey, Bounds(600_000, 800_000), 1_000_000, 2_000_000);

        token1.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: -100_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        vm.snapshotGasLastCall("initial_tick_far_from_zero_no_additional_fees_output");

        assertEq(delta0, -100_000);
        assertEq(delta1, 205_416);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, 709_845);
    }

    function test_second_swap_with_additional_fees_gas_price() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 700_000});
        createPosition(poolKey, Bounds(600_000, 800_000), 1_000_000, 2_000_000);

        token0.approve(address(router), type(uint256).max);
        router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: 300_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: 300_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        vm.snapshotGasLastCall("second_swap_with_additional_fees_gas_price");

        assertEq(delta0, 300_000);
        assertEq(delta1, -556_308);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, 642_496);
    }

    function test_swap_max_fee_token0_input() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 700_000});
        createPosition(poolKey, Bounds(600_000, 800_000), 1_000_000, 2_000_000);

        token0.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: type(int128).max,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });

        assertEq(delta0, 1_054_639);
        assertEq(delta1, 0);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, MIN_TICK - 1);
    }

    function test_swap_max_fee_token1_input() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 700_000});
        createPosition(poolKey, Bounds(600_000, 800_000), 1_000_000, 2_000_000);

        token1.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: true,
            amount: type(int128).max,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });

        assertEq(delta0, 0);
        assertEq(delta1, 2_123_781);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, MAX_TICK);
    }

    function test_swap_max_fee_token0_output() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 700_000});
        createPosition(poolKey, Bounds(600_000, 800_000), 1_000_000, 2_000_000);

        token1.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: type(int128).min,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });

        assertEq(delta0, -993_170);
        assertEq(delta1, 38785072624969501783380726); // divided by 2**64 (max fee) this is ~ 2e6
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, MAX_TICK);
    }

    function test_swap_max_fee_token1_output() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 700_000});
        createPosition(poolKey, Bounds(600_000, 800_000), 1_000_000, 2_000_000);

        token0.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap({
            poolKey: poolKey,
            isToken1: true,
            amount: type(int128).min,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });

        assertEq(delta0, 19260097913407553165863219); // divided by 2**64 (max fee) this is ~ 1e6
        assertEq(delta1, -1_999_999);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, MIN_TICK - 1);
    }

    function test_new_position_does_not_get_fees() public {
        PoolKey memory poolKey =
            createMEVResistPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 700_000});
        Bounds memory bounds = Bounds(600_000, 800_000);
        (uint256 id1,) = createPosition(poolKey, bounds, 1_000_000, 2_000_000);

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: 500_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });
        router.swap({
            poolKey: poolKey,
            isToken1: true,
            amount: 2_000_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            calculatedAmountThreshold: type(int256).min,
            recipient: address(this)
        });

        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, 748_511);

        advanceTime(1);
        (uint256 id2,) = createPosition(poolKey, bounds, 1_000_000, 2_000_000);

        (uint128 amount0, uint128 amount1) = positions.collectFees(id2, poolKey, bounds);
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        (amount0, amount1) = positions.collectFees(id1, poolKey, bounds);
        assertEq(amount0, 28_843);
        assertEq(amount1, 43_372);
    }
}
