// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolConfig, createConcentratedPoolConfig, createStableswapPoolConfig} from "../../src/types/poolConfig.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../../src/math/constants.sol";
import {FullTest} from "../FullTest.sol";
import {CircuitBreaker, circuitBreakerCallPoints} from "../../src/extensions/CircuitBreaker.sol";
import {ICircuitBreaker} from "../../src/interfaces/extensions/ICircuitBreaker.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {CircuitBreakerLib} from "../../src/libraries/CircuitBreakerLib.sol";
import {ExposedStorageLib} from "../../src/libraries/ExposedStorageLib.sol";
import {CircuitBreakerPoolState} from "../../src/types/circuitBreakerPoolState.sol";
import {Locker} from "../../src/types/locker.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolState} from "../../src/types/poolState.sol";

abstract contract BaseCircuitBreakerTest is FullTest {
    uint32 internal constant DEFAULT_AMPERAGE = 1;
    uint32 internal constant DEFAULT_HALT_DURATION = 3 days;

    CircuitBreaker internal circuitBreaker;

    function setUp() public virtual override {
        FullTest.setUp();
        address deployAddress = address(uint160(circuitBreakerCallPoints().toUint8()) << 152);
        deployCodeTo("CircuitBreaker.sol", abi.encode(core, DEFAULT_AMPERAGE, DEFAULT_HALT_DURATION), deployAddress);
        circuitBreaker = CircuitBreaker(deployAddress);
    }

    function coolAllContracts() internal virtual override {
        FullTest.coolAllContracts();
        vm.cool(address(circuitBreaker));
    }

    function createCircuitBreakerPool(uint64 fee, uint32 tickSpacing, int32 tick)
        internal
        returns (PoolKey memory poolKey)
    {
        poolKey = createPool(
            address(token0),
            address(token1),
            tick,
            createConcentratedPoolConfig(fee, tickSpacing, address(circuitBreaker))
        );
    }
}

