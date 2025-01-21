// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey, Bounds, maxBounds} from "../src/types/keys.sol";
import {FullTest} from "./FullTest.sol";
import {Router, Delta, RouteNode, TokenAmount, Swap} from "../src/Router.sol";
import {isPriceIncreasing} from "../src/math/swap.sol";
import {MaxLiquidityForToken0Overflow, MaxLiquidityForToken1Overflow} from "../src/math/liquidity.sol";
import {SwapParameters} from "../src/interfaces/ICore.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {StdAssertions} from "forge-std/StdAssertions.sol";
import {Positions} from "../src/Positions.sol";
import {TestToken} from "./TestToken.sol";
import {
    MIN_TICK,
    MAX_TICK,
    MIN_SQRT_RATIO,
    MAX_SQRT_RATIO,
    MAX_TICK_SPACING,
    tickToSqrtRatio
} from "../src/math/ticks.sol";

contract Handler is StdUtils, StdAssertions {
    uint256 immutable positionId;

    struct ActivePosition {
        PoolKey poolKey;
        Bounds bounds;
        uint128 liquidity;
    }

    struct Balances {
        int256 amount0;
        int256 amount1;
    }

    Positions immutable positions;
    Router immutable router;
    TestToken immutable token0;
    TestToken immutable token1;
    ActivePosition[] activePositions;
    PoolKey[] allPoolKeys;

    mapping(bytes32 poolId => Balances balances) poolBalances;

    constructor(Positions _positions, Router _router, TestToken _token0, TestToken _token1) {
        positions = _positions;
        router = _router;
        token0 = _token0;
        token1 = _token1;
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        positionId = positions.mint();
    }

    function createNewPool(uint128 fee, uint32 tickSpacing, int32 tick) public {
        tickSpacing = uint32(bound(tickSpacing, 1, MAX_TICK_SPACING));
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        PoolKey memory poolKey = PoolKey(address(token0), address(token1), fee, tickSpacing, address(0));
        (bool initialized, uint256 sqrtRatio) =
            positions.maybeInitializePool(PoolKey(address(token0), address(token1), fee, tickSpacing, address(0)), tick);
        assertNotEq(sqrtRatio, 0);
        if (initialized) allPoolKeys.push(poolKey);
    }

    modifier ifPoolExists() {
        if (allPoolKeys.length == 0) return;
        _;
    }

    error UnexpectedDepositError(bytes4 sig, bytes data);

    function deposit(uint256 poolKeyIndex, uint128 amount0, uint128 amount1, Bounds memory bounds)
        public
        ifPoolExists
    {
        PoolKey memory poolKey = allPoolKeys[bound(poolKeyIndex, 0, allPoolKeys.length - 1)];
        Bounds memory max = maxBounds(poolKey.tickSpacing);
        bounds.lower = int32(bound(bounds.lower, max.lower, max.upper - int32(poolKey.tickSpacing)));
        // snap to nearest valid tick
        bounds.lower = (bounds.lower / int32(poolKey.tickSpacing)) * int32(poolKey.tickSpacing);
        bounds.upper = int32(bound(bounds.upper, bounds.lower + int32(poolKey.tickSpacing), max.upper));
        bounds.upper = (bounds.upper / int32(poolKey.tickSpacing)) * int32(poolKey.tickSpacing);

        try positions.deposit(positionId, poolKey, bounds, amount0, amount1, 0) returns (
            uint128 liquidity, uint128 result0, uint128 result1
        ) {
            if (liquidity > 0) {
                activePositions.push(ActivePosition(poolKey, bounds, liquidity));
            }

            bytes32 poolId = poolKey.toPoolId();
            poolBalances[poolId].amount0 += int256(uint256(result0));
            poolBalances[poolId].amount1 += int256(uint256(result1));
        } catch (bytes memory err) {
            bytes4 sig;
            assembly ("memory-safe") {
                sig := mload(add(err, 32))
            }
            if (
                sig != Positions.DepositOverflow.selector && sig != MaxLiquidityForToken0Overflow.selector
                    && sig != MaxLiquidityForToken1Overflow.selector && sig != SafeCastLib.Overflow.selector
            ) {
                revert UnexpectedDepositError(sig, err);
            }
        }
    }

    function withdrawAllPositions() public {
        for (uint256 i = 0; i < activePositions.length; i++) {
            (uint128 amount0, uint128 amount1) = positions.collectFeesAndWithdraw(
                positionId,
                activePositions[i].poolKey,
                activePositions[i].bounds,
                activePositions[i].liquidity,
                address(this)
            );
            bytes32 poolId = activePositions[i].poolKey.toPoolId();
            poolBalances[poolId].amount0 -= int256(uint256(amount0));
            poolBalances[poolId].amount1 -= int256(uint256(amount1));
        }
        assembly ("memory-safe") {
            sstore(activePositions.slot, 0)
        }
    }

    // function swap(SwapParameters memory params) public ifPoolExists {
    //     (uint256 price, int32 tick) = positions.getPoolPrice(poolKey);

    //     PoolKey memory poolKey = allPoolKeys[bound(poolKeyIndex, 0, allPoolKeys.length)];
    //     if (isPriceIncreasing(params.amount, params.isToken1)) {
    //         // the max tick is far away in terms of tick spacing
    //         if (tick + (32768 * int32(poolKey.tickSpacing)) < MAX_TICK) {
    //             params.sqrtRatioLimit =
    //                 bound(params.sqrtRatioLimit, price, tickToSqrtRatio(tick + (100 * int32(poolKey.tickSpacing))));
    //         } else {
    //             params.sqrtRatioLimit = bound(params.sqrtRatioLimit, price, MAX_SQRT_RATIO);
    //         }
    //     } else {
    //         // the min tick is far away in terms of tick spacing
    //         if (tick - (32768 * int32(poolKey.tickSpacing)) > MIN_TICK) {
    //             params.sqrtRatioLimit =
    //                 bound(params.sqrtRatioLimit, price, tickToSqrtRatio(tick - (100 * int32(poolKey.tickSpacing))));
    //         } else {
    //             params.sqrtRatioLimit = bound(params.sqrtRatioLimit, MIN_SQRT_RATIO, price);
    //         }
    //     }

    //     params.skipAhead = bound(params.skipAhead, 0, 10);
    //     Delta memory d = router.swap(
    //         RouteNode(poolKey, params.sqrtRatioLimit, params.skipAhead),
    //         TokenAmount(params.isToken1 ? address(token1) : address(token0), params.amount)
    //     );

    //     bytes32 poolId = poolKey.toPoolId();
    //     poolBalances[poolId].amount0 += d.amount0;
    //     poolBalances[poolId].amount1 += d.amount1;
    // }

    function checkAllPoolsHavePositiveBalance() public view {
        for (uint256 i = 0; i < allPoolKeys.length; i++) {
            bytes32 poolId = allPoolKeys[i].toPoolId();
            assertGe(poolBalances[poolId].amount0, 0);
            assertGe(poolBalances[poolId].amount1, 0);
        }
    }
}

contract SolvencyInvariantTest is FullTest {
    Handler handler;

    function setUp() public override {
        FullTest.setUp();
        handler = new Handler(positions, router, token0, token1);
        token0.transfer(address(handler), type(uint256).max);
        token1.transfer(address(handler), type(uint256).max);
        targetContract(address(handler));
    }

    function invariant_allPoolsHavePositiveBalance() public view {
        handler.checkAllPoolsHavePositiveBalance();
    }
}
