// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolConfig, createConcentratedPoolConfig, createStableswapPoolConfig} from "../../src/types/poolConfig.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING_EXP} from "../../src/math/constants.sol";
import {FullTest} from "../FullTest.sol";
import {MEVCapture, mevCaptureCallPoints} from "../../src/extensions/MEVCapture.sol";
import {IMEVCapture} from "../../src/interfaces/extensions/IMEVCapture.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {ExposedStorageLib} from "../../src/libraries/ExposedStorageLib.sol";
import {Router} from "../../src/Router.sol";
import {MEVCapturePoolState} from "../../src/types/mevCapturePoolState.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";

abstract contract BaseMEVCaptureTest is FullTest {
    MEVCapture internal mevCapture;

    function setUp() public virtual override {
        FullTest.setUp();
        address deployAddress = address(uint160(mevCaptureCallPoints().toUint8()) << 152);
        deployCodeTo("MEVCapture.sol", abi.encode(core), deployAddress);
        mevCapture = MEVCapture(deployAddress);
        router = new Router(core, address(mevCapture), address(0));
    }

    function coolAllContracts() internal virtual override {
        FullTest.coolAllContracts();
        vm.cool(address(mevCapture));
    }

    function createMEVCapturePool(uint16 fee, uint8 tickSpacingExp, int32 tick)
        internal
        returns (PoolKey memory poolKey)
    {
        poolKey = createPool(
            address(token0),
            address(token1),
            tick,
            createConcentratedPoolConfig(fee, tickSpacingExp, address(mevCapture), 0)
        );
    }
}

