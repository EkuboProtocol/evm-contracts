// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {PoolKey} from "../types/poolKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {IBaseNonfungibleToken} from "./IBaseNonfungibleToken.sol";

/// @notice Shared interface for adding liquidity through a position NFT manager.
interface IPositionDepositor is IBaseNonfungibleToken {
    /// @notice Swaps the pool into the requested price range when necessary, then deposits liquidity.
    /// @param id The NFT token ID representing the position.
    /// @param poolKey Pool key identifying the pool.
    /// @param tickLower Lower tick of the position range.
    /// @param tickUpper Upper tick of the position range.
    /// @param maxAmount0 Maximum net amount of token0 to spend across the swap and deposit.
    /// @param maxAmount1 Maximum net amount of token1 to spend across the swap and deposit.
    /// @param minSqrtRatio Lower bound of the acceptable pool price range.
    /// @param maxSqrtRatio Upper bound of the acceptable pool price range.
    function deposit(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        SqrtRatio minSqrtRatio,
        SqrtRatio maxSqrtRatio
    ) external payable returns (uint128 liquidity, uint128 amount0, uint128 amount1);

    /// @notice Deposits within a price range and sends unused swap output to `swapRecipient`.
    function deposit(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        SqrtRatio minSqrtRatio,
        SqrtRatio maxSqrtRatio,
        address swapRecipient
    ) external payable returns (uint128 liquidity, uint128 amount0, uint128 amount1);

    /// @notice Initializes a pool if it has not been initialized yet.
    function maybeInitializePool(PoolKey memory poolKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio);

    /// @notice Mints a new NFT, swaps into the requested price range when necessary, and deposits liquidity.
    function mintAndDeposit(
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        SqrtRatio minSqrtRatio,
        SqrtRatio maxSqrtRatio
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1);

    /// @notice Mints a new NFT, deposits within a price range, and sends unused swap output to `swapRecipient`.
    function mintAndDeposit(
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        SqrtRatio minSqrtRatio,
        SqrtRatio maxSqrtRatio,
        address swapRecipient
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1);

    /// @notice Mints a deterministic NFT, swaps into the requested price range when necessary, and deposits liquidity.
    function mintAndDepositWithSalt(
        bytes32 salt,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        SqrtRatio minSqrtRatio,
        SqrtRatio maxSqrtRatio
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1);

    /// @notice Mints a deterministic NFT, deposits within a range, and sends unused swap output to `swapRecipient`.
    function mintAndDepositWithSalt(
        bytes32 salt,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        SqrtRatio minSqrtRatio,
        SqrtRatio maxSqrtRatio,
        address swapRecipient
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1);
}
