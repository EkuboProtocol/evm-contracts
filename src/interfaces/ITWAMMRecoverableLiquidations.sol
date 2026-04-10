// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

interface ITWAMMRecoverableLiquidations {
    struct BorrowerState {
        uint128 collateralAmount;
        uint128 debtAmount;
        uint64 activeOrderEndTime;
        uint256 nftId;
        bool active;
    }

    error InvalidOwner();
    error InvalidTokenPair();
    error InvalidCollateralFactorBps();
    error InvalidLiquidationDuration();
    error InvalidTwapDuration();
    error InvalidHealthFactorThresholds();
    error NoDebt();
    error LiquidationAlreadyActive();
    error LiquidationNotActive();
    error InsufficientCollateral();
    error InsufficientDebtLiquidity();
    error InsufficientDebt();
    error IncorrectPaymentAmount();
    error AccountHealthy(uint256 healthFactorX18);
    error AccountStillUnhealthy(uint256 healthFactorX18);
    error InvalidOrderEndTime();

    event BorrowerStateUpdated(address indexed borrower, uint128 collateralAmount, uint128 debtAmount);
    event CollateralDeposited(address indexed borrower, uint128 amount);
    event CollateralWithdrawn(address indexed borrower, uint128 amount, address recipient);
    event DebtBorrowed(address indexed borrower, uint128 amount, address recipient);
    event DebtRepaid(address indexed borrower, uint128 amount);
    event LiquidationStarted(
        address indexed borrower, uint256 indexed nftId, uint64 endTime, uint128 sellAmount, uint112 saleRate
    );
    event LiquidationCancelled(
        address indexed borrower, uint256 indexed nftId, uint256 soldAmount, uint128 proceeds, uint128 refund
    );
    event LiquidationFinalized(
        address indexed borrower, uint256 indexed nftId, uint256 soldAmount, uint128 proceeds, uint128 refund
    );

    function healthFactorX18(address borrower) external view returns (uint256);
    function getBorrowerState(address borrower) external view returns (BorrowerState memory);
    function depositCollateral(uint128 amount) external payable;
    function withdrawCollateral(uint128 amount, address recipient) external;
    function borrow(uint128 amount, address recipient) external;
    function repay(uint128 amount) external payable returns (uint128 repaidAmount);
    function approveMaxCollateral() external;
    function triggerLiquidation(address borrower, uint128 sellAmount, uint112 maxSaleRate)
        external
        payable
        returns (uint256 nftId, uint64 endTime, uint112 saleRate);
    function cancelLiquidationIfRecovered(address borrower) external returns (uint128 refund, uint128 proceeds);
    function finalizeLiquidation(address borrower) external returns (uint128 refund, uint128 proceeds);
    function withdraw(address token, address recipient, uint256 amount) external;
}
