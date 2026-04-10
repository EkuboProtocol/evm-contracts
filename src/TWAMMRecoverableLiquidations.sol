// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {IOrders} from "./interfaces/IOrders.sol";
import {ITWAMMRecoverableLiquidations} from "./interfaces/ITWAMMRecoverableLiquidations.sol";
import {IOracle} from "./interfaces/extensions/IOracle.sol";
import {nextValidTime} from "./math/time.sol";
import {NATIVE_TOKEN_ADDRESS, MIN_TICK, MAX_TICK} from "./math/constants.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {OrderKey} from "./types/orderKey.sol";
import {createOrderConfig} from "./types/orderConfig.sol";

/// @title TWAMM Recoverable Liquidations
/// @author Ekubo Protocol
/// @notice Reference lending protocol with TWAMM-based recoverable liquidations
/// @dev Users can deposit collateral, borrow debt assets, repay debt, and withdraw collateral subject to health checks.
/// Liquidations are executed over time through TWAMM and can be cancelled if account health recovers.
contract TWAMMRecoverableLiquidations is ITWAMMRecoverableLiquidations, Ownable, Multicallable {
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant ONE_X18 = 1e18;

    IOrders public immutable ORDERS;
    IOracle public immutable ORACLE;

    address public immutable COLLATERAL_TOKEN;
    address public immutable DEBT_TOKEN;
    uint64 public immutable POOL_FEE;
    uint32 public immutable LIQUIDATION_DURATION;
    uint32 public immutable TWAP_DURATION;
    uint16 public immutable COLLATERAL_FACTOR_BPS;
    uint256 public immutable TRIGGER_HEALTH_FACTOR_X18;
    uint256 public immutable CANCEL_HEALTH_FACTOR_X18;

    mapping(address borrower => BorrowerState state) internal _borrowerStates;

    constructor(
        address owner,
        IOrders orders,
        IOracle oracle,
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        uint32 liquidationDuration,
        uint32 twapDuration,
        uint16 collateralFactorBps,
        uint256 triggerHealthFactorX18,
        uint256 cancelHealthFactorX18
    ) {
        if (owner == address(0)) revert InvalidOwner();
        if (collateralToken == debtToken) revert InvalidTokenPair();
        if (liquidationDuration == 0) revert InvalidLiquidationDuration();
        if (twapDuration == 0) revert InvalidTwapDuration();
        if (collateralFactorBps == 0 || collateralFactorBps > BPS_DENOMINATOR) revert InvalidCollateralFactorBps();
        if (triggerHealthFactorX18 >= cancelHealthFactorX18) revert InvalidHealthFactorThresholds();

        _initializeOwner(owner);
        ORDERS = orders;
        ORACLE = oracle;
        COLLATERAL_TOKEN = collateralToken;
        DEBT_TOKEN = debtToken;
        POOL_FEE = poolFee;
        LIQUIDATION_DURATION = liquidationDuration;
        TWAP_DURATION = twapDuration;
        COLLATERAL_FACTOR_BPS = collateralFactorBps;
        TRIGGER_HEALTH_FACTOR_X18 = triggerHealthFactorX18;
        CANCEL_HEALTH_FACTOR_X18 = cancelHealthFactorX18;
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function healthFactorX18(address borrower) public view returns (uint256) {
        return _healthFactorX18(_borrowerStates[borrower]);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function getBorrowerState(address borrower) external view returns (BorrowerState memory) {
        return _borrowerStates[borrower];
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function depositCollateral(uint128 amount) external payable {
        if (amount == 0) revert InsufficientCollateral();

        BorrowerState storage state = _borrowerStates[msg.sender];
        state.collateralAmount += amount;

        if (COLLATERAL_TOKEN == NATIVE_TOKEN_ADDRESS) {
            if (msg.value != amount) revert IncorrectPaymentAmount();
        } else {
            if (msg.value != 0) revert IncorrectPaymentAmount();
            SafeTransferLib.safeTransferFrom(COLLATERAL_TOKEN, msg.sender, address(this), amount);
        }

        emit CollateralDeposited(msg.sender, amount);
        emit BorrowerStateUpdated(msg.sender, state.collateralAmount, state.debtAmount);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function withdrawCollateral(uint128 amount, address recipient) external {
        BorrowerState storage state = _borrowerStates[msg.sender];
        if (state.active) revert LiquidationAlreadyActive();
        if (amount == 0 || amount > state.collateralAmount) revert InsufficientCollateral();

        state.collateralAmount -= amount;
        uint256 healthFactor = _healthFactorX18(state);
        if (healthFactor < CANCEL_HEALTH_FACTOR_X18) revert AccountStillUnhealthy(healthFactor);

        if (COLLATERAL_TOKEN == NATIVE_TOKEN_ADDRESS) {
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(COLLATERAL_TOKEN, recipient, amount);
        }

        emit CollateralWithdrawn(msg.sender, amount, recipient);
        emit BorrowerStateUpdated(msg.sender, state.collateralAmount, state.debtAmount);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function borrow(uint128 amount, address recipient) external {
        BorrowerState storage state = _borrowerStates[msg.sender];
        if (state.active) revert LiquidationAlreadyActive();
        if (amount == 0) revert NoDebt();

        state.debtAmount += amount;
        uint256 healthFactor = _healthFactorX18(state);
        if (healthFactor < CANCEL_HEALTH_FACTOR_X18) revert AccountStillUnhealthy(healthFactor);

        if (DEBT_TOKEN == NATIVE_TOKEN_ADDRESS) {
            if (address(this).balance < amount) revert InsufficientDebtLiquidity();
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            if (SafeTransferLib.balanceOf(DEBT_TOKEN, address(this)) < amount) revert InsufficientDebtLiquidity();
            SafeTransferLib.safeTransfer(DEBT_TOKEN, recipient, amount);
        }

        emit DebtBorrowed(msg.sender, amount, recipient);
        emit BorrowerStateUpdated(msg.sender, state.collateralAmount, state.debtAmount);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function repay(uint128 amount) external payable returns (uint128 repaidAmount) {
        BorrowerState storage state = _borrowerStates[msg.sender];
        if (state.debtAmount == 0) revert NoDebt();
        if (amount == 0) revert InvalidRepaymentAmount();
        repaidAmount = amount < state.debtAmount ? amount : state.debtAmount;

        state.debtAmount -= repaidAmount;

        if (DEBT_TOKEN == NATIVE_TOKEN_ADDRESS) {
            if (msg.value != repaidAmount) revert IncorrectPaymentAmount();
        } else {
            if (msg.value != 0) revert IncorrectPaymentAmount();
            SafeTransferLib.safeTransferFrom(DEBT_TOKEN, msg.sender, address(this), repaidAmount);
        }

        emit DebtRepaid(msg.sender, repaidAmount);
        emit BorrowerStateUpdated(msg.sender, state.collateralAmount, state.debtAmount);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function approveMaxCollateral() external {
        if (COLLATERAL_TOKEN == NATIVE_TOKEN_ADDRESS) return;
        SafeTransferLib.safeApproveWithRetry(COLLATERAL_TOKEN, address(ORDERS), type(uint256).max);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function triggerLiquidation(address borrower, uint128 sellAmount, uint112 maxSaleRate)
        external
        payable
        returns (uint256 nftId, uint64 endTime, uint112 saleRate)
    {
        BorrowerState storage state = _borrowerStates[borrower];
        if (state.active) revert LiquidationAlreadyActive();
        if (state.debtAmount == 0) revert NoDebt();
        if (sellAmount == 0 || sellAmount > state.collateralAmount) revert InsufficientCollateral();

        uint256 healthFactor = _healthFactorX18(state);
        if (healthFactor >= TRIGGER_HEALTH_FACTOR_X18) revert AccountHealthy(healthFactor);

        endTime = uint64(nextValidTime(block.timestamp, block.timestamp + uint256(LIQUIDATION_DURATION) - 1));
        if (endTime <= block.timestamp) revert InvalidOrderEndTime();

        OrderKey memory key = _createOrderKey(endTime);

        if (state.nftId == 0) {
            if (COLLATERAL_TOKEN == NATIVE_TOKEN_ADDRESS) {
                (nftId, saleRate) = ORDERS.mintAndIncreaseSellAmount{value: sellAmount}(key, sellAmount, maxSaleRate);
            } else {
                (nftId, saleRate) = ORDERS.mintAndIncreaseSellAmount(key, sellAmount, maxSaleRate);
            }
            state.nftId = nftId;
        } else {
            nftId = state.nftId;
            if (COLLATERAL_TOKEN == NATIVE_TOKEN_ADDRESS) {
                saleRate = ORDERS.increaseSellAmount{value: sellAmount}(nftId, key, sellAmount, maxSaleRate);
            } else {
                saleRate = ORDERS.increaseSellAmount(nftId, key, sellAmount, maxSaleRate);
            }
        }

        state.active = true;
        state.activeOrderEndTime = endTime;

        emit LiquidationStarted(borrower, nftId, endTime, sellAmount, saleRate);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function cancelLiquidationIfRecovered(address borrower) external returns (uint128 refund, uint128 proceeds) {
        BorrowerState storage state = _borrowerStates[borrower];
        if (!state.active) revert LiquidationNotActive();

        uint256 healthFactor = _healthFactorX18(state);
        if (healthFactor < CANCEL_HEALTH_FACTOR_X18) revert AccountStillUnhealthy(healthFactor);

        (uint256 soldAmount, refund, proceeds) = _settleLiquidation(state);

        emit LiquidationCancelled(borrower, state.nftId, soldAmount, proceeds, refund);
        emit BorrowerStateUpdated(borrower, state.collateralAmount, state.debtAmount);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function finalizeLiquidation(address borrower) external returns (uint128 refund, uint128 proceeds) {
        BorrowerState storage state = _borrowerStates[borrower];
        if (!state.active) revert LiquidationNotActive();
        if (block.timestamp < state.activeOrderEndTime) {
            uint256 healthFactor = _healthFactorX18(state);
            revert AccountStillUnhealthy(healthFactor);
        }

        (uint256 soldAmount, refund, proceeds) = _settleLiquidation(state);

        emit LiquidationFinalized(borrower, state.nftId, soldAmount, proceeds, refund);
        emit BorrowerStateUpdated(borrower, state.collateralAmount, state.debtAmount);
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

    function _settleLiquidation(BorrowerState storage state)
        internal
        returns (uint256 soldAmount, uint128 refund, uint128 proceeds)
    {
        uint64 endTime = state.activeOrderEndTime;
        uint256 nftId = state.nftId;
        OrderKey memory key = _createOrderKey(endTime);

        state.active = false;
        state.activeOrderEndTime = 0;

        (uint112 currentSaleRate, uint256 amountSold,,) = ORDERS.executeVirtualOrdersAndGetCurrentOrderInfo(nftId, key);
        soldAmount = amountSold;
        if (currentSaleRate != 0) {
            refund = ORDERS.decreaseSaleRate(nftId, key, currentSaleRate, address(this));
        }

        proceeds = ORDERS.collectProceeds(nftId, key, address(this));

        _applySettlement(state, soldAmount, proceeds);
    }

    function _applySettlement(BorrowerState storage state, uint256 soldAmount, uint128 proceeds) internal {
        uint256 collateralAmount = state.collateralAmount;
        if (soldAmount > collateralAmount) soldAmount = collateralAmount;
        state.collateralAmount = uint128(collateralAmount - soldAmount);

        uint128 debtAmount = state.debtAmount;
        state.debtAmount = proceeds >= debtAmount ? 0 : debtAmount - proceeds;
    }

    function _healthFactorX18(BorrowerState memory state) internal view returns (uint256) {
        if (state.debtAmount == 0) return type(uint256).max;
        if (state.collateralAmount == 0) return 0;

        uint256 collateralValueInDebt = _quote(state.collateralAmount, COLLATERAL_TOKEN, DEBT_TOKEN);
        uint256 effectiveCollateralValueInDebt = (collateralValueInDebt * COLLATERAL_FACTOR_BPS) / BPS_DENOMINATOR;

        return (effectiveCollateralValueInDebt * ONE_X18) / state.debtAmount;
    }

    function _quote(uint256 baseAmount, address baseToken, address quoteToken)
        internal
        view
        returns (uint256 quoteAmount)
    {
        if (baseToken == quoteToken) return baseAmount;
        int32 tick = _getAverageTick(baseToken, quoteToken);
        // tickToSqrtRatio returns a sqrtRatio (Q64.64 sqrt(price)); the returned value's toFixed() converts it to 128-bit fixed point.
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

    function _createOrderKey(uint64 endTime) internal view returns (OrderKey memory key) {
        bool isToken1 = COLLATERAL_TOKEN > DEBT_TOKEN;
        (address token0, address token1) = isToken1 ? (DEBT_TOKEN, COLLATERAL_TOKEN) : (COLLATERAL_TOKEN, DEBT_TOKEN);

        key = OrderKey({
            token0: token0,
            token1: token1,
            config: createOrderConfig({_fee: POOL_FEE, _isToken1: isToken1, _startTime: 0, _endTime: endTime})
        });
    }
}
