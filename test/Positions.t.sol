// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {FullTest} from "./FullTest.sol";
import {RouteNode, TokenAmount} from "../src/Router.sol";
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

    function test_metadata() public {
        vm.prank(owner);
        positions.setMetadata("Ekubo Positions", "ekuPo", "ekubo://positions/");
        assertEq(positions.name(), "Ekubo Positions");
        assertEq(positions.symbol(), "ekuPo");
        assertEq(positions.tokenURI(1), "ekubo://positions/1");
    }

    function test_saltToId(address minter, bytes32 salt) public {
        uint256 id = positions.saltToId(minter, salt);
        unchecked {
            assertNotEq(id, positions.saltToId(address(uint160(minter) + 1), salt));
            assertNotEq(id, positions.saltToId(minter, bytes32(uint256(salt) + 1)));
        }
        // address is also incorporated
        Positions p2 = new Positions(core, owner, 0, 1);
        assertNotEq(id, p2.saltToId(minter, salt));
    }

    function test_mintAndDeposit(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        token0.approve(address(positions), 100);
        token1.approve(address(positions), 100);

        (uint256 id, uint128 liquidity,,) = positions.mintAndDeposit(poolKey, -100, 100, 100, 100, 0);
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

        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, -100, 100, liquidity);

        // original 100, rounded down, minus the 50% fee
        assertEq(amount0, 49);
        assertEq(amount1, 49);
    }

    function test_mintAndDeposit_shared_tick_boundary(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);

        (, uint128 liquidityA,,) = positions.mintAndDeposit(poolKey, -100, 100, 100, 100, 0);
        (, uint128 liquidityB,,) = positions.mintAndDeposit(poolKey, -300, -100, 100, 100, 0);

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

        (uint256 id, uint128 liquidity) = createPosition(poolKey, -100, 100, 100, 100);

        (uint128 amount0, uint128 amount1) = positions.collectFees(id, poolKey, -100, 100, address(this));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        token0.approve(address(router), 100);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );

        (amount0, amount1) = positions.collectFees(id, poolKey, -100, 100);
        assertEq(amount0, 49);
        assertEq(amount1, 0);

        (amount0, amount1) = positions.collectFees(id, poolKey, -100, 100);
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        (amount0, amount1) = positions.withdraw(id, poolKey, -100, 100, liquidity);

        assertEq(amount0, 74);
        assertEq(amount1, 25);
    }

    function test_collectFees_amount1(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, -100, 100, 100, 100);

        (uint128 amount0, uint128 amount1) = positions.collectFees(id, poolKey, -100, 100, address(this));
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        token1.approve(address(router), 100);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 100}),
            type(int256).min
        );

        (amount0, amount1) = positions.collectFees(id, poolKey, -100, 100);
        assertEq(amount0, 0);
        assertEq(amount1, 49);

        (amount0, amount1) = positions.collectFees(id, poolKey, -100, 100);
        assertEq(amount0, 0);
        assertEq(amount1, 0);

        (amount0, amount1) = positions.withdraw(id, poolKey, -100, 100, liquidity);

        assertEq(amount0, 25);
        assertEq(amount1, 74);
    }

    function test_collectFeesAndWithdraw(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, -100, 100, 100, 100);

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
            positions.getPositionFeesAndLiquidity(id, poolKey, -100, 100);
        assertEq(p0, 124);
        assertEq(p1, 75);
        assertEq(f0, 49);
        assertEq(f1, 24);

        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, -100, 100, liquidity);
        assertEq(amount0, 111); // 124/2 + 49
        assertEq(amount1, 61); // 75/2 + 24
    }

    function test_collectFeesAndWithdraw_above_range(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, -100, 100, 100, 100);

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
            positions.getPositionFeesAndLiquidity(id, poolKey, -100, 100);
        assertEq(p0, 0);
        assertEq(p1, 200);
        assertEq(f0, 49);
        assertEq(f1, 150);

        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, -100, 100, liquidity);
        assertEq(amount0, 49);
        assertEq(amount1, 250);
    }

    function test_collectFeesAndWithdraw_below_range(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, -100, 100, 100, 100);

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
            positions.getPositionFeesAndLiquidity(id, poolKey, -100, 100);
        assertEq(p0, 200);
        assertEq(p1, 0);
        assertEq(f0, 125);
        assertEq(f1, 24);

        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, -100, 100, liquidity);
        assertEq(amount0, 225);
        assertEq(amount1, 24);
    }

    function test_collectFeesOnly(CallPoints memory callPoints) public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100, callPoints);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, -100, 100, 100, 100);

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

        (uint128 amount0, uint128 amount1) = positions.collectFees(id, poolKey, -100, 100);

        assertEq(amount0, 49);
        assertEq(amount1, 24);

        (uint128 liquidityAfter, uint128 p0, uint128 p1, uint128 f0, uint128 f1) =
            positions.getPositionFeesAndLiquidity(id, poolKey, -100, 100);
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

        coolAllContracts();
        (uint256 id, uint128 liquidity,,) = positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e36, 1e36, 0);
        vm.snapshotGasLastCall("mintAndDeposit full range max");
        assertGt(liquidity, 0);

        token1.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap(poolKey, false, type(int128).min, MAX_SQRT_RATIO, 0);
        assertEq(delta0, 0);

        (SqrtRatio sqrtRatio, int32 tick, uint128 liqAfter) = core.poolState(poolKey.toPoolId());
        assertTrue(sqrtRatio == MAX_SQRT_RATIO);
        assertEq(tick, MAX_TICK);
        assertEq(liqAfter, liquidity);

        (, uint128 p0, uint128 p1, uint128 f0, uint128 f1) =
            positions.getPositionFeesAndLiquidity(id, poolKey, MIN_TICK, MAX_TICK);
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

        coolAllContracts();
        (uint256 id, uint128 liquidity,,) = positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e36, 1e36, 0);
        vm.snapshotGasLastCall("mintAndDeposit full range min");
        assertGt(liquidity, 0);

        token0.approve(address(router), type(uint256).max);
        (int128 delta0, int128 delta1) = router.swap(poolKey, true, type(int128).min, MIN_SQRT_RATIO, 0);
        assertEq(delta1, 0);

        (SqrtRatio sqrtRatio, int32 tick, uint128 liqAfter) = core.poolState(poolKey.toPoolId());
        assertTrue(sqrtRatio == MIN_SQRT_RATIO);
        assertEq(tick, MIN_TICK - 1);
        assertEq(liqAfter, liquidity);

        (, uint128 p0, uint128 p1, uint128 f0, uint128 f1) =
            positions.getPositionFeesAndLiquidity(id, poolKey, MIN_TICK, MAX_TICK);
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

        (uint256 id,,,) = positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e36, 1e36, 0);
        (,,, uint128 f0, uint128 f1) = positions.getPositionFeesAndLiquidity(id, poolKey, MIN_TICK, MAX_TICK);
        assertEq(f0, 0);
        assertEq(f1, 0);

        token0.approve(address(fae), 1000);
        token1.approve(address(fae), 2000);
        fae.accumulateFees(poolKey, 1000, 2000);

        (,,, f0, f1) = positions.getPositionFeesAndLiquidity(id, poolKey, MIN_TICK, MAX_TICK);
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

        (uint256 id,,,) = positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e36, 1e36, 0);
        (,,, uint128 f0, uint128 f1) = positions.getPositionFeesAndLiquidity(id, poolKey, MIN_TICK, MAX_TICK);
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    function test_mintAndDeposit_gas() public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100);
        token0.approve(address(positions), 100);
        token1.approve(address(positions), 100);

        coolAllContracts();
        positions.mintAndDeposit(poolKey, -100, 100, 100, 100, 0);
        vm.snapshotGasLastCall("mintAndDeposit");
    }

    function test_mintAndDeposit_eth_pool_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 63, 100);
        token1.approve(address(positions), 100);

        coolAllContracts();
        positions.mintAndDeposit{value: 100}(poolKey, -100, 100, 100, 100, 0);
        vm.snapshotGasLastCall("mintAndDeposit eth");
    }

    function test_burn_can_be_minted() public {
        uint256 id = positions.mint(bytes32(0));
        positions.burn(id);
        uint256 id2 = positions.mint(bytes32(0));
        assertEq(id, id2);
    }

    function test_gas_full_range_mintAndDeposit() public {
        PoolKey memory poolKey = createPool({tick: 0, fee: 1 << 63, tickSpacing: FULL_RANGE_ONLY_TICK_SPACING});
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);

        coolAllContracts();
        positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);
        vm.snapshotGasLastCall("mintAndDeposit full range both tokens");
    }

    function testFuzz_positions_with_any_protocol_fees(
        uint64 swapProtocolFeeX64,
        uint64 withdrawalProtocolFeeDenominator
    ) public {
        // Test with any values as requested - the contract handles edge cases properly
        // swapProtocolFeeX64 can be any uint64 value (including > 100% fees)
        // withdrawalProtocolFeeDenominator can be any uint64 value (including 0, which disables withdrawal fees)

        // Create a new Positions contract with the fuzzed parameters
        Positions testPositions = new Positions(core, owner, swapProtocolFeeX64, withdrawalProtocolFeeDenominator);

        // Verify the parameters are set correctly
        assertEq(testPositions.SWAP_PROTOCOL_FEE_X64(), swapProtocolFeeX64);
        assertEq(testPositions.WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR(), withdrawalProtocolFeeDenominator);

        // Create a pool for testing
        PoolKey memory poolKey = createPool(0, 1 << 63, 100); // 50% fee pool

        // Approve tokens for the test positions contract
        token0.approve(address(testPositions), type(uint256).max);
        token1.approve(address(testPositions), type(uint256).max);

        // Test 1: Mint and deposit should work regardless of protocol fee parameters
        (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1) =
            testPositions.mintAndDeposit(poolKey, -100, 100, 1000, 1000, 0);

        assertGt(id, 0, "Position ID should be greater than 0");
        assertGt(liquidity, 0, "Liquidity should be greater than 0");
        assertGt(amount0, 0, "Amount0 should be greater than 0");
        assertGt(amount1, 0, "Amount1 should be greater than 0");

        // Test 2: Generate some fees by swapping
        token0.approve(address(router), 500);
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 500}),
            type(int256).min
        );

        // Test 3: Collect fees and verify protocol fees are handled correctly
        uint256 balanceBefore0 = token0.balanceOf(address(this));
        uint256 balanceBefore1 = token1.balanceOf(address(this));

        // Record protocol fees before collecting to test monotonicity
        (uint128 protocolFeesBeforeCollect0, uint128 protocolFeesBeforeCollect1) =
            testPositions.getProtocolFees(address(token0), address(token1));

        (uint128 collectedFees0, uint128 collectedFees1) = testPositions.collectFees(id, poolKey, -100, 100);

        uint256 balanceAfter0 = token0.balanceOf(address(this));
        uint256 balanceAfter1 = token1.balanceOf(address(this));

        // Verify we received some fees (exact amount depends on protocol fee)
        assertEq(balanceAfter0 - balanceBefore0, collectedFees0, "Should receive collected fees0");
        assertEq(balanceAfter1 - balanceBefore1, collectedFees1, "Should receive collected fees1");

        // Test 4: Check protocol fees monotonicity after fee collection
        (uint128 protocolFeesAfterCollect0, uint128 protocolFeesAfterCollect1) =
            testPositions.getProtocolFees(address(token0), address(token1));

        // Protocol fees should not decrease after collecting fees
        assertTrue(
            protocolFeesAfterCollect0 >= protocolFeesBeforeCollect0
                && protocolFeesAfterCollect1 >= protocolFeesBeforeCollect1,
            "Protocol fees should not decrease after fee collection"
        );

        // Test 5: Withdraw liquidity and verify withdrawal fees are handled correctly
        balanceBefore0 = token0.balanceOf(address(this));
        balanceBefore1 = token1.balanceOf(address(this));

        (uint128 withdrawn0, uint128 withdrawn1) = testPositions.withdraw(id, poolKey, -100, 100, liquidity);

        balanceAfter0 = token0.balanceOf(address(this));
        balanceAfter1 = token1.balanceOf(address(this));

        // Verify we received the withdrawn amounts
        assertEq(balanceAfter0 - balanceBefore0, withdrawn0, "Should receive withdrawn amount0");
        assertEq(balanceAfter1 - balanceBefore1, withdrawn1, "Should receive withdrawn amount1");

        // Test 6: Verify withdrawal protocol fees monotonicity
        (uint128 finalProtocolFees0, uint128 finalProtocolFees1) =
            testPositions.getProtocolFees(address(token0), address(token1));

        // Protocol fees should not decrease after withdrawal
        assertTrue(
            finalProtocolFees0 >= protocolFeesAfterCollect0 && finalProtocolFees1 >= protocolFeesAfterCollect1,
            "Protocol fees should not decrease after withdrawal"
        );

        // Test 7: Verify position is empty after full withdrawal
        (uint128 remainingLiquidity,,,,) = testPositions.getPositionFeesAndLiquidity(id, poolKey, -100, 100);
        assertEq(remainingLiquidity, 0, "Position should have no liquidity after full withdrawal");
    }
}
