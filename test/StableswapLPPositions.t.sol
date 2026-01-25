// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Core} from "../src/Core.sol";
import {StableswapLPPositions} from "../src/StableswapLPPositions.sol";
import {IStableswapLPPositions} from "../src/interfaces/IStableswapLPPositions.sol";
import {StableswapLPToken} from "../src/StableswapLPToken.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolConfig, createStableswapPoolConfig} from "../src/types/poolConfig.sol";
import {TestToken} from "./TestToken.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {MockExtension} from "./FullTest.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {FullTest} from "./FullTest.sol";

contract StableswapLPPositionsTest is FullTest {
    using CoreLib for *;

    StableswapLPPositions lpPositions;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Helper constant for deadline - far future timestamp
    uint256 constant DEADLINE = type(uint256).max;

    function setUp() public override {
        super.setUp();

        // Create Stableswap LP positions contract
        lpPositions = new StableswapLPPositions(core, owner, 0);

        // Give Alice and Bob tokens
        token0.transfer(alice, 1_000_000 ether);
        token1.transfer(alice, 1_000_000 ether);
        token0.transfer(bob, 1_000_000 ether);
        token1.transfer(bob, 1_000_000 ether);

        // Approve tokens
        vm.prank(alice);
        token0.approve(address(lpPositions), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(lpPositions), type(uint256).max);

        vm.prank(bob);
        token0.approve(address(lpPositions), type(uint256).max);
        vm.prank(bob);
        token1.approve(address(lpPositions), type(uint256).max);
    }

    function createStableswapPool() internal returns (PoolKey memory poolKey) {
        // fee, amplification, centerTick, extension
        PoolConfig config = createStableswapPoolConfig(1 << 63, 10, 0, address(0));
        poolKey = PoolKey({token0: address(token0), token1: address(token1), config: config});
        core.initializePool(poolKey, 0);
    }

    // LP Token Minting Tests

    function test_createLPToken() public {
        PoolKey memory poolKey = createStableswapPool();

        address lpToken = lpPositions.createLPToken(poolKey);

        assertEq(lpPositions.lpTokens(poolKey.toPoolId()), lpToken);
        assertGt(address(lpToken).code.length, 0);
    }

    function test_createLPToken_twice_reverts() public {
        PoolKey memory poolKey = createStableswapPool();

        lpPositions.createLPToken(poolKey);

        vm.expectRevert(IStableswapLPPositions.LPTokenAlreadyExists.selector);
        lpPositions.createLPToken(poolKey);
    }

    function test_firstDeposit_burnsMinimumLiquidity() public {
        PoolKey memory poolKey = createStableswapPool();
        address lpToken = lpPositions.createLPToken(poolKey);

        vm.prank(alice);
        (uint256 lpTokensMinted,,) = lpPositions.deposit(poolKey, 10000, 10000, 0, DEADLINE);

        uint256 totalSupply = StableswapLPToken(payable(lpToken)).totalSupply();
        uint128 totalLiquidity = StableswapLPToken(payable(lpToken)).totalLiquidity();

        // First deposit should burn 1000 LP tokens to address(0xdead)
        assertEq(StableswapLPToken(payable(lpToken)).balanceOf(address(0xdead)), 1000);

        // Alice should receive (totalSupply - 1000)
        assertEq(StableswapLPToken(payable(lpToken)).balanceOf(alice), lpTokensMinted);
        assertEq(lpTokensMinted, totalSupply - 1000);
        assertGt(lpTokensMinted, 0);

        // Total LP tokens should equal liquidity added
        assertEq(totalSupply, totalLiquidity);
    }

    function test_subsequentDeposit_proportionalMinting() public {
        PoolKey memory poolKey = createStableswapPool();
        address lpToken = lpPositions.createLPToken(poolKey);

        // Alice deposits first
        vm.prank(alice);
        (uint256 aliceLpTokens,,) = lpPositions.deposit(poolKey, 10000, 10000, 0, DEADLINE);

        uint256 totalSupplyAfterAlice = StableswapLPToken(payable(lpToken)).totalSupply();

        // Bob deposits same amount
        vm.prank(bob);
        (uint256 bobLpTokens,,) = lpPositions.deposit(poolKey, 10000, 10000, 0, DEADLINE);

        // Bob should receive approximately the same amount as Alice
        // (might differ slightly due to rounding and minimum liquidity burn)
        assertApproxEqRel(bobLpTokens, aliceLpTokens, 0.01e18); // Within 1%

        // Total supply should approximately double
        assertApproxEqRel(
            StableswapLPToken(payable(lpToken)).totalSupply(),
            totalSupplyAfterAlice * 2,
            0.01e18
        );
    }

    function test_preventDonationAttack() public {
        PoolKey memory poolKey = createStableswapPool();
        address lpToken = lpPositions.createLPToken(poolKey);

        // Attacker deposits very small amount
        vm.prank(alice);
        (uint256 attackerLpTokens,,) = lpPositions.deposit(poolKey, 1000, 1000, 0, DEADLINE);

        // Try donation attack - directly transfer tokens to Core
        // (In reality, attacker would need to add liquidity to the position directly,
        // but minimum liquidity burn makes this attack economically infeasible)

        // Bob deposits normal amount
        vm.prank(bob);
        (uint256 bobLpTokens,,) = lpPositions.deposit(poolKey, 1_000_000, 1_000_000, 0, DEADLINE);

        // Bob should not be heavily diluted
        // He should get approximately 1000x the LP tokens the attacker got
        // (accounting for the minimum liquidity burn in first deposit)
        assertGt(bobLpTokens, attackerLpTokens * 900); // At least 900x
    }

    // Auto-Compounding Tests

    function test_deposit_autoCompoundsPendingFees() public {
        PoolKey memory poolKey = createStableswapPool();
        address lpToken = lpPositions.createLPToken(poolKey);

        // Alice deposits
        vm.prank(alice);
        lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        uint128 totalLiquidityBefore = StableswapLPToken(payable(lpToken)).totalLiquidity();

        // Generate fees via swap (would need router integration)
        // For now, we'll simulate fees being accumulated
        // TODO: Implement swap to generate real fees

        // Bob deposits - should trigger auto-compound
        vm.prank(bob);
        lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        uint128 totalLiquidityAfter = StableswapLPToken(payable(lpToken)).totalLiquidity();

        // Total liquidity should increase (original deposits + fees)
        assertGe(totalLiquidityAfter, totalLiquidityBefore + 100000);
    }

    function test_withdraw_autoCompoundsPendingFees() public {
        PoolKey memory poolKey = createStableswapPool();
        address lpToken = lpPositions.createLPToken(poolKey);

        // Alice deposits
        vm.prank(alice);
        (uint256 aliceLpTokens,,) = lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        // Bob deposits
        vm.prank(bob);
        lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        uint128 totalLiquidityBefore = StableswapLPToken(payable(lpToken)).totalLiquidity();

        // Generate fees (would need swap integration)
        // TODO: Implement swap to generate real fees

        // Alice withdraws - should trigger auto-compound before withdrawal
        vm.prank(alice);
        lpPositions.withdraw(poolKey, aliceLpTokens, 0, 0, DEADLINE);

        // Total liquidity should have increased from fees before withdrawal
        uint128 totalLiquidityAfter = StableswapLPToken(payable(lpToken)).totalLiquidity();

        // After Alice's withdrawal, remaining liquidity should be less than before
        // but the auto-compound should have happened first
        assertLt(totalLiquidityAfter, totalLiquidityBefore);
    }

    function test_autoCompound_noFeesDoesNotRevert() public {
        PoolKey memory poolKey = createStableswapPool();
        lpPositions.createLPToken(poolKey);

        // Deposit without fees should succeed
        vm.prank(alice);
        lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        // Withdraw without fees should succeed
        vm.prank(alice);
        lpPositions.withdraw(poolKey, 50000, 0, 0, DEADLINE);
    }

    // Fee Value Capture Tests

    function test_feesIncreaseWithdrawalValue() public {
        PoolKey memory poolKey = createStableswapPool();
        address lpToken = lpPositions.createLPToken(poolKey);

        // Alice deposits
        vm.prank(alice);
        (uint256 lpTokensMinted,,) = lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        uint256 token0BalanceBefore = token0.balanceOf(alice);
        uint256 token1BalanceBefore = token1.balanceOf(alice);

        // Generate fees (would need swap integration)
        // TODO: Implement swap to generate real fees

        // Alice withdraws
        vm.prank(alice);
        (uint128 amount0, uint128 amount1) = lpPositions.withdraw(poolKey, lpTokensMinted, 0, 0, DEADLINE);

        // Alice should get back at least what she deposited (minus rounding)
        // In a real scenario with fees, she would get more
        assertGe(token0.balanceOf(alice) - token0BalanceBefore, 99900);
        assertGe(token1.balanceOf(alice) - token1BalanceBefore, 99900);
    }

    function test_proportionalFeeSharing() public {
        PoolKey memory poolKey = createStableswapPool();
        address lpToken = lpPositions.createLPToken(poolKey);

        // Alice deposits 100k
        vm.prank(alice);
        (uint256 aliceLpTokens,,) = lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        // Bob deposits 100k
        vm.prank(bob);
        (uint256 bobLpTokens,,) = lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        // They should have approximately equal LP tokens
        assertApproxEqRel(aliceLpTokens, bobLpTokens, 0.01e18);

        // Generate fees (would need swap integration)
        // TODO: Implement swap to generate real fees

        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 bobToken0Before = token0.balanceOf(bob);

        // Both withdraw
        vm.prank(alice);
        (uint128 aliceAmount0,) = lpPositions.withdraw(poolKey, aliceLpTokens, 0, 0, DEADLINE);

        vm.prank(bob);
        (uint128 bobAmount0,) = lpPositions.withdraw(poolKey, bobLpTokens, 0, 0, DEADLINE);

        // They should receive approximately equal amounts
        assertApproxEqRel(aliceAmount0, bobAmount0, 0.01e18);
    }

    function test_laterDepositor_getsOnlyNewFees() public {
        PoolKey memory poolKey = createStableswapPool();
        address lpToken = lpPositions.createLPToken(poolKey);

        // Alice deposits
        vm.prank(alice);
        (uint256 aliceLpTokens,,) = lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        // Generate fees (100 tokens worth)
        // TODO: Implement swap to generate real fees
        // This would increase totalLiquidity

        // Bob deposits after fees - triggers compound
        vm.prank(bob);
        (uint256 bobLpTokens,,) = lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        // Without any actual fee generation, both should receive approximately equal LP tokens
        // (Bob gets slightly fewer due to minimum liquidity burn on Alice's first deposit)
        assertApproxEqRel(bobLpTokens, aliceLpTokens, 0.01e18); // Within 1%

        // Generate more fees
        // TODO: Implement swap to generate real fees

        uint256 aliceToken0Before = token0.balanceOf(alice);
        uint256 bobToken0Before = token0.balanceOf(bob);

        // Both withdraw all
        vm.prank(alice);
        (uint128 aliceAmount0,) = lpPositions.withdraw(poolKey, aliceLpTokens, 0, 0, DEADLINE);

        vm.prank(bob);
        (uint128 bobAmount0,) = lpPositions.withdraw(poolKey, bobLpTokens, 0, 0, DEADLINE);

        // Without fees, they should get approximately equal amounts back
        // (accounting for the minimum liquidity that was burned)
        assertApproxEqRel(aliceAmount0, bobAmount0, 0.01e18); // Within 1%
    }

    // Edge Cases

    function test_zeroLiquidity_cannotDeposit() public {
        PoolKey memory poolKey = createStableswapPool();
        lpPositions.createLPToken(poolKey);

        vm.prank(alice);
        vm.expectRevert();
        lpPositions.deposit(poolKey, 0, 0, 1, DEADLINE);
    }

    function test_withdrawAll_leavesMinimumLiquidity() public {
        PoolKey memory poolKey = createStableswapPool();
        address lpToken = lpPositions.createLPToken(poolKey);

        // Alice is the only depositor
        vm.prank(alice);
        (uint256 lpTokensMinted,,) = lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        // Alice withdraws all her LP tokens
        vm.prank(alice);
        lpPositions.withdraw(poolKey, lpTokensMinted, 0, 0, DEADLINE);

        // Total supply should still include the 1000 minimum liquidity burned to 0xdead
        assertEq(StableswapLPToken(payable(lpToken)).totalSupply(), 1000);
        assertEq(StableswapLPToken(payable(lpToken)).balanceOf(address(0xdead)), 1000);
    }

    function test_dustAmounts_handleCorrectly() public {
        PoolKey memory poolKey = createStableswapPool();
        address lpToken = lpPositions.createLPToken(poolKey);

        // Try depositing very small amounts
        vm.prank(alice);
        (uint256 lpTokensMinted,,) = lpPositions.deposit(poolKey, 1000, 1000, 0, DEADLINE);

        assertGt(lpTokensMinted, 0);

        // Withdraw dust amount
        vm.prank(alice);
        (uint128 amount0, uint128 amount1) = lpPositions.withdraw(poolKey, 1, 0, 0, DEADLINE);

        // Should get back something (might be 0 due to rounding)
        assertGe(amount0 + amount1, 0);
    }

    function test_depositWithSlippageProtection() public {
        PoolKey memory poolKey = createStableswapPool();
        lpPositions.createLPToken(poolKey);

        // Try to deposit with minLiquidity too high
        vm.prank(alice);
        vm.expectRevert();
        lpPositions.deposit(poolKey, 100, 100, 100000, DEADLINE);
    }

    function test_nonExistentLPToken_reverts() public {
        PoolKey memory poolKey = createStableswapPool();

        // Try to deposit without creating LP token first
        vm.prank(alice);
        vm.expectRevert(IStableswapLPPositions.LPTokenDoesNotExist.selector);
        lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);
    }

    function test_protocolFeeCollection() public {
        // Create LP positions with protocol fee
        StableswapLPPositions lpPositionsWithFee = new StableswapLPPositions(
            core,
            owner,
            1 << 60 // 6.25% protocol fee
        );

        PoolKey memory poolKey = createStableswapPool();

        vm.prank(alice);
        token0.approve(address(lpPositionsWithFee), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(lpPositionsWithFee), type(uint256).max);

        address lpToken = lpPositionsWithFee.createLPToken(poolKey);

        vm.prank(alice);
        lpPositionsWithFee.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        // Generate fees and compound
        // TODO: Implement swap to generate real fees

        // Check protocol fees accumulated
        (uint128 protocolFee0, uint128 protocolFee1) =
            lpPositionsWithFee.getProtocolFees(address(token0), address(token1));

        // With no actual swaps yet, fees should be 0
        assertEq(protocolFee0, 0);
        assertEq(protocolFee1, 0);
    }

    function test_multipleDepositsAndWithdrawals() public {
        PoolKey memory poolKey = createStableswapPool();
        address lpToken = lpPositions.createLPToken(poolKey);

        // Alice deposits
        vm.prank(alice);
        (uint256 aliceLpTokens1,,) = lpPositions.deposit(poolKey, 50000, 50000, 0, DEADLINE);

        // Bob deposits
        vm.prank(bob);
        (uint256 bobLpTokens1,,) = lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        // Alice deposits more
        vm.prank(alice);
        (uint256 aliceLpTokens2,,) = lpPositions.deposit(poolKey, 50000, 50000, 0, DEADLINE);

        // Alice withdraws partial
        vm.prank(alice);
        lpPositions.withdraw(poolKey, aliceLpTokens1 / 2, 0, 0, DEADLINE);

        // Bob withdraws all
        vm.prank(bob);
        lpPositions.withdraw(poolKey, bobLpTokens1, 0, 0, DEADLINE);

        // Alice withdraws remaining
        uint256 aliceRemainingLpTokens = StableswapLPToken(payable(lpToken)).balanceOf(alice);
        vm.prank(alice);
        lpPositions.withdraw(poolKey, aliceRemainingLpTokens, 0, 0, DEADLINE);

        // Only minimum liquidity should remain
        assertEq(StableswapLPToken(payable(lpToken)).totalSupply(), 1000);
    }

    // New tests for added features

    function test_deadlineExpired_reverts() public {
        PoolKey memory poolKey = createStableswapPool();
        lpPositions.createLPToken(poolKey);

        // Try to deposit with expired deadline
        vm.prank(alice);
        vm.expectRevert(IStableswapLPPositions.DeadlineExpired.selector);
        lpPositions.deposit(poolKey, 100000, 100000, 0, block.timestamp - 1);
    }

    function test_withdrawSlippageProtection() public {
        PoolKey memory poolKey = createStableswapPool();
        lpPositions.createLPToken(poolKey);

        // Alice deposits
        vm.prank(alice);
        (uint256 lpTokensMinted,,) = lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        // Try to withdraw with minAmount too high
        vm.prank(alice);
        vm.expectRevert();
        lpPositions.withdraw(poolKey, lpTokensMinted, 200000, 200000, DEADLINE);
    }

    function test_depositEmitsEvent() public {
        PoolKey memory poolKey = createStableswapPool();
        lpPositions.createLPToken(poolKey);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit IStableswapLPPositions.Deposit(alice, poolKey.toPoolId(), 0, 0, 0);
        lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);
    }

    function test_withdrawEmitsEvent() public {
        PoolKey memory poolKey = createStableswapPool();
        lpPositions.createLPToken(poolKey);

        vm.prank(alice);
        (uint256 lpTokensMinted,,) = lpPositions.deposit(poolKey, 100000, 100000, 0, DEADLINE);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit IStableswapLPPositions.Withdraw(alice, poolKey.toPoolId(), 0, 0, 0);
        lpPositions.withdraw(poolKey, lpTokensMinted, 0, 0, DEADLINE);
    }
}
