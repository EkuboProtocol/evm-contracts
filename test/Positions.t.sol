// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {Bounds} from "../src/types/positionKey.sol";
import {FullTest} from "./FullTest.sol";
import {Delta, RouteNode, TokenAmount} from "../src/Router.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING} from "../src/math/constants.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../src/types/sqrtRatio.sol";
import {Positions} from "../src/Positions.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {FeeAccumulatingExtension} from "./SolvencyInvariantTest.t.sol";
import {byteToCallPoints} from "../src/types/callPoints.sol";

contract PositionsTest is FullTest {
    using CoreLib for *;

    function test_metadata() public view {
        assertEq(positions.name(), "Ekubo Positions");
        assertEq(positions.symbol(), "ekuPo");
        assertEq(positions.tokenURI(1), "ekubo://positions/1");
    }

    function test_saltToId(address minter, bytes32 salt) public {
        uint256 id = positions.saltToId(minter, salt);
        assertLe(id, type(uint48).max);
        unchecked {
            assertNotEq(id, positions.saltToId(address(uint160(minter) + 1), salt));
            assertNotEq(id, positions.saltToId(minter, bytes32(uint256(salt) + 1)));
        }
        // address is also incorporated
        Positions p2 = new Positions(core, positions.tokenURIGenerator());
        assertNotEq(id, p2.saltToId(minter, salt));
    }

    function test_mintAndDeposit(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        token0.approve(address(positions), 100);
        token1.approve(address(positions), 100);

        Bounds memory bounds = Bounds({lower: -100, upper: 100});

        (uint256 id, uint128 liquidity,,) = positions.mintAndDeposit(poolKey, bounds, 100, 100, 0);
        assertGt(id, 0);
        assertGt(liquidity, 0);
        assertEq(token0.balanceOf(address(core)), 100);
        assertEq(token1.balanceOf(address(core)), 100);

        (int128 liquidityDeltaLower, uint128 liquidityNetLower) = core.poolTicks(poolKey.toPoolId(), -100);
        assertEq(liquidityDeltaLower, int128(liquidity), "lower.liquidityDelta");
        assertEq(liquidityNetLower, liquidity, "lower.liquidityNet");
        (int128 liquidityDeltaUpper, uint128 liquidityNetUpper) = core.poolTicks(poolKey.toPoolId(), 100);
        assertEq(liquidityNetUpper, liquidity, "upper.liquidityNet");
        assertEq(liquidityDeltaUpper, -int128(liquidity), "upper.liquidityDelta");

        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, bounds, liquidity);

        // original 100, rounded down, minus the 50% fee
        assertEq(amount0, 49);
        assertEq(amount1, 49);
    }

    function test_mintAndDeposit_shared_tick_boundary(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);

        Bounds memory boundsA = Bounds({lower: -100, upper: 100});
        Bounds memory boundsB = Bounds({lower: -300, upper: -100});

        (, uint128 liquidityA,,) = positions.mintAndDeposit(poolKey, boundsA, 100, 100, 0);
        (, uint128 liquidityB,,) = positions.mintAndDeposit(poolKey, boundsB, 100, 100, 0);

        (int128 liquidityDelta, uint128 liquidityNet) = core.poolTicks(poolKey.toPoolId(), -300);
        assertEq(liquidityDelta, int128(liquidityB));
        assertEq(liquidityNet, liquidityB);

        (liquidityDelta, liquidityNet) = core.poolTicks(poolKey.toPoolId(), -100);
        assertEq(liquidityDelta, int128(liquidityA) - int128(liquidityB));
        assertEq(liquidityNet, liquidityB + liquidityA);

        (liquidityDelta, liquidityNet) = core.poolTicks(poolKey.toPoolId(), 100);
        assertEq(liquidityDelta, -int128(liquidityA));
        assertEq(liquidityNet, liquidityA);
    }

    function test_collectFees_amount0(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(-100, 100), 100, 100);

        (uint128 amount0, uint128 amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100), address(this));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        token0.approve(address(router), 100);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );

        (amount0, amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100));
        assertEq(amount0, 49);
        assertEq(amount1, 0);

        (amount0, amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        (amount0, amount1) = positions.withdraw(id, poolKey, Bounds(-100, 100), liquidity);

        assertEq(amount0, 74);
        assertEq(amount1, 25);
    }

    function test_collectFees_amount1(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(-100, 100), 100, 100);

        (uint128 amount0, uint128 amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100), address(this));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        token1.approve(address(router), 100);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100}),
            type(int256).min
        );

        (amount0, amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100));
        assertEq(amount0, 0);
        assertEq(amount1, 49);

        (amount0, amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        (amount0, amount1) = positions.withdraw(id, poolKey, Bounds(-100, 100), liquidity);

        assertEq(amount0, 25);
        assertEq(amount1, 74);
    }

    function test_collectFeesAndWithdraw(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(-100, 100), 100, 100);

        token0.approve(address(router), 100);
        token1.approve(address(router), 50);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 50}),
            type(int256).min
        );

        (, uint128 p0, uint128 p1, uint128 f0, uint128 f1) =
            positions.getPositionFeesAndLiquidity(id, poolKey, Bounds(-100, 100));
        assertEq(p0, 124);
        assertEq(p1, 75);
        assertEq(f0, 49);
        assertEq(f1, 24);

        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, Bounds(-100, 100), liquidity);
        assertEq(amount0, 111); // 124/2 + 49
        assertEq(amount1, 61); // 75/2 + 24
    }

    function test_collectFeesAndWithdraw_above_range(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(-100, 100), 100, 100);

        token0.approve(address(router), 100);
        token1.approve(address(router), 50);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 50}),
            type(int256).min
        );

        token1.approve(address(router), type(uint256).max);
        router.swap({
            poolKey: poolKey,
            isToken1: true,
            amount: type(int128).max,
            sqrtRatioLimit: tickToSqrtRatio(100),
            skipAhead: 0
        });

        (, uint128 p0, uint128 p1, uint128 f0, uint128 f1) =
            positions.getPositionFeesAndLiquidity(id, poolKey, Bounds(-100, 100));
        assertEq(p0, 0);
        assertEq(p1, 200);
        assertEq(f0, 49);
        assertEq(f1, 150);

        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, Bounds(-100, 100), liquidity);
        assertEq(amount0, 49);
        assertEq(amount1, 250);
    }

    function test_collectFeesAndWithdraw_below_range(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(-100, 100), 100, 100);

        token0.approve(address(router), 100);
        token1.approve(address(router), 50);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 50}),
            type(int256).min
        );

        token0.approve(address(router), type(uint256).max);
        router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: type(int128).max,
            sqrtRatioLimit: tickToSqrtRatio(-100),
            skipAhead: 0
        });

        (, uint128 p0, uint128 p1, uint128 f0, uint128 f1) =
            positions.getPositionFeesAndLiquidity(id, poolKey, Bounds(-100, 100));
        assertEq(p0, 200);
        assertEq(p1, 0);
        assertEq(f0, 125);
        assertEq(f1, 24);

        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, Bounds(-100, 100), liquidity);
        assertEq(amount0, 225);
        assertEq(amount1, 24);
    }

    function test_collectFeesOnly(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, Bounds(-100, 100), 100, 100);

        token0.approve(address(router), 100);
        token1.approve(address(router), 50);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 50}),
            type(int256).min
        );

        (uint128 amount0, uint128 amount1) = positions.collectFees(id, poolKey, Bounds(-100, 100));

        assertEq(amount0, 49);
        assertEq(amount1, 24);

        (uint128 liquidityAfter, uint128 p0, uint128 p1, uint128 f0, uint128 f1) =
            positions.getPositionFeesAndLiquidity(id, poolKey, Bounds(-100, 100));
        assertEq(liquidityAfter, liquidity);
        assertEq(p0, 124);
        assertEq(p1, 75);
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    function test_fees_fullRange_max_price() public {
        PoolKey memory poolKey =
            createPool({tick: MAX_TICK - 1, fee: 1 << 63, tickSpacing: FULL_RANGE_ONLY_TICK_SPACING});
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);

        Bounds memory bounds = Bounds({lower: MIN_TICK, upper: MAX_TICK});

        (uint256 id, uint128 liquidity,,) = positions.mintAndDeposit(poolKey, bounds, 1e36, 1e36, 0);
        vm.snapshotGasLastCall("mintAndDeposit full range max");
        assertGt(liquidity, 0);

        token1.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap(poolKey, false, type(int128).min, MAX_SQRT_RATIO, 0);
        assertEq(delta0, 0);

        (SqrtRatio sqrtRatio, int32 tick, uint128 liqAfter) = core.poolState(poolKey.toPoolId());
        assertTrue(sqrtRatio == MAX_SQRT_RATIO);
        assertEq(tick, MAX_TICK);
        assertEq(liqAfter, liquidity);

        (, uint128 p0, uint128 p1, uint128 f0, uint128 f1) = positions.getPositionFeesAndLiquidity(id, poolKey, bounds);
        assertEq(p0, 0);
        assertEq(p1, 1000000499999874989827178462785727275);
        assertEq(f0, 0);
        assertEq(f1, ((uint128(delta1)) / 2) - 1);
    }

    function test_fees_fullRange_min_price() public {
        PoolKey memory poolKey =
            createPool({tick: MIN_TICK + 1, fee: 1 << 63, tickSpacing: FULL_RANGE_ONLY_TICK_SPACING});
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);

        Bounds memory bounds = Bounds({lower: MIN_TICK, upper: MAX_TICK});

        (uint256 id, uint128 liquidity,,) = positions.mintAndDeposit(poolKey, bounds, 1e36, 1e36, 0);
        vm.snapshotGasLastCall("mintAndDeposit full range min");
        assertGt(liquidity, 0);

        token0.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap(poolKey, true, type(int128).min, MIN_SQRT_RATIO, 0);
        assertEq(delta1, 0);

        (SqrtRatio sqrtRatio, int32 tick, uint128 liqAfter) = core.poolState(poolKey.toPoolId());
        assertTrue(sqrtRatio == MIN_SQRT_RATIO);
        assertEq(tick, MIN_TICK - 1);
        assertEq(liqAfter, liquidity);

        (, uint128 p0, uint128 p1, uint128 f0, uint128 f1) = positions.getPositionFeesAndLiquidity(id, poolKey, bounds);
        assertEq(p0, 1000000499999874989935596106549936381, "principal0");
        assertEq(p1, 0, "principal1");
        assertEq(f0, ((uint128(delta0)) / 2) - 1, "fees0");
        assertEq(f1, 0, "fees1");
    }

    function test_feeAccumulation_works_full_range() public {
        address impl = address(new FeeAccumulatingExtension(core));
        address actual = address((uint160(0xff) << 152) + 0xdeadbeef);
        vm.etch(actual, impl.code);
        FeeAccumulatingExtension fae = FeeAccumulatingExtension(actual);
        fae.register(core, byteToCallPoints(0xff));

        PoolKey memory poolKey = createPool({
            tick: MIN_TICK + 1,
            fee: 1 << 63,
            tickSpacing: FULL_RANGE_ONLY_TICK_SPACING,
            extension: address(fae)
        });
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);

        Bounds memory bounds = Bounds({lower: MIN_TICK, upper: MAX_TICK});

        (uint256 id,,,) = positions.mintAndDeposit(poolKey, bounds, 1e36, 1e36, 0);
        (,,, uint128 f0, uint128 f1) = positions.getPositionFeesAndLiquidity(id, poolKey, bounds);
        assertEq(f0, 0);
        assertEq(f1, 0);

        token0.approve(address(fae), 1000);
        token1.approve(address(fae), 2000);
        fae.accumulateFees(poolKey, 1000, 2000);

        (,,, f0, f1) = positions.getPositionFeesAndLiquidity(id, poolKey, bounds);
        assertEq(f0, 999);
        assertEq(f1, 1999);
    }

    function test_feeAccumulation_zero_liquidity_full_range() public {
        address impl = address(new FeeAccumulatingExtension(core));
        address actual = address((uint160(0xff) << 152) + 0xdeadbeef);
        vm.etch(actual, impl.code);
        FeeAccumulatingExtension fae = FeeAccumulatingExtension(actual);
        fae.register(core, byteToCallPoints(0xff));

        PoolKey memory poolKey = createPool({
            tick: MIN_TICK + 1,
            fee: 1 << 63,
            tickSpacing: FULL_RANGE_ONLY_TICK_SPACING,
            extension: address(fae)
        });

        token0.approve(address(fae), 1000);
        token1.approve(address(fae), 2000);
        fae.accumulateFees(poolKey, 1000, 2000);

        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);

        Bounds memory bounds = Bounds({lower: MIN_TICK, upper: MAX_TICK});

        (uint256 id,,,) = positions.mintAndDeposit(poolKey, bounds, 1e36, 1e36, 0);
        (,,, uint128 f0, uint128 f1) = positions.getPositionFeesAndLiquidity(id, poolKey, bounds);
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    function test_mintAndDeposit_gas() public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100);
        token0.approve(address(positions), 100);
        token1.approve(address(positions), 100);

        Bounds memory bounds = Bounds({lower: -100, upper: 100});

        positions.mintAndDeposit(poolKey, bounds, 100, 100, 0);
        vm.snapshotGasLastCall("mintAndDeposit");
    }

    function test_mintAndDeposit_eth_pool_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 63, 100);
        token1.approve(address(positions), 100);

        Bounds memory bounds = Bounds({lower: -100, upper: 100});

        positions.mintAndDeposit{value: 100}(poolKey, bounds, 100, 100, 0);
        vm.snapshotGasLastCall("mintAndDeposit eth");
    }

    function test_gas_full_range_mintAndDeposit() public {
        PoolKey memory poolKey = createPool({tick: 0, fee: 1 << 63, tickSpacing: FULL_RANGE_ONLY_TICK_SPACING});
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);

        Bounds memory bounds = Bounds({lower: MIN_TICK, upper: MAX_TICK});

        positions.mintAndDeposit(poolKey, bounds, 1e18, 1e18, 0);
        vm.snapshotGasLastCall("mintAndDeposit full range both tokens");
    }
}
