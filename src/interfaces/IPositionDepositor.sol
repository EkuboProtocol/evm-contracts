// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {PoolKey} from "../types/poolKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {IBaseNonfungibleToken} from "./IBaseNonfungibleToken.sol";

/// @notice Parameters for adding the maximum liquidity possible at an exact pool price.
struct PositionDeposit {
    /// @notice Pool receiving the liquidity.
    PoolKey poolKey;
    /// @notice Lower tick of the position range.
    int32 tickLower;
    /// @notice Upper tick of the position range.
    int32 tickUpper;
    /// @notice Maximum net amount of token0 the caller will pay across the price-setting swap and deposit.
    uint128 maxAmount0;
    /// @notice Maximum net amount of token1 the caller will pay across the price-setting swap and deposit.
    uint128 maxAmount1;
    /// @notice Minimum liquidity that must be added.
    uint128 minLiquidity;
    /// @notice Exact pool sqrt ratio at which liquidity must be added.
    SqrtRatio targetSqrtRatio;
    /// @notice Core forwardee used to rebalance the deposit. A nonzero address always runs; zero skips routing.
    /// @dev The forwardee must return ABI-encoded
    ///      `(address specifiedToken, address calculatedToken, int256 specifiedDelta, int256 calculatedDelta)`.
    ///      The deltas must be the endpoint debt changes its route leaves on the shared Core lock.
    ///      A price-limited route that consumes less than its specified maximum must return the amounts
    ///      actually swapped, including zero deltas when moving through empty liquidity.
    ///      The route always runs before liquidity is calculated and added. A swap can move through empty
    ///      liquidity to its limit without changing either token balance.
    address router;
    /// @notice Router-specific data forwarded through Core under the position manager's lock.
    bytes routerData;
}

/// @notice Shared interface for adding liquidity through a position NFT manager.
interface IPositionDepositor is IBaseNonfungibleToken {
    /// @notice Thrown when the maximum liquidity available is below the caller's minimum.
    error DepositLiquidityBelowMinimum(uint128 liquidity, uint128 minLiquidity);

    /// @notice Thrown when the available liquidity cannot fit in one Core position update.
    error DepositLiquidityOverflow(uint128 liquidity);

    /// @notice Thrown when adding liquidity would make a managed position exceed the Core update type.
    error PositionLiquidityOverflow(uint128 currentLiquidity, uint128 addedLiquidity);

    /// @notice Thrown when the target sqrt ratio is not a valid Core price.
    error InvalidTargetSqrtRatio(SqrtRatio targetSqrtRatio);

    /// @notice Thrown when the deposit does not leave the pool at the target price.
    error TargetSqrtRatioNotReached(SqrtRatio targetSqrtRatio, SqrtRatio actualSqrtRatio);

    /// @notice Thrown when the net price-setting swap and deposit amounts exceed a caller limit.
    error DepositExceedsMaxAmounts(int256 amount0, int256 amount1, uint128 maxAmount0, uint128 maxAmount1);

    /// @notice Thrown when route data is provided without a router.
    error RouterRequired();

    /// @notice Thrown when a router returns endpoint tokens other than the deposit pool pair.
    error InvalidRouteTokens(address specifiedToken, address calculatedToken, address token0, address token1);

    /// @notice Thrown when a routed output is too large to settle in one Core withdrawal.
    error RouteOutputOverflow(address token, int256 amount);

    /// @notice Routes when the router is nonzero, then adds the maximum liquidity allowed by the token limits.
    /// @dev Positive returned amounts are paid by the caller. Negative returned amounts are sent to the caller.
    function deposit(uint256 id, PositionDeposit calldata parameters)
        external
        payable
        returns (uint128 liquidity, int256 amount0, int256 amount1);

    /// @notice Initializes a pool if it has not been initialized yet.
    function maybeInitializePool(PoolKey calldata poolKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio);

    /// @notice Mints a new NFT, routes when the router is nonzero, and adds the maximum available liquidity.
    function mintAndDeposit(PositionDeposit calldata parameters)
        external
        payable
        returns (uint256 id, uint128 liquidity, int256 amount0, int256 amount1);

    /// @notice Mints a deterministic NFT, routes when the router is nonzero, and adds the maximum available liquidity.
    function mintAndDepositWithSalt(bytes32 salt, PositionDeposit calldata parameters)
        external
        payable
        returns (uint256 id, uint128 liquidity, int256 amount0, int256 amount1);
}
