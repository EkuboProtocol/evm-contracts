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

    function test_isRegistered() public view {
        assertTrue(core.isExtensionRegistered(address(mevResist)));
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

        assertEq(delta0, -100_000);
        assertEq(delta1, 101_507);
        (, int32 tick,) = core.poolState(poolKey.toPoolId());
        assertEq(tick, 9777);
    }
}
