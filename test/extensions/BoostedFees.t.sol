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

    function test_donatesFeesToActiveLiquidity() public {
        uint64 startTime = 256;
        vm.warp(startTime);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        (uint256 positionId,) = createPosition(poolKey, -100, 100, 1e18, 1e18);

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint64 endTime = 1024;
        uint112 rate = uint112(1 << 32);

        periphery.configure({poolKey: poolKey, startTime: startTime, endTime: endTime, rate0: rate, rate1: 0});

        uint64 midTime = startTime + 256;
        vm.warp(midTime);

        (uint128 partial0, uint128 partial1) = positions.collectFees(positionId, poolKey, -100, 100);
        assertEq(partial0, 255, "fees are streamed for elapsed time");
        assertEq(partial1, 0, "no token1 incentives");

        vm.warp(endTime + 256);

        (uint128 final0, uint128 final1) = positions.collectFees(positionId, poolKey, -100, 100);
        assertEq(final0, 511, "remaining amount is donated");
        assertEq(final1, 0, "no token1 incentives");
    }

    function test_donatesFeesOnlyWithinConfiguredWindow() public {
        uint64 currentTime = 256;
        vm.warp(currentTime);

        PoolKey memory poolKey = createPool({tick: 0, fee: 0, tickSpacing: 100, extension: address(boostedFees)});
        (uint256 positionId,) = createPosition(poolKey, -100, 100, 1e18, 1e18);

        token0.approve(address(periphery), type(uint128).max);
        token1.approve(address(periphery), type(uint128).max);

        uint64 startTime = 1024;
        uint64 endTime = 1792;

        uint112 rate = uint112(1 << 32);

        periphery.configure({poolKey: poolKey, startTime: startTime, endTime: endTime, rate0: 0, rate1: rate});

        (uint128 before0, uint128 before1) = positions.collectFees(positionId, poolKey, -100, 100);
        assertEq(before0, 0, "no token0 fees before start");
        assertEq(before1, 0, "no token1 fees before start");

        vm.warp(startTime + 256);
        (uint128 during0, uint128 during1) = positions.collectFees(positionId, poolKey, -100, 100);
        assertEq(during0, 0, "no token0 incentives");
        assertEq(during1, 255, "token1 fees accrue after start");

        vm.warp(endTime + 256);
        (uint128 after0, uint128 after1) = positions.collectFees(positionId, poolKey, -100, 100);
        assertEq(after0, 0, "no token0 incentives after window");
        assertEq(after1, 511, "only remaining window worth of token1 fees are donated");
    }
}
