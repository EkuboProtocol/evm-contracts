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
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {TestToken} from "../TestToken.sol";
import {amount0Delta, amount1Delta} from "../../src/math/delta.sol";
import {liquidityDeltaToAmountDelta} from "../../src/math/liquidity.sol";
import {FullRangeOnlyPool} from "../../src/types/positionKey.sol";
import {MEVResistRouter} from "../../src/MEVResistRouter.sol";
import {Vm} from "forge-std/Vm.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {MEVResistLib} from "../../src/libraries/MEVResistLib.sol";

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
    using MEVResistLib for *;

    function test_isRegistered() public view {
        assertTrue(core.isExtensionRegistered(address(mevResist)));
    }

    function test_pool_initialization_success(uint256 time, uint64 fee, uint32 tickSpacing, int32 tick) public {
        vm.warp(time);
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        fee = uint64(bound(fee, 1, type(uint64).max));
        tickSpacing = uint32(bound(tickSpacing, 1, MAX_TICK_SPACING));

        PoolKey memory poolKey = createMEVResistPool({fee: fee, tickSpacing: tickSpacing, tick: tick});

        (uint32 lastUpdateTime, int32 tickLast, uint96 fees0, uint96 fees1) = mevResist.poolState(poolKey.toPoolId());
        assertEq(lastUpdateTime, uint32(vm.getBlockTimestamp()));
        assertEq(tickLast, tick);
        assertEq(fees0, 0);
        assertEq(fees1, 0);
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
        assertEq(delta1, -98_524);
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
        assertEq(delta1, 101_507);
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

        assertEq(delta0, -98_524);
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

        assertEq(delta0, 101_507);
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
        assertEq(delta1, -473_664);
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
        assertEq(delta1, 528_135);
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

        assertEq(delta0, -473_664);
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

        assertEq(delta0, 528_135);
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
        assertEq(amount1, 9666);

        advanceTime(1);
        (amount0, amount1) = positions.collectFees(id, poolKey, bounds);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }
}
