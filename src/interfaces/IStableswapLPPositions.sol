// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";

/// @title IStableswapLPPositions Interface
/// @author Bogdan Sivochkin
/// @notice Interface for managing fungible LP positions for stableswap pools
interface IStableswapLPPositions {
    /// @notice Emitted when a new pool is initialized
    event PoolInitialized(uint256 indexed tokenId, address token0, address token1);

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

    /// @notice Error thrown when LP token doesn't exist for a pool
    error LPTokenDoesNotExist();

    /// @notice Thrown when LP token mint calculation results in zero tokens
    error InsufficientLiquidityMinted();

    /// @notice Error thrown when deposit fails due to slippage
    error DepositFailedDueToSlippage(uint128 actual, uint128 minimum);

    /// @notice Error thrown when withdrawal fails due to slippage
    error WithdrawFailedDueToSlippage(uint128 actual0, uint128 min0, uint128 actual1, uint128 min1);

    /// @notice Error thrown when transaction deadline has passed
    error DeadlineExpired();

    /// @notice Error thrown when attempting direct LP token transfers
    /// @dev Direct transfers bypass auto-compounding and are disabled for security
    error DirectTransfersDisabled();

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

    // ERC6909 Metadata functions (for wrapper compatibility)
    // Note: Standard ERC6909 functions (balanceOf, transfer, etc.) are inherited from ERC6909
    // and don't need to be redeclared in the interface

    /// @notice Returns the name for a specific pool's LP token
    /// @param id The token ID (poolId)
    function name(uint256 id) external view returns (string memory);

    /// @notice Returns the symbol for LP tokens
    /// @param id The token ID (poolId)
    function symbol(uint256 id) external view returns (string memory);

    /// @notice Returns the decimals for LP tokens
    /// @param id The token ID (poolId)
    function decimals(uint256 id) external view returns (uint8);

    /// @notice Returns the total supply of LP tokens for a pool
    /// @param id The token ID (poolId)
    function totalSupply(uint256 id) external view returns (uint256);

    /// @notice Gets the pool metadata
    /// @param id The token ID (poolId)
    function poolMetadata(uint256 id) external view returns (address token0, address token1, uint128 totalLiquidity, uint256 totalSupply, bool initialized);
}
