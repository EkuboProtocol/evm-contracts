// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

interface IMoneyMarket {
    struct MarketConfig {
        uint32 ltvX32;
        uint32 twapDuration;
        uint32 liquidationDuration;
        uint8 minLiquidityMagnitude;
    }

    struct BorrowerState {
        uint128 collateralAmount;
        uint128 debtAmount;
        uint64 activeOrderEndTime;
        uint128 liquidationAmount;
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

    event MarketConfigured(
        address indexed token0,
        address indexed token1,
        uint64 indexed poolFee,
        uint32 ltvX32,
        uint32 twapDuration,
        uint32 liquidationDuration,
        uint8 minLiquidityMagnitude
    );
    event BorrowerStateUpdated(
        address indexed borrower,
        address indexed collateralToken,
        address indexed debtToken,
        uint64 poolFee,
        uint128 collateralAmount,
        uint128 debtAmount,
        uint64 activeOrderEndTime,
        uint128 liquidationAmount
    );
    event CollateralDeposited(
        address indexed borrower,
        address indexed collateralToken,
        address indexed debtToken,
        uint64 poolFee,
        uint128 amount
    );
    event CollateralWithdrawn(
        address indexed borrower,
        address indexed collateralToken,
        address indexed debtToken,
        uint64 poolFee,
        uint128 amount,
        address recipient
    );
    event DebtBorrowed(
        address indexed borrower,
        address indexed collateralToken,
        address indexed debtToken,
        uint64 poolFee,
        uint128 amount,
        address recipient
    );
    event DebtRepaid(
        address indexed borrower,
        address indexed collateralToken,
        address indexed debtToken,
        uint64 poolFee,
        uint128 amount
    );
    event LiquidationStarted(
        address indexed borrower,
        address indexed collateralToken,
        address indexed debtToken,
        uint64 poolFee,
        bytes32 orderSalt,
        uint64 endTime,
        uint128 sellAmount,
        uint112 saleRate
    );
    event LiquidationCancelled(
        address indexed borrower,
        address indexed collateralToken,
        address indexed debtToken,
        uint64 poolFee,
        bytes32 orderSalt,
        uint256 soldAmount,
        uint128 proceeds,
        uint128 refund
    );
    event LiquidationFinalized(
        address indexed borrower,
        address indexed collateralToken,
        address indexed debtToken,
        uint64 poolFee,
        bytes32 orderSalt,
        uint256 soldAmount,
        uint128 proceeds,
        uint128 refund
    );

    function configureMarket(
        address tokenA,
        address tokenB,
        uint64 poolFee,
        uint32 ltvX32,
        uint32 twapDuration,
        uint32 liquidationDuration,
        uint8 minLiquidityMagnitude
    ) external;

    function getMarketConfig(address tokenA, address tokenB, uint64 poolFee) external view returns (MarketConfig memory);

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
