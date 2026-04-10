// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {IOracle} from "./interfaces/extensions/IOracle.sol";
import {ITWAMMRecoverableLiquidations} from "./interfaces/ITWAMMRecoverableLiquidations.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {nextValidTime} from "./math/time.sol";
import {computeSaleRate} from "./math/twamm.sol";
import {NATIVE_TOKEN_ADDRESS, MIN_TICK, MAX_TICK} from "./math/constants.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {OrderKey} from "./types/orderKey.sol";
import {createOrderConfig} from "./types/orderConfig.sol";
import {TWAMMRecoverablePairConfig, createTWAMMRecoverablePairConfig} from "./types/twammRecoverablePairConfig.sol";
import {
    TWAMMRecoverableBorrowerBalances,
    createTWAMMRecoverableBorrowerBalances
} from "./types/twammRecoverableBorrowerBalances.sol";
import {
    TWAMMRecoverableLiquidationState,
    createTWAMMRecoverableLiquidationState
} from "./types/twammRecoverableLiquidationState.sol";

/// @title TWAMM Recoverable Liquidations
/// @author Ekubo Protocol
/// @notice Singleton lending protocol for multiple asset pairs with TWAMM recoverable liquidations
/// @dev Uses Core's flash accountant lock pattern and interacts directly with the TWAMM extension.
contract TWAMMRecoverableLiquidations is
    ITWAMMRecoverableLiquidations,
    Ownable,
    PayableMulticallable,
    BaseLocker,
    UsesCore
{
    using FlashAccountantLib for *;
    using TWAMMLib for *;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant ONE_X18 = 1e18;
    uint256 private constant CALL_TYPE_UPDATE_SALE_RATE = 0;
    uint256 private constant CALL_TYPE_COLLECT_PROCEEDS = 1;

    IOracle public immutable ORACLE;
    ITWAMM public immutable TWAMM;
    uint32 public immutable LIQUIDATION_DURATION;
    uint32 public immutable TWAP_DURATION;

    mapping(bytes32 pairId => TWAMMRecoverablePairConfig config) internal _pairConfigs;
    mapping(bytes32 pairId => mapping(address borrower => TWAMMRecoverableBorrowerBalances balances)) internal
        _borrowerBalances;
    mapping(bytes32 pairId => mapping(address borrower => TWAMMRecoverableLiquidationState state)) internal
        _borrowerLiquidations;

    constructor(
        address owner,
        ICore core,
        ITWAMM twamm,
        IOracle oracle,
        uint32 liquidationDuration,
        uint32 twapDuration
    ) BaseLocker(core) UsesCore(core) {
        if (owner == address(0)) revert InvalidOwner();
        if (liquidationDuration == 0) revert InvalidLiquidationDuration();
        if (twapDuration == 0) revert InvalidTwapDuration();

        _initializeOwner(owner);
        TWAMM = twamm;
        ORACLE = oracle;
        LIQUIDATION_DURATION = liquidationDuration;
        TWAP_DURATION = twapDuration;
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function configurePair(
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        uint16 collateralFactorBps,
        uint64 triggerHealthFactorX18,
        uint64 cancelHealthFactorX18
    ) external onlyOwner {
        if (collateralToken == debtToken) revert InvalidTokenPair();
        if (collateralFactorBps == 0 || collateralFactorBps > BPS_DENOMINATOR) revert InvalidCollateralFactorBps();
        if (triggerHealthFactorX18 >= cancelHealthFactorX18) revert InvalidHealthFactorThresholds();

        bytes32 pairId = _pairId(collateralToken, debtToken, poolFee);
        _pairConfigs[pairId] =
            createTWAMMRecoverablePairConfig(collateralFactorBps, triggerHealthFactorX18, cancelHealthFactorX18, true);

        emit PairConfigured(
            collateralToken, debtToken, poolFee, collateralFactorBps, triggerHealthFactorX18, cancelHealthFactorX18
        );
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function getPairConfig(address collateralToken, address debtToken, uint64 poolFee)
        external
        view
        returns (PairConfig memory)
    {
        return _toPairConfig(_pairConfigs[_pairId(collateralToken, debtToken, poolFee)]);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function healthFactorX18(address borrower, address collateralToken, address debtToken, uint64 poolFee)
        public
        view
        returns (uint256)
    {
        bytes32 pairId = _pairId(collateralToken, debtToken, poolFee);
        PairConfig memory pair = _toPairConfig(_requirePairConfigured(pairId));
        return _healthFactorX18(_getBorrowerState(pairId, borrower), pair, collateralToken, debtToken);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function getBorrowerState(address borrower, address collateralToken, address debtToken, uint64 poolFee)
        external
        view
        returns (BorrowerState memory)
    {
        return _getBorrowerState(_pairId(collateralToken, debtToken, poolFee), borrower);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function depositCollateral(address collateralToken, address debtToken, uint64 poolFee, uint128 amount)
        external
        payable
    {
        if (amount == 0) revert InsufficientCollateral();
        bytes32 pairId = _pairId(collateralToken, debtToken, poolFee);
        _requirePairConfigured(pairId);

        BorrowerState memory state = _getBorrowerState(pairId, msg.sender);
        state.collateralAmount += amount;
        _setBorrowerBalances(pairId, msg.sender, state.collateralAmount, state.debtAmount);

        if (collateralToken == NATIVE_TOKEN_ADDRESS) {
            if (msg.value != amount) revert IncorrectPaymentAmount();
        } else {
            if (msg.value != 0) revert IncorrectPaymentAmount();
            SafeTransferLib.safeTransferFrom(collateralToken, msg.sender, address(this), amount);
        }

        emit CollateralDeposited(msg.sender, collateralToken, debtToken, poolFee, amount);
        emit BorrowerStateUpdated(
            msg.sender, collateralToken, debtToken, poolFee, state.collateralAmount, state.debtAmount
        );
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function withdrawCollateral(
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        uint128 amount,
        address recipient
    ) external {
        bytes32 pairId = _pairId(collateralToken, debtToken, poolFee);
        PairConfig memory pair = _toPairConfig(_requirePairConfigured(pairId));
        BorrowerState memory state = _getBorrowerState(pairId, msg.sender);
        if (state.active) revert LiquidationAlreadyActive();
        if (amount == 0 || amount > state.collateralAmount) revert InsufficientCollateral();

        state.collateralAmount -= amount;
        uint256 healthFactor = _healthFactorX18(state, pair, collateralToken, debtToken);
        if (healthFactor < pair.cancelHealthFactorX18) revert AccountStillUnhealthy(healthFactor);
        _setBorrowerBalances(pairId, msg.sender, state.collateralAmount, state.debtAmount);

        if (collateralToken == NATIVE_TOKEN_ADDRESS) {
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(collateralToken, recipient, amount);
        }

        emit CollateralWithdrawn(msg.sender, collateralToken, debtToken, poolFee, amount, recipient);
        emit BorrowerStateUpdated(
            msg.sender, collateralToken, debtToken, poolFee, state.collateralAmount, state.debtAmount
        );
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function borrow(address collateralToken, address debtToken, uint64 poolFee, uint128 amount, address recipient)
        external
    {
        bytes32 pairId = _pairId(collateralToken, debtToken, poolFee);
        PairConfig memory pair = _toPairConfig(_requirePairConfigured(pairId));
        BorrowerState memory state = _getBorrowerState(pairId, msg.sender);
        if (state.active) revert LiquidationAlreadyActive();
        if (amount == 0) revert NoDebt();

        state.debtAmount += amount;
        uint256 healthFactor = _healthFactorX18(state, pair, collateralToken, debtToken);
        if (healthFactor < pair.cancelHealthFactorX18) revert AccountStillUnhealthy(healthFactor);
        _setBorrowerBalances(pairId, msg.sender, state.collateralAmount, state.debtAmount);

        if (debtToken == NATIVE_TOKEN_ADDRESS) {
            if (address(this).balance < amount) revert InsufficientDebtLiquidity();
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            if (SafeTransferLib.balanceOf(debtToken, address(this)) < amount) revert InsufficientDebtLiquidity();
            SafeTransferLib.safeTransfer(debtToken, recipient, amount);
        }

        emit DebtBorrowed(msg.sender, collateralToken, debtToken, poolFee, amount, recipient);
        emit BorrowerStateUpdated(
            msg.sender, collateralToken, debtToken, poolFee, state.collateralAmount, state.debtAmount
        );
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function repay(address collateralToken, address debtToken, uint64 poolFee, uint128 amount)
        external
        payable
        returns (uint128 repaidAmount)
    {
        if (amount == 0) revert InvalidRepaymentAmount();
        bytes32 pairId = _pairId(collateralToken, debtToken, poolFee);
        _requirePairConfigured(pairId);
        BorrowerState memory state = _getBorrowerState(pairId, msg.sender);
        if (state.debtAmount == 0) revert NoDebt();
        repaidAmount = amount < state.debtAmount ? amount : state.debtAmount;

        state.debtAmount -= repaidAmount;
        _setBorrowerBalances(pairId, msg.sender, state.collateralAmount, state.debtAmount);

        if (debtToken == NATIVE_TOKEN_ADDRESS) {
            if (msg.value != repaidAmount) revert IncorrectPaymentAmount();
        } else {
            if (msg.value != 0) revert IncorrectPaymentAmount();
            SafeTransferLib.safeTransferFrom(debtToken, msg.sender, address(this), repaidAmount);
        }

        emit DebtRepaid(msg.sender, collateralToken, debtToken, poolFee, repaidAmount);
        emit BorrowerStateUpdated(
            msg.sender, collateralToken, debtToken, poolFee, state.collateralAmount, state.debtAmount
        );
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function triggerLiquidation(
        address borrower,
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        uint128 sellAmount,
        uint112 maxSaleRate
    ) external returns (bytes32 orderSalt, uint64 endTime, uint112 saleRate) {
        bytes32 pairId = _pairId(collateralToken, debtToken, poolFee);
        PairConfig memory pair = _toPairConfig(_requirePairConfigured(pairId));
        BorrowerState memory state = _getBorrowerState(pairId, borrower);
        if (state.active) revert LiquidationAlreadyActive();
        if (state.debtAmount == 0) revert NoDebt();
        if (sellAmount == 0 || sellAmount > state.collateralAmount) revert InsufficientCollateral();

        uint256 healthFactor = _healthFactorX18(state, pair, collateralToken, debtToken);
        if (healthFactor >= pair.triggerHealthFactorX18) revert AccountHealthy(healthFactor);

        endTime = uint64(nextValidTime(block.timestamp, block.timestamp + uint256(LIQUIDATION_DURATION) - 1));
        if (endTime <= block.timestamp) revert InvalidOrderEndTime();

        saleRate = uint112(computeSaleRate(sellAmount, uint32(endTime - block.timestamp)));
        if (saleRate > maxSaleRate) revert MaxSaleRateExceeded();

        orderSalt = _orderSalt(pairId, borrower);
        OrderKey memory key = _createOrderKey(collateralToken, debtToken, poolFee, endTime);
        _updateSaleRate(orderSalt, key, int112(saleRate), address(this));

        state.active = true;
        state.activeOrderEndTime = endTime;
        _setBorrowerLiquidation(pairId, borrower, endTime, true);

        emit LiquidationStarted(borrower, collateralToken, debtToken, poolFee, orderSalt, endTime, sellAmount, saleRate);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function cancelLiquidationIfRecovered(address borrower, address collateralToken, address debtToken, uint64 poolFee)
        external
        returns (uint128 refund, uint128 proceeds)
    {
        bytes32 pairId = _pairId(collateralToken, debtToken, poolFee);
        PairConfig memory pair = _toPairConfig(_requirePairConfigured(pairId));
        BorrowerState memory state = _getBorrowerState(pairId, borrower);
        if (!state.active) revert LiquidationNotActive();

        uint256 healthFactor = _healthFactorX18(state, pair, collateralToken, debtToken);
        if (healthFactor < pair.cancelHealthFactorX18) revert AccountStillUnhealthy(healthFactor);

        bytes32 orderSalt = _orderSalt(pairId, borrower);
        uint256 soldAmount;
        (state, soldAmount, refund, proceeds) = _settleLiquidation(
            state, orderSalt, _createOrderKey(collateralToken, debtToken, poolFee, state.activeOrderEndTime)
        );
        _setBorrowerState(pairId, borrower, state);

        emit LiquidationCancelled(
            borrower, collateralToken, debtToken, poolFee, orderSalt, soldAmount, proceeds, refund
        );
        emit BorrowerStateUpdated(
            borrower, collateralToken, debtToken, poolFee, state.collateralAmount, state.debtAmount
        );
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function finalizeLiquidation(address borrower, address collateralToken, address debtToken, uint64 poolFee)
        external
        returns (uint128 refund, uint128 proceeds)
    {
        bytes32 pairId = _pairId(collateralToken, debtToken, poolFee);
        _requirePairConfigured(pairId);
        BorrowerState memory state = _getBorrowerState(pairId, borrower);
        if (!state.active) revert LiquidationNotActive();
        if (block.timestamp < state.activeOrderEndTime) {
            revert LiquidationStillRunning(state.activeOrderEndTime);
        }

        bytes32 orderSalt = _orderSalt(pairId, borrower);
        uint256 soldAmount;
        (state, soldAmount, refund, proceeds) = _settleLiquidation(
            state, orderSalt, _createOrderKey(collateralToken, debtToken, poolFee, state.activeOrderEndTime)
        );
        _setBorrowerState(pairId, borrower, state);

        emit LiquidationFinalized(
            borrower, collateralToken, debtToken, poolFee, orderSalt, soldAmount, proceeds, refund
        );
        emit BorrowerStateUpdated(
            borrower, collateralToken, debtToken, poolFee, state.collateralAmount, state.debtAmount
        );
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function withdraw(address token, address recipient, uint256 amount) external onlyOwner {
        if (token == NATIVE_TOKEN_ADDRESS) {
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(token, recipient, amount);
        }
    }

    receive() external payable {}

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_UPDATE_SALE_RATE) {
            (, bytes32 salt, OrderKey memory orderKey, int112 saleRateDelta, address recipient) =
                abi.decode(data, (uint256, bytes32, OrderKey, int112, address));

            int256 amount = CORE.updateSaleRate(TWAMM, salt, orderKey, saleRateDelta);
            if (amount > 0) {
                address sellToken = orderKey.sellToken();
                uint256 payAmount = uint256(amount);
                if (sellToken == NATIVE_TOKEN_ADDRESS) {
                    SafeTransferLib.safeTransferETH(address(ACCOUNTANT), payAmount);
                } else {
                    ACCOUNTANT.pay(sellToken, payAmount);
                }
            } else if (amount < 0) {
                ACCOUNTANT.withdraw(orderKey.sellToken(), recipient, uint128(uint256(-amount)));
            }

            result = abi.encode(amount);
        } else if (callType == CALL_TYPE_COLLECT_PROCEEDS) {
            (, bytes32 salt, OrderKey memory orderKey, address recipient) =
                abi.decode(data, (uint256, bytes32, OrderKey, address));

            uint128 proceeds = CORE.collectProceeds(TWAMM, salt, orderKey);
            if (proceeds != 0) {
                ACCOUNTANT.withdraw(orderKey.buyToken(), recipient, proceeds);
            }
            result = abi.encode(proceeds);
        } else {
            revert InvalidCallType();
        }
    }

    function _settleLiquidation(BorrowerState memory state, bytes32 orderSalt, OrderKey memory key)
        internal
        returns (BorrowerState memory updatedState, uint256 soldAmount, uint128 refund, uint128 proceeds)
    {
        state.active = false;
        state.activeOrderEndTime = 0;

        (uint112 currentSaleRate, uint256 amountSold,,) =
            TWAMM.executeVirtualOrdersAndGetCurrentOrderInfo(address(this), orderSalt, key);
        soldAmount = amountSold;

        if (currentSaleRate != 0) {
            int256 refundAmount = _updateSaleRate(orderSalt, key, -int112(currentSaleRate), address(this));
            if (refundAmount > 0) revert UnexpectedPositiveRefund();
            refund = uint128(uint256(-refundAmount));
        }

        proceeds = _collectProceeds(orderSalt, key, address(this));
        state = _applySettlement(state, soldAmount, proceeds);
        updatedState = state;
    }

    function _updateSaleRate(bytes32 orderSalt, OrderKey memory key, int112 saleRateDelta, address recipient)
        internal
        returns (int256 amount)
    {
        amount = abi.decode(
            lock(abi.encode(CALL_TYPE_UPDATE_SALE_RATE, orderSalt, key, saleRateDelta, recipient)), (int256)
        );
    }

    function _collectProceeds(bytes32 orderSalt, OrderKey memory key, address recipient)
        internal
        returns (uint128 proceeds)
    {
        proceeds = abi.decode(lock(abi.encode(CALL_TYPE_COLLECT_PROCEEDS, orderSalt, key, recipient)), (uint128));
    }

    function _applySettlement(BorrowerState memory state, uint256 soldAmount, uint128 proceeds)
        internal
        pure
        returns (BorrowerState memory)
    {
        uint256 collateralAmount = state.collateralAmount;
        if (soldAmount > collateralAmount) soldAmount = collateralAmount;
        state.collateralAmount = uint128(collateralAmount - soldAmount);

        uint128 debtAmount = state.debtAmount;
        state.debtAmount = proceeds >= debtAmount ? 0 : debtAmount - proceeds;
        return state;
    }

    function _healthFactorX18(
        BorrowerState memory state,
        PairConfig memory pair,
        address collateralToken,
        address debtToken
    ) internal view returns (uint256) {
        if (state.debtAmount == 0) return type(uint256).max;
        if (state.collateralAmount == 0) return 0;

        uint256 collateralValueInDebt = _quote(state.collateralAmount, collateralToken, debtToken);
        uint256 effectiveCollateralValueInDebt = (collateralValueInDebt * pair.collateralFactorBps) / BPS_DENOMINATOR;
        return (effectiveCollateralValueInDebt * ONE_X18) / state.debtAmount;
    }

    function _quote(uint256 baseAmount, address baseToken, address quoteToken)
        internal
        view
        returns (uint256 quoteAmount)
    {
        if (baseToken == quoteToken) return baseAmount;
        int32 tick = _getAverageTick(baseToken, quoteToken);
        uint256 sqrtRatio = tickToSqrtRatio(tick).toFixed();
        uint256 ratio = FixedPointMathLib.fullMulDivN(sqrtRatio, sqrtRatio, 128);
        quoteAmount = FixedPointMathLib.fullMulDivN(baseAmount, ratio, 128);
    }

    function _getAverageTick(address baseToken, address quoteToken) internal view returns (int32 tick) {
        unchecked {
            bool baseIsNative = baseToken == NATIVE_TOKEN_ADDRESS;
            if (baseIsNative || quoteToken == NATIVE_TOKEN_ADDRESS) {
                (int32 tickSign, address otherToken) = baseIsNative ? (int32(1), quoteToken) : (int32(-1), baseToken);
                (, int64 tickCumulativeStart) = ORACLE.extrapolateSnapshot(otherToken, block.timestamp - TWAP_DURATION);
                (, int64 tickCumulativeEnd) = ORACLE.extrapolateSnapshot(otherToken, block.timestamp);
                // TWAP_DURATION is uint32, so this cast is always within int64 range.
                int64 twapDuration = int64(uint64(TWAP_DURATION));
                int64 averageTick = (tickCumulativeEnd - tickCumulativeStart) / twapDuration;
                if (averageTick < MIN_TICK) return tickSign * MIN_TICK;
                if (averageTick > MAX_TICK) return tickSign * MAX_TICK;
                return tickSign * int32(averageTick);
            }

            int32 baseTick = _getAverageTick(NATIVE_TOKEN_ADDRESS, baseToken);
            int32 quoteTick = _getAverageTick(NATIVE_TOKEN_ADDRESS, quoteToken);
            int256 relativeTick = int256(quoteTick) - int256(baseTick);
            if (relativeTick < MIN_TICK) return MIN_TICK;
            if (relativeTick > MAX_TICK) return MAX_TICK;
            return int32(relativeTick);
        }
    }

    function _createOrderKey(address collateralToken, address debtToken, uint64 poolFee, uint64 endTime)
        internal
        pure
        returns (OrderKey memory key)
    {
        bool isToken1 = collateralToken > debtToken;
        (address token0, address token1) = isToken1 ? (debtToken, collateralToken) : (collateralToken, debtToken);
        key = OrderKey({
            token0: token0,
            token1: token1,
            config: createOrderConfig({_fee: poolFee, _isToken1: isToken1, _startTime: 0, _endTime: endTime})
        });
    }

    function _pairId(address collateralToken, address debtToken, uint64 poolFee) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(collateralToken, debtToken, poolFee));
    }

    function _orderSalt(bytes32 pairId, address borrower) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(pairId, borrower));
    }

    function _requirePairConfigured(bytes32 pairId) internal view returns (TWAMMRecoverablePairConfig pair) {
        pair = _pairConfigs[pairId];
        if (!pair.configured()) revert PairNotConfigured();
    }

    function _toPairConfig(TWAMMRecoverablePairConfig packed) internal pure returns (PairConfig memory pair) {
        pair = PairConfig({
            collateralFactorBps: packed.collateralFactorBps(),
            triggerHealthFactorX18: packed.triggerHealthFactorX18(),
            cancelHealthFactorX18: packed.cancelHealthFactorX18(),
            configured: packed.configured()
        });
    }

    function _getBorrowerState(bytes32 pairId, address borrower) internal view returns (BorrowerState memory state) {
        TWAMMRecoverableBorrowerBalances packedBalances = _borrowerBalances[pairId][borrower];
        TWAMMRecoverableLiquidationState packedLiquidation = _borrowerLiquidations[pairId][borrower];
        state = BorrowerState({
            collateralAmount: packedBalances.collateralAmount(),
            debtAmount: packedBalances.debtAmount(),
            activeOrderEndTime: packedLiquidation.activeOrderEndTime(),
            active: packedLiquidation.active()
        });
    }

    function _setBorrowerBalances(bytes32 pairId, address borrower, uint128 collateral, uint128 debt) internal {
        _borrowerBalances[pairId][borrower] = createTWAMMRecoverableBorrowerBalances(collateral, debt);
    }

    function _setBorrowerLiquidation(bytes32 pairId, address borrower, uint64 activeOrderEndTime, bool activeState)
        internal
    {
        _borrowerLiquidations[pairId][borrower] =
            createTWAMMRecoverableLiquidationState(activeOrderEndTime, activeState);
    }

    function _setBorrowerState(bytes32 pairId, address borrower, BorrowerState memory state) internal {
        _setBorrowerBalances(pairId, borrower, state.collateralAmount, state.debtAmount);
        _setBorrowerLiquidation(pairId, borrower, state.activeOrderEndTime, state.active);
    }
}
