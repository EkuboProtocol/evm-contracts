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
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {BoostedFeesLib} from "../../src/libraries/BoostedFeesLib.sol";
import {CoreStorageLayout} from "../../src/libraries/CoreStorageLayout.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {MAX_ABS_VALUE_SALE_RATE_DELTA, nextValidTime} from "../../src/math/time.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {TwammPoolState} from "../../src/types/twammPoolState.sol";

contract BoostedFeesConfigurator is BaseLocker {
    using FlashAccountantLib for *;

    IBoostedFees private immutable boostedFees;

    constructor(ICore core, IBoostedFees _boostedFees) BaseLocker(core) {
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

        (uint112 amount0, uint112 amount1) = abi.decode(
            ACCOUNTANT.forward(address(boostedFees), abi.encode(poolKey, startTime, endTime, rate0, rate1)),
            (uint112, uint112)
        );

        ACCOUNTANT.payFrom(payer, poolKey.token0, amount0);
        ACCOUNTANT.payFrom(payer, poolKey.token1, amount1);

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
}
