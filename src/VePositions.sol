// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseNonfungibleToken} from "./base/BaseNonfungibleToken.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IPositions} from "./interfaces/IPositions.sol";
import {IVeGauge} from "./interfaces/IVeGauge.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {computeFee} from "./math/fee.sol";
import {maxLiquidity, liquidityDeltaToAmountDelta} from "./math/liquidity.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {FeesPerLiquidity} from "./types/feesPerLiquidity.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {PoolId} from "./types/poolId.sol";
import {PoolKey} from "./types/poolKey.sol";
import {Position} from "./types/position.sol";
import {PositionId, createPositionId} from "./types/positionId.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";

/// @notice Position manager for ve gauges. LP swap fees are routed to feeReceiver before every position update.
contract VePositions is IPositions, UsesCore, PayableMulticallable, BaseLocker, BaseNonfungibleToken {
    using CoreLib for *;
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_DEPOSIT = 0;
    uint256 private constant CALL_TYPE_WITHDRAW = 1;
    uint256 private constant CALL_TYPE_WITHDRAW_PROTOCOL_FEES = 2;

    uint64 public immutable SWAP_PROTOCOL_FEE_X64;
    uint64 public immutable WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR;

    address public feeReceiver;

    event FeeReceiverSet(address indexed feeReceiver);
    event PositionFeesRouted(uint256 indexed id, PoolId indexed poolId, uint128 amount0, uint128 amount1);

    error FeeReceiverNotSet();

    constructor(
        ICore core,
        address owner,
        address initialFeeReceiver,
        uint64 swapProtocolFeeX64,
        uint64 withdrawalProtocolFeeDenominator
    ) BaseNonfungibleToken(owner) BaseLocker(core) UsesCore(core) {
        feeReceiver = initialFeeReceiver;
        SWAP_PROTOCOL_FEE_X64 = swapProtocolFeeX64;
        WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR = withdrawalProtocolFeeDenominator;
    }

    function setFeeReceiver(address newFeeReceiver) external onlyOwner {
        feeReceiver = newFeeReceiver;
        emit FeeReceiverSet(newFeeReceiver);
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
        (liquidity, amount0, amount1) = abi.decode(
            lock(
                abi.encode(
                    CALL_TYPE_DEPOSIT,
                    msg.sender,
                    id,
                    poolKey,
                    tickLower,
                    tickUpper,
                    maxAmount0,
                    maxAmount1,
                    minLiquidity
                )
            ),
            (uint128, uint128, uint128)
        );
    }

    /// @inheritdoc IPositions
    function collectFees(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        public
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = collectFees(id, poolKey, tickLower, tickUpper, feeReceiver);
    }

    /// @inheritdoc IPositions
    function collectFees(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper, address)
        public
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = abi.decode(
            lock(abi.encode(CALL_TYPE_WITHDRAW, id, poolKey, tickLower, tickUpper, uint128(0), feeReceiver, true)),
            (uint128, uint128)
        );
    }

    /// @inheritdoc IPositions
    function withdraw(
        uint256 id,
        PoolKey memory poolKey,
        int32 tickLower,
        int32 tickUpper,
        uint128 liquidity,
        address recipient,
        bool
    ) public payable authorizedForNft(id) returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = abi.decode(
            lock(abi.encode(CALL_TYPE_WITHDRAW, id, poolKey, tickLower, tickUpper, liquidity, recipient, false)),
            (uint128, uint128)
        );
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

    function handleLockData(uint256 id, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_DEPOSIT) {
            (
                ,
                address caller,
                uint256 positionNftId,
                PoolKey memory poolKey,
                int32 tickLower,
                int32 tickUpper,
                uint128 maxAmount0,
                uint128 maxAmount1,
                uint128 minLiquidity
            ) = abi.decode(data, (uint256, address, uint256, PoolKey, int32, int32, uint128, uint128, uint128));

            SqrtRatio sqrtRatio = CORE.poolState(poolKey.toPoolId()).sqrtRatio();
            uint128 liquidity =
                maxLiquidity(sqrtRatio, tickToSqrtRatio(tickLower), tickToSqrtRatio(tickUpper), maxAmount0, maxAmount1);

            if (liquidity < minLiquidity) revert DepositFailedDueToSlippage(liquidity, minLiquidity);
            if (liquidity > uint128(type(int128).max)) revert DepositOverflow();

            _collectAndRouteFees(positionNftId, poolKey, tickLower, tickUpper);

            PoolBalanceUpdate balanceUpdate = CORE.updatePosition(
                poolKey,
                createPositionId({
                    _salt: bytes24(uint192(positionNftId)), _tickLower: tickLower, _tickUpper: tickUpper
                }),
                int128(liquidity)
            );

            uint128 amount0 = uint128(balanceUpdate.delta0());
            uint128 amount1 = uint128(balanceUpdate.delta1());

            if (amount0 > maxAmount0 || amount1 > maxAmount1) revert DepositFailedDueToPriceMovement();

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
                ,
                uint256 positionNftId,
                PoolKey memory poolKey,
                int32 tickLower,
                int32 tickUpper,
                uint128 liquidity,
                address recipient,
            ) = abi.decode(data, (uint256, uint256, PoolKey, int32, int32, uint128, address, bool));

            if (liquidity > uint128(type(int128).max)) revert WithdrawOverflow();

            _collectAndRouteFees(positionNftId, poolKey, tickLower, tickUpper);

            uint128 amount0;
            uint128 amount1;

            if (liquidity != 0) {
                PoolBalanceUpdate balanceUpdate = CORE.updatePosition(
                    poolKey,
                    createPositionId({
                        _salt: bytes24(uint192(positionNftId)), _tickLower: tickLower, _tickUpper: tickUpper
                    }),
                    -int128(liquidity)
                );

                uint128 withdrawnAmount0 = uint128(-balanceUpdate.delta0());
                uint128 withdrawnAmount1 = uint128(-balanceUpdate.delta1());

                (uint128 withdrawalFee0, uint128 withdrawalFee1) =
                    _computeWithdrawalProtocolFees(poolKey, withdrawnAmount0, withdrawnAmount1);

                if (withdrawalFee0 != 0 || withdrawalFee1 != 0) {
                    CORE.updateSavedBalances(
                        poolKey.token0, poolKey.token1, bytes32(0), int128(withdrawalFee0), int128(withdrawalFee1)
                    );
                }

                amount0 = withdrawnAmount0 - withdrawalFee0;
                amount1 = withdrawnAmount1 - withdrawalFee1;
            }

            ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, recipient, amount0, amount1);
            result = abi.encode(amount0, amount1);
        } else if (callType == CALL_TYPE_WITHDRAW_PROTOCOL_FEES) {
            (, address token0, address token1, uint128 amount0, uint128 amount1, address recipient) =
                abi.decode(data, (uint256, address, address, uint128, uint128, address));

            CORE.updateSavedBalances(token0, token1, bytes32(0), -int256(uint256(amount0)), -int256(uint256(amount1)));
            ACCOUNTANT.withdrawTwo(token0, token1, recipient, amount0, amount1);
        } else {
            id;
            revert();
        }
    }

    function _collectAndRouteFees(uint256 id, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        private
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = CORE.collectFees(
            poolKey, createPositionId({_salt: bytes24(uint192(id)), _tickLower: tickLower, _tickUpper: tickUpper})
        );

        (uint128 swapProtocolFee0, uint128 swapProtocolFee1) = _computeSwapProtocolFees(amount0, amount1);
        if (swapProtocolFee0 != 0 || swapProtocolFee1 != 0) {
            CORE.updateSavedBalances(
                poolKey.token0, poolKey.token1, bytes32(0), int128(swapProtocolFee0), int128(swapProtocolFee1)
            );

            unchecked {
                amount0 -= swapProtocolFee0;
                amount1 -= swapProtocolFee1;
            }
        }

        if (amount0 != 0 || amount1 != 0) {
            address receiver = feeReceiver;
            if (receiver == address(0)) revert FeeReceiverNotSet();

            ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, receiver, amount0, amount1);
            IVeGauge(receiver).notifyPoolFees(poolKey, amount0, amount1);

            emit PositionFeesRouted(id, poolKey.toPoolId(), amount0, amount1);
        }
    }

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

    function _computeWithdrawalProtocolFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1)
        internal
        view
        returns (uint128 protocolFee0, uint128 protocolFee1)
    {
        uint64 fee = poolKey.config.fee();
        if (fee != 0 && WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR != 0) {
            protocolFee0 = computeFee(amount0, fee / WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR);
            protocolFee1 = computeFee(amount1, fee / WITHDRAWAL_PROTOCOL_FEE_DENOMINATOR);
        }
    }
}
