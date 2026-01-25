// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IStableswapLPPositions} from "./interfaces/IStableswapLPPositions.sol";
import {StableswapLPToken} from "./StableswapLPToken.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolId} from "./types/poolId.sol";
import {PositionId, createPositionId} from "./types/positionId.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity} from "./math/liquidity.sol";
import {computeFee} from "./math/fee.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";

/// @title Stableswap LP Positions
/// @author Bogdan Sivochkin
/// @notice Manages fungible LP positions for stableswap pools with auto-compounding fees
/// @dev Uses Uniswap V2-style auto-compounding where fees increase LP token value
contract StableswapLPPositions is BaseLocker, UsesCore, PayableMulticallable, Ownable, ReentrancyGuard, IStableswapLPPositions {
    using CoreLib for *;
    using FlashAccountantLib for *;

    /// @notice Position salt used for all stableswap LP positions
    /// @dev All positions managed by this contract use the same salt
    bytes24 private constant POSITION_SALT = bytes24(uint192(1));

    /// @notice Protocol fee rate for swaps (as a fraction of 2^64)
    uint64 public immutable SWAP_PROTOCOL_FEE_X64;

    /// @notice LP token implementation for cloning (EIP-1167)
    address public immutable LP_TOKEN_IMPLEMENTATION;

    /// @notice Call type constants for handleLockData
    uint256 private constant CALL_TYPE_DEPOSIT = 0;
    uint256 private constant CALL_TYPE_WITHDRAW = 1;
    uint256 private constant CALL_TYPE_WITHDRAW_PROTOCOL_FEES = 2;

    /// @notice Pending fees that couldn't be compounded (packed into single slot)
    /// @dev These fees belong to LP holders and will be added to the next compound attempt
    struct PendingFees {
        uint128 amount0;
        uint128 amount1;
    }
    mapping(PoolId => PendingFees) public pendingFees;

    /// @notice Constructs the StableswapLPPositions contract
    /// @param core The core contract instance
    /// @param owner The owner of the contract (for access control)
    /// @param _swapProtocolFeeX64 Protocol fee rate for swaps
    constructor(ICore core, address owner, uint64 _swapProtocolFeeX64)
        BaseLocker(core)
        UsesCore(core)
    {
        _initializeOwner(owner);
        SWAP_PROTOCOL_FEE_X64 = _swapProtocolFeeX64;
        // Deploy LP token implementation for cloning
        LP_TOKEN_IMPLEMENTATION = address(new StableswapLPToken(address(this)));
    }

    /// @notice Validates that the deadline has not passed
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    /// @notice Creates a new LP token for a stableswap pool
    /// @dev Uses EIP-1167 minimal proxy with CREATE2 for deterministic addresses
    /// @param poolKey The pool key to create an LP token for
    /// @return lpToken The address of the created LP token
    function createLPToken(PoolKey memory poolKey) external returns (address lpToken) {
        bytes32 salt = PoolId.unwrap(poolKey.toPoolId());

        // Check if LP token already exists by checking code length at deterministic address
        address predicted = LibClone.predictDeterministicAddress(LP_TOKEN_IMPLEMENTATION, salt, address(this));
        if (predicted.code.length > 0) {
            revert LPTokenAlreadyExists();
        }

        // Clone LP token implementation with CREATE2 (deterministic address)
        lpToken = LibClone.cloneDeterministic(LP_TOKEN_IMPLEMENTATION, salt);
        StableswapLPToken(payable(lpToken)).initialize(poolKey);

        emit LPTokenCreated(poolKey, lpToken);
    }

    /// @notice Gets the LP token address for a pool (deterministically computed)
    /// @dev Address is computed via CREATE2, no storage lookup needed
    /// @param poolKey The pool key
    /// @return lpToken The LP token address (may not be deployed yet)
    function getLPToken(PoolKey memory poolKey) public view returns (address lpToken) {
        bytes32 salt = PoolId.unwrap(poolKey.toPoolId());
        lpToken = LibClone.predictDeterministicAddress(LP_TOKEN_IMPLEMENTATION, salt, address(this));
    }

    /// @notice Checks if an LP token exists for a pool
    /// @param poolKey The pool key
    /// @return exists True if LP token has been created
    function lpTokenExists(PoolKey memory poolKey) external view returns (bool exists) {
        return getLPToken(poolKey).code.length > 0;
    }

    /// @inheritdoc IStableswapLPPositions
    function deposit(
        PoolKey memory poolKey,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 lpTokensMinted, uint128 amount0, uint128 amount1)
    {
        (lpTokensMinted, amount0, amount1) = abi.decode(
            lock(abi.encode(CALL_TYPE_DEPOSIT, msg.sender, poolKey, maxAmount0, maxAmount1, minLiquidity)),
            (uint256, uint128, uint128)
        );

        emit Deposit(msg.sender, poolKey.toPoolId(), lpTokensMinted, amount0, amount1);
    }

    /// @inheritdoc IStableswapLPPositions
    function withdraw(
        PoolKey memory poolKey,
        uint256 lpTokensToWithdraw,
        uint128 minAmount0,
        uint128 minAmount1,
        uint256 deadline
    )
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = abi.decode(
            lock(abi.encode(CALL_TYPE_WITHDRAW, msg.sender, poolKey, lpTokensToWithdraw)),
            (uint128, uint128)
        );

        if (amount0 < minAmount0 || amount1 < minAmount1) {
            revert WithdrawFailedDueToSlippage(amount0, minAmount0, amount1, minAmount1);
        }

        emit Withdraw(msg.sender, poolKey.toPoolId(), lpTokensToWithdraw, amount0, amount1);
    }

    /// @notice Withdraws protocol fees (owner only)
    /// @param token0 The first token
    /// @param token1 The second token
    /// @param amount0 Amount of token0 to withdraw
    /// @param amount1 Amount of token1 to withdraw
    /// @param recipient The recipient of the fees
    function withdrawProtocolFees(address token0, address token1, uint128 amount0, uint128 amount1, address recipient)
        external
        onlyOwner
    {
        lock(abi.encode(CALL_TYPE_WITHDRAW_PROTOCOL_FEES, token0, token1, amount0, amount1, recipient));
    }

    /// @notice Gets the accumulated protocol fees
    /// @param token0 The first token
    /// @param token1 The second token
    /// @return amount0 Amount of token0 fees
    /// @return amount1 Amount of token1 fees
    function getProtocolFees(address token0, address token1) external view returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = CORE.savedBalances(address(this), token0, token1, bytes32(0));
    }

    /// @notice Auto-compounds pending fees by collecting and reinvesting them
    /// @dev Called before each deposit/withdraw to compound fees into the position
    /// @param poolKey The pool key
    /// @param lpToken The LP token address
    /// @return liquidityAdded The amount of liquidity added from fees
    function _autoCompoundFees(PoolKey memory poolKey, address lpToken) internal returns (uint128 liquidityAdded) {
        PoolId poolId = poolKey.toPoolId();
        (int32 tickLower, int32 tickUpper) = poolKey.config.stableswapActiveLiquidityTickRange();
        PositionId positionId = createPositionId({_salt: POSITION_SALT, _tickLower: tickLower, _tickUpper: tickUpper});

        // Collect fees from Core
        (uint128 fees0, uint128 fees1) = CORE.collectFees(poolKey, positionId);

        // Load pending fees (single SLOAD due to struct packing)
        PendingFees memory pending = pendingFees[poolId];

        // Add any pending fees from previous compounds that couldn't be used
        fees0 += pending.amount0;
        fees1 += pending.amount1;

        if (fees0 == 0 && fees1 == 0) return 0;

        // Deduct protocol fees BEFORE compounding (only on newly collected fees, not pending)
        (uint128 protocolFee0, uint128 protocolFee1) = _computeSwapProtocolFees(
            fees0 - pending.amount0, 
            fees1 - pending.amount1
        );

        if (protocolFee0 != 0 || protocolFee1 != 0) {
            CORE.updateSavedBalances(
                poolKey.token0, poolKey.token1, bytes32(0), int128(protocolFee0), int128(protocolFee1)
            );

            fees0 -= protocolFee0;
            fees1 -= protocolFee1;
        }

        if (fees0 == 0 && fees1 == 0) {
            // Clear pending fees if they were all used for protocol fees
            pendingFees[poolId] = PendingFees(0, 0);
            return 0;
        }

        // Calculate liquidity these fees can provide
        SqrtRatio sqrtRatio = CORE.poolState(poolId).sqrtRatio();
        liquidityAdded = maxLiquidity(sqrtRatio, tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper), fees0, fees1);

        if (liquidityAdded > 0) {
            // Add fees back to Core position (auto-compound)
            PoolBalanceUpdate balanceUpdate = CORE.updatePosition(poolKey, positionId, int128(liquidityAdded));

            // Calculate leftover fees that couldn't be compounded (due to one-sided liquidity)
            uint128 usedAmount0 = uint128(balanceUpdate.delta0());
            uint128 usedAmount1 = uint128(balanceUpdate.delta1());
            uint128 leftover0 = fees0 > usedAmount0 ? fees0 - usedAmount0 : 0;
            uint128 leftover1 = fees1 > usedAmount1 ? fees1 - usedAmount1 : 0;

            // Store leftover fees for next compound attempt (single SSTORE due to struct packing)
            pendingFees[poolId] = PendingFees(leftover0, leftover1);

            // Update LP token's total liquidity tracking
            StableswapLPToken(payable(lpToken)).incrementTotalLiquidity(liquidityAdded);

            emit FeesCompounded(poolKey, usedAmount0, usedAmount1, liquidityAdded);
        } else {
            // If we can't add any liquidity (e.g., price completely out of range),
            // store fees as pending for next attempt (they belong to LPs)
            pendingFees[poolId] = PendingFees(fees0, fees1);
        }

        return liquidityAdded;
    }

    /// @notice Handles deposit operation within lock callback
    /// @param caller The address initiating the deposit
    /// @param poolKey The pool key
    /// @param maxAmount0 Maximum token0 to deposit
    /// @param maxAmount1 Maximum token1 to deposit
    /// @param minLiquidity Minimum liquidity required
    /// @return lpTokensMinted LP tokens minted
    /// @return amount0 Actual token0 deposited
    /// @return amount1 Actual token1 deposited
    function _handleDeposit(
        address caller,
        PoolKey memory poolKey,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) internal returns (uint256 lpTokensMinted, uint128 amount0, uint128 amount1) {
        PoolId poolId = poolKey.toPoolId();
        address lpToken = getLPToken(poolKey);

        if (lpToken.code.length == 0) {
            revert LPTokenDoesNotExist();
        }

        // Get tick range from pool config
        (int32 tickLower, int32 tickUpper) = poolKey.config.stableswapActiveLiquidityTickRange();

        // Auto-compound fees before deposit
        _autoCompoundFees(poolKey, lpToken);

        // Calculate liquidity to add
        SqrtRatio sqrtRatio = CORE.poolState(poolId).sqrtRatio();
        uint128 liquidityToAdd =
            maxLiquidity(sqrtRatio, tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper), maxAmount0, maxAmount1);

        if (liquidityToAdd < minLiquidity) {
            revert DepositFailedDueToSlippage(liquidityToAdd, minLiquidity);
        }

        // Add liquidity to Core
        PositionId positionId = createPositionId({_salt: POSITION_SALT, _tickLower: tickLower, _tickUpper: tickUpper});

        PoolBalanceUpdate balanceUpdate = CORE.updatePosition(poolKey, positionId, int128(liquidityToAdd));

        // Get actual amounts used
        amount0 = uint128(balanceUpdate.delta0());
        amount1 = uint128(balanceUpdate.delta1());

        if (amount0 > maxAmount0 || amount1 > maxAmount1) {
            revert DepositFailedDueToSlippage(liquidityToAdd, minLiquidity);
        }

        // Mint LP tokens
        lpTokensMinted = StableswapLPToken(payable(lpToken)).mint(caller, liquidityToAdd);

        // Transfer tokens from caller
        if (poolKey.token0 != NATIVE_TOKEN_ADDRESS) {
            ACCOUNTANT.payTwoFrom(caller, poolKey.token0, poolKey.token1, amount0, amount1);
        } else {
            if (amount0 != 0) {
                SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount0);
            }
            if (amount1 != 0) {
                ACCOUNTANT.payFrom(caller, poolKey.token1, amount1);
            }
        }
    }

    /// @notice Handles withdraw operation within lock callback
    /// @param caller The address initiating the withdrawal
    /// @param poolKey The pool key
    /// @param lpTokensToWithdraw Amount of LP tokens to burn
    /// @return amount0 Amount of token0 withdrawn
    /// @return amount1 Amount of token1 withdrawn
    function _handleWithdraw(address caller, PoolKey memory poolKey, uint256 lpTokensToWithdraw)
        internal
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId poolId = poolKey.toPoolId();
        address lpToken = getLPToken(poolKey);

        if (lpToken.code.length == 0) {
            revert LPTokenDoesNotExist();
        }

        // Get tick range from pool config
        (int32 tickLower, int32 tickUpper) = poolKey.config.stableswapActiveLiquidityTickRange();

        // Auto-compound fees before withdrawal
        _autoCompoundFees(poolKey, lpToken);

        // Burn LP tokens and calculate liquidity to withdraw
        uint128 liquidityToWithdraw = StableswapLPToken(payable(lpToken)).burn(caller, lpTokensToWithdraw);

        // Remove liquidity from Core
        PositionId positionId = createPositionId({_salt: POSITION_SALT, _tickLower: tickLower, _tickUpper: tickUpper});

        PoolBalanceUpdate balanceUpdate = CORE.updatePosition(poolKey, positionId, -int128(liquidityToWithdraw));

        // Get amounts from withdrawal (negative deltas mean we receive tokens)
        // Note: fees were already collected and compounded in _autoCompoundFees above,
        // so user receives their proportional share of total liquidity (including compounded fees)
        amount0 = uint128(-balanceUpdate.delta0());
        amount1 = uint128(-balanceUpdate.delta1());

        // Transfer tokens to caller
        ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, caller, amount0, amount1);
    }

    /// @notice Computes protocol fees on swap fees
    /// @param amount0 Fee amount for token0
    /// @param amount1 Fee amount for token1
    /// @return protocolFee0 Protocol fee for token0
    /// @return protocolFee1 Protocol fee for token1
    function _computeSwapProtocolFees(uint128 amount0, uint128 amount1)
        internal
        view
        returns (uint128 protocolFee0, uint128 protocolFee1)
    {
        if (SWAP_PROTOCOL_FEE_X64 != 0) {
            protocolFee0 = computeFee(amount0, SWAP_PROTOCOL_FEE_X64);
            protocolFee1 = computeFee(amount1, SWAP_PROTOCOL_FEE_X64);
        }
    }

    /// @notice Handles lock callback data
    /// @param data Encoded operation data
    /// @return result Encoded result data
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_DEPOSIT) {
            (, address caller, PoolKey memory poolKey, uint128 maxAmount0, uint128 maxAmount1, uint128 minLiquidity) =
                abi.decode(data, (uint256, address, PoolKey, uint128, uint128, uint128));

            (uint256 lpTokensMinted, uint128 amount0, uint128 amount1) =
                _handleDeposit(caller, poolKey, maxAmount0, maxAmount1, minLiquidity);

            result = abi.encode(lpTokensMinted, amount0, amount1);
        } else if (callType == CALL_TYPE_WITHDRAW) {
            (, address caller, PoolKey memory poolKey, uint256 lpTokensToWithdraw) =
                abi.decode(data, (uint256, address, PoolKey, uint256));

            (uint128 amount0, uint128 amount1) = _handleWithdraw(caller, poolKey, lpTokensToWithdraw);

            result = abi.encode(amount0, amount1);
        } else if (callType == CALL_TYPE_WITHDRAW_PROTOCOL_FEES) {
            (, address token0, address token1, uint128 amount0, uint128 amount1, address recipient) =
                abi.decode(data, (uint256, address, address, uint128, uint128, address));

            CORE.updateSavedBalances(token0, token1, bytes32(0), -int128(amount0), -int128(amount1));
            ACCOUNTANT.withdrawTwo(token0, token1, recipient, amount0, amount1);

            result = "";
        }
    }
}
