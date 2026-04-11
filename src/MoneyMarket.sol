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
import {IMoneyMarket} from "./interfaces/IMoneyMarket.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {nextValidTime} from "./math/time.sol";
import {computeSaleRate} from "./math/twamm.sol";
import {NATIVE_TOKEN_ADDRESS, MIN_TICK, MAX_TICK} from "./math/constants.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {OrderKey} from "./types/orderKey.sol";
import {createOrderConfig} from "./types/orderConfig.sol";
import {MarketId} from "./types/marketId.sol";
import {MarketKey} from "./types/marketKey.sol";
import {MoneyMarketConfig} from "./types/moneyMarketConfig.sol";
import {MoneyMarketBorrowerBalances, createMoneyMarketBorrowerBalances} from "./types/moneyMarketBorrowerBalances.sol";
import {LiquidationInfo, createLiquidationInfo} from "./types/liquidationInfo.sol";

/// @title Money Market
/// @author Ekubo Protocol
/// @notice Singleton lending protocol for multiple asset pairs with TWAMM recoverable liquidations
/// @dev Uses Core's flash accountant lock pattern and interacts directly with the TWAMM extension.
contract MoneyMarket is IMoneyMarket, Ownable, PayableMulticallable, BaseLocker, UsesCore {
    using FlashAccountantLib for *;
    using TWAMMLib for *;

    uint256 private constant ONE_X32 = uint256(type(uint32).max);
    uint256 private constant CALL_TYPE_UPDATE_SALE_RATE = 0;
    uint256 private constant CALL_TYPE_COLLECT_PROCEEDS = 1;

    IOracle public immutable ORACLE;
    ITWAMM public immutable TWAMM;

    mapping(MarketId marketId => MoneyMarketConfig config) internal _marketConfigs;
    mapping(bytes32 positionId => mapping(address borrower => MoneyMarketBorrowerBalances balances)) internal
        _borrowerBalances;
    mapping(bytes32 positionId => mapping(address borrower => LiquidationInfo info)) internal _borrowerLiquidations;

    constructor(address owner, ICore core, ITWAMM twamm, IOracle oracle) BaseLocker(core) UsesCore(core) {
        if (owner == address(0)) revert InvalidOwner();

        _initializeOwner(owner);
        TWAMM = twamm;
        ORACLE = oracle;
    }

    /// @inheritdoc IMoneyMarket
    function configureMarket(MarketKey calldata marketKey) external onlyOwner {
        if (marketKey.collateralToken == marketKey.debtToken) revert InvalidTokenPair();
        MoneyMarketConfig config = marketKey.config;
        if (config.ltvX32() == 0) revert InvalidLtv();
        if (config.twapDuration() == 0) revert InvalidTwapDuration();
        if (config.liquidationDuration() == 0) revert InvalidLiquidationDuration();
        if (config.minLiquidityMagnitude() > 127) revert InvalidMinLiquidityMagnitude();

        (address token0, address token1) = _sortedTokens(marketKey.collateralToken, marketKey.debtToken);
        MarketId marketId = _marketId(token0, token1, config.poolFee());
        _marketConfigs[marketId] = config;

        emit MarketConfigured(MarketKey({collateralToken: token0, debtToken: token1, config: config}));
    }

    /// @inheritdoc IMoneyMarket
    function getMarketConfig(address tokenA, address tokenB, uint64 poolFee) external view returns (MoneyMarketConfig) {
        (address token0, address token1) = _sortedTokens(tokenA, tokenB);
        return _marketConfigs[_marketId(token0, token1, poolFee)];
    }

    /// @inheritdoc IMoneyMarket
    function healthFactorX32(address borrower, address collateralToken, address debtToken, uint64 poolFee)
        public
        view
        returns (uint256)
    {
        MoneyMarketConfig market = _requireMarketConfigured(collateralToken, debtToken, poolFee);
        bytes32 positionId = _positionId(collateralToken, debtToken, poolFee);
        return _healthFactorX32(_getBorrowerState(positionId, borrower), market, collateralToken, debtToken);
    }

    /// @inheritdoc IMoneyMarket
    function getBorrowerState(address borrower, address collateralToken, address debtToken, uint64 poolFee)
        external
        view
        returns (BorrowerState memory)
    {
        return _getBorrowerState(_positionId(collateralToken, debtToken, poolFee), borrower);
    }

    /// @inheritdoc IMoneyMarket
    function depositCollateral(address collateralToken, address debtToken, uint64 poolFee, uint128 amount)
        external
        payable
    {
        if (amount == 0) revert InsufficientCollateral();
        _requireMarketConfigured(collateralToken, debtToken, poolFee);
        bytes32 positionId = _positionId(collateralToken, debtToken, poolFee);

        BorrowerState memory state = _getBorrowerState(positionId, msg.sender);
        state.collateralAmount += amount;
        _setBorrowerBalances(positionId, msg.sender, state.collateralAmount, state.debtAmount);

        if (collateralToken == NATIVE_TOKEN_ADDRESS) {
            if (msg.value != amount) revert IncorrectPaymentAmount();
        } else {
            if (msg.value != 0) revert IncorrectPaymentAmount();
            SafeTransferLib.safeTransferFrom(collateralToken, msg.sender, address(this), amount);
        }

        emit CollateralDeposited(msg.sender, collateralToken, debtToken, poolFee, amount);
        emit BorrowerStateUpdated(
            msg.sender,
            collateralToken,
            debtToken,
            poolFee,
            state.collateralAmount,
            state.debtAmount,
            state.liquidationInfo
        );
    }

    /// @inheritdoc IMoneyMarket
    function withdrawCollateral(
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        uint128 amount,
        address recipient
    ) external {
        MoneyMarketConfig market = _requireMarketConfigured(collateralToken, debtToken, poolFee);
        bytes32 positionId = _positionId(collateralToken, debtToken, poolFee);
        BorrowerState memory state = _getBorrowerState(positionId, msg.sender);
        if (state.liquidationInfo.active()) revert LiquidationAlreadyActive();
        if (amount == 0 || amount > state.collateralAmount) revert InsufficientCollateral();

        state.collateralAmount -= amount;
        uint256 healthFactor = _healthFactorX32(state, market, collateralToken, debtToken);
        if (healthFactor < ONE_X32) revert AccountStillUnhealthy(healthFactor);
        _setBorrowerBalances(positionId, msg.sender, state.collateralAmount, state.debtAmount);

        if (collateralToken == NATIVE_TOKEN_ADDRESS) {
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(collateralToken, recipient, amount);
        }

        emit CollateralWithdrawn(msg.sender, collateralToken, debtToken, poolFee, amount, recipient);
        emit BorrowerStateUpdated(
            msg.sender,
            collateralToken,
            debtToken,
            poolFee,
            state.collateralAmount,
            state.debtAmount,
            state.liquidationInfo
        );
    }

    /// @inheritdoc IMoneyMarket
    function borrow(address collateralToken, address debtToken, uint64 poolFee, uint128 amount, address recipient)
        external
    {
        MoneyMarketConfig market = _requireMarketConfigured(collateralToken, debtToken, poolFee);
        bytes32 positionId = _positionId(collateralToken, debtToken, poolFee);
        BorrowerState memory state = _getBorrowerState(positionId, msg.sender);
        if (state.liquidationInfo.active()) revert LiquidationAlreadyActive();
        if (amount == 0) revert NoDebt();

        state.debtAmount += amount;
        uint256 healthFactor = _healthFactorX32(state, market, collateralToken, debtToken);
        if (healthFactor < ONE_X32) revert AccountStillUnhealthy(healthFactor);
        _setBorrowerBalances(positionId, msg.sender, state.collateralAmount, state.debtAmount);

        if (debtToken == NATIVE_TOKEN_ADDRESS) {
            if (address(this).balance < amount) revert InsufficientDebtLiquidity();
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            if (SafeTransferLib.balanceOf(debtToken, address(this)) < amount) revert InsufficientDebtLiquidity();
            SafeTransferLib.safeTransfer(debtToken, recipient, amount);
        }

        emit DebtBorrowed(msg.sender, collateralToken, debtToken, poolFee, amount, recipient);
        emit BorrowerStateUpdated(
            msg.sender,
            collateralToken,
            debtToken,
            poolFee,
            state.collateralAmount,
            state.debtAmount,
            state.liquidationInfo
        );
    }

    /// @inheritdoc IMoneyMarket
    function repay(address collateralToken, address debtToken, uint64 poolFee, uint128 amount)
        external
        payable
        returns (uint128 repaidAmount)
    {
        if (amount == 0) revert InvalidRepaymentAmount();
        _requireMarketConfigured(collateralToken, debtToken, poolFee);
        bytes32 positionId = _positionId(collateralToken, debtToken, poolFee);
        BorrowerState memory state = _getBorrowerState(positionId, msg.sender);
        if (state.debtAmount == 0) revert NoDebt();
        repaidAmount = amount < state.debtAmount ? amount : state.debtAmount;

        state.debtAmount -= repaidAmount;
        _setBorrowerBalances(positionId, msg.sender, state.collateralAmount, state.debtAmount);

        if (debtToken == NATIVE_TOKEN_ADDRESS) {
            if (msg.value != repaidAmount) revert IncorrectPaymentAmount();
        } else {
            if (msg.value != 0) revert IncorrectPaymentAmount();
            SafeTransferLib.safeTransferFrom(debtToken, msg.sender, address(this), repaidAmount);
        }

        emit DebtRepaid(msg.sender, collateralToken, debtToken, poolFee, repaidAmount);
        emit BorrowerStateUpdated(
            msg.sender,
            collateralToken,
            debtToken,
            poolFee,
            state.collateralAmount,
            state.debtAmount,
            state.liquidationInfo
        );
    }

    /// @inheritdoc IMoneyMarket
    function triggerLiquidation(
        address borrower,
        address collateralToken,
        address debtToken,
        uint64 poolFee,
        uint128 sellAmount,
        uint112 maxSaleRate
    ) external returns (bytes32 orderSalt, uint64 endTime, uint112 saleRate) {
        MoneyMarketConfig market = _requireMarketConfigured(collateralToken, debtToken, poolFee);
        bytes32 positionId = _positionId(collateralToken, debtToken, poolFee);
        BorrowerState memory state = _getBorrowerState(positionId, borrower);
        if (state.liquidationInfo.active()) revert LiquidationAlreadyActive();
        if (state.debtAmount == 0) revert NoDebt();
        if (sellAmount == 0 || sellAmount > state.collateralAmount) revert InsufficientCollateral();

        uint256 healthFactor = _healthFactorX32(state, market, collateralToken, debtToken);
        if (healthFactor >= ONE_X32) revert AccountHealthy(healthFactor);

        endTime = uint64(nextValidTime(block.timestamp, block.timestamp + uint256(market.liquidationDuration()) - 1));
        if (endTime <= block.timestamp) revert InvalidOrderEndTime();

        saleRate = uint112(computeSaleRate(sellAmount, uint32(endTime - block.timestamp)));
        if (saleRate > maxSaleRate) revert MaxSaleRateExceeded();

        orderSalt = _orderSalt(positionId, borrower);
        OrderKey memory key = _createOrderKey(collateralToken, debtToken, poolFee, endTime);
        _updateSaleRate(orderSalt, key, int112(saleRate), address(this));

        uint64 startTime = uint64(block.timestamp);
        LiquidationInfo liquidationInfo = createLiquidationInfo(startTime, uint32(endTime - startTime));
        state.liquidationInfo = liquidationInfo;
        _setBorrowerLiquidation(positionId, borrower, liquidationInfo);

        emit LiquidationStarted(borrower, collateralToken, debtToken, poolFee, orderSalt, endTime, sellAmount, saleRate);
    }

    /// @inheritdoc IMoneyMarket
    function cancelLiquidationIfRecovered(address borrower, address collateralToken, address debtToken, uint64 poolFee)
        external
        returns (uint128 refund, uint128 proceeds)
    {
        MoneyMarketConfig market = _requireMarketConfigured(collateralToken, debtToken, poolFee);
        bytes32 positionId = _positionId(collateralToken, debtToken, poolFee);
        BorrowerState memory state = _getBorrowerState(positionId, borrower);
        if (!state.liquidationInfo.active()) revert LiquidationNotActive();

        uint256 healthFactor = _healthFactorX32(state, market, collateralToken, debtToken);
        if (healthFactor < ONE_X32) revert AccountStillUnhealthy(healthFactor);

        uint64 liquidationEndTime = state.liquidationInfo.endTime();
        bytes32 orderSalt = _orderSalt(positionId, borrower);
        uint256 soldAmount;
        (state, soldAmount, refund, proceeds) = _settleLiquidation(
            state, orderSalt, _createOrderKey(collateralToken, debtToken, poolFee, liquidationEndTime)
        );
        _setBorrowerState(positionId, borrower, state);

        emit LiquidationCancelled(
            borrower, collateralToken, debtToken, poolFee, orderSalt, soldAmount, proceeds, refund
        );
        emit BorrowerStateUpdated(
            borrower,
            collateralToken,
            debtToken,
            poolFee,
            state.collateralAmount,
            state.debtAmount,
            state.liquidationInfo
        );
    }

    /// @inheritdoc IMoneyMarket
    function finalizeLiquidation(address borrower, address collateralToken, address debtToken, uint64 poolFee)
        external
        returns (uint128 refund, uint128 proceeds)
    {
        _requireMarketConfigured(collateralToken, debtToken, poolFee);
        bytes32 positionId = _positionId(collateralToken, debtToken, poolFee);
        BorrowerState memory state = _getBorrowerState(positionId, borrower);
        if (!state.liquidationInfo.active()) revert LiquidationNotActive();
        uint64 liquidationEndTime = state.liquidationInfo.endTime();
        if (block.timestamp < liquidationEndTime) {
            revert LiquidationStillRunning(liquidationEndTime);
        }

        bytes32 orderSalt = _orderSalt(positionId, borrower);
        uint256 soldAmount;
        (state, soldAmount, refund, proceeds) = _settleLiquidation(
            state, orderSalt, _createOrderKey(collateralToken, debtToken, poolFee, liquidationEndTime)
        );
        _setBorrowerState(positionId, borrower, state);

        emit LiquidationFinalized(
            borrower, collateralToken, debtToken, poolFee, orderSalt, soldAmount, proceeds, refund
        );
        emit BorrowerStateUpdated(
            borrower,
            collateralToken,
            debtToken,
            poolFee,
            state.collateralAmount,
            state.debtAmount,
            state.liquidationInfo
        );
    }

    /// @inheritdoc IMoneyMarket
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
        state.liquidationInfo = LiquidationInfo.wrap(0);

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
        returns (BorrowerState memory updatedState)
    {
        uint128 currentCollateral = state.collateralAmount;
        uint128 newCollateral = soldAmount >= currentCollateral ? 0 : uint128(uint256(currentCollateral) - soldAmount);
        uint128 currentDebt = state.debtAmount;
        uint128 newDebt = proceeds >= currentDebt ? 0 : currentDebt - proceeds;

        updatedState = BorrowerState({
            collateralAmount: newCollateral, debtAmount: newDebt, liquidationInfo: state.liquidationInfo
        });
    }

    function _healthFactorX32(
        BorrowerState memory state,
        MoneyMarketConfig market,
        address collateralToken,
        address debtToken
    ) internal view returns (uint256) {
        if (state.debtAmount == 0) return type(uint256).max;
        if (state.collateralAmount == 0) return 0;

        uint256 collateralValueInDebt = _quote(state.collateralAmount, collateralToken, debtToken, market);
        uint256 effectiveCollateralValueInDebt =
            FixedPointMathLib.fullMulDiv(collateralValueInDebt, market.ltvX32(), ONE_X32);
        return FixedPointMathLib.fullMulDiv(effectiveCollateralValueInDebt, ONE_X32, state.debtAmount);
    }

    function _quote(uint256 baseAmount, address baseToken, address quoteToken, MoneyMarketConfig market)
        internal
        view
        returns (uint256 quoteAmount)
    {
        if (baseToken == quoteToken) return baseAmount;
        int32 tick = _getAverageTick(baseToken, quoteToken, market);
        uint256 sqrtRatio = tickToSqrtRatio(tick).toFixed();
        uint256 ratio = FixedPointMathLib.fullMulDivN(sqrtRatio, sqrtRatio, 128);
        quoteAmount = FixedPointMathLib.fullMulDivN(baseAmount, ratio, 128);
    }

    function _getAverageTick(address baseToken, address quoteToken, MoneyMarketConfig market)
        internal
        view
        returns (int32 tick)
    {
        bool baseIsNative = baseToken == NATIVE_TOKEN_ADDRESS;
        if (baseIsNative || quoteToken == NATIVE_TOKEN_ADDRESS) {
            (int32 tickSign, address otherToken) = baseIsNative ? (int32(1), quoteToken) : (int32(-1), baseToken);
            uint256 twapDuration = market.twapDuration();
            uint256 startTime = block.timestamp > twapDuration ? block.timestamp - twapDuration : 0;
            (uint160 splStart, int64 tickCumulativeStart) = ORACLE.extrapolateSnapshot(otherToken, startTime);
            (uint160 splEnd, int64 tickCumulativeEnd) = ORACLE.extrapolateSnapshot(otherToken, block.timestamp);

            uint256 averageLiquidity;
            if (splEnd == splStart) {
                averageLiquidity = type(uint256).max;
            } else {
                averageLiquidity = (twapDuration << 128) / (uint256(splEnd) - uint256(splStart));
            }
            uint256 requiredLiquidity = uint256(1) << market.minLiquidityMagnitude();
            if (averageLiquidity < requiredLiquidity) {
                revert InsufficientOracleLiquidity(averageLiquidity, requiredLiquidity);
            }

            int64 averageTick = (tickCumulativeEnd - tickCumulativeStart) / int64(uint64(twapDuration));
            if (averageTick < MIN_TICK) return tickSign * MIN_TICK;
            if (averageTick > MAX_TICK) return tickSign * MAX_TICK;
            return tickSign * int32(averageTick);
        }

        int32 baseTick = _getAverageTick(NATIVE_TOKEN_ADDRESS, baseToken, market);
        int32 quoteTick = _getAverageTick(NATIVE_TOKEN_ADDRESS, quoteToken, market);
        int256 relativeTick = int256(quoteTick) - int256(baseTick);
        if (relativeTick < MIN_TICK) return MIN_TICK;
        if (relativeTick > MAX_TICK) return MAX_TICK;
        return int32(relativeTick);
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

    function _sortedTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert InvalidTokenPair();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _marketId(address token0, address token1, uint64 poolFee) internal pure returns (MarketId) {
        return MarketId.wrap(keccak256(abi.encodePacked(token0, token1, poolFee)));
    }

    function _positionId(address collateralToken, address debtToken, uint64 poolFee) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(collateralToken, debtToken, poolFee));
    }

    function _orderSalt(bytes32 positionId, address borrower) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(positionId, borrower));
    }

    function _requireMarketConfigured(address collateralToken, address debtToken, uint64 poolFee)
        internal
        view
        returns (MoneyMarketConfig market)
    {
        (address token0, address token1) = _sortedTokens(collateralToken, debtToken);
        market = _marketConfigs[_marketId(token0, token1, poolFee)];
        if (market.ltvX32() == 0) revert MarketNotConfigured();
    }

    function _getBorrowerState(bytes32 positionId, address borrower)
        internal
        view
        returns (BorrowerState memory state)
    {
        MoneyMarketBorrowerBalances packedBalances = _borrowerBalances[positionId][borrower];
        LiquidationInfo liquidationInfo = _borrowerLiquidations[positionId][borrower];
        state = BorrowerState({
            collateralAmount: packedBalances.collateralAmount(),
            debtAmount: packedBalances.debtAmount(),
            liquidationInfo: liquidationInfo
        });
    }

    function _setBorrowerBalances(bytes32 positionId, address borrower, uint128 collateral, uint128 debt) internal {
        _borrowerBalances[positionId][borrower] = createMoneyMarketBorrowerBalances(collateral, debt);
    }

    function _setBorrowerLiquidation(bytes32 positionId, address borrower, LiquidationInfo liquidationInfo) internal {
        _borrowerLiquidations[positionId][borrower] = liquidationInfo;
    }

    function _setBorrowerState(bytes32 positionId, address borrower, BorrowerState memory state) internal {
        _setBorrowerBalances(positionId, borrower, state.collateralAmount, state.debtAmount);
        _setBorrowerLiquidation(positionId, borrower, state.liquidationInfo);
    }
}
