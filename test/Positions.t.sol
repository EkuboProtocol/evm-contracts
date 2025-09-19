// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {FullTest, MockExtension} from "./FullTest.sol";
import {RouteNode, TokenAmount} from "../src/Router.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING} from "../src/math/constants.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../src/types/sqrtRatio.sol";
import {Positions} from "../src/Positions.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {computeFee} from "../src/math/fee.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
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

        (SqrtRatio sqrtRatio, int32 tick, uint128 liqAfter) = core.poolState(poolKey.toPoolId()).parse();
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

        (SqrtRatio sqrtRatio, int32 tick, uint128 liqAfter) = core.poolState(poolKey.toPoolId()).parse();
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
        MockExtension fae = createAndRegisterExtension();

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
        MockExtension fae = createAndRegisterExtension();

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

    function test_positions_with_any_protocol_fees(
        uint64 poolFee,
        uint64 swapProtocolFeeX64,
        uint64 withdrawalProtocolFeeDenominator,
        uint64 swapFeesAmount0,
        uint64 swapFeesAmount1
    ) public {
        MockExtension fae = createAndRegisterExtension();

        Positions testPositions = new Positions(core, owner, swapProtocolFeeX64, withdrawalProtocolFeeDenominator);

        assertEq(testPositions.SWAP_PROTOCOL_FEE_X64(), swapProtocolFeeX64);
        assertEq(testPositions.WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR(), withdrawalProtocolFeeDenominator);

        PoolKey memory poolKey = createPool(0, poolFee, 100, address(fae));

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

        token0.approve(address(fae), swapFeesAmount0);
        token1.approve(address(fae), swapFeesAmount1);
        fae.accumulateFees(poolKey, swapFeesAmount0, swapFeesAmount1);

        (uint128 protocolFeesBeforeCollect0, uint128 protocolFeesBeforeCollect1) =
            testPositions.getProtocolFees(address(token0), address(token1));
        assertEq(protocolFeesBeforeCollect0, 0);
        assertEq(protocolFeesBeforeCollect1, 0);

        (uint128 collectedFees0, uint128 collectedFees1) = testPositions.collectFees(id, poolKey, -100, 100);

        (uint128 protocolFeesAfterCollect0, uint128 protocolFeesAfterCollect1) =
            testPositions.getProtocolFees(address(token0), address(token1));

        uint128 expectedSwapProtocolFee0 = computeFee(swapFeesAmount0, swapProtocolFeeX64);
        uint128 expectedSwapProtocolFee1 = computeFee(swapFeesAmount1, swapProtocolFeeX64);

        assertApproxEqAbs(
            protocolFeesAfterCollect0,
            computeFee(swapFeesAmount0, swapProtocolFeeX64),
            1,
            "Protocol fees 0 should be fraction of swap fees"
        );
        assertApproxEqAbs(
            protocolFeesAfterCollect1,
            computeFee(swapFeesAmount1, swapProtocolFeeX64),
            1,
            "Protocol fees 1 should be fraction of swap fees"
        );

        assertApproxEqAbs(collectedFees0 + protocolFeesAfterCollect0, swapFeesAmount0, 1, "swap fees are split");
        assertApproxEqAbs(collectedFees1 + protocolFeesAfterCollect1, swapFeesAmount1, 1, "swap fees are split");

        // Test 5: Withdraw liquidity and verify withdrawal fees are handled correctly
        (uint128 withdrawn0, uint128 withdrawn1) = testPositions.withdraw(id, poolKey, -100, 100, liquidity);

        uint256 expectedWithdrawalFee0 =
            withdrawalProtocolFeeDenominator == 0 ? 0 : computeFee(amount0, poolFee / withdrawalProtocolFeeDenominator);
        uint256 expectedWithdrawalFee1 =
            withdrawalProtocolFeeDenominator == 0 ? 0 : computeFee(amount0, poolFee / withdrawalProtocolFeeDenominator);

        assertApproxEqAbs(withdrawn0, amount0 - expectedWithdrawalFee0, 1, "Should receive amount0 minus protocol fee");
        assertApproxEqAbs(withdrawn1, amount1 - expectedWithdrawalFee1, 1, "Should receive amount1 minus protocol fee");

        (uint128 finalProtocolFees0, uint128 finalProtocolFees1) =
            testPositions.getProtocolFees(address(token0), address(token1));

        assertApproxEqAbs(
            finalProtocolFees0, expectedSwapProtocolFee0 + expectedWithdrawalFee0, 2, "Final protocol fees0"
        );
        assertApproxEqAbs(
            finalProtocolFees1, expectedSwapProtocolFee1 + expectedWithdrawalFee1, 2, "Final protocol fees0"
        );
    }
}
