// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {MarketKey} from "../types/marketKey.sol";
import {MoneyMarketConfig} from "../types/moneyMarketConfig.sol";
import {LiquidationInfo} from "../types/liquidationInfo.sol";

interface IMoneyMarket {
    struct BorrowerState {
        uint128 collateralAmount;
        uint128 debtAmount;
        LiquidationInfo liquidationInfo;
    }

    error InvalidOwner();
    error InvalidTokenPair();
    error InvalidLtv();
    error InvalidMinLiquidityMagnitude();
    error InvalidLiquidationDuration();
    error InvalidTwapDuration();
    error MarketNotConfigured();
    error NoDebt();
    error LiquidationAlreadyActive();
    error LiquidationNotActive();
    error InsufficientCollateral();
    error InsufficientDebtLiquidity();
    error InvalidRepaymentAmount();
    error IncorrectPaymentAmount();
    error InvalidCallType();
    error UnexpectedPositiveRefund();
    error AccountHealthy(uint256 healthFactorX32);
    error AccountStillUnhealthy(uint256 healthFactorX32);
    error LiquidationStillRunning(uint64 endTime);
    error InvalidOrderEndTime();
    error MaxSaleRateExceeded();
    error InsufficientOracleLiquidity(uint256 averageLiquidity, uint256 requiredLiquidity);

    event MarketConfigured(MarketKey marketKey);
    event BorrowerStateUpdated(
        address borrower,
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        uint128 collateralAmount,
        uint128 debtAmount,
        LiquidationInfo liquidationInfo
    );
    event CollateralDeposited(
        address borrower, address collateralToken, address debtToken, uint64 poolFee, uint128 amount
    );
    event CollateralWithdrawn(
        address borrower, address collateralToken, address debtToken, uint64 poolFee, uint128 amount, address recipient
    );
    event DebtBorrowed(
        address borrower, address collateralToken, address debtToken, uint64 poolFee, uint128 amount, address recipient
    );
    event DebtRepaid(address borrower, address collateralToken, address debtToken, uint64 poolFee, uint128 amount);
    event LiquidationStarted(
        address borrower,
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        bytes32 orderSalt,
        uint64 endTime,
        uint128 sellAmount,
        uint112 saleRate
    );
    event LiquidationCancelled(
        address borrower,
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        bytes32 orderSalt,
        uint256 soldAmount,
        uint128 proceeds,
        uint128 refund
    );
    event LiquidationFinalized(
        address borrower,
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        bytes32 orderSalt,
        uint256 soldAmount,
        uint128 proceeds,
        uint128 refund
    );

    function configureMarket(MarketKey calldata marketKey) external;

    function getMarketConfig(address tokenA, address tokenB, uint64 poolFee) external view returns (MoneyMarketConfig);

    function healthFactorX32(address borrower, address collateralToken, address debtToken, uint64 poolFee)
        external
        view
        returns (uint256);
    function getBorrowerState(address borrower, address collateralToken, address debtToken, uint64 poolFee)
        external
        view
        returns (BorrowerState memory);
    function depositCollateral(address collateralToken, address debtToken, uint64 poolFee, uint128 amount)
        external
        payable;
    function withdrawCollateral(
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        uint128 amount,
        address recipient
    ) external;
    function borrow(address collateralToken, address debtToken, uint64 poolFee, uint128 amount, address recipient)
        external;
    function repay(address collateralToken, address debtToken, uint64 poolFee, uint128 amount)
        external
        payable
        returns (uint128 repaidAmount);
    function triggerLiquidation(
        address borrower,
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        uint128 sellAmount,
        uint112 maxSaleRate
    ) external returns (bytes32 orderSalt, uint64 endTime, uint112 saleRate);
    function cancelLiquidationIfRecovered(address borrower, address collateralToken, address debtToken, uint64 poolFee)
        external
        returns (uint128 refund, uint128 proceeds);
    function finalizeLiquidation(address borrower, address collateralToken, address debtToken, uint64 poolFee)
        external
        returns (uint128 refund, uint128 proceeds);
    function withdraw(address token, address recipient, uint256 amount) external;
}
