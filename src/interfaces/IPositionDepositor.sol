// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {PoolKey} from "../types/poolKey.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {IBaseNonfungibleToken} from "./IBaseNonfungibleToken.sol";

/// @notice Parameters for adding an exact amount of liquidity at an exact pool price.
struct PositionDeposit {
    /// @notice Pool receiving the liquidity.
    PoolKey poolKey;
    /// @notice Lower tick of the position range.
    int32 tickLower;
    /// @notice Upper tick of the position range.
    int32 tickUpper;
    /// @notice Exact amount of liquidity to add.
    uint128 liquidity;
    /// @notice Exact final pool sqrt ratio after the liquidity update and optional route.
    SqrtRatio targetSqrtRatio;
    /// @notice Maximum net amount of token0 the caller will pay across the price-setting swap and deposit.
    uint128 maxAmount0;
    /// @notice Maximum net amount of token1 the caller will pay across the price-setting swap and deposit.
    uint128 maxAmount1;
    /// @notice Optional Core forwardee used to rebalance the deposit. Zero skips routing.
    /// @dev The forwardee must return ABI-encoded
    ///      `(address specifiedToken, address calculatedToken, int256 specifiedDelta, int256 calculatedDelta)`.
    ///      The deltas must be the endpoint debt changes its route leaves on the shared Core lock.
    ///      The route runs before the deposit unless the pool has no active liquidity, in which case the deposit
    ///      runs first so the route can move the pool.
    address router;
    /// @notice Router-specific data forwarded through Core under the position manager's lock.
    bytes routerData;
}

/// @notice Shared interface for adding liquidity through a position NFT manager.
interface IPositionDepositor is IBaseNonfungibleToken {
    /// @notice Thrown when deposit liquidity is zero or cannot fit in the Core position update type.
    error InvalidDepositLiquidity(uint128 liquidity);

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

    /// @notice Adds exactly the requested liquidity and optionally routes around the update.
    /// @dev Positive returned amounts are paid by the caller. Negative returned amounts are sent to the caller.
    function deposit(uint256 id, PositionDeposit calldata parameters)
        external
        payable
        returns (int256 amount0, int256 amount1);

    /// @notice Initializes a pool if it has not been initialized yet.
    function maybeInitializePool(PoolKey calldata poolKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio);

    /// @notice Mints a new NFT, adds exactly the requested liquidity, and optionally routes around the update.
    function mintAndDeposit(PositionDeposit calldata parameters)
        external
        payable
        returns (uint256 id, int256 amount0, int256 amount1);

    /// @notice Mints a deterministic NFT, adds exactly the requested liquidity, and optionally routes around the update.
    function mintAndDepositWithSalt(bytes32 salt, PositionDeposit calldata parameters)
        external
        payable
        returns (uint256 id, int256 amount0, int256 amount1);
}
