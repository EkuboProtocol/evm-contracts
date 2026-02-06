// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {PoolAllocation} from "../types/vaultTypes.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";

/// @title IBaseVault
/// @notice Interface for automated liquidity management vaults
/// @dev Users deposit a single token, receive ERC20 shares, and the vault manages
///      liquidity allocation according to strategy-defined targets
interface IBaseVault {
    /// @notice Emitted when a user deposits tokens into the vault
    /// @param user The address of the depositor
    /// @param epoch The epoch in which the deposit was made
    /// @param amount The amount of tokens deposited
    event Deposited(address indexed user, uint256 indexed epoch, uint256 amount);

    /// @notice Emitted when a user queues a withdrawal
    /// @param user The address of the withdrawer
    /// @param epoch The epoch in which the withdrawal was queued
    /// @param shares The number of shares queued for withdrawal
    event WithdrawalQueued(address indexed user, uint256 indexed epoch, uint256 shares);

    /// @notice Emitted when a user claims their shares from a processed epoch
    /// @param user The address claiming shares
    /// @param epoch The epoch from which shares are claimed
    /// @param shares The number of shares minted
    event SharesClaimed(address indexed user, uint256 indexed epoch, uint256 shares);

    /// @notice Emitted when a user claims their withdrawal tokens from a processed epoch
    /// @param user The address claiming tokens
    /// @param epoch The epoch from which tokens are claimed
    /// @param amount The amount of tokens claimed
    event WithdrawalClaimed(address indexed user, uint256 indexed epoch, uint256 amount);

    /// @notice Emitted when an epoch is processed
    /// @param epoch The epoch that was processed
    /// @param totalNAV The total net asset value at processing
    /// @param shareRate Shares per deposit token (scaled by 1e18)
    /// @param withdrawRate Tokens per share (scaled by 1e18)
    event EpochProcessed(uint256 indexed epoch, uint256 totalNAV, uint256 shareRate, uint256 withdrawRate);

    /// @notice Emitted when liquidity is deployed to a pool
    /// @param poolId The pool identifier
    /// @param liquidity The amount of liquidity deployed
    event LiquidityDeployed(PoolId indexed poolId, uint128 liquidity);

    /// @notice Emitted when liquidity is withdrawn from a pool
    /// @param poolId The pool identifier
    /// @param liquidity The amount of liquidity withdrawn
    event LiquidityWithdrawn(PoolId indexed poolId, uint128 liquidity);

    /// @notice Thrown when epoch processing is attempted before minimum duration has passed
    error EpochNotReady();

    /// @notice Thrown when deposit amount is zero
    error ZeroDeposit();

    /// @notice Thrown when withdrawal shares is zero
    error ZeroWithdrawal();

    /// @notice Thrown when claiming from an unprocessed epoch
    error EpochNotProcessed();

    /// @notice Thrown when user has no deposit in the specified epoch
    error NoDepositInEpoch();

    /// @notice Thrown when user has no withdrawal in the specified epoch
    error NoWithdrawalInEpoch();

    /// @notice Thrown when target allocations don't sum to 10000 bps
    error InvalidTargetAllocations();

    /// @notice Thrown when slippage exceeds acceptable bounds during rebalancing
    error RebalanceSlippageExceeded();

    /// @notice Queue a deposit for the current epoch
    /// @param amount The amount of deposit tokens to deposit
    function deposit(uint256 amount) external;

    /// @notice Queue a withdrawal for the current epoch
    /// @param shares The number of vault shares to withdraw
    function withdraw(uint256 shares) external;

    /// @notice Claim shares from a processed epoch deposit
    /// @param epoch The epoch to claim from
    /// @return shares The number of shares minted
    function claimShares(uint256 epoch) external returns (uint256 shares);

    /// @notice Claim tokens from a processed epoch withdrawal
    /// @param epoch The epoch to claim from
    /// @return amount The amount of tokens received
    function claimWithdrawal(uint256 epoch) external returns (uint256 amount);

    /// @notice Batch claim shares and/or withdrawals from multiple epochs
    /// @param depositEpochs Epochs to claim deposit shares from
    /// @param withdrawalEpochs Epochs to claim withdrawal tokens from
    function batchClaim(uint256[] calldata depositEpochs, uint256[] calldata withdrawalEpochs) external;

    /// @notice Process the current epoch and start a new one
    /// @dev Can be called by anyone after MIN_EPOCH_DURATION has passed
    function processEpoch() external;

    /// @notice Returns the deposit token address
    function DEPOSIT_TOKEN() external view returns (address);

    /// @notice Returns the minimum epoch duration in seconds
    function MIN_EPOCH_DURATION() external view returns (uint256);

    /// @notice Returns the current epoch number
    function currentEpoch() external view returns (uint256);

    /// @notice Returns the start time of the current epoch
    function epochStartTime() external view returns (uint256);

    /// @notice Returns the total pending deposits for the current epoch
    function pendingDeposits() external view returns (uint256);

    /// @notice Returns the total pending withdrawal shares for the current epoch
    function pendingWithdrawShares() external view returns (uint256);

    /// @notice Returns a user's deposit amount for a specific epoch
    /// @param epoch The epoch to query
    /// @param user The user address
    function userEpochDeposits(uint256 epoch, address user) external view returns (uint256);

    /// @notice Returns a user's withdrawal shares for a specific epoch
    /// @param epoch The epoch to query
    /// @param user The user address
    function userEpochWithdrawals(uint256 epoch, address user) external view returns (uint256);

    /// @notice Returns the share rate for a processed epoch
    /// @param epoch The epoch to query
    function epochShareRate(uint256 epoch) external view returns (uint256);

    /// @notice Returns the withdrawal rate for a processed epoch
    /// @param epoch The epoch to query
    function epochWithdrawRate(uint256 epoch) external view returns (uint256);

    /// @notice Returns whether an epoch has been processed
    /// @param epoch The epoch to query
    function epochProcessed(uint256 epoch) external view returns (bool);

    /// @notice Returns the liquidity deployed in a specific pool
    /// @param poolId The pool identifier
    function poolLiquidity(bytes32 poolId) external view returns (uint128);

    /// @notice Returns the list of active pool IDs
    function getActivePools() external view returns (bytes32[] memory);

    /// @notice Returns the target allocations defined by the strategy
    /// @dev Must be implemented by concrete vault strategies
    function getTargetAllocations() external view returns (PoolAllocation[] memory);
}
