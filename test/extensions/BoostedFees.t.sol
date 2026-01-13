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
import {nextValidTime} from "../../src/math/time.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {TwammPoolState} from "../../src/types/twammPoolState.sol";

contract BoostedFeesConfigurator is BaseLocker {
    using FlashAccountantLib for *;

    IBoostedFees private immutable boostedFees;

    constructor(ICore core, IBoostedFees boostedFees) BaseLocker(core) {}

    function configure(PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint128 amount0, uint128 amount1)
        external
    {
        lock(abi.encode(poolKey, startTime, endTime, amount0, amount1));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint128 amount0, uint128 amount1) =
            abi.decode(data, (PoolKey, uint64, uint64, uint128, uint128));

        ACCOUNTANT.forward(address(boostedFees), data);
    }
}

contract BoostedFeesTest is FullTest {
    using BoostedFeesLib for *;

    BoostedFees internal boostedFees;
    BoostedFeesConfigurator internal configurator;

    function setUp() public override {
        super.setUp();

        CallPoints memory cp = boostedFeesCallPoints();
        address target = address((uint160(cp.toUint8()) << 152) | 0xb005);
        deployCodeTo("BoostedFees.sol", abi.encode(core), target);
        boostedFees = BoostedFees(target);

        configurator = new BoostedFeesConfigurator(core, boostedFees);
    }

    function test_afterInitializePool_setsState(uint256 time, uint64 fee) public {
        vm.warp(time);

        PoolKey memory poolKey = createPool({tick: 0, fee: fee, tickSpacing: 100, extension: address(boostedFees)});

        TwammPoolState state = boostedFees.poolState(poolKey.toPoolId());
        (uint32 lastTime, uint112 rate0, uint112 rate1) = state.parse();

        assertEq(lastTime, uint32(vm.getBlockTimestamp()));
        assertEq(rate0, 0);
        assertEq(rate1, 0);

        assertEq(state.realLastVirtualOrderExecutionTime(), time);
    }
}
