// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {FullTest} from "./FullTest.sol";
import {SimpleVault} from "../src/examples/SimpleVault.sol";
import {IBaseVault} from "../src/interfaces/IBaseVault.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolConfig, createStableswapPoolConfig, createFullRangePoolConfig} from "../src/types/poolConfig.sol";
import {PoolAllocation} from "../src/types/vaultTypes.sol";
import {TestToken} from "./TestToken.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {SwapParameters, createSwapParameters} from "../src/types/swapParameters.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";

contract BaseVaultTest is FullTest {
    using CoreLib for *;

    SimpleVault vault;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant MIN_EPOCH_DURATION = 1 hours;

    function setUp() public override {
        super.setUp();

        // Create vault with token0 as deposit token
        vault = new SimpleVault(
            core,
            owner,
            address(token0),
            MIN_EPOCH_DURATION
        );

        // Give Alice and Bob tokens
        token0.transfer(alice, 1_000_000 ether);
        token1.transfer(alice, 1_000_000 ether);
        token0.transfer(bob, 1_000_000 ether);
        token1.transfer(bob, 1_000_000 ether);

        // Approve vault for deposits
        vm.prank(alice);
        token0.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        token0.approve(address(vault), type(uint256).max);
    }

    function createStableswapPool() internal returns (PoolKey memory poolKey) {
        // fee, amplification, centerTick, extension
        PoolConfig config = createStableswapPoolConfig(1 << 63, 10, 0, address(0));
        poolKey = PoolKey({token0: address(token0), token1: address(token1), config: config});
        core.initializePool(poolKey, 0);
    }

    function createAndSetTargetPool() internal returns (PoolKey memory poolKey) {
        poolKey = createStableswapPool();
        vm.prank(owner);
        vault.setTargetPool(poolKey);
    }

    // ============ Basic Configuration Tests ============

    function test_constructor_setsCorrectValues() public view {
        assertEq(vault.DEPOSIT_TOKEN(), address(token0));
        assertEq(vault.MIN_EPOCH_DURATION(), MIN_EPOCH_DURATION);
        assertEq(vault.currentEpoch(), 0);
        assertEq(vault.pendingDeposits(), 0);
        assertEq(vault.pendingWithdrawShares(), 0);
    }

    function test_name_returnsCorrectName() public view {
        assertEq(vault.name(), "Simple Ekubo Vault");
    }

    function test_symbol_returnsCorrectSymbol() public view {
        assertEq(vault.symbol(), "sEKV");
    }

    function test_decimals_returns18() public view {
        assertEq(vault.decimals(), 18);
    }

    // ============ Target Pool Tests ============

    function test_setTargetPool_onlyOwner() public {
        PoolKey memory poolKey = createStableswapPool();

        vm.prank(alice);
        vm.expectRevert();
        vault.setTargetPool(poolKey);
    }

    function test_setTargetPool_ownerCanSet() public {
        PoolKey memory poolKey = createStableswapPool();

        vm.prank(owner);
        vault.setTargetPool(poolKey);

        assertTrue(vault.hasTargetPool());
    }

    function test_getTargetAllocations_emptyWhenNoPool() public view {
        PoolAllocation[] memory allocations = vault.getTargetAllocations();
        assertEq(allocations.length, 0);
    }

    function test_getTargetAllocations_returnsPoolWhenSet() public {
        PoolKey memory poolKey = createAndSetTargetPool();

        PoolAllocation[] memory allocations = vault.getTargetAllocations();
        assertEq(allocations.length, 1);
        assertEq(allocations[0].poolKey.token0, poolKey.token0);
        assertEq(allocations[0].poolKey.token1, poolKey.token1);
        assertEq(allocations[0].targetBps, 10000);
    }

    // ============ Deposit Tests ============

    function test_deposit_transfersTokens() public {
        createAndSetTargetPool();

        uint256 depositAmount = 1000 ether;
        uint256 balanceBefore = token0.balanceOf(alice);

        vm.prank(alice);
        vault.queueDeposit(depositAmount);

        assertEq(token0.balanceOf(alice), balanceBefore - depositAmount);
        assertEq(token0.balanceOf(address(vault)), depositAmount);
    }

    function test_deposit_recordsPendingDeposit() public {
        createAndSetTargetPool();

        uint256 depositAmount = 1000 ether;

        vm.prank(alice);
        vault.queueDeposit(depositAmount);

        assertEq(vault.pendingDeposits(), depositAmount);
        assertEq(vault.userEpochDeposits(0, alice), depositAmount);
    }

    function test_deposit_emitsEvent() public {
        createAndSetTargetPool();

        uint256 depositAmount = 1000 ether;

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit IBaseVault.Deposited(alice, 0, depositAmount);
        vault.queueDeposit(depositAmount);
    }

    function test_deposit_revertsOnZeroAmount() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vm.expectRevert(IBaseVault.ZeroDeposit.selector);
        vault.queueDeposit(0);
    }

    function test_deposit_multipleDepositsAccumulate() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.prank(bob);
        vault.queueDeposit(2000 ether);

        assertEq(vault.pendingDeposits(), 3000 ether);
        assertEq(vault.userEpochDeposits(0, alice), 1000 ether);
        assertEq(vault.userEpochDeposits(0, bob), 2000 ether);
    }

    // ============ Withdraw Tests ============

    function test_withdraw_transfersShares() public {
        createAndSetTargetPool();

        // First deposit and process epoch to get shares
        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        // Claim shares
        vm.prank(alice);
        uint256 shares = vault.claimShares(0);

        // Queue withdrawal
        vm.prank(alice);
        vault.queueWithdraw(shares);

        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
    }

    function test_withdraw_recordsPendingWithdrawal() public {
        createAndSetTargetPool();

        // First deposit and process epoch to get shares
        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        // Claim shares
        vm.prank(alice);
        uint256 shares = vault.claimShares(0);

        // Queue withdrawal
        vm.prank(alice);
        vault.queueWithdraw(shares);

        assertEq(vault.pendingWithdrawShares(), shares);
        assertEq(vault.userEpochWithdrawals(1, alice), shares);
    }

    function test_withdraw_revertsOnZeroShares() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vm.expectRevert(IBaseVault.ZeroWithdrawal.selector);
        vault.queueWithdraw(0);
    }

    // ============ Epoch Processing Tests ============

    function test_processEpoch_revertsBeforeMinDuration() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.expectRevert(IBaseVault.EpochNotReady.selector);
        vault.processEpoch();
    }

    function test_processEpoch_succeedsAfterMinDuration() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        assertEq(vault.currentEpoch(), 1);
        assertTrue(vault.epochProcessed(0));
    }

    function test_processEpoch_setsShareRateForFirstDeposit() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        // First deposit should have 1:1 share rate (1e18)
        assertEq(vault.epochShareRate(0), 1e18);
    }

    function test_processEpoch_resetsPendingAmounts() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        assertEq(vault.pendingDeposits(), 0);
        assertEq(vault.pendingWithdrawShares(), 0);
    }

    // ============ Claim Tests ============

    function test_claimShares_mintsShares() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        uint256 balanceBefore = vault.balanceOf(alice);

        vm.prank(alice);
        uint256 shares = vault.claimShares(0);

        assertEq(vault.balanceOf(alice), balanceBefore + shares);
        assertGt(shares, 0);
    }

    function test_claimShares_clearsUserDeposit() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        vm.prank(alice);
        vault.claimShares(0);

        assertEq(vault.userEpochDeposits(0, alice), 0);
    }

    function test_claimShares_revertsForUnprocessedEpoch() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.prank(alice);
        vm.expectRevert(IBaseVault.EpochNotProcessed.selector);
        vault.claimShares(0);
    }

    function test_claimShares_revertsForNoDeposit() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        vm.prank(bob);
        vm.expectRevert(IBaseVault.NoDepositInEpoch.selector);
        vault.claimShares(0);
    }

    function test_claimWithdrawal_transfersTokens() public {
        createAndSetTargetPool();

        // Deposit and get shares
        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        vm.prank(alice);
        uint256 shares = vault.claimShares(0);

        // Queue withdrawal
        vm.prank(alice);
        vault.queueWithdraw(shares);

        // Process withdrawal epoch
        skip(MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        uint256 balanceBefore = token0.balanceOf(alice);

        vm.prank(alice);
        uint256 amount = vault.claimWithdrawal(1);

        assertEq(token0.balanceOf(alice), balanceBefore + amount);
        assertGt(amount, 0);
    }

    function test_claimWithdrawal_revertsForUnprocessedEpoch() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vm.expectRevert(IBaseVault.EpochNotProcessed.selector);
        vault.claimWithdrawal(0);
    }

    function test_claimWithdrawal_revertsForNoWithdrawal() public {
        createAndSetTargetPool();

        // Process an empty epoch
        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        vm.prank(alice);
        vm.expectRevert(IBaseVault.NoWithdrawalInEpoch.selector);
        vault.claimWithdrawal(0);
    }

    // ============ Batch Claim Tests ============

    function test_batchClaim_claimsMultipleEpochs() public {
        createAndSetTargetPool();

        // Epoch 0 deposit
        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        // Epoch 1 deposit
        vm.prank(alice);
        vault.queueDeposit(500 ether);

        skip(MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        uint256[] memory depositEpochs = new uint256[](2);
        depositEpochs[0] = 0;
        depositEpochs[1] = 1;
        uint256[] memory withdrawalEpochs = new uint256[](0);

        vm.prank(alice);
        vault.batchClaim(depositEpochs, withdrawalEpochs);

        assertGt(vault.balanceOf(alice), 0);
        assertEq(vault.userEpochDeposits(0, alice), 0);
        assertEq(vault.userEpochDeposits(1, alice), 0);
    }

    // ============ Full Cycle Test ============

    function test_fullCycle_depositWithdraw() public {
        createAndSetTargetPool();

        uint256 depositAmount = 1000 ether;

        // Alice deposits
        vm.prank(alice);
        vault.queueDeposit(depositAmount);

        // Process epoch
        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        // Claim shares
        vm.prank(alice);
        uint256 shares = vault.claimShares(0);
        assertGt(shares, 0);

        // Queue withdrawal
        vm.prank(alice);
        vault.queueWithdraw(shares);

        // Process withdrawal epoch
        skip(MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        // Claim withdrawal
        uint256 balanceBefore = token0.balanceOf(alice);
        vm.prank(alice);
        uint256 withdrawnAmount = vault.claimWithdrawal(1);

        // Should get back approximately the deposit amount (minus any slippage/fees)
        assertApproxEqRel(withdrawnAmount, depositAmount, 0.05e18); // Within 5%
        assertEq(token0.balanceOf(alice), balanceBefore + withdrawnAmount);
    }

    // ============ ERC-4626 Compliance Tests ============

    function test_asset_returnsDepositToken() public view {
        assertEq(vault.asset(), address(token0));
    }

    function test_totalAssets_returnsZeroWhenEmpty() public view {
        assertEq(vault.totalAssets(), 0);
    }

    function test_totalAssets_excludesPendingDeposits() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        // Pending deposits should not count as totalAssets
        assertEq(vault.totalAssets(), 0);
    }

    function test_totalAssets_includesWorkingAssets() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        // After epoch processing, assets should be counted
        assertGt(vault.totalAssets(), 0);
    }

    function test_convertToShares_oneToOneWhenEmpty() public view {
        uint256 assets = 1000 ether;
        assertEq(vault.convertToShares(assets), assets);
    }

    function test_convertToAssets_oneToOneWhenEmpty() public view {
        uint256 shares = 1000 ether;
        assertEq(vault.convertToAssets(shares), shares);
    }

    function test_maxDeposit_returnsMaxUint() public view {
        assertEq(vault.maxDeposit(alice), type(uint256).max);
    }

    function test_maxMint_returnsMaxUint() public view {
        assertEq(vault.maxMint(alice), type(uint256).max);
    }

    function test_maxWithdraw_returnsConvertedBalance() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        vm.prank(alice);
        vault.claimShares(0);

        uint256 maxWithdraw = vault.maxWithdraw(alice);
        assertGt(maxWithdraw, 0);
    }

    function test_maxRedeem_returnsShareBalance() public {
        createAndSetTargetPool();

        vm.prank(alice);
        vault.queueDeposit(1000 ether);

        vm.warp(block.timestamp + MIN_EPOCH_DURATION + 1);
        vault.processEpoch();

        vm.prank(alice);
        uint256 shares = vault.claimShares(0);

        assertEq(vault.maxRedeem(alice), shares);
    }

    function test_previewDeposit_returnsZero() public view {
        assertEq(vault.previewDeposit(1000 ether), 0);
    }

    function test_previewMint_returnsZero() public view {
        assertEq(vault.previewMint(1000 ether), 0);
    }

    function test_previewWithdraw_returnsZero() public view {
        assertEq(vault.previewWithdraw(1000 ether), 0);
    }

    function test_previewRedeem_returnsZero() public view {
        assertEq(vault.previewRedeem(1000 ether), 0);
    }

    // ============ ERC-4626 Sync Operations Revert Tests ============

    function test_deposit_erc4626_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IBaseVault.MustUseEpochQueue.selector);
        vault.deposit(1000 ether, alice);
    }

    function test_mint_erc4626_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IBaseVault.MustUseEpochQueue.selector);
        vault.mint(1000 ether, alice);
    }

    function test_withdraw_erc4626_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IBaseVault.MustUseEpochQueue.selector);
        vault.withdraw(1000 ether, alice, alice);
    }

    function test_redeem_erc4626_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IBaseVault.MustUseEpochQueue.selector);
        vault.redeem(1000 ether, alice, alice);
    }
}