contract MEVCaptureTest is BaseMEVCaptureTest {
    using CoreLib for *;
    using ExposedStorageLib for *;

    function test_isRegistered() public view {
        assertTrue(core.isExtensionRegistered(address(mevCapture)));
    }

    function getPoolState(PoolId poolId) private view returns (MEVCapturePoolState state) {
        state = MEVCapturePoolState.wrap(mevCapture.sload(PoolId.unwrap(poolId)));
    }

    function test_pool_initialization_success(uint256 time, uint16 fee, uint8 tickSpacingExp, int32 tick, uint32 warp)
        public
    {
        vm.warp(time);
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        fee = uint16(bound(fee, 1, type(uint16).max));
        tickSpacingExp = uint8(bound(tickSpacingExp, 0, MAX_TICK_SPACING_EXP));

        PoolKey memory poolKey = createMEVCapturePool({fee: fee, tickSpacingExp: tickSpacingExp, tick: tick});

        MEVCapturePoolState state = getPoolState(poolKey.toPoolId());
        assertEq(state.lastUpdateTime(), uint32(vm.getBlockTimestamp()));
        assertEq(state.tickLast(), tick);

        unchecked {
            vm.warp(time + uint256(warp));
        }
        mevCapture.accumulatePoolFees(poolKey);
        state = getPoolState(poolKey.toPoolId());
        assertEq(state.lastUpdateTime(), uint32(vm.getBlockTimestamp()));
        assertEq(state.tickLast(), tick);
    }

    function test_before_initialize_pool_must_be_called_by_core() public {
        vm.expectRevert(UsesCore.CoreOnly.selector);
        mevCapture.beforeInitializePool(
            address(0), PoolKey({token0: address(0), token1: address(1), config: PoolConfig.wrap(bytes32(0))}), 123
        );
    }

    function test_accumulate_fees_for_any_pool(uint256 time, PoolKey memory poolKey) public {
        // note that you can accumulate fees for any pool at any time, but it is no-op if the pool does not exist
        vm.warp(time);
        mevCapture.accumulatePoolFees(poolKey);
        MEVCapturePoolState state = getPoolState(poolKey.toPoolId());
        assertEq(state.lastUpdateTime(), uint32(vm.getBlockTimestamp()));
        assertEq(state.tickLast(), 0);
    }

    function test_pool_initialization_validation(uint16 fee, uint8 amplification, int32 centerTick) public {
        amplification = uint8(bound(amplification, 0, 26));
        centerTick = int32(bound(centerTick, MIN_TICK, MAX_TICK));

        vm.expectRevert(IMEVCapture.ConcentratedLiquidityPoolsOnly.selector);
        createPool({
            _token0: address(token0),
            _token1: address(token1),
            tick: 0,
            // full range is included because
            config: createStableswapPoolConfig({
                _fee: fee,
                _amplification: amplification,
                _centerTick: centerTick,
                _extension: address(mevCapture),
                _salt: 0
            })
        });

        vm.expectRevert(IMEVCapture.NonzeroFeesOnly.selector);
        createPool({
            _token0: address(token0),
            _token1: address(token1),
            tick: 0,
            config: createConcentratedPoolConfig({
                _fee: 0, _tickSpacingExp: 0, _extension: address(mevCapture), _salt: 0
            })
        });
    }

    /// forge-config: default.isolate = true
    function test_swap_input_token0_no_movement() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 0});
        createPosition(poolKey, -98304, 98304, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);
        coolAllContracts();
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("input_token0_no_movement");

        assertEq(balanceUpdate.delta0(), 100_000);
        assertEq(balanceUpdate.delta1(), -97_963);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, -9475);
    }

    function test_quote() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 0});
        createPosition(poolKey, -98304, 98304, 1_000_000, 1_000_000);

        (PoolBalanceUpdate balanceUpdate,) = router.quote({
            poolKey: poolKey, isToken1: false, amount: 100_000, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0
        });

        assertEq(balanceUpdate.delta0(), 100_000);
        assertEq(balanceUpdate.delta1(), -97_963);
    }

    /// forge-config: default.isolate = true
    function test_swap_output_token0_no_movement() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 0});
        createPosition(poolKey, -98304, 98304, 1_000_000, 1_000_000);

        token1.approve(address(router), type(uint256).max);
        coolAllContracts();
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: -100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("output_token0_no_movement");

        assertEq(balanceUpdate.delta0(), -100_000);
        assertEq(balanceUpdate.delta1(), 102_090);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, 9615);
    }

    /// forge-config: default.isolate = true
    function test_swap_input_token1_no_movement() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 0});
        createPosition(poolKey, -98304, 98304, 1_000_000, 1_000_000);

        token1.approve(address(router), type(uint256).max);
        coolAllContracts();
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: true, _amount: 100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("input_token1_no_movement");

        assertEq(balanceUpdate.delta0(), -97_963);
        assertEq(balanceUpdate.delta1(), 100_000);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, 9474);
    }

    /// forge-config: default.isolate = true
    function test_swap_output_token1_no_movement() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 0});
        createPosition(poolKey, -98304, 98304, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);
        coolAllContracts();
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: true, _amount: -100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("output_token1_no_movement");

        assertEq(balanceUpdate.delta0(), 102_090);
        assertEq(balanceUpdate.delta1(), -100_000);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, -9616);
    }

    /// now tests with movement more than one tick spacing

    /// forge-config: default.isolate = true
    function test_swap_input_token0_move_tick_spacings() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 0});
        createPosition(poolKey, -98304, 98304, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);
        coolAllContracts();
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 500_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("input_token0_move_tick_spacings");

        assertEq(balanceUpdate.delta0(), 500_000);
        assertEq(balanceUpdate.delta1(), -469_680);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, -46930);
    }

    /// forge-config: default.isolate = true
    function test_swap_output_token0_move_tick_spacings() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 0});
        createPosition(poolKey, -98304, 98304, 1_000_000, 1_000_000);

        token1.approve(address(router), type(uint256).max);
        coolAllContracts();
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: -500_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("output_token0_move_tick_spacings");

        assertEq(balanceUpdate.delta0(), -500_000);
        assertEq(balanceUpdate.delta1(), 533_086);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, 48548);
    }

    /// forge-config: default.isolate = true
    function test_swap_input_token1_move_tick_spacings() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 0});
        createPosition(poolKey, -98304, 98304, 1_000_000, 1_000_000);

        token1.approve(address(router), type(uint256).max);
        coolAllContracts();
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: true, _amount: 500_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("input_token1_move_tick_spacings");

        assertEq(balanceUpdate.delta0(), -469_680);
        assertEq(balanceUpdate.delta1(), 500_000);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, 46929);
    }

    /// forge-config: default.isolate = true
    function test_swap_output_token1_move_tick_spacings() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 0});
        createPosition(poolKey, -98304, 98304, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);
        coolAllContracts();
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: true, _amount: -500_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("output_token1_move_tick_spacings");

        assertEq(balanceUpdate.delta0(), 533_086);
        assertEq(balanceUpdate.delta1(), -500_000);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, -48549);
    }

    /// forge-config: default.isolate = true
    function test_extra_fees_are_accumulated_in_next_block() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 0});
        (uint256 id,) = createPosition(poolKey, -98304, 98304, 1_000_000, 1_000_000);

        token0.approve(address(router), type(uint256).max);
        router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: false,
            amount: 500_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            recipient: address(this)
        });
        (uint128 amount0, uint128 amount1) = positions.collectFees(id, poolKey, -98304, 98304);
        assertEq(amount0, 4997);
        assertEq(amount1, 0);

        advanceTime(1);
        (amount0, amount1) = positions.collectFees(id, poolKey, -98304, 98304);
        assertEq(amount0, 0);
        assertEq(amount1, 13840);

        advanceTime(1);
        (amount0, amount1) = positions.collectFees(id, poolKey, -98304, 98304);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
    }

    /// forge-config: default.isolate = true
    function test_swap_initial_tick_far_from_zero_no_additional_fees() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 700_000});
        createPosition(poolKey, 589824, 802816, 1_000_000, 2_000_000);

        token0.approve(address(router), type(uint256).max);
        coolAllContracts();
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("initial_tick_far_from_zero_no_additional_fees");

        assertEq(balanceUpdate.delta0(), 100_000);
        assertEq(balanceUpdate.delta1(), -197_011);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, 689343);
    }

    /// forge-config: default.isolate = true
    function test_swap_initial_tick_far_from_zero_no_additional_fees_output() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 700_000});
        createPosition(poolKey, 589824, 802816, 1_000_000, 2_000_000);

        token1.approve(address(router), type(uint256).max);
        coolAllContracts();
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: -100_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("initial_tick_far_from_zero_no_additional_fees_output");

        assertEq(balanceUpdate.delta0(), -100_000);
        assertEq(balanceUpdate.delta1(), 205_856);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, 710822);
    }

    /// forge-config: default.isolate = true
    function test_second_swap_with_additional_fees_gas_price() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 700_000});
        createPosition(poolKey, 589824, 802816, 1_000_000, 2_000_000);

        token0.approve(address(router), type(uint256).max);
        router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: false,
            amount: 300_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            recipient: address(this)
        });
        coolAllContracts();
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 300_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("second_swap_with_additional_fees_gas_price");

        assertEq(balanceUpdate.delta0(), 300_000);
        assertEq(balanceUpdate.delta1(), -548_415);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, 636893);
    }

    /// forge-config: default.isolate = true
    function test_second_swap_after_some_time_gas_price() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 700_000});
        createPosition(poolKey, 589824, 802816, 1_000_000, 2_000_000);

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: false,
            amount: 300_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            recipient: address(this)
        });
        router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: true,
            amount: 900_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            recipient: address(this)
        });

        advanceTime(1);

        coolAllContracts();
        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _isToken1: false, _amount: 500_000, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0, _minFee: 0
            }),
            recipient: address(this)
        });
        vm.snapshotGasLastCall("third_swap_accumulates_fees");
    }

    /// forge-config: default.isolate = true
    function test_withdraw_after_fees_accumulated() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 700_000});
        (uint256 id, uint128 liquidity) = createPosition(poolKey, 589824, 802816, 1_000_000, 2_000_000);

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: false,
            amount: 300_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            recipient: address(this)
        });
        router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: true,
            amount: 900_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            recipient: address(this)
        });

        advanceTime(1);

        coolAllContracts();
        positions.withdraw({
            id: id,
            poolKey: poolKey,
            tickLower: 589824,
            tickUpper: 802816,
            liquidity: liquidity,
            withFees: true,
            recipient: address(this)
        });
        vm.snapshotGasLastCall("positions withdraw after fees accumulate");
    }

    function test_swap_max_fee_token0_input() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 700_000});
        createPosition(poolKey, 589824, 802816, 1_000_000, 2_000_000);

        token0.approve(address(router), type(uint256).max);
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: false,
            amount: type(int128).max,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            recipient: address(this)
        });

        assertEq(balanceUpdate.delta0(), 1_060_013);
        assertEq(balanceUpdate.delta1(), -30);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, MIN_TICK - 1);
    }

    function test_swap_max_fee_token1_input() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 700_000});
        createPosition(poolKey, 589824, 802816, 1_000_000, 2_000_000);

        token1.approve(address(router), type(uint256).max);
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: true,
            amount: type(int128).max,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            recipient: address(this)
        });

        assertEq(balanceUpdate.delta0(), -14);
        assertEq(balanceUpdate.delta1(), 1_988_312);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, MAX_TICK);
    }

    function test_swap_max_fee_token0_output() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 700_000});
        createPosition(poolKey, 589824, 802816, 1_000_000, 2_000_000);

        token1.approve(address(router), type(uint256).max);
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: false,
            amount: type(int128).min,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            recipient: address(this)
        });

        assertEq(balanceUpdate.delta0(), -928_516);
        assertEq(balanceUpdate.delta1(), 129003638177); // divided by 2**64 (max fee) this is ~ 2e6
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, MAX_TICK);
    }

    function test_swap_max_fee_token1_output() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 700_000});
        createPosition(poolKey, 589824, 802816, 1_000_000, 2_000_000);

        token0.approve(address(router), type(uint256).max);
        PoolBalanceUpdate balanceUpdate = router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: true,
            amount: type(int128).min,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            recipient: address(this)
        });

        assertEq(balanceUpdate.delta0(), 68774668643); // divided by 2**16 (max fee) this is ~ 1e6
        assertEq(balanceUpdate.delta1(), -1_999_999);
        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, MIN_TICK - 1);
    }

    function test_new_position_does_not_get_fees() public {
        PoolKey memory poolKey =
            createMEVCapturePool({fee: uint16(uint256(1 << 16) / 100), tickSpacingExp: 14, tick: 700_000});
        (uint256 id1,) = createPosition(poolKey, 589824, 802816, 1_000_000, 2_000_000);

        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: false,
            amount: 500_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            recipient: address(this)
        });
        router.swapAllowPartialFill({
            poolKey: poolKey,
            isToken1: true,
            amount: 2_000_000,
            sqrtRatioLimit: SqrtRatio.wrap(0),
            skipAhead: 0,
            recipient: address(this)
        });

        int32 tick = core.poolState(poolKey.toPoolId()).tick();
        assertEq(tick, 753369);

        advanceTime(1);
        (uint256 id2,) = createPosition(poolKey, 589824, 802816, 1_000_000, 2_000_000);

        (uint128 amount0, uint128 amount1) = positions.collectFees(id2, poolKey, 589824, 802816);
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        (amount0, amount1) = positions.collectFees(id1, poolKey, 589824, 802816);
        assertEq(amount0, 36_988);
        assertEq(amount1, 51_202);
    }
}
