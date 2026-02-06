// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./BaseLocker.sol";
import {UsesCore} from "./UsesCore.sol";
import {PayableMulticallable} from "./PayableMulticallable.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ICore} from "../interfaces/ICore.sol";
import {IBaseVault} from "../interfaces/IBaseVault.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {PositionId, createPositionId} from "../types/positionId.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";
import {PoolAllocation} from "../types/vaultTypes.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {maxLiquidity} from "../math/liquidity.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title BaseVault
/// @notice Abstract base contract for automated liquidity management vaults
/// @dev Users deposit a single token, receive ERC20 shares, and the vault manages
///      liquidity allocation according to strategy-defined targets.
///      All deposits and withdrawals are processed in epochs for gas efficiency
///      and to enable atomic rebalancing.
abstract contract BaseVault is
    ERC20,
    BaseLocker,
    UsesCore,
    PayableMulticallable,
    Ownable,
    IBaseVault
{
    using CoreLib for *;
    using FlashAccountantLib for *;
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    /// @notice Position salt used for all vault LP positions
    bytes24 private constant POSITION_SALT = bytes24(uint192(1));

    /// @notice Scale factor for rate calculations (1e18)
    uint256 private constant RATE_SCALE = 1e18;

    /// @notice Basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice Call type constants for handleLockData
    uint256 private constant CALL_TYPE_PROCESS_EPOCH = 0;

    // ============ Immutable Configuration ============

    /// @inheritdoc IBaseVault
    address public immutable DEPOSIT_TOKEN;

    /// @inheritdoc IBaseVault
    uint256 public immutable MIN_EPOCH_DURATION;

    // ============ Epoch State ============

    /// @inheritdoc IBaseVault
    uint256 public currentEpoch;

    /// @inheritdoc IBaseVault
    uint256 public epochStartTime;

    /// @inheritdoc IBaseVault
    uint256 public pendingDeposits;

    /// @inheritdoc IBaseVault
    uint256 public pendingWithdrawShares;

    // ============ User Claims ============

    /// @notice epoch => user => deposit amount
    mapping(uint256 => mapping(address => uint256)) private _userEpochDeposits;

    /// @notice epoch => user => withdrawal shares
    mapping(uint256 => mapping(address => uint256)) private _userEpochWithdrawals;

    // ============ Epoch Settlement ============

    /// @notice epoch => shares per deposit token (scaled by RATE_SCALE)
    mapping(uint256 => uint256) private _epochShareRate;

    /// @notice epoch => tokens per share (scaled by RATE_SCALE)
    mapping(uint256 => uint256) private _epochWithdrawRate;

    /// @notice epoch => processed flag
    mapping(uint256 => bool) private _epochProcessed;

    // ============ Pool Tracking ============

    /// @notice poolId => liquidity amount
    mapping(bytes32 => uint128) private _poolLiquidity;

    /// @notice Array of active pool IDs
    bytes32[] private _activePools;

    /// @notice poolId => index+1 in _activePools (0 means not active)
    mapping(bytes32 => uint256) private _poolIndex;

    /// @notice Error thrown when uint128 to int128 cast would overflow
    error CastOverflow();

    /// @notice Constructs the BaseVault
    /// @param core The core contract instance
    /// @param owner_ The owner of the contract
    /// @param depositToken The token users deposit
    /// @param minEpochDuration Minimum time between epoch processing
    constructor(
        ICore core,
        address owner_,
        address depositToken,
        uint256 minEpochDuration
    )
        BaseLocker(core)
        UsesCore(core)
    {
        _initializeOwner(owner_);
        DEPOSIT_TOKEN = depositToken;
        MIN_EPOCH_DURATION = minEpochDuration;
        epochStartTime = block.timestamp;
    }

    // ============ ERC20 Metadata ============

    /// @notice Returns the name of the vault token
    function name() public view virtual override returns (string memory);

    /// @notice Returns the symbol of the vault token
    function symbol() public view virtual override returns (string memory);

    /// @notice Returns 18 decimals for vault shares
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    // ============ View Functions ============

    /// @inheritdoc IBaseVault
    function userEpochDeposits(uint256 epoch, address user) external view returns (uint256) {
        return _userEpochDeposits[epoch][user];
    }

    /// @inheritdoc IBaseVault
    function userEpochWithdrawals(uint256 epoch, address user) external view returns (uint256) {
        return _userEpochWithdrawals[epoch][user];
    }

    /// @inheritdoc IBaseVault
    function epochShareRate(uint256 epoch) external view returns (uint256) {
        return _epochShareRate[epoch];
    }

    /// @inheritdoc IBaseVault
    function epochWithdrawRate(uint256 epoch) external view returns (uint256) {
        return _epochWithdrawRate[epoch];
    }

    /// @inheritdoc IBaseVault
    function epochProcessed(uint256 epoch) external view returns (bool) {
        return _epochProcessed[epoch];
    }

    /// @inheritdoc IBaseVault
    function poolLiquidity(bytes32 poolId) external view returns (uint128) {
        return _poolLiquidity[poolId];
    }

    /// @inheritdoc IBaseVault
    function getActivePools() external view returns (bytes32[] memory) {
        return _activePools;
    }

    /// @inheritdoc IBaseVault
    /// @dev Must be implemented by concrete vault strategies
    function getTargetAllocations() public view virtual returns (PoolAllocation[] memory);

    // ============ User Functions ============

    /// @inheritdoc IBaseVault
    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroDeposit();

        // Transfer tokens from user
        DEPOSIT_TOKEN.safeTransferFrom(msg.sender, address(this), amount);

        // Record deposit for current epoch
        _userEpochDeposits[currentEpoch][msg.sender] += amount;
        pendingDeposits += amount;

        emit Deposited(msg.sender, currentEpoch, amount);
    }

    /// @inheritdoc IBaseVault
    function withdraw(uint256 shares) external {
        if (shares == 0) revert ZeroWithdrawal();

        // Transfer shares from user to vault (will be burned during epoch processing)
        _transfer(msg.sender, address(this), shares);

        // Record withdrawal for current epoch
        _userEpochWithdrawals[currentEpoch][msg.sender] += shares;
        pendingWithdrawShares += shares;

        emit WithdrawalQueued(msg.sender, currentEpoch, shares);
    }

    /// @inheritdoc IBaseVault
    function claimShares(uint256 epoch) external returns (uint256 shares) {
        if (!_epochProcessed[epoch]) revert EpochNotProcessed();

        uint256 depositAmount = _userEpochDeposits[epoch][msg.sender];
        if (depositAmount == 0) revert NoDepositInEpoch();

        // Clear user's deposit record
        delete _userEpochDeposits[epoch][msg.sender];

        // Calculate shares to mint
        shares = depositAmount.mulDiv(_epochShareRate[epoch], RATE_SCALE);

        // Mint shares to user
        _mint(msg.sender, shares);

        emit SharesClaimed(msg.sender, epoch, shares);
    }

    /// @inheritdoc IBaseVault
    function claimWithdrawal(uint256 epoch) external returns (uint256 amount) {
        if (!_epochProcessed[epoch]) revert EpochNotProcessed();

        uint256 withdrawShares = _userEpochWithdrawals[epoch][msg.sender];
        if (withdrawShares == 0) revert NoWithdrawalInEpoch();

        // Clear user's withdrawal record
        delete _userEpochWithdrawals[epoch][msg.sender];

        // Calculate tokens to transfer
        amount = withdrawShares.mulDiv(_epochWithdrawRate[epoch], RATE_SCALE);

        // Transfer tokens to user
        DEPOSIT_TOKEN.safeTransfer(msg.sender, amount);

        emit WithdrawalClaimed(msg.sender, epoch, amount);
    }

    /// @inheritdoc IBaseVault
    function batchClaim(uint256[] calldata depositEpochs, uint256[] calldata withdrawalEpochs) external {
        uint256 totalShares;
        uint256 totalAmount;

        // Process deposit claims
        for (uint256 i = 0; i < depositEpochs.length; i++) {
            uint256 epoch = depositEpochs[i];
            if (!_epochProcessed[epoch]) revert EpochNotProcessed();

            uint256 depositAmount = _userEpochDeposits[epoch][msg.sender];
            if (depositAmount > 0) {
                delete _userEpochDeposits[epoch][msg.sender];
                uint256 shares = depositAmount.mulDiv(_epochShareRate[epoch], RATE_SCALE);
                totalShares += shares;
                emit SharesClaimed(msg.sender, epoch, shares);
            }
        }

        // Process withdrawal claims
        for (uint256 i = 0; i < withdrawalEpochs.length; i++) {
            uint256 epoch = withdrawalEpochs[i];
            if (!_epochProcessed[epoch]) revert EpochNotProcessed();

            uint256 withdrawShares = _userEpochWithdrawals[epoch][msg.sender];
            if (withdrawShares > 0) {
                delete _userEpochWithdrawals[epoch][msg.sender];
                uint256 amount = withdrawShares.mulDiv(_epochWithdrawRate[epoch], RATE_SCALE);
                totalAmount += amount;
                emit WithdrawalClaimed(msg.sender, epoch, amount);
            }
        }

        // Execute transfers
        if (totalShares > 0) {
            _mint(msg.sender, totalShares);
        }
        if (totalAmount > 0) {
            DEPOSIT_TOKEN.safeTransfer(msg.sender, totalAmount);
        }
    }

    // ============ Epoch Processing ============

    /// @inheritdoc IBaseVault
    function processEpoch() external {
        if (block.timestamp < epochStartTime + MIN_EPOCH_DURATION) {
            revert EpochNotReady();
        }

        // Execute all operations atomically within lock
        lock(abi.encode(CALL_TYPE_PROCESS_EPOCH));
    }

    /// @notice Handles the lock callback for epoch processing
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_PROCESS_EPOCH) {
            _handleProcessEpoch();
        }

        return "";
    }

    /// @notice Internal handler for epoch processing
    function _handleProcessEpoch() internal {
        uint256 epoch = currentEpoch;

        // Step 1: Collect fees from all active pools
        _collectAllFees();

        // Step 2: Calculate total NAV (value of all positions in deposit token terms)
        uint256 totalNAV = _calculateTotalNAV();

        // Step 3: Withdraw all liquidity to consolidate tokens
        _withdrawAllLiquidity();

        // Step 4: Swap all non-deposit tokens to deposit token
        _consolidateToDepositToken();

        // Get current state
        uint256 currentTotalSupply = totalSupply();
        uint256 epochPendingDeposits = pendingDeposits;
        uint256 epochPendingWithdrawShares = pendingWithdrawShares;

        // Step 5: Calculate settlement rates
        uint256 shareRate;
        uint256 withdrawRate;

        if (epochPendingDeposits > 0) {
            if (currentTotalSupply == 0) {
                // First deposits - 1:1 rate
                shareRate = RATE_SCALE;
            } else {
                // Shares per deposit token = totalSupply / totalNAV
                shareRate = currentTotalSupply.mulDiv(RATE_SCALE, totalNAV);
            }
        }

        if (epochPendingWithdrawShares > 0) {
            // Tokens per share = totalNAV / totalSupply
            if (currentTotalSupply > 0) {
                withdrawRate = totalNAV.mulDiv(RATE_SCALE, currentTotalSupply);
            }
        }

        // Step 6: Process withdrawals (burn shares held by vault)
        if (epochPendingWithdrawShares > 0) {
            _burn(address(this), epochPendingWithdrawShares);
        }

        // Step 7: Record settlement rates
        _epochShareRate[epoch] = shareRate;
        _epochWithdrawRate[epoch] = withdrawRate;
        _epochProcessed[epoch] = true;

        // Step 8: Calculate new total value and rebalance
        // Total value now includes pending deposits and excludes withdrawal amounts
        uint256 withdrawalTokens = epochPendingWithdrawShares.mulDiv(withdrawRate, RATE_SCALE);
        uint256 newTotalValue = totalNAV + epochPendingDeposits - withdrawalTokens;

        // Step 9: Rebalance to target allocations
        if (newTotalValue > 0) {
            _rebalance(newTotalValue);
        }

        // Step 10: Reset pending amounts and increment epoch
        pendingDeposits = 0;
        pendingWithdrawShares = 0;
        currentEpoch = epoch + 1;
        epochStartTime = block.timestamp;

        emit EpochProcessed(epoch, totalNAV, shareRate, withdrawRate);
    }

    // ============ Internal Position Management ============

    /// @notice Collects fees from all active pool positions
    function _collectAllFees() internal {
        PoolAllocation[] memory allocations = getTargetAllocations();

        for (uint256 i = 0; i < allocations.length; i++) {
            bytes32 poolIdBytes = PoolId.unwrap(allocations[i].poolKey.toPoolId());
            if (_poolLiquidity[poolIdBytes] > 0) {
                _collectFeesFromPool(allocations[i].poolKey);
            }
        }
    }

    /// @notice Collects fees from a specific pool position
    function _collectFeesFromPool(PoolKey memory poolKey) internal {
        (int32 tickLower, int32 tickUpper) = _getPositionTickRange(poolKey);
        PositionId positionId = createPositionId(POSITION_SALT, tickLower, tickUpper);

        CORE.collectFees(poolKey, positionId);
    }

    /// @notice Calculates the total NAV of all positions in deposit token terms
    function _calculateTotalNAV() internal view returns (uint256 totalNAV) {
        // Start with deposit token balance held by vault
        totalNAV = DEPOSIT_TOKEN.balanceOf(address(this));

        // Add value of all pool positions
        PoolAllocation[] memory allocations = getTargetAllocations();

        for (uint256 i = 0; i < allocations.length; i++) {
            PoolKey memory poolKey = allocations[i].poolKey;
            bytes32 poolIdBytes = PoolId.unwrap(poolKey.toPoolId());
            uint128 liquidity = _poolLiquidity[poolIdBytes];

            if (liquidity > 0) {
                (uint256 amount0, uint256 amount1) = _getPositionValue(poolKey, liquidity);

                // Convert amounts to deposit token value
                // If deposit token is token0, add amount0 + swap value of amount1
                // If deposit token is token1, add amount1 + swap value of amount0
                if (poolKey.token0 == DEPOSIT_TOKEN) {
                    totalNAV += amount0;
                    if (amount1 > 0) {
                        totalNAV += _estimateSwapOutput(poolKey, true, amount1);
                    }
                } else if (poolKey.token1 == DEPOSIT_TOKEN) {
                    totalNAV += amount1;
                    if (amount0 > 0) {
                        totalNAV += _estimateSwapOutput(poolKey, false, amount0);
                    }
                }
            }
        }
    }

    /// @notice Gets the value of a position in terms of both tokens
    function _getPositionValue(PoolKey memory poolKey, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        PoolId poolId = poolKey.toPoolId();
        PoolState state = CORE.poolState(poolId);
        SqrtRatio sqrtRatio = state.sqrtRatio();

        (int32 tickLower, int32 tickUpper) = _getPositionTickRange(poolKey);
        SqrtRatio sqrtRatioLower = tickToSqrtRatio(tickLower);
        SqrtRatio sqrtRatioUpper = tickToSqrtRatio(tickUpper);

        // Calculate amounts based on current price and position bounds
        (amount0, amount1) = _calculateAmountsFromLiquidity(
            sqrtRatio,
            sqrtRatioLower,
            sqrtRatioUpper,
            liquidity
        );
    }

    /// @notice Calculates token amounts for a given liquidity
    function _calculateAmountsFromLiquidity(
        SqrtRatio sqrtRatio,
        SqrtRatio sqrtRatioLower,
        SqrtRatio sqrtRatioUpper,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        // Early return for zero liquidity
        if (liquidity == 0) {
            return (0, 0);
        }

        uint256 sqrtRatioFixed = sqrtRatio.toFixed();
        uint256 sqrtRatioLowerFixed = sqrtRatioLower.toFixed();
        uint256 sqrtRatioUpperFixed = sqrtRatioUpper.toFixed();

        // Guard against zero denominators
        if (sqrtRatioFixed == 0 || sqrtRatioLowerFixed == 0 || sqrtRatioUpperFixed == 0) {
            return (0, 0);
        }

        if (sqrtRatioFixed <= sqrtRatioLowerFixed) {
            // Current price below range - all token0
            // Use fullMulDiv to handle potential overflow
            uint256 denominator = FixedPointMathLib.fullMulDiv(sqrtRatioLowerFixed, sqrtRatioUpperFixed, 1 << 128);
            if (denominator > 0) {
                amount0 = uint256(liquidity).mulDiv(
                    sqrtRatioUpperFixed - sqrtRatioLowerFixed,
                    denominator
                );
            }
        } else if (sqrtRatioFixed >= sqrtRatioUpperFixed) {
            // Current price above range - all token1
            amount1 = uint256(liquidity).mulDiv(
                sqrtRatioUpperFixed - sqrtRatioLowerFixed,
                1 << 128
            );
        } else {
            // Current price within range
            // Use fullMulDiv to handle potential overflow
            uint256 denominator = FixedPointMathLib.fullMulDiv(sqrtRatioFixed, sqrtRatioUpperFixed, 1 << 128);
            if (denominator > 0) {
                amount0 = uint256(liquidity).mulDiv(
                    sqrtRatioUpperFixed - sqrtRatioFixed,
                    denominator
                );
            }
            amount1 = uint256(liquidity).mulDiv(
                sqrtRatioFixed - sqrtRatioLowerFixed,
                1 << 128
            );
        }
    }

    /// @notice Estimates swap output for NAV calculation
    function _estimateSwapOutput(PoolKey memory poolKey, bool isToken1, uint256 amountIn)
        internal
        view
        returns (uint256 amountOut)
    {
        if (amountIn == 0) return 0;

        // Simple estimate using current price
        PoolId poolId = poolKey.toPoolId();
        PoolState state = CORE.poolState(poolId);
        uint256 sqrtRatioFixed = state.sqrtRatio().toFixed();

        // Guard against uninitialized pool or zero price
        if (sqrtRatioFixed == 0) return 0;

        // price = sqrtRatio^2 / 2^128
        // Use fullMulDiv to handle 512-bit intermediate value when sqrtRatio is large
        uint256 priceX128 = FixedPointMathLib.fullMulDiv(sqrtRatioFixed, sqrtRatioFixed, 1 << 128);
        if (priceX128 == 0) return 0;

        if (isToken1) {
            // Selling token1 for token0
            amountOut = amountIn.mulDiv(1 << 128, priceX128);
        } else {
            // Selling token0 for token1
            amountOut = amountIn.mulDiv(priceX128, 1 << 128);
        }
    }

    /// @notice Withdraws all liquidity from all active pools
    function _withdrawAllLiquidity() internal {
        PoolAllocation[] memory allocations = getTargetAllocations();

        for (uint256 i = 0; i < allocations.length; i++) {
            bytes32 poolIdBytes = PoolId.unwrap(allocations[i].poolKey.toPoolId());
            uint128 liquidity = _poolLiquidity[poolIdBytes];

            if (liquidity > 0) {
                _withdrawFromPool(allocations[i].poolKey, liquidity);
            }
        }
    }

    /// @notice Withdraws liquidity from a specific pool
    function _withdrawFromPool(PoolKey memory poolKey, uint128 liquidity) internal {
        (int32 tickLower, int32 tickUpper) = _getPositionTickRange(poolKey);
        PositionId positionId = createPositionId(POSITION_SALT, tickLower, tickUpper);

        // Remove liquidity
        PoolBalanceUpdate balanceUpdate = CORE.updatePosition(
            poolKey,
            positionId,
            -_safeInt128(liquidity)
        );

        // Withdraw tokens to vault
        uint128 amount0 = uint128(-balanceUpdate.delta0());
        uint128 amount1 = uint128(-balanceUpdate.delta1());

        ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, address(this), amount0, amount1);

        // Update tracking
        bytes32 poolIdBytes = PoolId.unwrap(poolKey.toPoolId());
        _poolLiquidity[poolIdBytes] = 0;
        _removeFromActivePools(poolIdBytes);

        emit LiquidityWithdrawn(poolKey.toPoolId(), liquidity);
    }

    /// @notice Consolidates all tokens to deposit token
    function _consolidateToDepositToken() internal {
        PoolAllocation[] memory allocations = getTargetAllocations();

        for (uint256 i = 0; i < allocations.length; i++) {
            PoolKey memory poolKey = allocations[i].poolKey;

            // Swap non-deposit token to deposit token
            if (poolKey.token0 == DEPOSIT_TOKEN) {
                // Swap all token1 to token0 (deposit token)
                uint256 balance1 = poolKey.token1.balanceOf(address(this));
                if (balance1 > 0) {
                    _swapExactInput(poolKey, true, balance1);
                }
            } else if (poolKey.token1 == DEPOSIT_TOKEN) {
                // Swap all token0 to token1 (deposit token)
                uint256 balance0 = poolKey.token0.balanceOf(address(this));
                if (balance0 > 0) {
                    _swapExactInput(poolKey, false, balance0);
                }
            }
        }
    }

    /// @notice Rebalances vault to target allocations
    function _rebalance(uint256 totalValue) internal {
        PoolAllocation[] memory allocations = getTargetAllocations();

        // If no allocations, just keep tokens in vault
        if (allocations.length == 0) {
            return;
        }

        // Validate allocations sum to 100%
        uint256 totalBps;
        for (uint256 i = 0; i < allocations.length; i++) {
            totalBps += allocations[i].targetBps;
        }
        if (totalBps != BPS_DENOMINATOR) revert InvalidTargetAllocations();

        // Deploy to each pool according to target
        for (uint256 i = 0; i < allocations.length; i++) {
            if (allocations[i].targetBps > 0) {
                uint256 targetAmount = totalValue.mulDiv(allocations[i].targetBps, BPS_DENOMINATOR);
                if (targetAmount > 0) {
                    _deployToPool(allocations[i].poolKey, targetAmount);
                }
            }
        }
    }

    /// @notice Deploys tokens to a specific pool
    function _deployToPool(PoolKey memory poolKey, uint256 amount) internal {
        PoolId poolId = poolKey.toPoolId();
        bytes32 poolIdBytes = PoolId.unwrap(poolId);

        // Get position parameters
        (int32 tickLower, int32 tickUpper) = _getPositionTickRange(poolKey);
        PositionId positionId = createPositionId(POSITION_SALT, tickLower, tickUpper);

        PoolState state = CORE.poolState(poolId);
        SqrtRatio sqrtRatio = state.sqrtRatio();
        SqrtRatio sqrtRatioLower = tickToSqrtRatio(tickLower);
        SqrtRatio sqrtRatioUpper = tickToSqrtRatio(tickUpper);

        // Calculate how much of each token we need
        (uint256 amount0Needed, uint256 amount1Needed) = _calculateAmountsNeeded(
            sqrtRatio,
            sqrtRatioLower,
            sqrtRatioUpper,
            amount,
            poolKey
        );

        // Only swap if the pool has liquidity to swap against
        // Otherwise we would corrupt the pool state without getting any tokens
        if (state.liquidity() > 0) {
            // Swap deposit token to get the other token if needed
            if (poolKey.token0 == DEPOSIT_TOKEN && amount1Needed > 0) {
                // Swap some deposit token (token0) to token1
                _swapExactOutput(poolKey, false, amount1Needed);
            } else if (poolKey.token1 == DEPOSIT_TOKEN && amount0Needed > 0) {
                // Swap some deposit token (token1) to token0
                _swapExactOutput(poolKey, true, amount0Needed);
            }
        }

        // Get actual balances available
        uint128 maxAmount0 = uint128(poolKey.token0.balanceOf(address(this)));
        uint128 maxAmount1 = uint128(poolKey.token1.balanceOf(address(this)));

        // Calculate maximum liquidity we can add
        uint128 liquidityToAdd = maxLiquidity(sqrtRatio, sqrtRatioLower, sqrtRatioUpper, maxAmount0, maxAmount1);

        if (liquidityToAdd > 0) {
            // Add liquidity first - this creates debt
            PoolBalanceUpdate balanceUpdate = CORE.updatePosition(poolKey, positionId, _safeInt128(liquidityToAdd));

            // Pay the debt using tokens from vault balance
            uint128 owed0 = uint128(balanceUpdate.delta0());
            uint128 owed1 = uint128(balanceUpdate.delta1());

            if (owed0 > 0) {
                ACCOUNTANT.pay(poolKey.token0, owed0);
            }
            if (owed1 > 0) {
                ACCOUNTANT.pay(poolKey.token1, owed1);
            }

            // Update tracking
            _poolLiquidity[poolIdBytes] += liquidityToAdd;
            _addToActivePools(poolIdBytes);

            emit LiquidityDeployed(poolId, liquidityToAdd);
        }
    }

    /// @notice Calculates token amounts needed for a target value
    function _calculateAmountsNeeded(
        SqrtRatio sqrtRatio,
        SqrtRatio sqrtRatioLower,
        SqrtRatio sqrtRatioUpper,
        uint256 totalValue,
        PoolKey memory poolKey
    ) internal view returns (uint256 amount0, uint256 amount1) {
        if (totalValue == 0) return (0, 0);

        uint256 sqrtRatioFixed = sqrtRatio.toFixed();
        uint256 sqrtRatioLowerFixed = sqrtRatioLower.toFixed();
        uint256 sqrtRatioUpperFixed = sqrtRatioUpper.toFixed();

        // Guard against uninitialized pool
        if (sqrtRatioFixed == 0) {
            // Fallback: allocate all to deposit token side
            if (poolKey.token0 == DEPOSIT_TOKEN) {
                return (totalValue, 0);
            } else {
                return (0, totalValue);
            }
        }

        // Calculate the ratio of token0 to token1 value at current price
        // Use fullMulDiv to handle 512-bit intermediate when sqrtRatio is large
        uint256 price = FixedPointMathLib.fullMulDiv(sqrtRatioFixed, sqrtRatioFixed, 1 << 128);
        if (price == 0) {
            // Fallback for edge case
            if (poolKey.token0 == DEPOSIT_TOKEN) {
                return (totalValue, 0);
            } else {
                return (0, totalValue);
            }
        }

        if (sqrtRatioFixed <= sqrtRatioLowerFixed) {
            // All token0
            if (poolKey.token0 == DEPOSIT_TOKEN) {
                amount0 = totalValue;
            } else {
                amount0 = totalValue.mulDiv(1 << 128, price);
            }
        } else if (sqrtRatioFixed >= sqrtRatioUpperFixed) {
            // All token1
            if (poolKey.token1 == DEPOSIT_TOKEN) {
                amount1 = totalValue;
            } else {
                amount1 = totalValue.mulDiv(price, 1 << 128);
            }
        } else {
            // Split based on position within range
            uint256 ratio0 = sqrtRatioUpperFixed - sqrtRatioFixed;
            uint256 ratio1 = sqrtRatioFixed - sqrtRatioLowerFixed;
            uint256 totalRatio = ratio0 + ratio1.mulDiv(price, 1 << 128);

            if (totalRatio == 0) {
                // Edge case fallback
                if (poolKey.token0 == DEPOSIT_TOKEN) {
                    return (totalValue, 0);
                } else {
                    return (0, totalValue);
                }
            }

            uint256 value0 = totalValue.mulDiv(ratio0, totalRatio);
            uint256 value1 = totalValue - value0;

            if (poolKey.token0 == DEPOSIT_TOKEN) {
                amount0 = value0;
                amount1 = value1.mulDiv(1 << 128, price);
            } else {
                amount0 = value0.mulDiv(1 << 128, price);
                amount1 = value1;
            }
        }
    }

    /// @notice Executes an exact input swap
    function _swapExactInput(PoolKey memory poolKey, bool isToken1, uint256 amountIn) internal {
        // Execute swap first - this creates debt
        SwapParameters params = createSwapParameters(
            SqrtRatio.wrap(0), // Use default limit
            int128(uint128(amountIn)),
            isToken1,
            0
        );

        (PoolBalanceUpdate balanceUpdate,) = CORE.swap(0, poolKey, params.withDefaultSqrtRatioLimit());

        // Pay the input token debt and withdraw output tokens
        if (isToken1) {
            // Paid token1, received token0
            if (balanceUpdate.delta1() > 0) {
                ACCOUNTANT.pay(poolKey.token1, uint256(uint128(balanceUpdate.delta1())));
            }
            if (balanceUpdate.delta0() < 0) {
                ACCOUNTANT.withdraw(poolKey.token0, address(this), uint128(-balanceUpdate.delta0()));
            }
        } else {
            // Paid token0, received token1
            if (balanceUpdate.delta0() > 0) {
                ACCOUNTANT.pay(poolKey.token0, uint256(uint128(balanceUpdate.delta0())));
            }
            if (balanceUpdate.delta1() < 0) {
                ACCOUNTANT.withdraw(poolKey.token1, address(this), uint128(-balanceUpdate.delta1()));
            }
        }
    }

    /// @notice Executes an exact output swap
    function _swapExactOutput(PoolKey memory poolKey, bool isToken1, uint256 amountOut) internal {
        // Execute swap with negative amount for exact output
        SwapParameters params = createSwapParameters(
            SqrtRatio.wrap(0),
            -int128(uint128(amountOut)),
            isToken1,
            0
        );

        (PoolBalanceUpdate balanceUpdate,) = CORE.swap(0, poolKey, params.withDefaultSqrtRatioLimit());

        // Pay the input token debt and withdraw output tokens
        if (isToken1) {
            // Paid token1, received token0
            if (balanceUpdate.delta1() > 0) {
                ACCOUNTANT.pay(poolKey.token1, uint256(uint128(balanceUpdate.delta1())));
            }
            if (balanceUpdate.delta0() < 0) {
                ACCOUNTANT.withdraw(poolKey.token0, address(this), uint128(-balanceUpdate.delta0()));
            }
        } else {
            // Paid token0, received token1
            if (balanceUpdate.delta0() > 0) {
                ACCOUNTANT.pay(poolKey.token0, uint256(uint128(balanceUpdate.delta0())));
            }
            if (balanceUpdate.delta1() < 0) {
                ACCOUNTANT.withdraw(poolKey.token1, address(this), uint128(-balanceUpdate.delta1()));
            }
        }
    }

    /// @notice Estimates input needed for a given output
    function _estimateSwapInput(PoolKey memory poolKey, bool isToken1, uint256 amountOut)
        internal
        view
        returns (uint256 amountIn)
    {
        if (amountOut == 0) return 0;

        PoolId poolId = poolKey.toPoolId();
        PoolState state = CORE.poolState(poolId);
        uint256 sqrtRatioFixed = state.sqrtRatio().toFixed();

        // Guard against uninitialized pool
        if (sqrtRatioFixed == 0) return amountOut; // 1:1 fallback

        // Use fullMulDiv to handle 512-bit intermediate
        uint256 price = FixedPointMathLib.fullMulDiv(sqrtRatioFixed, sqrtRatioFixed, 1 << 128);
        if (price == 0) return amountOut; // 1:1 fallback

        // Add 1% buffer for slippage
        if (isToken1) {
            // Buying token0 with token1
            amountIn = amountOut.mulDiv(price, 1 << 128).mulDiv(101, 100);
        } else {
            // Buying token1 with token0
            amountIn = amountOut.mulDiv(1 << 128, price).mulDiv(101, 100);
        }
    }

    /// @notice Gets the tick range for a position based on pool config
    function _getPositionTickRange(PoolKey memory poolKey) internal pure returns (int32 tickLower, int32 tickUpper) {
        if (poolKey.config.isConcentrated()) {
            // For concentrated pools, use full range aligned to tick spacing
            uint32 tickSpacing = poolKey.config.concentratedTickSpacing();
            int32 minTick = -887272; // MIN_TICK
            int32 maxTick = 887272;  // MAX_TICK

            // Align to tick spacing
            tickLower = (minTick / int32(tickSpacing)) * int32(tickSpacing);
            tickUpper = (maxTick / int32(tickSpacing)) * int32(tickSpacing);
        } else {
            // For stableswap pools, use the configured range
            (tickLower, tickUpper) = poolKey.config.stableswapActiveLiquidityTickRange();
        }
    }

    // ============ Pool Tracking Helpers ============

    /// @notice Adds a pool to the active pools list
    function _addToActivePools(bytes32 poolIdBytes) internal {
        if (_poolIndex[poolIdBytes] == 0) {
            _activePools.push(poolIdBytes);
            _poolIndex[poolIdBytes] = _activePools.length;
        }
    }

    /// @notice Removes a pool from the active pools list
    function _removeFromActivePools(bytes32 poolIdBytes) internal {
        uint256 index = _poolIndex[poolIdBytes];
        if (index > 0) {
            uint256 lastIndex = _activePools.length;
            if (index != lastIndex) {
                bytes32 lastPoolId = _activePools[lastIndex - 1];
                _activePools[index - 1] = lastPoolId;
                _poolIndex[lastPoolId] = index;
            }
            _activePools.pop();
            delete _poolIndex[poolIdBytes];
        }
    }

    // ============ Utility Functions ============

    /// @notice Safely casts uint128 to int128
    function _safeInt128(uint128 value) internal pure returns (int128) {
        if (value > uint128(type(int128).max)) revert CastOverflow();
        return int128(value);
    }

    /// @notice Gets balance of a token, handling native token
    function _balanceOf(address token) internal view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
