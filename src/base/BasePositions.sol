// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./BaseLocker.sol";
import {UsesCore} from "./UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {IBaseNonfungibleToken} from "../interfaces/IBaseNonfungibleToken.sol";
import {IPositions} from "../interfaces/IPositions.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionId, createPositionId} from "../types/positionId.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {Position} from "../types/position.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {maxLiquidity, liquidityDeltaToAmountDelta} from "../math/liquidity.sol";
import {PayableMulticallable} from "./PayableMulticallable.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BaseNonfungibleToken} from "./BaseNonfungibleToken.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";

/// @title Base Positions Contract
/// @author Moody Salem <moody@ekubo.org>
/// @notice Abstract base contract for tracking liquidity positions in Ekubo Protocol as NFTs
/// @dev Provides core position management functionality with abstract protocol fee collection methods
abstract contract BasePositions is IPositions, UsesCore, PayableMulticallable, BaseLocker, BaseNonfungibleToken {
    using CoreLib for *;
    using FlashAccountantLib for *;

    /// @notice Constructs the BasePositions contract
    /// @param core The core contract instance
    /// @param owner The owner of the contract (for access control)
    constructor(ICore core, address owner) BaseNonfungibleToken(owner) BaseLocker(core) UsesCore(core) {}

    uint256 private constant CALL_TYPE_DEPOSIT = 0;
    uint256 private constant CALL_TYPE_WITHDRAW = 1;
    uint256 private constant CALL_TYPE_WITHDRAW_PROTOCOL_FEES = 2;

    /// @inheritdoc BaseNonfungibleToken
    /// @dev Restricts generated token ids to 192 bits so the complete id is used as the Core position salt.
    function saltToId(address minter, bytes32 salt)
        public
        view
        override(BaseNonfungibleToken, IBaseNonfungibleToken)
        returns (uint256 id)
    {
        id = uint192(super.saltToId(minter, salt));
    }

    /// @inheritdoc IPositions
    function getPositionFeesAndLiquidity(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        external
        view
        returns (uint128 liquidity, uint128 principal0, uint128 principal1, uint128 fees0, uint128 fees1)
    {
        PoolId poolId = poolKey.toPoolId();
        SqrtRatio sqrtRatio = CORE.poolState(poolId).sqrtRatio();
        PositionId positionId =
            createPositionId({_salt: bytes24(uint192(id)), _tickLower: tickLower, _tickUpper: tickUpper});
        Position memory position = CORE.poolPositions(poolId, address(this), positionId);

        liquidity = position.liquidity;

        // the sqrt ratio may be 0 (because the pool is uninitialized) but this is
        // fine since amount0Delta isn't called with it in this case
        (int128 delta0, int128 delta1) = liquidityDeltaToAmountDelta(
            sqrtRatio, -SafeCastLib.toInt128(position.liquidity), tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper)
        );

        (principal0, principal1) = (uint128(-delta0), uint128(-delta1));

        FeesPerLiquidity memory feesPerLiquidityInside = poolKey.config.isStableswap()
            ? CORE.getPoolFeesPerLiquidity(poolId)
            : CORE.getPoolFeesPerLiquidityInside(poolId, tickLower, tickUpper);
        (fees0, fees1) = position.fees(feesPerLiquidityInside);
    }

    /// @inheritdoc IPositions
    function deposit(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) public payable authorizedForNft(id) returns (uint128 liquidity, uint128 amount0, uint128 amount1) {
        (liquidity, amount0, amount1) =
            _lockDeposit(id, poolKey, tickLower, tickUpper, maxAmount0, maxAmount1, minLiquidity);
    }

    /// @inheritdoc IPositions
    function collectFees(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        public
        payable
        authorizedForNft(id)
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = collectFees(id, poolKey, tickLower, tickUpper, msg.sender);
    }

    /// @inheritdoc IPositions
    function collectFees(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper, address recipient)
        public
        payable
        authorizedForNft(id)
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = withdraw(id, poolKey, tickLower, tickUpper, 0, recipient, true);
    }

    /// @inheritdoc IPositions
    function withdraw(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 liquidity,
        address recipient,
        bool withFees
    ) public payable authorizedForNft(id) returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = _lockWithdraw(id, poolKey, tickLower, tickUpper, liquidity, recipient, withFees);
    }

    /// @inheritdoc IPositions
    function withdraw(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper, uint128 liquidity)
        public
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = withdraw(id, poolKey, tickLower, tickUpper, liquidity, address(msg.sender), true);
    }

    /// @inheritdoc IPositions
    function maybeInitializePool(PoolKey memory poolKey, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio)
    {
        // the before update position hook shouldn't be taken into account here
        sqrtRatio = CORE.poolState(poolKey.toPoolId()).sqrtRatio();
        if (sqrtRatio.isZero()) {
            initialized = true;
            sqrtRatio = CORE.initializePool(poolKey, tick);
        }
    }

    /// @inheritdoc IPositions
    function mintAndDeposit(
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1) {
        id = mint();
        (liquidity, amount0, amount1) = deposit(id, poolKey, tickLower, tickUpper, maxAmount0, maxAmount1, minLiquidity);
    }

    /// @inheritdoc IPositions
    function mintAndDepositWithSalt(
        bytes32 salt,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1) {
        id = mint(salt);
        (liquidity, amount0, amount1) = deposit(id, poolKey, tickLower, tickUpper, maxAmount0, maxAmount1, minLiquidity);
    }

    /// @inheritdoc IPositions
    function withdrawProtocolFees(address token0, address token1, uint128 amount0, uint128 amount1, address recipient)
        external
        payable
        onlyOwner
    {
        lock(abi.encode(CALL_TYPE_WITHDRAW_PROTOCOL_FEES, token0, token1, amount0, amount1, recipient));
    }

    /// @inheritdoc IPositions
    function getProtocolFees(address token0, address token1) external view returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = CORE.savedBalances(address(this), token0, token1, bytes32(0));
    }

    /// @notice Handles protocol fee collection during fee collection
    /// @dev Abstract method that must be implemented by concrete contracts
    /// @param poolKey The pool key for the position
    /// @param amount0 The amount of token0 fees collected before protocol fee deduction
    /// @param amount1 The amount of token1 fees collected before protocol fee deduction
    /// @return protocolFee0 The amount of token0 protocol fees to collect
    /// @return protocolFee1 The amount of token1 protocol fees to collect
    function _computeSwapProtocolFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1)
        internal
        view
        virtual
        returns (uint128 protocolFee0, uint128 protocolFee1);

    /// @notice Handles protocol fee collection during liquidity withdrawal
    /// @dev Abstract method that must be implemented by concrete contracts
    /// @param poolKey The pool key for the position
    /// @param amount0 The amount of token0 being withdrawn before protocol fee deduction
    /// @param amount1 The amount of token1 being withdrawn before protocol fee deduction
    /// @return protocolFee0 The amount of token0 protocol fees to collect
    /// @return protocolFee1 The amount of token1 protocol fees to collect
    function _computeWithdrawalProtocolFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1)
        internal
        view
        virtual
        returns (uint128 protocolFee0, uint128 protocolFee1);

    /// @notice Decodes the fixed-size deposit lock payload without copying its pool key.
    /// @dev Preserves the length check and the canonical address, int32 and uint128 checks performed by
    ///   `abi.decode(data, (uint256, address, uint256, PoolKey, int32, int32, uint128, uint128, uint128))`. The returned
    ///   pool key points into `data`, so `data` must not be modified while the pool key is in use.
    function _decodeDeposit(bytes memory data)
        private
        pure
        returns (
            address depositor,
            uint256 id,
            PoolKey memory poolKey,
            int32 tickLower,
            int32 tickUpper,
            uint128 maxAmount0,
            uint128 maxAmount1,
            uint128 minLiquidity
        )
    {
        assembly ("memory-safe") {
            if lt(mload(data), 0x160) { revert(0, 0) }

            depositor := mload(add(data, 0x40))
            id := mload(add(data, 0x60))
            poolKey := add(data, 0x80)
            tickLower := mload(add(data, 0xe0))
            tickUpper := mload(add(data, 0x100))
            maxAmount0 := mload(add(data, 0x120))
            maxAmount1 := mload(add(data, 0x140))
            minLiquidity := mload(add(data, 0x160))

            if or(
                or(
                    shr(160, or(depositor, or(mload(poolKey), mload(add(poolKey, 0x20))))),
                    shr(128, or(maxAmount0, or(maxAmount1, minLiquidity)))
                ),
                or(xor(tickLower, signextend(3, tickLower)), xor(tickUpper, signextend(3, tickUpper)))
            ) { revert(0, 0) }
        }
    }

    /// @notice Decodes the fixed-size withdraw lock payload without copying its pool key.
    /// @dev Preserves the length check and the canonical address, int32, uint128 and bool checks performed by
    ///   `abi.decode(data, (uint256, uint256, PoolKey, int32, int32, uint128, address, bool))`. The returned pool key
    ///   points into `data`, so `data` must not be modified while the pool key is in use.
    function _decodeWithdraw(bytes memory data)
        private
        pure
        returns (
            uint256 id,
            PoolKey memory poolKey,
            int32 tickLower,
            int32 tickUpper,
            uint128 liquidity,
            address recipient,
            bool withFees
        )
    {
        assembly ("memory-safe") {
            if lt(mload(data), 0x140) { revert(0, 0) }

            id := mload(add(data, 0x40))
            poolKey := add(data, 0x60)
            tickLower := mload(add(data, 0xc0))
            tickUpper := mload(add(data, 0xe0))
            liquidity := mload(add(data, 0x100))
            recipient := mload(add(data, 0x120))
            withFees := mload(add(data, 0x140))

            if or(
                or(
                    shr(160, or(recipient, or(mload(poolKey), mload(add(poolKey, 0x20))))),
                    or(shr(128, liquidity), shr(1, withFees))
                ),
                or(xor(tickLower, signextend(3, tickLower)), xor(tickUpper, signextend(3, tickUpper)))
            ) { revert(0, 0) }
        }
    }

    /// @dev Equivalent to decoding
    ///   `lock(abi.encode(CALL_TYPE_DEPOSIT, msg.sender, id, poolKey, tickLower, tickUpper, maxAmount0, maxAmount1,
    ///   minLiquidity))` as `(uint128, uint128, uint128)`, but writes the call data once, directly into the buffer
    ///   that is sent to the accountant, and reads the result words without copying the return data into a new
    ///   allocation.
    function _lockDeposit(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) private returns (uint128 liquidity, uint128 amount0, uint128 amount1) {
        address target = address(ACCOUNTANT);

        assembly ("memory-safe") {
            let free := mload(0x40)

            // Selector of lock(), followed by the call type, the depositor and the position id
            mstore(free, shl(224, 0xf83d08ba))
            mstore(add(free, 4), CALL_TYPE_DEPOSIT)
            mstore(add(free, 36), caller())
            mstore(add(free, 68), id)

            // The three words of the pool key, then the remaining arguments
            mcopy(add(free, 100), poolKey, 96)
            mstore(add(free, 196), tickLower)
            mstore(add(free, 228), tickUpper)
            mstore(add(free, 260), maxAmount0)
            mstore(add(free, 292), maxAmount1)
            mstore(add(free, 324), minLiquidity)

            // If the call failed, pass through the revert
            if iszero(call(gas(), target, 0, free, 356, free, 96)) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }

            liquidity := mload(free)
            amount0 := mload(add(free, 32))
            amount1 := mload(add(free, 64))

            // A result shorter than three words, or a word that is not a uint128, reverts with no data, as
            // decoding it does
            if or(lt(returndatasize(), 96), shr(128, or(or(liquidity, amount0), amount1))) { revert(0, 0) }
        }
    }

    /// @dev Equivalent to decoding
    ///   `lock(abi.encode(CALL_TYPE_WITHDRAW, id, poolKey, tickLower, tickUpper, liquidity, recipient, withFees))`
    ///   as `(uint128, uint128)`, but writes the call data once, directly into the buffer that is sent to the
    ///   accountant, and reads the result words without copying the return data into a new allocation.
    function _lockWithdraw(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 liquidity,
        address recipient,
        bool withFees
    ) private returns (uint128 amount0, uint128 amount1) {
        address target = address(ACCOUNTANT);

        assembly ("memory-safe") {
            let free := mload(0x40)

            // Selector of lock(), followed by the call type and the position id
            mstore(free, shl(224, 0xf83d08ba))
            mstore(add(free, 4), CALL_TYPE_WITHDRAW)
            mstore(add(free, 36), id)

            // The three words of the pool key, then the remaining arguments
            mcopy(add(free, 68), poolKey, 96)
            mstore(add(free, 164), tickLower)
            mstore(add(free, 196), tickUpper)
            mstore(add(free, 228), liquidity)
            mstore(add(free, 260), recipient)
            mstore(add(free, 292), withFees)

            // If the call failed, pass through the revert
            if iszero(call(gas(), target, 0, free, 324, free, 64)) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }

            amount0 := mload(free)
            amount1 := mload(add(free, 32))

            // A result shorter than two words, or a word that is not a uint128, reverts with no data, as decoding it
            // does
            if or(lt(returndatasize(), 64), shr(128, or(amount0, amount1))) { revert(0, 0) }
        }
    }

    /// @notice Handles lock callback data for position operations
    /// @dev Internal function that processes different types of position operations
    /// @param data Encoded operation data
    /// @return result Encoded result data
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_DEPOSIT) {
            (
                address caller,
                uint256 id,
                PoolKey memory poolKey,
                int32 tickLower,
                int32 tickUpper,
                uint128 maxAmount0,
                uint128 maxAmount1,
                uint128 minLiquidity
            ) = _decodeDeposit(data);

            SqrtRatio sqrtRatio = CORE.poolState(poolKey.toPoolId()).sqrtRatio();

            uint128 liquidity =
                maxLiquidity(sqrtRatio, tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper), maxAmount0, maxAmount1);

            if (liquidity < minLiquidity) {
                revert DepositFailedDueToSlippage(liquidity, minLiquidity);
            }

            if (liquidity > uint128(type(int128).max)) {
                revert DepositOverflow();
            }

            PoolBalanceUpdate balanceUpdate = CORE.updatePosition(
                poolKey,
                createPositionId({_salt: bytes24(uint192(id)), _tickLower: tickLower, _tickUpper: tickUpper}),
                int128(liquidity)
            );

            uint128 amount0 = uint128(balanceUpdate.delta0());
            uint128 amount1 = uint128(balanceUpdate.delta1());

            if (amount0 > maxAmount0 || amount1 > maxAmount1) revert DepositFailedDueToPriceMovement();

            // Use multi-token payment for ERC20-only pools, fall back to individual payments for native token pools
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

            result = abi.encode(liquidity, amount0, amount1);
        } else if (callType == CALL_TYPE_WITHDRAW) {
            (
                uint256 id,
                PoolKey memory poolKey,
                int32 tickLower,
                int32 tickUpper,
                uint128 liquidity,
                address recipient,
                bool withFees
            ) = _decodeWithdraw(data);

            if (liquidity > uint128(type(int128).max)) revert WithdrawOverflow();

            uint128 amount0;
            uint128 amount1;

            // collect first in case we are withdrawing the entire amount
            if (withFees) {
                (amount0, amount1) = CORE.collectFees(
                    poolKey,
                    createPositionId({_salt: bytes24(uint192(id)), _tickLower: tickLower, _tickUpper: tickUpper})
                );

                // Collect swap protocol fees
                (uint128 swapProtocolFee0, uint128 swapProtocolFee1) =
                    _computeSwapProtocolFees(poolKey, amount0, amount1);

                if (swapProtocolFee0 != 0 || swapProtocolFee1 != 0) {
                    CORE.updateSavedBalances(
                        poolKey.token0, poolKey.token1, bytes32(0), int128(swapProtocolFee0), int128(swapProtocolFee1)
                    );

                    amount0 -= swapProtocolFee0;
                    amount1 -= swapProtocolFee1;
                }
            }

            if (liquidity != 0) {
                PoolBalanceUpdate balanceUpdate = CORE.updatePosition(
                    poolKey,
                    createPositionId({_salt: bytes24(uint192(id)), _tickLower: tickLower, _tickUpper: tickUpper}),
                    -int128(liquidity)
                );

                uint128 withdrawnAmount0 = uint128(-balanceUpdate.delta0());
                uint128 withdrawnAmount1 = uint128(-balanceUpdate.delta1());

                // Collect withdrawal protocol fees
                (uint128 withdrawalFee0, uint128 withdrawalFee1) =
                    _computeWithdrawalProtocolFees(poolKey, withdrawnAmount0, withdrawnAmount1);

                if (withdrawalFee0 != 0 || withdrawalFee1 != 0) {
                    // we know cast won't overflow because delta0 and delta1 were originally int128
                    CORE.updateSavedBalances(
                        poolKey.token0, poolKey.token1, bytes32(0), int128(withdrawalFee0), int128(withdrawalFee1)
                    );
                }

                amount0 += withdrawnAmount0 - withdrawalFee0;
                amount1 += withdrawnAmount1 - withdrawalFee1;
            }

            ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, recipient, amount0, amount1);

            result = abi.encode(amount0, amount1);
        } else if (callType == CALL_TYPE_WITHDRAW_PROTOCOL_FEES) {
            (, address token0, address token1, uint128 amount0, uint128 amount1, address recipient) =
                abi.decode(data, (uint256, address, address, uint128, uint128, address));

            CORE.updateSavedBalances(token0, token1, bytes32(0), -int256(uint256(amount0)), -int256(uint256(amount1)));
            ACCOUNTANT.withdrawTwo(token0, token1, recipient, amount0, amount1);
        } else {
            // Will never actually happen
            revert();
        }
    }
}
