// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title LP Token Math Library
/// @notice Library for calculating LP token minting and burning amounts
/// @dev Implements Uniswap V2-style auto-compounding LP token math
/// @dev Separated from main contract for reusability and easier testing
library LPTokenMathLib {
    /// @notice Minimum liquidity burned on first deposit to prevent inflation attacks
    /// @dev Following Uniswap V2 pattern - first depositor loses 1000 wei worth of LP tokens
    uint256 internal constant MINIMUM_LIQUIDITY = 1000;

    /// @notice Error thrown when liquidity is insufficient for minimum requirement
    error InsufficientLiquidityForMinimum();

    /// @notice Error thrown when LP token mint calculation results in zero tokens
    error InsufficientLPTokensMinted();

    /// @notice Error thrown when burn amount exceeds total supply
    error BurnAmountExceedsTotalSupply();

    /// @notice Error thrown when liquidity removal would exceed total liquidity
    error LiquidityRemovalExceedsTotal();

    /// @notice Error thrown when total supply overflow would occur
    error TotalSupplyOverflow();

    /// @notice Error thrown when total liquidity overflow would occur
    error TotalLiquidityOverflow();

    /// @notice Calculates LP tokens to mint for a given liquidity addition
    /// @dev On first deposit (totalSupply == 0), burns MINIMUM_LIQUIDITY to prevent inflation attacks
    /// @dev On subsequent deposits, mints proportional to share of total liquidity
    /// @param totalSupply Current total supply of LP tokens
    /// @param totalLiquidity Current total liquidity in the position
    /// @param liquidityAdded Amount of liquidity being added
    /// @return lpTokensToMint Amount of LP tokens to mint to user
    /// @return lpTokensToBurn Amount of LP tokens to burn (only non-zero on first deposit)
    /// @return newTotalSupply New total supply after minting
    function calculateMint(
        uint256 totalSupply,
        uint128 totalLiquidity,
        uint128 liquidityAdded
    )
        internal
        pure
        returns (
            uint256 lpTokensToMint,
            uint256 lpTokensToBurn,
            uint256 newTotalSupply
        )
    {
        if (totalSupply == 0) {
            // First deposit - burn minimum liquidity for security
            // This prevents first-depositor inflation attacks where an attacker:
            // 1. Deposits 1 wei -> gets 1 LP token
            // 2. Donates huge amount directly to position
            // 3. Next depositor gets heavily diluted
            if (liquidityAdded < MINIMUM_LIQUIDITY) {
                revert InsufficientLiquidityForMinimum();
            }

            lpTokensToMint = uint256(liquidityAdded) - MINIMUM_LIQUIDITY;
            lpTokensToBurn = MINIMUM_LIQUIDITY;
            newTotalSupply = uint256(liquidityAdded);
        } else {
            // Subsequent deposits - mint proportional to share of total liquidity
            // Formula: lpToMint = (liquidityAdded * totalSupply) / totalLiquidity
            // Use FixedPointMathLib.fullMulDiv to prevent overflow when totalSupply is very large
            lpTokensToMint = FixedPointMathLib.fullMulDiv(
                uint256(liquidityAdded),
                totalSupply,
                uint256(totalLiquidity)
            );

            if (lpTokensToMint == 0) {
                revert InsufficientLPTokensMinted();
            }

            // Check for overflow before updating totalSupply
            newTotalSupply = totalSupply + lpTokensToMint;
            if (newTotalSupply < totalSupply) {
                revert TotalSupplyOverflow();
            }

            lpTokensToBurn = 0; // No burn on subsequent deposits
        }
    }

    /// @notice Calculates liquidity to remove for a given LP token burn
    /// @dev Uses proportional calculation: liquidityToRemove = (lpTokensBurned * totalLiquidity) / totalSupply
    /// @param totalSupply Current total supply of LP tokens
    /// @param totalLiquidity Current total liquidity in the position
    /// @param lpTokensToBurn Amount of LP tokens being burned
    /// @return liquidityToRemove Amount of liquidity to remove from position
    /// @return newTotalSupply New total supply after burning
    function calculateBurn(
        uint256 totalSupply,
        uint128 totalLiquidity,
        uint256 lpTokensToBurn
    )
        internal
        pure
        returns (
            uint128 liquidityToRemove,
            uint256 newTotalSupply
        )
    {
        // Validate burn amount doesn't exceed total supply
        if (lpTokensToBurn > totalSupply) {
            revert BurnAmountExceedsTotalSupply();
        }

        // Calculate proportional liquidity to remove
        // Formula: liquidityToRemove = (lpTokensBurned * totalLiquidity) / totalSupply
        liquidityToRemove = uint128((lpTokensToBurn * uint256(totalLiquidity)) / totalSupply);

        // Validate liquidityToRemove doesn't exceed totalLiquidity
        if (liquidityToRemove > totalLiquidity) {
            revert LiquidityRemovalExceedsTotal();
        }

        // Calculate new total supply (underflow protected by Solidity 0.8+)
        newTotalSupply = totalSupply - lpTokensToBurn;
    }

    /// @notice Validates and updates total liquidity after adding liquidity
    /// @param currentTotalLiquidity Current total liquidity
    /// @param liquidityAdded Amount of liquidity being added
    /// @return newTotalLiquidity New total liquidity after addition
    function addLiquidity(
        uint128 currentTotalLiquidity,
        uint128 liquidityAdded
    ) internal pure returns (uint128 newTotalLiquidity) {
        newTotalLiquidity = currentTotalLiquidity + liquidityAdded;
        
        // Check for overflow
        if (newTotalLiquidity < currentTotalLiquidity) {
            revert TotalLiquidityOverflow();
        }
    }

    /// @notice Validates and updates total liquidity after removing liquidity
    /// @param currentTotalLiquidity Current total liquidity
    /// @param liquidityToRemove Amount of liquidity being removed
    /// @return newTotalLiquidity New total liquidity after removal
    function removeLiquidity(
        uint128 currentTotalLiquidity,
        uint128 liquidityToRemove
    ) internal pure returns (uint128 newTotalLiquidity) {
        // Underflow protected by Solidity 0.8+
        newTotalLiquidity = currentTotalLiquidity - liquidityToRemove;
    }
}
