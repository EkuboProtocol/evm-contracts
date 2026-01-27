// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {LPTokenMathLib} from "./libraries/LPTokenMathLib.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IStableswapLPPositions} from "./interfaces/IStableswapLPPositions.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolId} from "./types/poolId.sol";
import {PositionId, createPositionId} from "./types/positionId.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity} from "./math/liquidity.sol";
import {computeFee} from "./math/fee.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {ERC6909} from "solady/tokens/ERC6909.sol";

/// @title Stableswap LP Positions
/// @author Bogdan Sivochkin
/// @notice Manages fungible LP positions for stableswap pools with auto-compounding fees
/// @dev Uses ERC-6909 multi-token standard for gas-efficient LP token management
/// @dev Uses Uniswap V2-style auto-compounding where fees increase LP token value
contract StableswapLPPositions is
    ERC6909,
    BaseLocker,
    UsesCore,
    PayableMulticallable,
    Ownable,
    IStableswapLPPositions
{
    using CoreLib for *;
    using FlashAccountantLib for *;
    using LPTokenMathLib for *;

    /// @notice Position salt used for all stableswap LP positions
    /// @dev All positions managed by this contract use the same salt
    bytes24 private constant POSITION_SALT = bytes24(uint192(1));

    /// @notice Protocol fee rate for swaps (as a fraction of 2^64)
    uint64 public immutable SWAP_PROTOCOL_FEE_X64;

    /// @notice Call type constants for handleLockData
    uint256 private constant CALL_TYPE_DEPOSIT = 0;
    uint256 private constant CALL_TYPE_WITHDRAW = 1;
    uint256 private constant CALL_TYPE_WITHDRAW_PROTOCOL_FEES = 2;

    /// @notice Metadata for each pool's LP tokens
    struct PoolMetadata {
        uint128 totalLiquidity;
        uint128 totalSupply;
    }

    /// @notice Pool metadata indexed by token ID (poolId)
    mapping(uint256 => PoolMetadata) private _poolMetadata;

    /// @notice Addresses allowed to receive/send LP token transfers (e.g. ERC20 wrappers)
    mapping(address => bool) public allowedTransferTargets;

    /// @notice Error thrown when uint128 to int128 cast would overflow
    error CastOverflow();

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
    }

    /// @notice Sets whether an address is allowed as a transfer target (e.g. ERC20 wrapper)
    /// @param target The address to allow or disallow
    /// @param allowed Whether the address is allowed
    function setAllowedTransferTarget(address target, bool allowed) external onlyOwner {
        allowedTransferTargets[target] = allowed;
    }

    /// @notice Validates that the deadline has not passed
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    /// @notice Safely casts uint128 to int128, reverting on overflow
    /// @dev This overflow is extremely unlikely in practice (requires 2^127 wei of fees)
    /// @param value The uint128 value to cast
    /// @return The int128 representation
    function _safeInt128(uint128 value) internal pure returns (int128) {
        if (value > uint128(type(int128).max)) revert CastOverflow();
        return int128(value);
    }

    /// @notice ERC6909 hook to prevent direct LP token transfers
    /// @dev Direct transfers would bypass auto-compounding of fees, causing fee leakage
    /// @dev Allows minting (from == address(0)), burning (to == address(0)),
    ///      and transfers to/from allowed targets (e.g. ERC20 wrappers)
    function _beforeTokenTransfer(
        address from,
        address to,
        uint256 /* id */,
        uint256 /* amount */
    ) internal virtual override {
        if (from != address(0) && to != address(0)) {
            if (!allowedTransferTargets[from] && !allowedTransferTargets[to]) {
                revert DirectTransfersDisabled();
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        ERC6909 METADATA OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the name for LP tokens
    function name(uint256 /* id */) public pure override(ERC6909, IStableswapLPPositions) returns (string memory) {
        return "Ekubo Stableswap LP";
    }

    /// @notice Returns the symbol for LP tokens (same for all pools)
    function symbol(uint256 /* id */) public pure override(ERC6909, IStableswapLPPositions) returns (string memory) {
        return "EKUBO-SLP";
    }

    /// @notice Returns 18 decimals for all LP tokens
    function decimals(uint256 /* id */) public pure override(ERC6909, IStableswapLPPositions) returns (uint8) {
        return 18;
    }

    /// @notice Returns empty tokenURI (not used for LP tokens)
    function tokenURI(uint256 /* id */) public pure override returns (string memory) {
        return "";
    }

    /// @notice Returns the total supply of LP tokens for a pool
    /// @param id The token ID (poolId)
    function totalSupply(uint256 id) public view returns (uint256) {
        return _poolMetadata[id].totalSupply;
    }

    /// @notice Returns the total liquidity in a pool's position
    /// @param id The token ID (poolId)
    function totalLiquidity(uint256 id) external view returns (uint128) {
        return _poolMetadata[id].totalLiquidity;
    }

    /*//////////////////////////////////////////////////////////////
                        LP TOKEN MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Mints LP tokens in exchange for liquidity added to the position
    /// @dev OPTIMIZED: Uses LPTokenMathLib for calculation logic
    /// @param to The address to mint LP tokens to
    /// @param poolId The pool ID
    /// @param liquidityAdded The amount of liquidity being added to the Core position
    /// @return lpTokensMinted The amount of LP tokens minted
    function _mintLPTokens(
        address to,
        PoolId poolId,
        uint128 liquidityAdded
    ) internal returns (uint256 lpTokensMinted) {
        uint256 tokenId = uint256(PoolId.unwrap(poolId));
        PoolMetadata storage metadata = _poolMetadata[tokenId];

        // Use library for calculation
        (uint256 lpTokensToMint, uint256 lpTokensToBurn, uint256 newTotalSupply) =
            LPTokenMathLib.calculateMint(
                uint256(metadata.totalSupply),
                metadata.totalLiquidity,
                liquidityAdded
            );

        // Mint tokens
        if (lpTokensToBurn > 0) {
            // First deposit - burn minimum liquidity
            _mint(address(0xdead), tokenId, lpTokensToBurn);
        }
        _mint(to, tokenId, lpTokensToMint);

        // Update metadata
        metadata.totalSupply = uint128(newTotalSupply);
        metadata.totalLiquidity = LPTokenMathLib.addLiquidity(metadata.totalLiquidity, liquidityAdded);

        return lpTokensToMint;
    }

    /// @notice Burns LP tokens and calculates proportional liquidity to remove
    /// @dev OPTIMIZED: Uses LPTokenMathLib for calculation logic
    /// @param from The address to burn LP tokens from
    /// @param poolId The pool ID
    /// @param lpTokensToBurn The amount of LP tokens to burn
    /// @return liquidityToRemove The amount of liquidity to remove from the Core position
    function _burnLPTokens(
        address from,
        PoolId poolId,
        uint256 lpTokensToBurn
    ) internal returns (uint128 liquidityToRemove) {
        uint256 tokenId = uint256(PoolId.unwrap(poolId));
        PoolMetadata storage metadata = _poolMetadata[tokenId];

        // Use library for calculation
        (uint128 liquidity, uint256 newTotalSupply) =
            LPTokenMathLib.calculateBurn(
                uint256(metadata.totalSupply),
                metadata.totalLiquidity,
                lpTokensToBurn
            );

        liquidityToRemove = liquidity;

        // Burn tokens
        _burn(from, tokenId, lpTokensToBurn);

        // Update metadata
        metadata.totalSupply = uint128(newTotalSupply);
        metadata.totalLiquidity = LPTokenMathLib.removeLiquidity(metadata.totalLiquidity, liquidityToRemove);

        return liquidityToRemove;
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC INTERFACE
    //////////////////////////////////////////////////////////////*/

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

    /// @notice Gets the pending fees that couldn't be compounded for a pool
    /// @dev Reads directly from Core's savedBalances - no local storage
    /// @param poolKey The pool key
    /// @return amount0 Amount of pending token0 fees
    /// @return amount1 Amount of pending token1 fees
    function getPendingFees(PoolKey memory poolKey) external view returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = CORE.savedBalances(address(this), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Auto-compounds pending fees by collecting and reinvesting them
    /// @param poolKey The pool key
    /// @param poolId The pool ID (passed to avoid redundant keccak)
    /// @param tokenId The token ID (for metadata lookup)
    /// @param sqrtRatio Current sqrt ratio (passed to avoid redundant query)
    /// @param tickLower Lower tick of the position
    /// @param tickUpper Upper tick of the position
    /// @return liquidityAdded The amount of liquidity added from fees
    /// @return positionId The position ID (returned to avoid redundant keccak in callers)
    function _autoCompoundFees(
        PoolKey memory poolKey,
        PoolId poolId,
        uint256 tokenId,
        SqrtRatio sqrtRatio,
        int32 tickLower,
        int32 tickUpper
    ) internal returns (uint128 liquidityAdded, PositionId positionId) {
        positionId = createPositionId({_salt: POSITION_SALT, _tickLower: tickLower, _tickUpper: tickUpper});

        // Step 1: Collect NEW fees from Core
        (uint128 newFees0, uint128 newFees1) = CORE.collectFees(poolKey, positionId);

        // Step 2: Deduct protocol fees IMMEDIATELY from new fees (before any other accounting)
        (uint128 protocolFee0, uint128 protocolFee1) = _computeSwapProtocolFees(newFees0, newFees1);

        // Step 3: Save protocol fees to their dedicated salt (bytes32(0))
        if (protocolFee0 != 0 || protocolFee1 != 0) {
            CORE.updateSavedBalances(
                poolKey.token0, poolKey.token1, bytes32(0),  // Protocol fees use salt = 0
                _safeInt128(protocolFee0), _safeInt128(protocolFee1)
            );
        }

        // Step 4: Calculate net new fees (after protocol fee deduction)
        uint128 netNewFees0 = newFees0 - protocolFee0;
        uint128 netNewFees1 = newFees1 - protocolFee1;

        // Step 5: Load pending fees (these ALREADY had protocol fees deducted when first collected)
        (uint128 pending0, uint128 pending1) = CORE.savedBalances(
            address(this), poolKey.token0, poolKey.token1, PoolId.unwrap(poolId)
        );

        // Step 6: Total fees available for compounding (all net of protocol fees)
        uint128 fees0 = netNewFees0 + pending0;
        uint128 fees1 = netNewFees1 + pending1;

        if (fees0 == 0 && fees1 == 0) return (0, positionId);

        // Step 7: Calculate liquidity from NET fees (using passed sqrtRatio)
        liquidityAdded = maxLiquidity(sqrtRatio, tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper), fees0, fees1);

        // Step 8: Compound if possible, track leftovers
        uint128 leftover0 = fees0;
        uint128 leftover1 = fees1;

        if (liquidityAdded > 0) {
            PoolBalanceUpdate balanceUpdate = CORE.updatePosition(poolKey, positionId, _safeInt128(liquidityAdded));

            uint128 usedAmount0 = uint128(balanceUpdate.delta0());
            uint128 usedAmount1 = uint128(balanceUpdate.delta1());
            leftover0 = fees0 > usedAmount0 ? fees0 - usedAmount0 : 0;
            leftover1 = fees1 > usedAmount1 ? fees1 - usedAmount1 : 0;

            _poolMetadata[tokenId].totalLiquidity += liquidityAdded;

            emit FeesCompounded(poolKey, usedAmount0, usedAmount1, liquidityAdded);
        }

        // Step 9: Update pending fees (single path for both compound and no-compound)
        int128 netPendingDelta0 = _safeInt128(leftover0) - _safeInt128(pending0);
        int128 netPendingDelta1 = _safeInt128(leftover1) - _safeInt128(pending1);

        if (netPendingDelta0 != 0 || netPendingDelta1 != 0) {
            CORE.updateSavedBalances(
                poolKey.token0, poolKey.token1, PoolId.unwrap(poolId),
                netPendingDelta0, netPendingDelta1
            );
        }
    }

    /// @notice Handles deposit operation within lock callback
    /// @dev OPTIMIZED: Calculates sqrtRatio and tick range once, passes to _autoCompoundFees
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
        uint256 tokenId = uint256(PoolId.unwrap(poolId));

        // Emit event on first deposit (totalSupply == 0 means uninitialized)
        if (_poolMetadata[tokenId].totalSupply == 0) {
            emit PoolInitialized(tokenId, poolKey.token0, poolKey.token1);
        }

        // OPTIMIZATION: Get tick range and sqrtRatio once
        (int32 tickLower, int32 tickUpper) = poolKey.config.stableswapActiveLiquidityTickRange();
        SqrtRatio sqrtRatio = CORE.poolState(poolId).sqrtRatio();

        // Auto-compound fees before deposit (returns positionId to avoid redundant keccak)
        (, PositionId positionId) = _autoCompoundFees(poolKey, poolId, tokenId, sqrtRatio, tickLower, tickUpper);

        // Calculate liquidity to add (reuse sqrtRatio)
        uint128 liquidityToAdd =
            maxLiquidity(sqrtRatio, tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper), maxAmount0, maxAmount1);

        if (liquidityToAdd < minLiquidity) {
            revert DepositFailedDueToSlippage(liquidityToAdd, minLiquidity);
        }

        // Add liquidity to Core
        PoolBalanceUpdate balanceUpdate = CORE.updatePosition(poolKey, positionId, _safeInt128(liquidityToAdd));

        // Get actual amounts used
        amount0 = uint128(balanceUpdate.delta0());
        amount1 = uint128(balanceUpdate.delta1());

        if (amount0 > maxAmount0 || amount1 > maxAmount1) {
            revert DepositFailedDueToSlippage(liquidityToAdd, minLiquidity);
        }

        // Mint ERC6909 LP tokens
        lpTokensMinted = _mintLPTokens(caller, poolId, liquidityToAdd);

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
    /// @dev OPTIMIZED: Calculates sqrtRatio and tick range once, passes to _autoCompoundFees
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
        uint256 tokenId = uint256(PoolId.unwrap(poolId));

        // Verify pool exists (totalSupply > 0 means initialized)
        if (_poolMetadata[tokenId].totalSupply == 0) {
            revert LPTokenDoesNotExist();
        }

        // OPTIMIZATION: Get tick range and sqrtRatio once
        (int32 tickLower, int32 tickUpper) = poolKey.config.stableswapActiveLiquidityTickRange();
        SqrtRatio sqrtRatio = CORE.poolState(poolId).sqrtRatio();

        // Auto-compound fees before withdrawal (returns positionId to avoid redundant keccak)
        (, PositionId positionId) = _autoCompoundFees(poolKey, poolId, tokenId, sqrtRatio, tickLower, tickUpper);

        // Burn ERC6909 LP tokens and calculate liquidity to withdraw
        uint128 liquidityToWithdraw = _burnLPTokens(caller, poolId, lpTokensToWithdraw);

        // Remove liquidity from Core
        PoolBalanceUpdate balanceUpdate = CORE.updatePosition(poolKey, positionId, -_safeInt128(liquidityToWithdraw));

        // Get amounts from withdrawal (negative deltas mean we receive tokens)
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

            CORE.updateSavedBalances(token0, token1, bytes32(0), -_safeInt128(amount0), -_safeInt128(amount1));
            ACCOUNTANT.withdrawTwo(token0, token1, recipient, amount0, amount1);
        }
    }
}
