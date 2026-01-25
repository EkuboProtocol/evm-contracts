// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";

/// @title IStableswapLPPositions Interface
/// @author Bogdan Sivochkin
/// @notice Interface for managing fungible LP positions for stableswap pools
interface IStableswapLPPositions {
    /// @notice Emitted when a new LP token is created for a pool
    event LPTokenCreated(PoolKey poolKey, address lpToken);

    /// @notice Emitted when fees are auto-compounded into a position
    event FeesCompounded(PoolKey poolKey, uint128 fees0, uint128 fees1, uint128 liquidityAdded);

    /// @notice Emitted when a user deposits liquidity
    event Deposit(
        address indexed user,
        PoolId indexed poolId,
        uint256 lpTokensMinted,
        uint128 amount0,
        uint128 amount1
    );

    /// @notice Emitted when a user withdraws liquidity
    event Withdraw(
        address indexed user,
        PoolId indexed poolId,
        uint256 lpTokensBurned,
        uint128 amount0,
        uint128 amount1
    );

    /// @notice Error thrown when LP token already exists for a pool
    error LPTokenAlreadyExists();

    /// @notice Error thrown when LP token doesn't exist for a pool
    error LPTokenDoesNotExist();

    /// @notice Error thrown when deposit fails due to slippage
    error DepositFailedDueToSlippage(uint128 actual, uint128 minimum);

    /// @notice Error thrown when withdrawal fails due to slippage
    error WithdrawFailedDueToSlippage(uint128 actual0, uint128 min0, uint128 actual1, uint128 min1);

    /// @notice Error thrown when transaction deadline has passed
    error DeadlineExpired();

    /// @notice Creates a new LP token for a stableswap pool
    /// @param poolKey The pool key to create an LP token for
    /// @return lpToken The address of the created LP token
    function createLPToken(PoolKey memory poolKey) external returns (address lpToken);

    /// @notice Deposits tokens and receives LP tokens
    /// @param poolKey The pool to deposit into
    /// @param maxAmount0 Maximum amount of token0 to deposit
    /// @param maxAmount1 Maximum amount of token1 to deposit
    /// @param minLiquidity Minimum liquidity required (slippage protection)
    /// @param deadline Transaction deadline timestamp
    /// @return lpTokensMinted The amount of LP tokens minted
    /// @return amount0 The actual amount of token0 deposited
    /// @return amount1 The actual amount of token1 deposited
    function deposit(
        PoolKey memory poolKey,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity,
        uint256 deadline
    ) external payable returns (uint256 lpTokensMinted, uint128 amount0, uint128 amount1);

    /// @notice Withdraws liquidity by burning LP tokens
    /// @param poolKey The pool to withdraw from
    /// @param lpTokensToWithdraw The amount of LP tokens to burn
    /// @param minAmount0 Minimum amount of token0 to receive (slippage protection)
    /// @param minAmount1 Minimum amount of token1 to receive (slippage protection)
    /// @param deadline Transaction deadline timestamp
    /// @return amount0 The amount of token0 withdrawn
    /// @return amount1 The amount of token1 withdrawn
    function withdraw(
        PoolKey memory poolKey,
        uint256 lpTokensToWithdraw,
        uint128 minAmount0,
        uint128 minAmount1,
        uint256 deadline
    ) external returns (uint128 amount0, uint128 amount1);

    /// @notice Withdraws protocol fees (owner only)
    /// @param token0 The first token
    /// @param token1 The second token
    /// @param amount0 Amount of token0 to withdraw
    /// @param amount1 Amount of token1 to withdraw
    /// @param recipient The recipient of the fees
    function withdrawProtocolFees(
        address token0,
        address token1,
        uint128 amount0,
        uint128 amount1,
        address recipient
    ) external;

    /// @notice Gets the accumulated protocol fees
    /// @param token0 The first token
    /// @param token1 The second token
    /// @return amount0 Amount of token0 fees
    /// @return amount1 Amount of token1 fees
    function getProtocolFees(address token0, address token1) external view returns (uint128 amount0, uint128 amount1);

    /// @notice Gets the LP token address for a pool (deterministically computed)
    /// @dev Address is computed via CREATE2, no storage lookup needed
    /// @param poolKey The pool key
    /// @return lpToken The LP token address (may not be deployed yet)
    function getLPToken(PoolKey memory poolKey) external view returns (address lpToken);

    /// @notice Checks if an LP token exists for a pool
    /// @param poolKey The pool key
    /// @return exists True if LP token has been created
    function lpTokenExists(PoolKey memory poolKey) external view returns (bool exists);
}
