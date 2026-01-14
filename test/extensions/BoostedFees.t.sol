// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {BoostedFees, boostedFeesCallPoints} from "../../src/extensions/BoostedFees.sol";
import {IBoostedFees} from "../../src/interfaces/extensions/IBoostedFees.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PositionId} from "../../src/types/positionId.sol";
import {Locker} from "../../src/types/locker.sol";
import {CallPoints} from "../../src/types/callPoints.sol";
import {BoostedFeesLib} from "../../src/libraries/BoostedFeesLib.sol";
import {CoreStorageLayout} from "../../src/libraries/CoreStorageLayout.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {MAX_ABS_VALUE_SALE_RATE_DELTA, nextValidTime} from "../../src/math/time.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {TwammPoolState} from "../../src/types/twammPoolState.sol";

contract BoostedFeesConfigurator is UsesCore, BaseLocker {
    using FlashAccountantLib for *;
    using BoostedFeesLib for *;

    IBoostedFees private immutable boostedFees;

    constructor(ICore core, IBoostedFees _boostedFees) UsesCore(core) BaseLocker(core) {
        boostedFees = _boostedFees;
    }

    function configure(PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint112 rate0, uint112 rate1)
        external
        returns (uint112, uint112)
    {
        return abi.decode(lock(abi.encode(msg.sender, poolKey, startTime, endTime, rate0, rate1)), (uint112, uint112));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address payer, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint112 rate0, uint112 rate1) =
            abi.decode(data, (address, PoolKey, uint64, uint64, uint112, uint112));

        (uint112 amount0, uint112 amount1) = CORE.addIncentives(poolKey, startTime, endTime, rate0, rate1);

        if (amount0 != 0) ACCOUNTANT.payFrom(payer, poolKey.token0, amount0);
        if (amount1 != 0) ACCOUNTANT.payFrom(payer, poolKey.token1, amount1);

        return abi.encode(amount0, amount1);
    }
}

contract BoostedFeesTest is FullTest {
    using BoostedFeesLib for *;

    BoostedFees internal boostedFees;
    BoostedFeesConfigurator internal periphery;

    function setUp() public override {
        super.setUp();

        CallPoints memory cp = boostedFeesCallPoints();
        address target = address((uint160(cp.toUint8()) << 152) | 0xb005);
        deployCodeTo("BoostedFees.sol", abi.encode(core), target);
        boostedFees = BoostedFees(target);

        periphery = new BoostedFeesConfigurator(core, boostedFees);
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

    function test_configure_activeOrder_changesSaleRate(uint256 time, uint112 rate0, uint112 rate1, uint16 minDuration)
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
            periphery.configure({poolKey: poolKey, startTime: 0, endTime: endTime, rate0: rate0, rate1: rate1});

        assertEq(rate0 > 0, amount0 > 0, "amount0 is nonzero iff rate0 is nonzero");
        assertEq(rate1 > 0, amount1 > 0, "amount1 is nonzero iff rate1 is nonzero");

        TwammPoolState state = boostedFees.poolState(poolKey.toPoolId());
        (uint32 lastTime, uint112 totalRate0, uint112 totalRate1) = state.parse();
        assertEq(lastTime, uint32(vm.getBlockTimestamp()), "time is set to current");
        assertEq(totalRate0, rate0, "current rate0 is updated");
        assertEq(totalRate1, rate1, "current rate1 is updated");
    }

    function test_configure_futureOrder_doesNotChangeSaleRate(
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
            periphery.configure({poolKey: poolKey, startTime: startTime, endTime: endTime, rate0: rate0, rate1: rate1});

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

        periphery.configure({poolKey: poolKey, startTime: 0, endTime: endTime, rate0: rate, rate1: 0});

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

    function test_donatesFeesOnlyWithinConfiguredWindow(
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

        periphery.configure({poolKey: poolKey, startTime: startTime, endTime: endTime, rate0: 0, rate1: rate});

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
        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint112 rate = uint112(1 << 32);
        uint256 time = 1;

        while (true) {
            uint256 endTime = nextValidTime({currentTime: 1, afterTime: time});
            if (endTime == 0) break;
            periphery.configure({poolKey: poolKey, startTime: 0, endTime: uint64(endTime), rate0: rate, rate1: rate});
            time = endTime;
        }

        advanceTime(type(uint32).max);
        coolAllContracts();

        boostedFees.maybeAccumulateFees(poolKey);
        vm.snapshotGasLastCall("maybeAccumulateFees (donating all boosted fees)");
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
        periphery.configure({poolKey: poolKey, startTime: startTime, endTime: endTime, rate0: rate, rate1: rate});

        // warm up storage so the measured call is not paying the fees slot initialization cost
        advanceTime(1);
        boostedFees.maybeAccumulateFees(poolKey);

        advanceTime(1);
        coolAllContracts();

        boostedFees.maybeAccumulateFees(poolKey);
        vm.snapshotGasLastCall("maybeAccumulateFees (regular donation)");
    }
}
