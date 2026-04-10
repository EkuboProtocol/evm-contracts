// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {IOrders} from "./interfaces/IOrders.sol";
import {ITWAMMRecoverableLiquidations} from "./interfaces/ITWAMMRecoverableLiquidations.sol";
import {IERC7726} from "./lens/ERC7726.sol";
import {nextValidTime} from "./math/time.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {OrderKey} from "./types/orderKey.sol";
import {createOrderConfig} from "./types/orderConfig.sol";

/// @title TWAMM Recoverable Liquidations
/// @author Ekubo Protocol
/// @notice Starts liquidations through TWAMM when health factor falls below a conservative threshold,
/// and supports cancellation if health recovers before completion
/// @dev Expects borrower collateral/debt accounting to be synchronized by an external lending protocol
contract TWAMMRecoverableLiquidations is ITWAMMRecoverableLiquidations, Ownable, Multicallable {
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant ONE_X18 = 1e18;

    IOrders public immutable ORDERS;
    IERC7726 public immutable QUOTER;

    address public immutable COLLATERAL_TOKEN;
    address public immutable DEBT_TOKEN;
    uint64 public immutable POOL_FEE;
    uint32 public immutable LIQUIDATION_DURATION;
    uint16 public immutable COLLATERAL_FACTOR_BPS;
    uint256 public immutable TRIGGER_HEALTH_FACTOR_X18;
    uint256 public immutable CANCEL_HEALTH_FACTOR_X18;

    mapping(address borrower => BorrowerState state) internal _borrowerStates;

    constructor(
        address owner,
        IOrders orders,
        IERC7726 quoter,
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        uint32 liquidationDuration,
        uint16 collateralFactorBps,
        uint256 triggerHealthFactorX18,
        uint256 cancelHealthFactorX18
    ) {
        if (owner == address(0)) revert InvalidOwner();
        if (collateralToken == debtToken) revert InvalidTokenPair();
        if (liquidationDuration == 0) revert InvalidLiquidationDuration();
        if (collateralFactorBps == 0 || collateralFactorBps > BPS_DENOMINATOR) revert InvalidCollateralFactorBps();
        if (triggerHealthFactorX18 >= cancelHealthFactorX18) revert InvalidHealthFactorThresholds();

        _initializeOwner(owner);
        ORDERS = orders;
        QUOTER = quoter;
        COLLATERAL_TOKEN = collateralToken;
        DEBT_TOKEN = debtToken;
        POOL_FEE = poolFee;
        LIQUIDATION_DURATION = liquidationDuration;
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
    function updateBorrowerState(address borrower, uint128 collateralAmount, uint128 debtAmount) external onlyOwner {
        BorrowerState storage state = _borrowerStates[borrower];
        state.collateralAmount = collateralAmount;
        state.debtAmount = debtAmount;
        emit BorrowerStateUpdated(borrower, collateralAmount, debtAmount);
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
    function cancelLiquidationIfRecovered(address borrower, address refundRecipient, address proceedsRecipient)
        external
        returns (uint128 refund, uint128 proceeds)
    {
        BorrowerState storage state = _borrowerStates[borrower];
        if (!state.active) revert LiquidationNotActive();

        uint256 healthFactor = _healthFactorX18(state);
        if (healthFactor < CANCEL_HEALTH_FACTOR_X18) revert AccountStillUnhealthy(healthFactor);

        (uint256 soldAmount, refund, proceeds) = _settleLiquidation(state, refundRecipient, proceedsRecipient);

        emit LiquidationCancelled(borrower, state.nftId, soldAmount, proceeds, refund);
    }

    /// @inheritdoc ITWAMMRecoverableLiquidations
    function finalizeLiquidation(address borrower, address refundRecipient, address proceedsRecipient)
        external
        returns (uint128 refund, uint128 proceeds)
    {
        BorrowerState storage state = _borrowerStates[borrower];
        if (!state.active) revert LiquidationNotActive();
        if (block.timestamp < state.activeOrderEndTime) {
            uint256 healthFactor = _healthFactorX18(state);
            revert AccountStillUnhealthy(healthFactor);
        }

        (uint256 soldAmount, refund, proceeds) = _settleLiquidation(state, refundRecipient, proceedsRecipient);

        emit LiquidationFinalized(borrower, state.nftId, soldAmount, proceeds, refund);
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

    function _settleLiquidation(BorrowerState storage state, address refundRecipient, address proceedsRecipient)
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
            refund = ORDERS.decreaseSaleRate(nftId, key, currentSaleRate, refundRecipient);
        }

        proceeds = ORDERS.collectProceeds(nftId, key, proceedsRecipient);

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

        uint256 collateralValueInDebt = QUOTER.getQuote(state.collateralAmount, COLLATERAL_TOKEN, DEBT_TOKEN);
        uint256 effectiveCollateralValueInDebt = (collateralValueInDebt * COLLATERAL_FACTOR_BPS) / BPS_DENOMINATOR;

        return (effectiveCollateralValueInDebt * ONE_X18) / state.debtAmount;
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
