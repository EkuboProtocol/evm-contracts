// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "../../src/math/constants.sol";
import {BoostedFees, boostedFeesCallPoints} from "../../src/extensions/BoostedFees.sol";
import {IBoostedFees} from "../../src/interfaces/extensions/IBoostedFees.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PositionId} from "../../src/types/positionId.sol";
import {Locker} from "../../src/types/locker.sol";
import {PoolConfig} from "../../src/types/poolConfig.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {BoostedFeesLib} from "../../src/libraries/BoostedFeesLib.sol";
import {CoreStorageLayout} from "../../src/libraries/CoreStorageLayout.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {PayableMulticallable} from "../../src/base/PayableMulticallable.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {MAX_ABS_VALUE_SALE_RATE_DELTA, MAX_NUM_VALID_TIMES, nextValidTime} from "../../src/math/time.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {TwammPoolState} from "../../src/types/twammPoolState.sol";
import {TWAMMStorageLayout} from "../../src/libraries/TWAMMStorageLayout.sol";
import {ExposedStorageLib} from "../../src/libraries/ExposedStorageLib.sol";
import {timeToBitmapWordAndIndex} from "../../src/math/timeBitmap.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title Manual Pool Booster
/// @dev Enables boosting pools manually. Approve this contract and then call boost.
contract ManualPoolBooster is PayableMulticallable, UsesCore, BaseLocker {
    using FlashAccountantLib for *;
    using BoostedFeesLib for *;

    IBoostedFees public immutable boostedFees;

    constructor(ICore core, IBoostedFees _boostedFees) UsesCore(core) BaseLocker(core) {
        boostedFees = _boostedFees;
    }

    function boost(PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint112 rate0, uint112 rate1)
        external
        payable
        returns (uint112, uint112)
    {
        return abi.decode(lock(abi.encode(msg.sender, poolKey, startTime, endTime, rate0, rate1)), (uint112, uint112));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address payer, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint112 rate0, uint112 rate1) =
            abi.decode(data, (address, PoolKey, uint64, uint64, uint112, uint112));

        (uint112 amount0, uint112 amount1) = CORE.addIncentives(poolKey, startTime, endTime, rate0, rate1);

        if (poolKey.token0 == NATIVE_TOKEN_ADDRESS) {
            if (amount0 != 0) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount0);
            if (amount1 != 0) ACCOUNTANT.payFrom(payer, poolKey.token1, amount1);
        } else {
            if (amount0 != 0 && amount1 != 0) {
                ACCOUNTANT.payTwoFrom(payer, poolKey.token0, poolKey.token1, amount0, amount1);
            } else if (amount0 != 0) {
                ACCOUNTANT.payFrom(payer, poolKey.token0, amount0);
            } else if (amount1 != 0) {
                ACCOUNTANT.payFrom(payer, poolKey.token1, amount1);
            }
        }

        return abi.encode(amount0, amount1);
    }
}