contract CircuitBreakerTest is BaseCircuitBreakerTest {
    using CoreLib for *;
    using ExposedStorageLib for *;
    using CircuitBreakerLib for *;

    uint256 internal constant MAX_START_TIME = type(uint256).max - type(uint32).max;

    function test_isRegistered() public view {
        assertTrue(core.isExtensionRegistered(address(circuitBreaker)));
        assertEq(circuitBreaker.AMPERAGE(), DEFAULT_AMPERAGE);
        assertEq(circuitBreaker.HALT_DURATION(), DEFAULT_HALT_DURATION);
    }

    function test_pool_initialization_success(uint64 fee, uint32 tickSpacing, int32 tick, uint256 startTime) public {
        fee = uint64(bound(fee, 0, type(uint64).max));
        tickSpacing = uint32(bound(tickSpacing, 1, MAX_TICK_SPACING));
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        startTime = bound(startTime, 0, MAX_START_TIME);
        vm.warp(startTime);

        PoolKey memory poolKey = createCircuitBreakerPool(fee, tickSpacing, tick);
        CircuitBreakerPoolState state = circuitBreaker.poolState(poolKey.toPoolId());

        assertEq(state.lastSwapTimestamp(), uint64(vm.getBlockTimestamp()));
        assertEq(state.blockStartTick(), tick);
    }

    function test_before_initialize_pool_must_be_called_by_core() public {
        vm.expectRevert(UsesCore.CoreOnly.selector);
        circuitBreaker.beforeInitializePool(
            address(0), PoolKey({token0: address(0), token1: address(1), config: PoolConfig.wrap(bytes32(0))}), 123
        );
    }

    function test_before_initialize_pool_reverts_for_stableswap_pool() public {
        vm.expectRevert(ICircuitBreaker.ConcentratedLiquidityPoolsOnly.selector);
        createPool(address(token0), address(token1), 0, createStableswapPoolConfig(0, 4, 0, address(circuitBreaker)));
    }

    function test_before_swap_must_be_called_by_core() public {
        PoolKey memory poolKey = createCircuitBreakerPool({fee: 0, tickSpacing: 1, tick: 0});
        vm.expectRevert(UsesCore.CoreOnly.selector);
        circuitBreaker.beforeSwap(
            Locker.wrap(bytes32(0)), poolKey, createSwapParameters(SqrtRatio.wrap(0), 1, false, 0)
        );
    }

    function test_after_swap_must_be_called_by_core() public {
        PoolKey memory poolKey = createCircuitBreakerPool({fee: 0, tickSpacing: 1, tick: 0});
        vm.expectRevert(UsesCore.CoreOnly.selector);
        circuitBreaker.afterSwap(
            Locker.wrap(bytes32(0)),
            poolKey,
            createSwapParameters(SqrtRatio.wrap(0), 1, false, 0),
            PoolBalanceUpdate.wrap(bytes32(0)),
            PoolState.wrap(bytes32(0))
        );
    }

    function test_reverts_when_swap_exceeds_hard_limit(uint256 startTime) public {
        startTime = bound(startTime, 0, MAX_START_TIME);
        vm.warp(startTime);

        PoolKey memory poolKey =
            createCircuitBreakerPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                ICircuitBreaker.TickMovementExceedsHardLimit.selector, 40_000, int32(0), int32(-47_710)
            )
        );
        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 500_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }),
            recipient: address(this)
        });
    }

    function test_before_swap_reverts_after_black_swan_move(uint256 startTime) public {
        startTime = bound(startTime, 0, MAX_START_TIME);
        vm.warp(startTime);

        PoolKey memory poolKey =
            createCircuitBreakerPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);

        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 250_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }),
            recipient: address(this)
        });
        vm.warp(startTime + 1);
        uint256 resetTime = CircuitBreakerLib.resetTime(circuitBreaker, poolKey.toPoolId());

        vm.expectRevert(abi.encodeWithSelector(ICircuitBreaker.BreakerTripped.selector, resetTime));
        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 1, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }),
            recipient: address(this)
        });
    }

    function test_allows_swapping_again_after_halt_duration(uint256 startTime) public {
        startTime = bound(startTime, 0, MAX_START_TIME);
        vm.warp(startTime);

        PoolKey memory poolKey =
            createCircuitBreakerPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);

        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 250_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }),
            recipient: address(this)
        });
        uint256 resetTime = CircuitBreakerLib.resetTime(circuitBreaker, poolKey.toPoolId());

        vm.warp(resetTime);

        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 1, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }),
            recipient: address(this)
        });

        assertEq(balanceUpdate.delta0(), 1);
    }

    function test_successful_swap_updates_last_swap_timestamp(uint256 startTime) public {
        startTime = bound(startTime, 0, MAX_START_TIME);
        vm.warp(startTime);

        PoolKey memory poolKey =
            createCircuitBreakerPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);

        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 1, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }),
            recipient: address(this)
        });

        CircuitBreakerPoolState state = circuitBreaker.poolState(poolKey.toPoolId());
        assertEq(state.lastSwapTimestamp(), uint64(vm.getBlockTimestamp()));
        assertEq(state.blockStartTick(), 0);
    }

    function test_gas_snapshot_swap_on_circuit_breaker_pool() public {
        PoolKey memory poolKey =
            createCircuitBreakerPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);
        coolAllContracts();

        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("circuit breaker swap token0 no movement");
    }

    function test_library_reports_fuse_not_tripped_within_same_block(uint256 startTime) public {
        startTime = bound(startTime, 0, MAX_START_TIME);
        vm.warp(startTime);

        PoolKey memory poolKey =
            createCircuitBreakerPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);

        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 250_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }),
            recipient: address(this)
        });

        assertFalse(CircuitBreakerLib.isFuseTripped(core, circuitBreaker, poolKey));
    }

    function test_library_reports_fuse_tripped_next_block(uint256 startTime) public {
        startTime = bound(startTime, 0, MAX_START_TIME);
        vm.warp(startTime);

        PoolKey memory poolKey =
            createCircuitBreakerPool({fee: uint64(uint256(1 << 64) / 100), tickSpacing: 20_000, tick: 0});
        createPosition(poolKey, -100_000, 100_000, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);

        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 250_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
            }),
            recipient: address(this)
        });

        vm.warp(vm.getBlockTimestamp() + 1);

        assertTrue(CircuitBreakerLib.isFuseTripped(core, circuitBreaker, poolKey));
        assertEq(CircuitBreakerLib.resetTime(circuitBreaker, poolKey.toPoolId()), startTime + DEFAULT_HALT_DURATION);
    }
}
