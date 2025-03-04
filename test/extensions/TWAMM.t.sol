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
import {TWAMM, twammCallPoints} from "../../src/extensions/TWAMM.sol";
import {Core} from "../../src/Core.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {TestToken} from "../TestToken.sol";
import {amount0Delta, amount1Delta} from "../../src/math/delta.sol";
import {liquidityDeltaToAmountDelta} from "../../src/math/liquidity.sol";
import {FullRangeOnlyPool} from "../../src/types/positionKey.sol";
import {FeesPerLiquidity} from "../../src/types/feesPerLiquidity.sol";
import {TWAMMLib} from "../../src/libraries/TWAMMLib.sol";
import {Vm} from "forge-std/Vm.sol";
import {LibBytes} from "solady/utils/LibBytes.sol";
import {Test} from "forge-std/Test.sol";

abstract contract BaseTWAMMTest is FullTest {
    TWAMM internal twamm;

    uint256 positionId;

    function setUp() public virtual override {
        FullTest.setUp();
        address deployAddress = address(uint160(twammCallPoints().toUint8()) << 152);
        deployCodeTo("TWAMM.sol", abi.encode(core), deployAddress);
        twamm = TWAMM(deployAddress);
        positionId = positions.mint();
    }

    function advanceTime(uint32 by) internal returns (uint64 next) {
        next = uint64(vm.getBlockTimestamp() + by);
        vm.warp(next);
    }

    function createTwammPool(uint64 fee, int32 tick) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(address(token0), address(token1), tick, fee, FULL_RANGE_ONLY_TICK_SPACING, address(twamm));
    }
}

contract TWAMMTest is BaseTWAMMTest {
    using TWAMMLib for *;

    function test_createPool_fails_not_full_range() public {
        vm.expectRevert(FullRangeOnlyPool.selector);
        createPool(address(token0), address(token1), 0, 0, 1, address(twamm));
    }

    function test_createPool() public {
        PoolKey memory key = createTwammPool(100, 0);
        (uint32 lvoe, uint112 srt0, uint112 srt1) = twamm.poolState(key.toPoolId());
        assertEq(lvoe, 1);
        assertEq(srt0, 0);
        assertEq(srt1, 0);
    }
}

// Note the inheritance order matters because Test contains storage variables
contract TWAMMInternalMethodsTests is TWAMM, Test {
    constructor() TWAMM(new Core(address(0xdeadbeef))) {}

    function _registerInConstructor() internal override returns (bool) {
        return false;
    }

    function test_getRewardRateInside_token0() public {
        bytes32 poolId = bytes32(0);

        vm.warp(99);
        assertEq(_getRewardRateInside(poolId, 100, 200, false), 0);

        vm.warp(150);
        assertEq(_getRewardRateInside(poolId, 100, 200, false), 0);

        poolRewardRates[poolId] = FeesPerLiquidity(100, 75);
        assertEq(_getRewardRateInside(poolId, 100, 200, false), 100);

        poolRewardRates[poolId] = FeesPerLiquidity(300, 450);
        poolRewardRatesBefore[poolId][200] = FeesPerLiquidity(150, 150);
        vm.warp(250);
        assertEq(_getRewardRateInside(poolId, 100, 200, false), 150);

        poolRewardRatesBefore[poolId][100] = FeesPerLiquidity(50, 100);
        assertEq(_getRewardRateInside(poolId, 100, 200, false), 100);
    }

    function test_getRewardRateInside_token1() public {
        bytes32 poolId = bytes32(0);

        vm.warp(99);
        assertEq(_getRewardRateInside(poolId, 100, 200, true), 0);

        vm.warp(150);
        assertEq(_getRewardRateInside(poolId, 100, 200, true), 0);

        poolRewardRates[poolId] = FeesPerLiquidity(100, 75);
        assertEq(_getRewardRateInside(poolId, 100, 200, true), 75);

        poolRewardRates[poolId] = FeesPerLiquidity(300, 450);
        poolRewardRatesBefore[poolId][200] = FeesPerLiquidity(150, 160);
        vm.warp(250);
        assertEq(_getRewardRateInside(poolId, 100, 200, true), 160);

        poolRewardRatesBefore[poolId][100] = FeesPerLiquidity(50, 100);
        assertEq(_getRewardRateInside(poolId, 100, 200, true), 60);
    }
}