contract BoostedFeesTest is FullTest {
    using BoostedFeesLib for *;
    using ExposedStorageLib for *;

    BoostedFees internal boostedFees;
    ManualPoolBooster internal periphery;

    function _isTimeInitialized(PoolId poolId, uint256 time) internal view returns (bool) {
        StorageSlot base = TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId);
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        bytes32 bitmapWord = boostedFees.sload(base.add(word));
        return (uint256(bitmapWord) & (uint256(1) << index)) != 0;
    }

    function _timeInfo(PoolId poolId, uint256 time) internal view returns (bytes32) {
        return boostedFees.sload(TWAMMStorageLayout.poolTimeInfosSlot(poolId, time));
    }

    function _feesDonatedLogData(PoolId poolId, uint256 rate0, uint256 rate1)
        internal
        pure
        returns (bytes memory data)
    {
        data = new bytes(60);
        bytes32 poolIdValue = PoolId.unwrap(poolId);

        assembly ("memory-safe") {
            let ptr := add(data, 32)
            mstore(add(ptr, 28), rate1)
            mstore(add(ptr, 14), rate0)
            mstore(ptr, poolIdValue)
        }
    }

    function _hasFeesDonatedLog(Vm.Log[] memory logs, address emitter, PoolId poolId, uint256 rate0, uint256 rate1)
        internal
        pure
        returns (bool)
    {
        bytes memory expected = _feesDonatedLogData(poolId, rate0, rate1);
        bytes32 expectedHash = keccak256(expected);

        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != emitter) continue;
            if (logs[i].topics.length != 0) continue;
            if (logs[i].data.length != 60) continue;
            if (keccak256(logs[i].data) != expectedHash) continue;
            return true;
        }

        return false;
    }

    function _assertFeesDonatedLog(Vm.Log[] memory logs, address emitter, PoolId poolId, uint256 rate0, uint256 rate1)
        internal
        pure
    {
        bool found = _hasFeesDonatedLog(logs, emitter, poolId, rate0, rate1);
        assertTrue(found, "missing fees donated log");
    }

    function setUp() public override {
        super.setUp();

        CallPoints memory cp = boostedFeesCallPoints();
        address target = address((uint160(cp.toUint8()) << 152) | 0xb005);
        deployCodeTo("BoostedFees.sol", abi.encode(core), target);
        boostedFees = BoostedFees(target);

        periphery = new ManualPoolBooster(core, boostedFees);
    }

    function test_pool_mustBeInitialized(PoolKey memory otherPoolKey) public {
        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        boostedFees.maybeAccumulateFees(poolKey);

        vm.assume(
            !(poolKey.token0 == otherPoolKey.token0 && poolKey.token1 == otherPoolKey.token1
                    && PoolConfig.unwrap(poolKey.config) == PoolConfig.unwrap(otherPoolKey.config))
        );
        vm.expectRevert(IBoostedFees.PoolNotInitialized.selector);
        boostedFees.maybeAccumulateFees(otherPoolKey);
    }

    function test_pool_extension_mustMatchBoostedFees_evenIfInitialized() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(0)});

        // Core pool is initialized, but BoostedFees has no state for it and the pool's
        // configured extension is not BoostedFees.
        vm.expectRevert(IBoostedFees.PoolNotInitialized.selector);
        boostedFees.maybeAccumulateFees(poolKey);
    }

    function test_maybeAccumulateFees_recoversIfLocalStateMissing() public {
        vm.warp(1 << 32);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        PoolId poolId = poolKey.toPoolId();

        assertEq(boostedFees.sload(TWAMMStorageLayout.twammPoolStateSlot(poolId)), bytes32(0));

        // does not revert
        boostedFees.maybeAccumulateFees(poolKey);
    }

    function test_boost_reverts_invalidStartTime() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        vm.expectRevert(IBoostedFees.InvalidTimestamps.selector);
        periphery.boost({poolKey: poolKey, startTime: 257, endTime: 512, rate0: 1 << 32, rate1: 0});
    }

    function test_boost_reverts_invalidEndTime() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        vm.expectRevert(IBoostedFees.InvalidTimestamps.selector);
        periphery.boost({poolKey: poolKey, startTime: 0, endTime: 257, rate0: 1 << 32, rate1: 0});
    }

    function test_boost_reverts_endTimeLessOrEqualStartTime() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        vm.expectRevert(IBoostedFees.InvalidTimestamps.selector);
        periphery.boost({poolKey: poolKey, startTime: 512, endTime: 512, rate0: 1 << 32, rate1: 0});
    }

    function test_boost_reverts_endTimeInPast() public {
        vm.warp(512);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        vm.expectRevert(IBoostedFees.InvalidTimestamps.selector);
        periphery.boost({poolKey: poolKey, startTime: 0, endTime: 256, rate0: 1 << 32, rate1: 0});
    }

    function test_boost_reverts_maxRateDeltaPerTime() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint64 startTime = 512;
        uint64 endTime = 1024;

        uint112 rate = uint112(MAX_ABS_VALUE_SALE_RATE_DELTA);

        periphery.boost({poolKey: poolKey, startTime: startTime, endTime: endTime, rate0: rate, rate1: 0});

        vm.expectRevert(IBoostedFees.MaxRateDeltaPerTime.selector);
        periphery.boost({poolKey: poolKey, startTime: startTime, endTime: endTime, rate0: rate, rate1: 0});
    }

    function test_maybeAccumulateFees_isNoop_sameTimestamp() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        PoolId poolId = poolKey.toPoolId();
        createPosition(poolKey, -100, 100, 1e18, 1e18);

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        periphery.boost({poolKey: poolKey, startTime: 0, endTime: 512, rate0: 1 << 32, rate1: 0});

        vm.warp(257);
        vm.recordLogs();
        boostedFees.maybeAccumulateFees(poolKey);
        Vm.Log[] memory firstLogs = vm.getRecordedLogs();
        _assertFeesDonatedLog(firstLogs, address(boostedFees), poolId, 1 << 32, 0);

        vm.recordLogs();
        boostedFees.maybeAccumulateFees(poolKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no events emitted on second call");
    }

    function test_initialize_emitsFeesDonatedLog() public {
        vm.warp(1);

        vm.recordLogs();
        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertFeesDonatedLog(logs, address(boostedFees), poolKey.toPoolId(), 0, 0);
    }

    function test_maybeAccumulateFees_emitsWhenTimeChanges() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        PoolId poolId = poolKey.toPoolId();

        vm.warp(2);
        vm.recordLogs();
        boostedFees.maybeAccumulateFees(poolKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        _assertFeesDonatedLog(logs, address(boostedFees), poolId, 0, 0);
    }

    function test_boost_bitmap_cancels_whenOrderEndsAndNextStartsSameTime() public {
        uint64 currentTime = 1;
        vm.warp(currentTime);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        PoolId poolId = poolKey.toPoolId();

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint64 start1 = 512;
        uint64 end1 = 1024;
        uint64 end2 = 1536;

        uint112 rate = uint112(1 << 32);

        periphery.boost({poolKey: poolKey, startTime: start1, endTime: end1, rate0: rate, rate1: 0});
        periphery.boost({poolKey: poolKey, startTime: end1, endTime: end2, rate0: rate, rate1: 0});

        // At `end1`, the end of the first order (-rate) and the start of the
        // second order (+rate) cancel out.
        assertEq(_timeInfo(poolId, end1), bytes32(0));
        assertFalse(_isTimeInitialized(poolId, end1));

        assertNotEq(_timeInfo(poolId, start1), bytes32(0));
        assertTrue(_isTimeInitialized(poolId, start1));

        assertNotEq(_timeInfo(poolId, end2), bytes32(0));
        assertTrue(_isTimeInitialized(poolId, end2));

        // When we cross start1, maybeAccumulateFees should apply the delta and
        // clear the start1 time info.
        vm.warp(start1 + 256);
        boostedFees.maybeAccumulateFees(poolKey);

        assertEq(_timeInfo(poolId, start1), bytes32(0));
        assertFalse(_isTimeInitialized(poolId, start1));

        TwammPoolState state = boostedFees.poolState(poolId);
        (, uint112 rate0,) = state.parse();
        assertEq(rate0, rate);
    }

    function test_afterInitializePool_setsState(uint256 time, uint64 fee) public {
        vm.warp(time);

        PoolKey memory poolKey = createPool({tick: 0, fee: fee, tickSpacing: 100, extension: address(boostedFees)});

        TwammPoolState state = boostedFees.poolState(poolKey.toPoolId());
        (uint32 lastTime, uint112 rate0, uint112 rate1) = state.parse();

        assertEq(lastTime, uint32(vm.getBlockTimestamp()), "time is set to current");
        assertEq(rate0, 0, "rate0 is 0");
        assertEq(rate1, 0, "rate1 is 0");

        assertEq(state.realLastVirtualOrderExecutionTime(), time, "the real virtual execution time is now");
    }

    function test_boost_activeOrder_changesSaleRate(uint256 time, uint112 rate0, uint112 rate1, uint16 minDuration)
        public
    {
        time = bound(time, 0, type(uint64).max - type(uint32).max);
        vm.warp(time);

        rate0 = uint112(bound(rate0, 0, MAX_ABS_VALUE_SALE_RATE_DELTA));
        rate1 = uint112(bound(rate1, 0, MAX_ABS_VALUE_SALE_RATE_DELTA));

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint64 endTime = uint64(nextValidTime({currentTime: time, afterTime: time + minDuration}));

        (uint112 amount0, uint112 amount1) =
            periphery.boost({poolKey: poolKey, startTime: 0, endTime: endTime, rate0: rate0, rate1: rate1});

        assertEq(rate0 > 0, amount0 > 0, "amount0 is nonzero iff rate0 is nonzero");
        assertEq(rate1 > 0, amount1 > 0, "amount1 is nonzero iff rate1 is nonzero");

        TwammPoolState state = boostedFees.poolState(poolKey.toPoolId());
        (uint32 lastTime, uint112 totalRate0, uint112 totalRate1) = state.parse();
        assertEq(lastTime, uint32(vm.getBlockTimestamp()), "time is set to current");
        assertEq(totalRate0, rate0, "current rate0 is updated");
        assertEq(totalRate1, rate1, "current rate1 is updated");
    }

    function test_boost_futureOrder_doesNotChangeSaleRate(
        uint256 time,
        uint112 rate0,
        uint112 rate1,
        uint16 minDelay,
        uint16 minDuration
    ) public {
        time = bound(time, 0, type(uint64).max - type(uint32).max);
        vm.warp(time);

        rate0 = uint112(bound(rate0, 0, MAX_ABS_VALUE_SALE_RATE_DELTA));
        rate1 = uint112(bound(rate1, 0, MAX_ABS_VALUE_SALE_RATE_DELTA));

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint64 startTime = uint64(nextValidTime({currentTime: time, afterTime: time + minDelay}));
        uint64 endTime = uint64(nextValidTime({currentTime: time, afterTime: startTime + minDuration}));
        (uint112 amount0, uint112 amount1) =
            periphery.boost({poolKey: poolKey, startTime: startTime, endTime: endTime, rate0: rate0, rate1: rate1});

        assertEq(rate0 > 0, amount0 > 0, "amount0 is nonzero iff rate0 is nonzero");
        assertEq(rate1 > 0, amount1 > 0, "amount1 is nonzero iff rate1 is nonzero");

        TwammPoolState state = boostedFees.poolState(poolKey.toPoolId());
        (uint32 lastTime, uint112 totalRate0, uint112 totalRate1) = state.parse();
        assertEq(lastTime, uint32(vm.getBlockTimestamp()), "time is set to current");
        assertEq(totalRate0, 0, "current rate0 is zero");
        assertEq(totalRate1, 0, "current rate1 is zero");
    }

    function test_donatesFeesToActiveLiquidity(
        uint64 warpTime,
        uint32 durationHint,
        uint32 elapsedHint,
        uint112 rateHint
    ) public {
        uint64 currentTime = uint64(bound(warpTime, 1, type(uint64).max - type(uint32).max));
        vm.warp(currentTime);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        (uint256 positionId,) = createPosition(poolKey, -100, 100, 1e18, 1e18);

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint256 duration = bound(durationHint, 256, 7 days);
        uint64 endTime = uint64(nextValidTime({currentTime: currentTime, afterTime: currentTime + duration}));
        uint256 totalDuration = endTime - currentTime;
        vm.assume(totalDuration > 1);

        uint256 elapsedDuration = bound(elapsedHint, 1, totalDuration - 1);
        uint64 midTime = uint64(currentTime + elapsedDuration);

        uint112 rate = uint112(bound(rateHint, uint112(1 << 32), MAX_ABS_VALUE_SALE_RATE_DELTA));

        periphery.boost({poolKey: poolKey, startTime: 0, endTime: endTime, rate0: rate, rate1: 0});

        vm.warp(midTime);
        (uint128 partial0,) = positions.collectFees(positionId, poolKey, -100, 100);

        vm.warp(endTime + 256);
        (uint128 final0,) = positions.collectFees(positionId, poolKey, -100, 100);

        uint256 total = uint256(partial0) + uint256(final0);
        if (total > 0) {
            uint256 expectedPartial = (total * elapsedDuration) / totalDuration;
            assertApproxEqAbs(partial0, expectedPartial, 2, "token0 fees stream linearly over window");
        }
    }

    function test_donatesFeesOnlyWithinboostdWindow(
        uint64 warpTime,
        uint32 startDelayHint,
        uint32 durationHint,
        uint32 elapsedHint,
        uint112 rateHint
    ) public {
        uint64 currentTime = uint64(bound(warpTime, 1, type(uint64).max - type(uint32).max));
        vm.warp(currentTime);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        (uint256 positionId,) = createPosition(poolKey, -100, 100, 1e18, 1e18);

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint256 startDelay = bound(startDelayHint, 256, 7 days);
        uint64 startTime = uint64(nextValidTime({currentTime: currentTime, afterTime: currentTime + startDelay}));

        uint256 duration = bound(durationHint, 256, 7 days);
        uint64 endTime = uint64(nextValidTime({currentTime: currentTime, afterTime: startTime + duration}));

        uint256 totalDuration = endTime - startTime;
        vm.assume(totalDuration > 1);
        uint256 elapsedDuration = bound(elapsedHint, 1, totalDuration - 1);
        uint64 midTime = uint64(startTime + elapsedDuration);

        uint112 rate = uint112(bound(rateHint, uint112(1 << 32), MAX_ABS_VALUE_SALE_RATE_DELTA));

        periphery.boost({poolKey: poolKey, startTime: startTime, endTime: endTime, rate0: 0, rate1: rate});

        (uint128 before0, uint128 before1) = positions.collectFees(positionId, poolKey, -100, 100);
        assertEq(before0, 0, "no token0 fees before start");
        assertEq(before1, 0, "no token1 fees before start");

        vm.warp(midTime);
        (, uint128 during1) = positions.collectFees(positionId, poolKey, -100, 100);

        vm.warp(endTime + 256);
        (, uint128 after1) = positions.collectFees(positionId, poolKey, -100, 100);

        uint256 total = uint256(during1) + uint256(after1);
        if (total > 0) {
            uint256 expectedPartial = (total * elapsedDuration) / totalDuration;
            assertApproxEqAbs(during1, expectedPartial, 2, "token1 fees stream linearly within window");
        }
    }

    /// forge-config: default.isolate = true
    function test_donateFees_maximum_gas_cost() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});

        createPosition(poolKey, -100, 100, 1e18, 1e18);

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint112 rate = uint112(1 << 32);
        uint256 time = 1;

        while (true) {
            uint256 endTime = nextValidTime({currentTime: 1, afterTime: time});
            if (endTime == 0) break;
            periphery.boost({poolKey: poolKey, startTime: 0, endTime: uint64(endTime), rate0: rate, rate1: rate});
            time = endTime;
        }

        advanceTime(type(uint32).max);
        coolAllContracts();

        boostedFees.maybeAccumulateFees(poolKey);
        vm.snapshotGasLastCall("maybeAccumulateFees (donating all boosted fees)");
    }

    /// forge-config: default.isolate = true
    function test_swap_same_token_as_donated() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 1 << 63, tickSpacing: 100, extension: address(boostedFees)});
        createPosition(poolKey, -100, 100, 1e18, 1e18);

        token0.approve(address(periphery), type(uint128).max);
        token0.approve(address(router), type(uint128).max);
        periphery.boost({poolKey: poolKey, startTime: 0, endTime: 256, rate0: 1 << 32, rate1: 0});

        advanceTime(1);
        boostedFees.maybeAccumulateFees(poolKey);

        advanceTime(1);
        coolAllContracts();
        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: 100, _isToken1: false, _skipAhead: 0
            })
        });
        vm.snapshotGasLastCall("swap token0 (same token donated)");
    }

    /// forge-config: default.isolate = true
    function test_swap_different_token_as_donated() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 1 << 63, tickSpacing: 100, extension: address(boostedFees)});
        createPosition(poolKey, -100, 100, 1e18, 1e18);

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(router), type(uint128).max);
        periphery.boost({poolKey: poolKey, startTime: 0, endTime: 256, rate0: 1 << 32, rate1: 0});

        advanceTime(1);
        boostedFees.maybeAccumulateFees(poolKey);

        advanceTime(1);
        coolAllContracts();
        router.swapAllowPartialFill({
            poolKey: poolKey,
            params: createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: 100, _isToken1: true, _skipAhead: 0
            })
        });
        vm.snapshotGasLastCall("swap token1 (different token donated)");
    }

    /// forge-config: default.isolate = true
    function test_maybeAccumulateFees_regular_donation_gas_cost() public {
        uint64 currentTime = 256;
        vm.warp(currentTime);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});

        uint64 startTime = 0;
        uint64 endTime = uint64(nextValidTime({currentTime: currentTime, afterTime: currentTime}));
        uint112 rate = uint112(1 << 32);

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);
        periphery.boost({poolKey: poolKey, startTime: startTime, endTime: endTime, rate0: rate, rate1: rate});

        // warm up storage so the measured call is not paying the fees slot initialization cost
        advanceTime(1);
        boostedFees.maybeAccumulateFees(poolKey);

        advanceTime(1);
        coolAllContracts();

        boostedFees.maybeAccumulateFees(poolKey);
        vm.snapshotGasLastCall("maybeAccumulateFees (regular donation)");
    }

    function test_maxedEndTimes_saleRateNeverExceedsUint112Max_and_returnsToZero() public {
        vm.warp(1);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        PoolId poolId = poolKey.toPoolId();

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint112 rate = uint112(MAX_ABS_VALUE_SALE_RATE_DELTA);

        uint256 time = 1;
        uint256 lastEndTime;
        uint256 numOrders;

        while (true) {
            uint256 endTime = nextValidTime({currentTime: 1, afterTime: time});
            if (endTime == 0) break;

            periphery.boost({poolKey: poolKey, startTime: 0, endTime: uint64(endTime), rate0: rate, rate1: rate});

            numOrders++;
            lastEndTime = endTime;
            time = endTime;
        }

        TwammPoolState state = boostedFees.poolState(poolId);
        (, uint112 rate0, uint112 rate1) = state.parse();

        assertEq(numOrders, MAX_NUM_VALID_TIMES, "max number of orders");
        uint256 expectedTotalRate = numOrders * uint256(rate);
        assertLe(expectedTotalRate, type(uint112).max, "total rate fits uint112");
        assertEq(rate0, uint112(expectedTotalRate), "rate0 matches total");
        assertEq(rate1, uint112(expectedTotalRate), "rate1 matches total");

        // Settle all events up to the final end time.
        // Note: `TwammPoolState.realLastVirtualOrderExecutionTime()` reconstructs an absolute
        // time using modulo-2**32 arithmetic, so we settle exactly at `lastEndTime` first.
        vm.warp(lastEndTime);
        boostedFees.maybeAccumulateFees(poolKey);

        state = boostedFees.poolState(poolId);
        (, rate0, rate1) = state.parse();
        assertEq(rate0, 0, "rate0 returns to 0");
        assertEq(rate1, 0, "rate1 returns to 0");

        // After time has advanced past the last order, sale rates remain zero.
        vm.warp(lastEndTime + 256);
        boostedFees.maybeAccumulateFees(poolKey);

        state = boostedFees.poolState(poolId);
        (, rate0, rate1) = state.parse();
        assertEq(rate0, 0, "rate0 stays 0");
        assertEq(rate1, 0, "rate1 stays 0");
    }

    function test_boost_emitsPoolBoosted(
        uint64 warpTime,
        uint64 startDelay,
        uint64 duration,
        uint112 rate0,
        uint112 rate1
    ) public {
        uint64 currentTime = uint64(bound(warpTime, 1, type(uint32).max - 8192));
        vm.warp(currentTime);

        rate0 = uint112(bound(rate0, 1, MAX_ABS_VALUE_SALE_RATE_DELTA));
        rate1 = uint112(bound(rate1, 1, MAX_ABS_VALUE_SALE_RATE_DELTA));

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint64 startTime =
            uint64(nextValidTime({currentTime: currentTime, afterTime: currentTime + bound(startDelay, 0, 7 days)}));
        uint64 endTime =
            uint64(nextValidTime({currentTime: currentTime, afterTime: startTime + bound(duration, 256, 7 days)}));

        vm.expectEmit(true, true, true, true, address(boostedFees));
        emit IBoostedFees.PoolBoosted(poolKey.toPoolId(), startTime, endTime, rate0, rate1);

        periphery.boost({poolKey: poolKey, startTime: startTime, endTime: endTime, rate0: rate0, rate1: rate1});
    }

    function test_maybeAccumulateFees_emitsFeesAccumulated(uint64 warpTime) public {
        uint64 currentTime = uint64(bound(warpTime, 1, type(uint32).max - 8192));
        vm.warp(currentTime);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint64 startTime = uint64(nextValidTime({currentTime: currentTime, afterTime: currentTime + 256}));
        uint64 endTime = uint64(nextValidTime({currentTime: currentTime, afterTime: startTime + 512}));
        vm.assume(startTime != 0 && endTime != 0 && endTime > startTime);

        uint112 rate0 = uint112(1 << 32);
        uint112 rate1 = 0;

        periphery.boost({poolKey: poolKey, startTime: startTime, endTime: endTime, rate0: rate0, rate1: rate1});

        uint64 donationTime = startTime + 256;
        vm.warp(donationTime);

        vm.expectEmit(true, true, true, true, address(core));
        uint128 expectedAmount0 = uint128((uint256(rate0) * (donationTime - startTime)) >> 32);
        emit ICore.FeesAccumulated(poolKey.toPoolId(), expectedAmount0, 0);

        boostedFees.maybeAccumulateFees(poolKey);
    }
}
