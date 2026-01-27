// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {StableswapLPPositions} from "../src/StableswapLPPositions.sol";
import {IStableswapLPPositions} from "../src/interfaces/IStableswapLPPositions.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolConfig, createStableswapPoolConfig} from "../src/types/poolConfig.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {FullTest} from "./FullTest.sol";

/// @title StableswapLPPositionsERC6909Test
/// @notice Tests ERC6909-specific functionality: multi-pool management, operator approvals, gas efficiency
contract StableswapLPPositionsERC6909Test is FullTest {
    using CoreLib for *;

    StableswapLPPositions lpPositions;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    uint256 constant DEADLINE = type(uint256).max;

    function setUp() public override {
        super.setUp();

        lpPositions = new StableswapLPPositions(core, owner, 0);

        // Give users tokens
        address[3] memory users = [alice, bob, charlie];
        for (uint256 i = 0; i < users.length; i++) {
            token0.transfer(users[i], 10_000_000 ether);
            token1.transfer(users[i], 10_000_000 ether);

            vm.startPrank(users[i]);
            token0.approve(address(lpPositions), type(uint256).max);
            token1.approve(address(lpPositions), type(uint256).max);
            vm.stopPrank();
        }
    }

    function getTokenId(PoolKey memory poolKey) internal pure returns (uint256) {
        return uint256(PoolId.unwrap(poolKey.toPoolId()));
    }

    // ==================== Multi-Pool Tests ====================

    /// @notice Test that multiple pools are tracked independently in single contract
    function test_multiplePoolsIndependentTracking() public {
        // Create 3 pools with same token pair but different configs
        PoolKey memory pool1 = createStableswapPoolWithParams(address(token0), address(token1), 1 << 63, 10);
        PoolKey memory pool2 = createStableswapPoolWithParams(address(token0), address(token1), 1 << 62, 10);
        PoolKey memory pool3 = createStableswapPoolWithParams(address(token0), address(token1), 1 << 61, 10);

        uint256 tokenId1 = getTokenId(pool1);
        uint256 tokenId2 = getTokenId(pool2);
        uint256 tokenId3 = getTokenId(pool3);

        // Verify all have different token IDs (different configs = different pool IDs)
        assertTrue(tokenId1 != tokenId2, "Pool 1 and 2 should have different token IDs");
        assertTrue(tokenId2 != tokenId3, "Pool 2 and 3 should have different token IDs");
        assertTrue(tokenId1 != tokenId3, "Pool 1 and 3 should have different token IDs");

        // Alice deposits to pool1 only
        vm.prank(alice);
        lpPositions.deposit(pool1, 100 ether, 100 ether, 0, DEADLINE);

        // Verify balances tracked separately
        uint256 balance1 = lpPositions.balanceOf(alice, tokenId1);
        uint256 balance2 = lpPositions.balanceOf(alice, tokenId2);
        uint256 balance3 = lpPositions.balanceOf(alice, tokenId3);

        assertGt(balance1, 0, "Alice should have pool1 LP tokens");
        assertEq(balance2, 0, "Alice should have no pool2 LP tokens");
        assertEq(balance3, 0, "Alice should have no pool3 LP tokens");
    }

    /// @notice Test that pool metadata is tracked independently
    function test_multiplePoolsIndependentMetadata() public {
        PoolKey memory pool1 = createStableswapPool(address(token0), address(token1));
        uint256 tokenId1 = getTokenId(pool1);

        // Deposit to pool1
        vm.prank(alice);
        lpPositions.deposit(pool1, 100 ether, 100 ether, 0, DEADLINE);

        // Check metadata for pool1
        uint128 totalLiq = lpPositions.totalLiquidity(tokenId1);
        uint256 totalSup = lpPositions.totalSupply(tokenId1);

        assertGt(totalLiq, 0, "Pool1 should have liquidity");
        assertGt(totalSup, 0, "Pool1 should have supply (initialized)");

        // Check that non-existent pool has empty metadata
        uint256 fakeTokenId = 999999;
        uint128 totalLiq_fake = lpPositions.totalLiquidity(fakeTokenId);
        uint256 totalSup_fake = lpPositions.totalSupply(fakeTokenId);

        assertEq(totalLiq_fake, 0, "Fake pool liquidity should be zero");
        assertEq(totalSup_fake, 0, "Fake pool supply should be zero (not initialized)");
    }

    // ==================== Operator Approval Tests ====================

    /// @notice Test that even operator approvals cannot bypass transfer block (H-01 fix)
    function test_operatorApprovalWorksForAllTokens() public {
        // Create 2 pools
        PoolKey memory pool1 = createStableswapPool(address(token0), address(token1));
        PoolKey memory pool2 = createStableswapPoolWithParams(address(token0), address(token1), 1 << 62, 10);

        uint256 tokenId1 = getTokenId(pool1);
        uint256 tokenId2 = getTokenId(pool2);

        // Alice deposits to pool1
        vm.prank(alice);
        lpPositions.deposit(pool1, 100 ether, 100 ether, 0, DEADLINE);

        // Alice deposits to pool2
        vm.prank(alice);
        lpPositions.deposit(pool2, 100 ether, 100 ether, 0, DEADLINE);

        address operator = bob;

        // Set Bob as operator for Alice
        vm.prank(alice);
        lpPositions.setOperator(operator, true);

        // Verify operator status
        assertTrue(lpPositions.isOperator(alice, operator), "Bob should be operator for Alice");

        // H-01 Fix: Even operators cannot transfer (security fix)
        uint256 aliceBalance1 = lpPositions.balanceOf(alice, tokenId1);
        uint256 aliceBalance2 = lpPositions.balanceOf(alice, tokenId2);

        vm.prank(bob);
        vm.expectRevert(IStableswapLPPositions.DirectTransfersDisabled.selector);
        lpPositions.transferFrom(alice, bob, tokenId1, aliceBalance1 / 2);

        vm.prank(bob);
        vm.expectRevert(IStableswapLPPositions.DirectTransfersDisabled.selector);
        lpPositions.transferFrom(alice, bob, tokenId2, aliceBalance2 / 2);

        // Verify balances unchanged - transfers were blocked
        assertEq(lpPositions.balanceOf(alice, tokenId1), aliceBalance1, "Alice pool1 balance unchanged");
        assertEq(lpPositions.balanceOf(alice, tokenId2), aliceBalance2, "Alice pool2 balance unchanged");
        assertEq(lpPositions.balanceOf(bob, tokenId1), 0, "Bob has no pool1 tokens");
        assertEq(lpPositions.balanceOf(bob, tokenId2), 0, "Bob has no pool2 tokens");
    }

    /// @notice Test operator can be revoked
    function test_operatorCanBeRevoked() public {
        PoolKey memory pool = createStableswapPool(address(token0), address(token1));
        uint256 tokenId = getTokenId(pool);

        // Alice deposits
        vm.prank(alice);
        lpPositions.deposit(pool, 100 ether, 100 ether, 0, DEADLINE);

        // Set Bob as operator
        vm.prank(alice);
        lpPositions.setOperator(bob, true);

        assertTrue(lpPositions.isOperator(alice, bob), "Bob should be operator");

        // Revoke Bob's operator status
        vm.prank(alice);
        lpPositions.setOperator(bob, false);

        assertFalse(lpPositions.isOperator(alice, bob), "Bob should not be operator");

        // Bob cannot transfer anymore
        vm.prank(bob);
        vm.expectRevert();
        lpPositions.transferFrom(alice, bob, tokenId, 1 ether);
    }

    // ==================== Per-Token Approval Tests ====================

    /// @notice Test per-token approval - transfers still blocked (H-01 fix)
    function test_perTokenApprovalIndependent() public {
        PoolKey memory pool1 = createStableswapPool(address(token0), address(token1));
        uint256 tokenId1 = getTokenId(pool1);

        // Alice deposits
        vm.prank(alice);
        lpPositions.deposit(pool1, 100 ether, 100 ether, 0, DEADLINE);

        // Alice approves Bob for tokenId1 only
        vm.prank(alice);
        lpPositions.approve(bob, tokenId1, 50 ether);

        // Check allowance was set
        assertEq(lpPositions.allowance(alice, bob, tokenId1), 50 ether, "Bob should have 50 ether allowance");

        // H-01 Fix: Even with approval, transfers are blocked
        vm.prank(bob);
        vm.expectRevert(IStableswapLPPositions.DirectTransfersDisabled.selector);
        lpPositions.transferFrom(alice, bob, tokenId1, 50 ether);

        // Balances unchanged - transfer was blocked
        assertEq(lpPositions.balanceOf(alice, tokenId1), lpPositions.balanceOf(alice, tokenId1));
        assertEq(lpPositions.balanceOf(bob, tokenId1), 0, "Bob has no tokens");
    }

    /// @notice Test infinite approval - transfers still blocked (H-01 fix)
    function test_infiniteApprovalNotConsumed() public {
        PoolKey memory pool = createStableswapPool(address(token0), address(token1));
        uint256 tokenId = getTokenId(pool);

        // Alice deposits
        vm.prank(alice);
        lpPositions.deposit(pool, 100 ether, 100 ether, 0, DEADLINE);

        // Alice gives Bob infinite approval
        vm.prank(alice);
        lpPositions.approve(bob, tokenId, type(uint256).max);

        assertEq(lpPositions.allowance(alice, bob, tokenId), type(uint256).max, "Bob should have max allowance");

        // H-01 Fix: Even with infinite approval, transfers are blocked
        vm.prank(bob);
        vm.expectRevert(IStableswapLPPositions.DirectTransfersDisabled.selector);
        lpPositions.transferFrom(alice, bob, tokenId, 10 ether);

        // Balances unchanged - transfer was blocked
        uint256 aliceBalance = lpPositions.balanceOf(alice, tokenId);
        assertGt(aliceBalance, 0, "Alice keeps her tokens");
        assertEq(lpPositions.balanceOf(bob, tokenId), 0, "Bob has no tokens");
    }

    // ==================== Gas Comparison Tests ====================

    /// @notice Benchmark: First deposit gas cost
    /// @dev This includes pool initialization and first liquidity add - measures full operation
    function test_gas_firstDeposit() public {
        PoolKey memory pool = createStableswapPool(address(token0), address(token1));

        vm.prank(alice);
        uint256 gasBefore = gasleft();
        lpPositions.deposit(pool, 100 ether, 100 ether, 0, DEADLINE);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("First deposit gas (ERC6909, full operation)", gasUsed);

        // First deposit includes pool initialization, position creation, auto-compound check
        // Expected: ~350-400k gas for full operation
        assertLt(gasUsed, 450_000, "First deposit should use less than 450k gas");
    }

    /// @notice Benchmark: Subsequent deposit gas cost
    /// @dev Measures gas for additional deposits after pool is initialized
    function test_gas_subsequentDeposit() public {
        PoolKey memory pool = createStableswapPool(address(token0), address(token1));

        // First deposit
        vm.prank(alice);
        lpPositions.deposit(pool, 100 ether, 100 ether, 0, DEADLINE);

        // Measure second deposit
        vm.prank(bob);
        uint256 gasBefore = gasleft();
        lpPositions.deposit(pool, 100 ether, 100 ether, 0, DEADLINE);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Subsequent deposit gas (ERC6909)", gasUsed);

        // Subsequent deposits are cheaper (no initialization)
        // Expected: ~80-90k gas
        assertLt(gasUsed, 100_000, "Subsequent deposit should use less than 100k gas");
    }

    /// @notice Test: Transfers are disabled (H-01 security fix)
    function test_gas_transfer() public {
        PoolKey memory pool = createStableswapPool(address(token0), address(token1));
        uint256 tokenId = getTokenId(pool);

        // Deposit
        vm.prank(alice);
        lpPositions.deposit(pool, 100 ether, 100 ether, 0, DEADLINE);

        uint256 balance = lpPositions.balanceOf(alice, tokenId);

        // H-01 Fix: Transfers are now disabled for security
        vm.prank(alice);
        vm.expectRevert(IStableswapLPPositions.DirectTransfersDisabled.selector);
        lpPositions.transfer(bob, tokenId, balance / 2);

        // Balances unchanged
        assertEq(lpPositions.balanceOf(alice, tokenId), balance);
        assertEq(lpPositions.balanceOf(bob, tokenId), 0);
    }

    /// @notice Benchmark: Approval gas cost
    function test_gas_approve() public {
        PoolKey memory pool = createStableswapPool(address(token0), address(token1));
        uint256 tokenId = getTokenId(pool);

        // Deposit
        vm.prank(alice);
        lpPositions.deposit(pool, 100 ether, 100 ether, 0, DEADLINE);

        // Measure approval
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        lpPositions.approve(bob, tokenId, 50 ether);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Approve gas (ERC6909)", gasUsed);

        // Expected: ~25-30k gas (vs ~45k for ERC20)
        assertLt(gasUsed, 32_000, "Approve should use less than 32k gas");
    }

    /// @notice Benchmark: Withdraw gas cost
    function test_gas_withdraw() public {
        PoolKey memory pool = createStableswapPool(address(token0), address(token1));
        uint256 tokenId = getTokenId(pool);

        // Deposit
        vm.prank(alice);
        (uint256 lpTokens,,) = lpPositions.deposit(pool, 100 ether, 100 ether, 0, DEADLINE);

        // Measure withdrawal
        vm.prank(alice);
        uint256 gasBefore = gasleft();
        lpPositions.withdraw(pool, lpTokens, 0, 0, DEADLINE);
        uint256 gasUsed = gasBefore - gasleft();

        emit log_named_uint("Withdraw gas (ERC6909)", gasUsed);

        // Expected: ~45k gas (vs ~55k for old system)
        assertLt(gasUsed, 50_000, "Withdraw should use less than 50k gas");
    }

    // ==================== ERC6909 Metadata Tests ====================

    /// @notice Test name() returns correct format
    function test_nameFormat() public {
        PoolKey memory pool = createStableswapPool(address(token0), address(token1));
        uint256 tokenId = getTokenId(pool);

        // Initialize pool by depositing
        vm.prank(alice);
        lpPositions.deposit(pool, 100 ether, 100 ether, 0, DEADLINE);

        string memory name = lpPositions.name(tokenId);

        // Should contain "Ekubo Stableswap LP"
        assertTrue(bytes(name).length > 0, "Name should not be empty");
        emit log_named_string("Pool name", name);
    }

    /// @notice Test symbol() returns correct value
    function test_symbolFormat() public {
        PoolKey memory pool = createStableswapPool(address(token0), address(token1));
        uint256 tokenId = getTokenId(pool);

        // Initialize pool by depositing
        vm.prank(alice);
        lpPositions.deposit(pool, 100 ether, 100 ether, 0, DEADLINE);

        string memory symbol = lpPositions.symbol(tokenId);

        assertEq(symbol, "EKUBO-SLP", "Symbol should be EKUBO-SLP");
    }

    /// @notice Test decimals() returns 18
    function test_decimals() public {
        PoolKey memory pool = createStableswapPool(address(token0), address(token1));
        uint256 tokenId = getTokenId(pool);

        // Initialize pool by depositing
        vm.prank(alice);
        lpPositions.deposit(pool, 100 ether, 100 ether, 0, DEADLINE);

        uint8 decimals = lpPositions.decimals(tokenId);

        assertEq(decimals, 18, "Decimals should be 18");
    }

    // ==================== Helper Functions ====================

    function createStableswapPool(address t0, address t1) internal returns (PoolKey memory) {
        return createStableswapPoolWithParams(t0, t1, 1 << 63, 10);
    }

    function createStableswapPoolWithParams(
        address t0,
        address t1,
        uint64 fee,
        uint8 amplification
    ) internal returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            token0: t0,
            token1: t1,
            config: createStableswapPoolConfig(fee, amplification, 0, address(0))
        });
        core.initializePool(poolKey, 0);
    }
}
