// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {PoolKey} from "../types/poolKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {IBaseNonfungibleToken} from "./IBaseNonfungibleToken.sol";

/// @title Positions Interface
/// @notice Interface for managing liquidity positions as NFTs in Ekubo Protocol
/// @dev Defines the interface for depositing, withdrawing, and collecting fees from liquidity positions
interface IPositions is IBaseNonfungibleToken {
    /// @notice Thrown when deposit fails due to insufficient liquidity for the given slippage tolerance
    /// @param liquidity The actual liquidity that would be provided
    /// @param minLiquidity The minimum liquidity required
    error DepositFailedDueToSlippage(uint128 liquidity, uint128 minLiquidity);

    /// @notice Thrown when deposit amount would cause overflow
    error DepositOverflow();

    /// @notice Thrown when the specified withdraw liquidity amount overflows type(int128).max
    error WithdrawOverflow();

    /// @notice Gets the liquidity, principal amounts, and accumulated fees for a position
    /// @param id The NFT token ID representing the position
    /// @param poolKey Pool key identifying the pool
    /// @param tickLower Lower tick of the price range of the position
    /// @param tickUpper Upper tick of the price range of the position
    /// @return liquidity Current liquidity in the position
    /// @return principal0 Principal amount of token0 in the position
    /// @return principal1 Principal amount of token1 in the position
    /// @return fees0 Accumulated fees in token0
    /// @return fees1 Accumulated fees in token1
    function getPositionFeesAndLiquidity(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        external
        view
        returns (uint128 liquidity, uint128 principal0, uint128 principal1, uint128 fees0, uint128 fees1);

    /// @notice Deposits tokens into a liquidity position
    /// @param id The NFT token ID representing the position
    /// @param poolKey Pool key identifying the pool
    /// @param tickLower Lower tick of the price range of the position
    /// @param tickUpper Upper tick of the price range of the position
    /// @param maxAmount0 Maximum amount of token0 to deposit
    /// @param maxAmount1 Maximum amount of token1 to deposit
    /// @param minLiquidity Minimum liquidity to receive (for slippage protection)
    /// @return liquidity Amount of liquidity added to the position
    /// @return amount0 Actual amount of token0 deposited
    /// @return amount1 Actual amount of token1 deposited
    function deposit(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) external payable returns (uint128 liquidity, uint128 amount0, uint128 amount1);

    /// @notice Collects accumulated fees from a position to msg.sender
    /// @param id The NFT token ID representing the position
    /// @param poolKey Pool key identifying the pool
    /// @param tickLower Lower tick of the price range of the position
    /// @param tickUpper Upper tick of the price range of the position
    /// @return amount0 Amount of token0 fees collected
    /// @return amount1 Amount of token1 fees collected
    function collectFees(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        external
        payable
        returns (uint128 amount0, uint128 amount1);

    /// @notice Collects accumulated fees from a position to a specified recipient
    /// @param id The NFT token ID representing the position
    /// @param poolKey Pool key identifying the pool
    /// @param tickLower Lower tick of the price range of the position
    /// @param tickUpper Upper tick of the price range of the position
    /// @param recipient Address to receive the collected fees
    /// @return amount0 Amount of token0 fees collected
    /// @return amount1 Amount of token1 fees collected
    function collectFees(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper, address recipient)
        external
        payable
        returns (uint128 amount0, uint128 amount1);

    /// @notice Withdraws liquidity from a position
    /// @param id The NFT token ID representing the position
    /// @param poolKey Pool key identifying the pool
    /// @param tickLower Lower tick of the price range of the position
    /// @param tickUpper Upper tick of the price range of the position
    /// @param liquidity Amount of liquidity to withdraw
    /// @param recipient Address to receive the withdrawn tokens
    /// @param withFees Whether to also collect accumulated fees
    /// @return amount0 Amount of token0 withdrawn
    /// @return amount1 Amount of token1 withdrawn
    function withdraw(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 liquidity,
        address recipient,
        bool withFees
    ) external payable returns (uint128 amount0, uint128 amount1);

    /// @notice Withdraws liquidity from a position to msg.sender with fees
    /// @param id The NFT token ID representing the position
    /// @param poolKey Pool key identifying the pool
    /// @param tickLower Lower tick of the price range of the position
    /// @param tickUpper Upper tick of the price range of the position
    /// @param liquidity Amount of liquidity to withdraw
    /// @return amount0 Amount of token0 withdrawn
    /// @return amount1 Amount of token1 withdrawn
    function withdraw(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper, uint128 liquidity)
        external
        payable
        returns (uint128 amount0, uint128 amount1);

    /// @notice Initializes a pool if it hasn't been initialized yet
    /// @param poolKey Pool key identifying the pool
    /// @param tick Initial tick for the pool if initialization is needed
    /// @return initialized Whether the pool was initialized by this call
    /// @return sqrtRatio The sqrt price ratio of the pool (existing or newly set)
    function maybeInitializePool(PoolKey memory poolKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio);

    /// @notice Mints a new NFT and deposits liquidity into it
    /// @param poolKey Pool key identifying the pool
    /// @param tickLower Lower tick of the price range of the position
    /// @param tickUpper Upper tick of the price range of the position
    /// @param maxAmount0 Maximum amount of token0 to deposit
    /// @param maxAmount1 Maximum amount of token1 to deposit
    /// @param minLiquidity Minimum liquidity to receive (for slippage protection)
    /// @return id The newly minted NFT token ID
    /// @return liquidity Amount of liquidity added to the position
    /// @return amount0 Actual amount of token0 deposited
    /// @return amount1 Actual amount of token1 deposited
    function mintAndDeposit(
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1);

    /// @notice Mints a new NFT with a specific salt and deposits liquidity into it
    /// @param salt Salt for deterministic NFT ID generation
    /// @param poolKey Pool key identifying the pool
    /// @param tickLower Lower tick of the price range of the position
    /// @param tickUpper Upper tick of the price range of the position
    /// @param maxAmount0 Maximum amount of token0 to deposit
    /// @param maxAmount1 Maximum amount of token1 to deposit
    /// @param minLiquidity Minimum liquidity to receive (for slippage protection)
    /// @return id The newly minted NFT token ID
    /// @return liquidity Amount of liquidity added to the position
    /// @return amount0 Actual amount of token0 deposited
    /// @return amount1 Actual amount of token1 deposited
    function mintAndDepositWithSalt(
        bytes32 salt,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1);

    /// @notice Withdraws accumulated protocol fees (only callable by owner)
    /// @param token0 Address of token0
    /// @param token1 Address of token1
    /// @param amount0 Amount of token0 fees to withdraw
    /// @param amount1 Amount of token1 fees to withdraw
    /// @param recipient Address to receive the protocol fees
    function withdrawProtocolFees(address token0, address token1, uint128 amount0, uint128 amount1, address recipient)
        external
        payable;

    /// @notice Gets the accumulated protocol fees for a token pair
    /// @param token0 Address of token0
    /// @param token1 Address of token1
    /// @return amount0 Amount of token0 protocol fees
    /// @return amount1 Amount of token1 protocol fees
    function getProtocolFees(address token0, address token1) external view returns (uint128 amount0, uint128 amount1);
}
