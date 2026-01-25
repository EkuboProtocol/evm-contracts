// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {StableswapLPToken} from "../src/StableswapLPToken.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolConfig, createStableswapPoolConfig} from "../src/types/poolConfig.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @title StableswapLPToken Overflow Test
/// @notice Tests for C-01: Integer Overflow in LP Token Mint
/// @dev Demonstrates overflow vulnerability when totalSupply is very large
contract StableswapLPTokenOverflowTest is Test {
    StableswapLPToken public lpToken;
    StableswapLPToken public implementation;
    address public positionsContract;
    address public user1;
    address public user2;

    PoolKey public poolKey;

    function setUp() public {
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        positionsContract = address(this);

        // Deploy LP token implementation
        implementation = new StableswapLPToken(positionsContract);

        // Initialize with dummy pool key - proper 3 field struct
        address token0Addr = address(0x1);
        address token1Addr = address(0x2);

        poolKey = PoolKey({
            token0: token0Addr,
            token1: token1Addr,
            config: createStableswapPoolConfig(0, 10, 0, address(0))
        });

        // Create a clone and initialize it
        lpToken = StableswapLPToken(payable(LibClone.clone(address(implementation))));
        lpToken.initialize(poolKey);
    }

    /// @notice Test for C-01: Integer Overflow in LP Token Mint - Normal Case
    /// @dev This test verifies that the fix correctly handles large values without overflow
    function testFix_C01_IntegerOverflowInMint() public {
        // Step 1: Setup initial state with large total supply
        uint128 initialLiquidity = 1000000 * 1e18; // Reasonable initial amount
        lpToken.mint(user1, initialLiquidity);

        uint256 initialTotalSupply = lpToken.totalSupply();
        uint128 initialTotalLiquidity = lpToken.totalLiquidity();

        // Step 2: Mint additional liquidity
        uint128 additionalLiquidity = 500000 * 1e18;
        lpToken.mint(user1, additionalLiquidity);

        // Step 3: Compound fees to increase totalLiquidity
        uint128 compoundedFees = 100000 * 1e18;
        lpToken.incrementTotalLiquidity(compoundedFees);

        uint256 currentTotalSupply = lpToken.totalSupply();
        uint128 currentTotalLiquidity = lpToken.totalLiquidity();

        // Step 4: Attempt mint with reasonable liquidityAdded
        uint128 newLiquidityAdded = 10000 * 1e18;

        // Calculate expected result using the same safe math the contract now uses
        uint256 expectedLpTokens = (uint256(newLiquidityAdded) * currentTotalSupply) / uint256(currentTotalLiquidity);

        // Step 5: Execute mint and verify it doesn't overflow
        uint256 lpTokensMinted = lpToken.mint(user2, newLiquidityAdded);

        // Step 6: Assert expected safe behavior
        assertGt(lpTokensMinted, 0, "LP tokens should be minted");
        assertEq(lpTokensMinted, expectedLpTokens, "LP tokens minted should match expected calculation");

        // Verify state is consistent
        assertEq(lpToken.totalLiquidity(), currentTotalLiquidity + newLiquidityAdded, "Total liquidity should increase");
        assertEq(lpToken.balanceOf(user2), lpTokensMinted, "User2 should receive minted LP tokens");
    }

    /// @notice Test that zero-mint protection works correctly
    /// @dev When liquidityAdded is so small relative to totalSupply that it would mint 0 tokens, it should revert
    function testFix_C01_ZeroMintProtection() public {
        // Create a scenario where totalSupply is extremely large relative to totalLiquidity
        uint128 firstDeposit = type(uint128).max / 4;
        lpToken.mint(user1, firstDeposit);

        // Compound massive fees - creates huge ratio
        uint128 massiveFees = type(uint128).max / 2;
        lpToken.incrementTotalLiquidity(massiveFees);

        uint256 totalSupplyBefore = lpToken.totalSupply();
        uint128 totalLiquidityBefore = lpToken.totalLiquidity();

        // Attempt to mint with very small liquidityAdded that would result in 0 LP tokens
        // The calculation: (liquidityAdded * totalSupply) / totalLiquidity would truncate to 0
        uint128 tinyLiquidityAdded = 1; // 1 wei

        // This should revert with InsufficientLiquidityMinted
        vm.expectRevert(StableswapLPToken.InsufficientLiquidityMinted.selector);
        lpToken.mint(user2, tinyLiquidityAdded);
    }

    /// @notice Test overflow protection with large values
    /// @dev Verifies that fullMulDiv prevents overflow even with maximum values
    function testFix_C01_OverflowProtection() public {
        // Setup with large but valid values
        uint128 firstDeposit = type(uint128).max / 8;
        lpToken.mint(user1, firstDeposit);

        uint128 secondDeposit = type(uint128).max / 8;
        lpToken.mint(user1, secondDeposit);

        // Compound fees
        uint128 fees = type(uint128).max / 8;
        lpToken.incrementTotalLiquidity(fees);

        uint256 totalSupplyBefore = lpToken.totalSupply();
        uint128 totalLiquidityBefore = lpToken.totalLiquidity();

        // Add significant liquidity - this would overflow with standard multiplication
        // if totalSupply were even larger
        uint128 newLiquidity = type(uint128).max / 8;

        // This should succeed without overflow thanks to fullMulDiv
        uint256 lpTokensMinted = lpToken.mint(user2, newLiquidity);

        // Verify the mint succeeded and returned non-zero tokens
        assertGt(lpTokensMinted, 0, "Should mint non-zero tokens");
        assertEq(lpToken.totalLiquidity(), totalLiquidityBefore + newLiquidity, "Total liquidity should be consistent");

        // Verify the calculation matches expected value
        uint256 expectedTokens = (uint256(newLiquidity) * totalSupplyBefore) / uint256(totalLiquidityBefore);
        assertEq(lpTokensMinted, expectedTokens, "Minted tokens should match expected calculation");
    }

    /// @notice Fuzz test for overflow protection with valid inputs
    /// @dev Tests various combinations that should succeed
    function testFix_C01_FuzzOverflowProtection(
        uint128 firstLiquidity,
        uint128 secondLiquidity,
        uint128 compoundedFees,
        uint128 newLiquidity
    ) public {
        // Bound inputs to reasonable values that should result in successful mints
        firstLiquidity = uint128(bound(firstLiquidity, 1e18, type(uint128).max / 8));
        secondLiquidity = uint128(bound(secondLiquidity, 1e18, type(uint128).max / 8));
        compoundedFees = uint128(bound(compoundedFees, 0, type(uint128).max / 8));
        newLiquidity = uint128(bound(newLiquidity, 1e18, type(uint128).max / 8));

        // Setup state
        lpToken.mint(user1, firstLiquidity);
        if (secondLiquidity > 0) {
            lpToken.mint(user1, secondLiquidity);
        }
        if (compoundedFees > 0) {
            lpToken.incrementTotalLiquidity(compoundedFees);
        }

        uint128 currentTotalLiquidity = lpToken.totalLiquidity();

        // Ensure we don't overflow totalLiquidity itself
        if (newLiquidity > type(uint128).max - currentTotalLiquidity) {
            newLiquidity = type(uint128).max - currentTotalLiquidity;
        }

        vm.assume(newLiquidity > 0);

        uint256 totalSupplyBefore = lpToken.totalSupply();
        uint128 totalLiquidityBefore = lpToken.totalLiquidity();

        // Calculate expected result - if it would be 0, skip this test case
        uint256 expectedTokens = (uint256(newLiquidity) * totalSupplyBefore) / uint256(totalLiquidityBefore);
        vm.assume(expectedTokens > 0);

        // This should succeed without overflow
        uint256 lpTokensMinted = lpToken.mint(user2, newLiquidity);

        // Verify consistency
        assertGt(lpTokensMinted, 0, "Should always mint non-zero tokens for non-zero liquidity");
        assertEq(lpToken.totalLiquidity(), totalLiquidityBefore + newLiquidity, "Total liquidity must be consistent");
        assertEq(lpTokensMinted, expectedTokens, "Minted tokens should match expected calculation");
    }

    /// @notice Fuzz test for zero-mint scenarios
    /// @dev Tests that small deposits revert when they would mint 0 tokens
    function testFix_C01_FuzzZeroMintReverts(
        uint128 largeLiquidity,
        uint128 massiveFees,
        uint128 tinyNewLiquidity
    ) public {
        // Create scenario with very large totalSupply relative to totalLiquidity
        largeLiquidity = uint128(bound(largeLiquidity, type(uint128).max / 8, type(uint128).max / 4));
        tinyNewLiquidity = uint128(bound(tinyNewLiquidity, 1, 1000));

        lpToken.mint(user1, largeLiquidity);

        uint128 currentLiquidity = lpToken.totalLiquidity();

        // Bound massiveFees to ensure we don't overflow when added to current liquidity
        massiveFees = uint128(bound(massiveFees, 0, type(uint128).max - currentLiquidity - 1000));

        // Skip if massiveFees is too small to create the desired effect
        vm.assume(massiveFees > type(uint128).max / 8);

        lpToken.incrementTotalLiquidity(massiveFees);

        uint256 totalSupply = lpToken.totalSupply();
        uint128 totalLiquidity = lpToken.totalLiquidity();

        // Calculate what the result would be
        uint256 wouldMint = (uint256(tinyNewLiquidity) * totalSupply) / uint256(totalLiquidity);

        // If it would mint 0, it should revert
        if (wouldMint == 0) {
            vm.expectRevert(StableswapLPToken.InsufficientLiquidityMinted.selector);
            lpToken.mint(user2, tinyNewLiquidity);
        } else {
            // Otherwise it should succeed
            uint256 minted = lpToken.mint(user2, tinyNewLiquidity);
            assertEq(minted, wouldMint, "Should mint expected amount");
        }
    }
}
