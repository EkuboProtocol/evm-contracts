// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {CallPoints} from "../src/types/callPoints.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {FullTest, MockExtension} from "./FullTest.sol";
import {RouteNode, TokenAmount} from "../src/Router.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {createSwapParameters} from "../src/types/swapParameters.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../src/types/sqrtRatio.sol";
import {Positions} from "../src/Positions.sol";
import {FreePositions} from "../src/FreePositions.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {computeFee} from "../src/math/fee.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {CoreStorageLayout} from "../src/libraries/CoreStorageLayout.sol";
import {StorageSlot} from "../src/types/storageSlot.sol";
import {PoolState, createPoolState} from "../src/types/poolState.sol";
import {PoolConfig, createStableswapPoolConfig} from "../src/types/poolConfig.sol";

contract PositionsTest is FullTest {
    using CoreLib for *;

    function test_metadata() public {
        vm.prank(owner);
        positions.setMetadata("Ekubo Positions", "ekuPo", "ekubo://positions/");
        assertEq(positions.name(), "Ekubo Positions");
        assertEq(positions.symbol(), "ekuPo");
        assertEq(positions.tokenURI(1), "ekubo://positions/31337/0x2e234DAe75C793f67A35089C9d99245E1C58470b/1");
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

    /// forge-config: default.isolate = true
    function test_fees_fullRange_max_price() public {
        PoolKey memory poolKey = createFullRangePool({tick: MAX_TICK - 1, fee: 1 << 63});
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);

        coolAllContracts();
        (uint256 id, uint128 liquidity,,) = positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e36, 1e36, 0);
        vm.snapshotGasLastCall("mintAndDeposit full range max");
        assertGt(liquidity, 0);

        token1.approve(address(router), type(uint256).max);
        PoolBalanceUpdate balanceUpdate = router.swap(poolKey, false, type(int128).min, MAX_SQRT_RATIO, 0);
        assertEq(balanceUpdate.delta0(), 0);

        (SqrtRatio sqrtRatio, int32 tick, uint128 liqAfter) = core.poolState(poolKey.toPoolId()).parse();
        assertTrue(sqrtRatio == MAX_SQRT_RATIO);
        assertEq(tick, MAX_TICK);
        assertEq(liqAfter, liquidity);

        (, uint128 p0, uint128 p1, uint128 f0, uint128 f1) =
            positions.getPositionFeesAndLiquidity(id, poolKey, MIN_TICK, MAX_TICK);
        assertEq(p0, 0);
        assertEq(p1, 1000000499999874989827178462785727275);
        assertEq(f0, 0);
        assertEq(f1, ((uint128(balanceUpdate.delta1())) / 2) - 1);
    }

    /// forge-config: default.isolate = true
    function test_fees_fullRange_min_price() public {
        PoolKey memory poolKey = createFullRangePool({tick: MIN_TICK + 1, fee: 1 << 63});
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);

        coolAllContracts();
        (uint256 id, uint128 liquidity,,) = positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e36, 1e36, 0);
        vm.snapshotGasLastCall("mintAndDeposit full range min");
        assertGt(liquidity, 0);

        token0.approve(address(router), type(uint256).max);
        PoolBalanceUpdate balanceUpdate = router.swap(poolKey, true, type(int128).min, MIN_SQRT_RATIO, 0);
        assertEq(balanceUpdate.delta1(), 0);

        (SqrtRatio sqrtRatio, int32 tick, uint128 liqAfter) = core.poolState(poolKey.toPoolId()).parse();
        assertTrue(sqrtRatio == MIN_SQRT_RATIO);
        assertEq(tick, MIN_TICK - 1);
        assertEq(liqAfter, liquidity);

        (, uint128 p0, uint128 p1, uint128 f0, uint128 f1) =
            positions.getPositionFeesAndLiquidity(id, poolKey, MIN_TICK, MAX_TICK);
        assertEq(p0, 1000000499999874989935596106549936381, "principal0");
        assertEq(p1, 0, "principal1");
        assertEq(f0, ((uint128(balanceUpdate.delta0())) / 2) - 1, "fees0");
        assertEq(f1, 0, "fees1");
    }

    function test_feeAccumulation_works_full_range() public {
        MockExtension fae = createAndRegisterExtension();

        PoolKey memory poolKey = createFullRangePool({tick: MIN_TICK + 1, fee: 1 << 63, extension: address(fae)});
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

        PoolKey memory poolKey = createFullRangePool({tick: MIN_TICK + 1, fee: 1 << 63, extension: address(fae)});

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

    function test_getPositionFeesAndLiquidity_stableswap_returns_fees_outside_range() public {
        MockExtension fae = createAndRegisterExtension();

        PoolConfig config =
            createStableswapPoolConfig({_fee: 1 << 63, _amplification: 20, _centerTick: 0, _extension: address(fae)});
        PoolKey memory poolKey = createPool(address(token0), address(token1), 0, config);
        (int32 lower, int32 upper) = config.stableswapActiveLiquidityTickRange();

        (uint256 id, uint128 liquidity) = createPosition(poolKey, lower, upper, 1e6, 1e6);
        assertGt(liquidity, 0);

        token0.approve(address(fae), 1000);
        token1.approve(address(fae), 2000);
        fae.accumulateFees(poolKey, 1000, 2000);

        (,,, uint128 viewFees0, uint128 viewFees1) = positions.getPositionFeesAndLiquidity(id, poolKey, lower, upper);
        assertEq(viewFees0, 999);
        assertEq(viewFees1, 1999);

        (uint128 collect0, uint128 collect1) = positions.collectFees(id, poolKey, lower, upper);
        assertEq(collect0, viewFees0);
        assertEq(collect1, viewFees1);

        // swap to max price
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        router.swap({
            poolKey: poolKey,
            params: createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: type(int128).min, _isToken1: false, _skipAhead: 0
            }),
            calculatedAmountThreshold: type(int256).min
        });

        (,,, viewFees0, viewFees1) = positions.getPositionFeesAndLiquidity(id, poolKey, lower, upper);
        assertEq(viewFees0, 0);
        assertEq(viewFees1, 1000042);

        router.swap({
            poolKey: poolKey,
            params: createSwapParameters({
                _sqrtRatioLimit: SqrtRatio.wrap(0), _amount: type(int128).min, _isToken1: true, _skipAhead: 0
            }),
            calculatedAmountThreshold: type(int256).min
        });

        (,,, viewFees0, viewFees1) = positions.getPositionFeesAndLiquidity(id, poolKey, lower, upper);
        assertEq(viewFees0, 2000042);
        assertEq(viewFees1, 1000042);

        (collect0, collect1) = positions.collectFees(id, poolKey, lower, upper);
        assertEq(collect0, viewFees0);
        assertEq(collect1, viewFees1);
    }

    /// forge-config: default.isolate = true
    function test_mintAndDeposit_gas() public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100);
        token0.approve(address(positions), 100);
        token1.approve(address(positions), 100);

        coolAllContracts();
        (uint256 id, uint128 liquidity,,) = positions.mintAndDeposit(poolKey, -100, 100, 100, 100, 0);
        vm.snapshotGasLastCall("mintAndDeposit");

        coolAllContracts();
        positions.withdraw(id, poolKey, -100, 100, liquidity);
        vm.snapshotGasLastCall("withdraw");
    }

    /// forge-config: default.isolate = true
    function test_mintAndDeposit_eth_pool_gas() public {
        PoolKey memory poolKey = createETHPool(0, 1 << 63, 100);
        token1.approve(address(positions), 100);

        coolAllContracts();
        (uint256 id, uint128 liquidity,,) = positions.mintAndDeposit{value: 100}(poolKey, -100, 100, 100, 100, 0);
        vm.snapshotGasLastCall("mintAndDeposit eth");

        coolAllContracts();
        positions.withdraw(id, poolKey, -100, 100, liquidity);
        vm.snapshotGasLastCall("withdraw eth");
    }

    /// forge-config: default.isolate = true
    function test_mintAndDeposit_eth_pool_gas_free() public {
        positions = Positions(address(new FreePositions(core, address(this))));
        PoolKey memory poolKey = createETHPool(0, 1 << 63, 100);
        token1.approve(address(positions), 100);

        coolAllContracts();
        (uint256 id, uint128 liquidity,,) = positions.mintAndDeposit{value: 100}(poolKey, -100, 100, 100, 100, 0);
        vm.snapshotGasLastCall("mintAndDeposit eth (free)");

        coolAllContracts();
        positions.withdraw(id, poolKey, -100, 100, liquidity);
        vm.snapshotGasLastCall("withdraw eth (free)");
    }

    function test_burn_can_be_minted() public {
        uint256 id = positions.mint(bytes32(0));
        positions.burn(id);
        uint256 id2 = positions.mint(bytes32(0));
        assertEq(id, id2);
    }

    /// forge-config: default.isolate = true
    function test_gas_full_range_mintAndDeposit() public {
        PoolKey memory poolKey = createFullRangePool({tick: 0, fee: 1 << 63});
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);

        coolAllContracts();
        (uint256 id, uint128 liquidity,,) = positions.mintAndDeposit(poolKey, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);
        vm.snapshotGasLastCall("mintAndDeposit full range both tokens");

        coolAllContracts();
        positions.withdraw(id, poolKey, MIN_TICK, MAX_TICK, liquidity);
        vm.snapshotGasLastCall("withdraw full range both tokens");
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

    function test_free_positions(uint64 poolFee, uint64 swapFeesAmount0, uint64 swapFeesAmount1) public {
        MockExtension fae = createAndRegisterExtension();

        FreePositions testPositions = new FreePositions(core, owner);

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

        assertApproxEqAbs(protocolFeesAfterCollect0, 0, 1, "Protocol fees 0 should be fraction of swap fees");
        assertApproxEqAbs(protocolFeesAfterCollect1, 0, 1, "Protocol fees 1 should be fraction of swap fees");

        assertApproxEqAbs(collectedFees0, swapFeesAmount0, 1, "swap fees are not modified");
        assertApproxEqAbs(collectedFees1, swapFeesAmount1, 1, "swap fees are not modified");

        // Test 5: Withdraw liquidity and verify withdrawal fees are handled correctly
        (uint128 withdrawn0, uint128 withdrawn1) = testPositions.withdraw(id, poolKey, -100, 100, liquidity);

        assertApproxEqAbs(withdrawn0, amount0, 1, "Should receive amount0");
        assertApproxEqAbs(withdrawn1, amount1, 1, "Should receive amount1");

        (uint128 finalProtocolFees0, uint128 finalProtocolFees1) =
            testPositions.getProtocolFees(address(token0), address(token1));

        assertEq(finalProtocolFees0, 0, "Final protocol fees0");
        assertEq(finalProtocolFees1, 0, "Final protocol fees0");
    }

    function test_withdraw_without_fees_burns_fees() public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, -100, 100, 100, 100);

        // Generate fees by swapping
        token0.approve(address(router), 100);
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );

        // Verify fees exist before withdrawal
        (,,, uint128 f0Before, uint128 f1Before) = positions.getPositionFeesAndLiquidity(id, poolKey, -100, 100);
        assertEq(f0Before, 49, "Should have token0 fees before withdrawal");
        assertEq(f1Before, 0, "Should have no token1 fees");

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        // Withdraw WITHOUT collecting fees (withFees = false)
        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, -100, 100, liquidity, address(this), false);

        uint256 balance0After = token0.balanceOf(address(this));
        uint256 balance1After = token1.balanceOf(address(this));

        // Verify we only received principal, not fees
        assertEq(amount0, 74, "Should receive principal token0 only");
        assertEq(amount1, 25, "Should receive principal token1 only");
        assertEq(balance0After - balance0Before, 74, "Balance should increase by principal only");
        assertEq(balance1After - balance1Before, 25, "Balance should increase by principal only");

        // Verify the position no longer has liquidity
        (uint128 liquidityAfter,,,,) = positions.getPositionFeesAndLiquidity(id, poolKey, -100, 100);
        assertEq(liquidityAfter, 0, "Position should have no liquidity after full withdrawal");

        // The fees are now burned - they cannot be collected since the position has zero liquidity
        // Attempting to collect fees should return zero
        (uint128 collectedAfter0, uint128 collectedAfter1) = positions.collectFees(id, poolKey, -100, 100);
        assertEq(collectedAfter0, 0, "Should not be able to collect fees after full withdrawal");
        assertEq(collectedAfter1, 0, "Should not be able to collect fees after full withdrawal");
    }

    function test_withdraw_without_fees_multiple_swaps() public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, -100, 100, 100, 100);

        // Generate fees with multiple swaps
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

        // Verify fees accumulated from both swaps
        (, uint128 p0Before, uint128 p1Before, uint128 f0Before, uint128 f1Before) =
            positions.getPositionFeesAndLiquidity(id, poolKey, -100, 100);
        assertEq(f0Before, 49, "Should have token0 fees");
        assertEq(f1Before, 24, "Should have token1 fees");

        uint256 balance0Before = token0.balanceOf(address(this));
        uint256 balance1Before = token1.balanceOf(address(this));

        // Withdraw without fees
        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, -100, 100, liquidity, address(this), false);

        uint256 balance0After = token0.balanceOf(address(this));
        uint256 balance1After = token1.balanceOf(address(this));

        // Verify we only received principal amounts minus withdrawal protocol fee, fees are burned
        assertEq(balance0After - balance0Before, amount0, "Should receive only principal token0");
        assertEq(balance1After - balance1Before, amount1, "Should receive only principal token1");

        // Should receive principal minus 50% withdrawal protocol fee
        assertApproxEqAbs(uint256(amount0), uint256(p0Before / 2), 1, "Should receive half of principal token0");
        assertApproxEqAbs(uint256(amount1), uint256(p1Before / 2), 1, "Should receive half of principal token1");

        // Verify fees cannot be collected after full withdrawal
        (uint128 collectedAfter0, uint128 collectedAfter1) = positions.collectFees(id, poolKey, -100, 100);
        assertEq(collectedAfter0, 0, "Should not be able to collect fees after full withdrawal");
        assertEq(collectedAfter1, 0, "Should not be able to collect fees after full withdrawal");
    }

    function test_withdraw_without_fees_above_range() public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, -100, 100, 100, 100);

        // Generate fees
        token0.approve(address(router), 100);
        token1.approve(address(router), type(uint256).max);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );

        // Move price above range
        router.swap({
            poolKey: poolKey,
            isToken1: true,
            amount: type(int128).max,
            sqrtRatioLimit: tickToSqrtRatio(100),
            skipAhead: 0
        });

        // Verify position is above range with fees
        (, uint128 p0Before, uint128 p1Before, uint128 f0Before, uint128 f1Before) =
            positions.getPositionFeesAndLiquidity(id, poolKey, -100, 100);
        assertEq(p0Before, 0, "Should have no token0 principal above range");
        assertEq(p1Before, 200, "Should have token1 principal above range");
        assertEq(f0Before, 49, "Should have token0 fees");
        assertGt(f1Before, 0, "Should have token1 fees");

        // Withdraw without fees
        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, -100, 100, liquidity, address(this), false);

        // Should only receive principal minus withdrawal protocol fee (all in token1 since above range)
        // Withdrawal protocol fee = 50% of principal = 100, so we receive 100
        assertEq(amount0, 0, "Should receive no token0 above range");
        assertEq(amount1, 100, "Should receive principal minus withdrawal protocol fee");

        // Fees (f1Before) are burned - not collected
        assertLt(amount1, p1Before, "Should receive less than principal due to withdrawal protocol fee");

        // Verify fees cannot be collected after full withdrawal
        (uint128 collectedAfter0, uint128 collectedAfter1) = positions.collectFees(id, poolKey, -100, 100);
        assertEq(collectedAfter0, 0, "Should not be able to collect fees after full withdrawal");
        assertEq(collectedAfter1, 0, "Should not be able to collect fees after full withdrawal");
    }

    function test_withdraw_without_fees_below_range() public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100);

        (uint256 id, uint128 liquidity) = createPosition(poolKey, -100, 100, 100, 100);

        // Generate fees
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), 50);

        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token1), amount: 50}),
            type(int256).min
        );

        // Move price below range
        router.swap({
            poolKey: poolKey,
            isToken1: false,
            amount: type(int128).max,
            sqrtRatioLimit: tickToSqrtRatio(-100),
            skipAhead: 0
        });

        // Verify position is below range with fees
        (, uint128 p0Before, uint128 p1Before, uint128 f0Before, uint128 f1Before) =
            positions.getPositionFeesAndLiquidity(id, poolKey, -100, 100);
        assertEq(p0Before, 200, "Should have token0 principal below range");
        assertEq(p1Before, 0, "Should have no token1 principal below range");
        assertGt(f0Before, 0, "Should have token0 fees");
        assertEq(f1Before, 24, "Should have token1 fees");

        // Withdraw without fees
        (uint128 amount0, uint128 amount1) = positions.withdraw(id, poolKey, -100, 100, liquidity, address(this), false);

        // Should only receive principal minus withdrawal protocol fee (all in token0 since below range)
        // Withdrawal protocol fee = 50% of principal = 100, so we receive 100
        assertEq(amount0, 100, "Should receive principal minus withdrawal protocol fee");
        assertEq(amount1, 0, "Should receive no token1 below range");

        // Fees (f0Before) are burned - not collected
        assertLt(amount0, p0Before, "Should receive less than principal due to withdrawal protocol fee");

        // Verify fees cannot be collected after full withdrawal
        (uint128 collectedAfter0, uint128 collectedAfter1) = positions.collectFees(id, poolKey, -100, 100);
        assertEq(collectedAfter0, 0, "Should not be able to collect fees after full withdrawal");
        assertEq(collectedAfter1, 0, "Should not be able to collect fees after full withdrawal");
    }

    function test_partial_withdraw_without_fees_leaves_fees_collectible() public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100);

        (uint256 id,) = createPosition(poolKey, -100, 100, 100, 100);

        // Generate fees
        token0.approve(address(router), 100);
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 100}),
            type(int256).min
        );

        // Verify fees before partial withdrawal
        (uint128 liquidityBefore,,, uint128 f0Before,) = positions.getPositionFeesAndLiquidity(id, poolKey, -100, 100);
        assertEq(f0Before, 49, "Should have token0 fees");

        // Withdraw half the liquidity without fees
        uint128 halfLiquidity = liquidityBefore / 2;
        (uint128 amount0, uint128 amount1) =
            positions.withdraw(id, poolKey, -100, 100, halfLiquidity, address(this), false);

        // Should receive approximately half the principal (minus withdrawal protocol fee)
        assertApproxEqAbs(uint256(amount0), 37, 1, "Should receive half of principal token0");
        assertApproxEqAbs(uint256(amount1), 12, 1, "Should receive half of principal token1");

        // Verify remaining position still has liquidity and fees remain collectible
        (uint128 liquidityAfter,,, uint128 f0After,) = positions.getPositionFeesAndLiquidity(id, poolKey, -100, 100);
        assertApproxEqAbs(
            uint256(liquidityAfter), uint256(halfLiquidity), uint256(1), "Should have half liquidity remaining"
        );
        assertApproxEqAbs(
            uint256(f0After), 49, 1, "Fees should remain approximately unchanged after partial withdrawal without fees"
        );

        // Now collect the fees that remained
        (uint128 collectedFees0, uint128 collectedFees1) = positions.collectFees(id, poolKey, -100, 100);
        assertApproxEqAbs(
            uint256(collectedFees0), 49, 1, "Should be able to collect approximately all fees after partial withdrawal"
        );
        assertEq(collectedFees1, 0, "Should have no token1 fees");
    }

    function test_compare_withdraw_with_and_without_fees() public {
        PoolKey memory poolKey = createPool(0, 1 << 63, 100);

        // Create two identical positions
        (uint256 id1, uint128 liquidity1) = createPosition(poolKey, -100, 100, 100, 100);
        (uint256 id2, uint128 liquidity2) = createPosition(poolKey, -100, 100, 100, 100);

        assertEq(liquidity1, liquidity2, "Both positions should have same liquidity");

        // Generate fees for both positions
        token0.approve(address(router), 200);
        router.swap(
            RouteNode({poolKey: poolKey, sqrtRatioLimit: SqrtRatio.wrap(0), skipAhead: 0}),
            TokenAmount({token: address(token0), amount: 200}),
            type(int256).min
        );

        // Verify both have same fees (allow 1 wei difference for rounding)
        (,,, uint128 f0_1, uint128 f1_1) = positions.getPositionFeesAndLiquidity(id1, poolKey, -100, 100);
        (,,, uint128 f0_2, uint128 f1_2) = positions.getPositionFeesAndLiquidity(id2, poolKey, -100, 100);
        assertApproxEqAbs(uint256(f0_1), uint256(f0_2), 1, "Both positions should have approximately same token0 fees");
        assertApproxEqAbs(uint256(f1_1), uint256(f1_2), 1, "Both positions should have approximately same token1 fees");

        // Withdraw position 1 WITH fees (default behavior)
        (uint128 amount0_with, uint128 amount1_with) = positions.withdraw(id1, poolKey, -100, 100, liquidity1);

        // Withdraw position 2 WITHOUT fees
        (uint128 amount0_without, uint128 amount1_without) =
            positions.withdraw(id2, poolKey, -100, 100, liquidity2, address(this), false);

        // Position 1 collected fees, position 2 burned them
        assertGt(amount0_with, amount0_without, "Withdrawing with fees should return more token0");

        // Verify the difference approximately equals the fees (allow 1 wei difference for rounding)
        assertApproxEqAbs(
            uint256(amount0_with - amount0_without),
            uint256(f0_1),
            1,
            "Difference should approximately equal token0 fees"
        );
        assertApproxEqAbs(
            uint256(amount1_with - amount1_without),
            uint256(f1_1),
            1,
            "Difference should approximately equal token1 fees"
        );
    }
}
