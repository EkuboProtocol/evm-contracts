// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {OwnableRoles} from "solady/auth/OwnableRoles.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {ICore} from "./interfaces/ICore.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {PriceFetcher} from "./lens/PriceFetcher.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {computeSaleRate} from "./math/twamm.sol";
import {nextValidTime} from "./math/time.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {OrderKey} from "./types/orderKey.sol";
import {createOrderConfig} from "./types/orderConfig.sol";

contract IndexFund is ERC20, OwnableRoles, ReentrancyGuard, UsesCore, BaseLocker {
    using TWAMMLib for *;

    uint256 public constant KEEPER_ROLE = 1 << 0;
    uint256 public constant WEIGHT_SCALE = 1e18;
    uint256 private constant Q128 = 1 << 128;

    uint256 private constant CALL_TYPE_OPEN_ORDER = 0;
    uint256 private constant CALL_TYPE_COLLECT_ORDER = 1;

    error ZeroAddress();
    error ZeroAmount();
    error ZeroComponents();
    error WeightsMustSumToOne();
    error DuplicateComponent();
    error QuoteTokenCannotBeComponent();
    error InvalidInitialSharePrice();
    error InvalidCollectionPeriod();
    error InvalidOrderDuration();
    error CollectionPhaseOnly();
    error ExecutionPhaseOnly();
    error EpochNotReadyToClose();
    error EpochAlreadyStarted();
    error RebalanceNotStarted();
    error RebalanceAlreadyStarted();
    error RebalanceNotReady();
    error PreviousEpochStillOpen();
    error NothingToClaim();
    error NoCapital();
    error InsufficientOracleLiquidity(address token, uint128 observed, uint128 minimumRequired);
    error InvalidOrderAmount();
    error InvalidLockCall();

    event ComponentsUpdated();
    event EpochParametersUpdated(uint64 collectionPeriod, uint64 sellOrderDuration, uint64 buyOrderDuration);
    event SubscriptionQueued(uint256 indexed epochId, address indexed owner, address indexed receiver, uint256 amountQ);
    event RedemptionQueued(uint256 indexed epochId, address indexed owner, address indexed receiver, uint256 shares);
    event EpochClosed(
        uint256 indexed epochId,
        uint64 collectionStart,
        uint64 collectionEnd,
        uint256 navQuote,
        uint256 sharePriceQuote,
        uint256 postFlowAumQuote
    );
    event RebalanceOrderOpened(
        uint256 indexed epochId,
        address indexed token,
        bool indexed isBuyOrder,
        bytes32 salt,
        uint256 sellAmount,
        uint64 startTime,
        uint64 endTime
    );
    event RebalanceOrderCollected(
        uint256 indexed epochId, address indexed token, bool indexed isBuyOrder, bytes32 salt, uint256 proceeds
    );
    event EpochSettled(uint256 indexed epochId, uint256 mintedShares, uint256 redemptionQuoteReserved);
    event SharesClaimed(uint256 indexed epochId, address indexed owner, address indexed receiver, uint256 shares);
    event QuoteClaimed(uint256 indexed epochId, address indexed owner, address indexed receiver, uint256 amountQ);

    enum EpochPhase {
        Collection,
        Execution,
        Settled
    }

    enum RebalanceStage {
        None,
        Sell,
        Buy,
        Ready
    }

    enum OrderStatus {
        None,
        Open,
        Collected
    }

    struct ComponentConfig {
        address token;
        uint256 weightX18;
        uint64 twammFee;
        uint128 minOracleLiquidity;
    }

    struct EpochState {
        uint64 collectionStart;
        uint64 collectionEnd;
        uint64 sellStart;
        uint64 sellEnd;
        uint64 buyStart;
        uint64 buyEnd;
        uint256 navQuote;
        uint256 sharePriceQuote;
        uint256 postFlowAumQuote;
        uint256 totalSubscriptionsQuote;
        uint256 totalRedemptionShares;
        uint256 totalRedemptionQuote;
        uint256 totalMintedShares;
        uint256 remainingSubscriptionQuote;
        uint256 remainingMintedShares;
        uint256 remainingRedemptionShares;
        uint256 remainingRedemptionQuote;
        EpochPhase phase;
        RebalanceStage rebalanceStage;
    }

    struct EpochComponentState {
        uint256 priceX128;
        uint128 oracleLiquidity;
        uint256 closeBalance;
        uint256 closeValueQuote;
        uint256 targetValueQuote;
        uint256 plannedSellAmount;
        uint256 plannedBuyValueQuote;
        uint256 openedSellAmount;
        uint256 sellProceedsQuote;
        uint256 openedBuyQuoteAmount;
        uint256 boughtComponentAmount;
        bytes32 sellOrderSalt;
        bytes32 buyOrderSalt;
        OrderStatus sellOrderStatus;
        OrderStatus buyOrderStatus;
    }

    IERC20 public immutable QUOTE_TOKEN;
    PriceFetcher public immutable PRICE_FETCHER;
    ITWAMM public immutable TWAMM;
    uint256 public immutable INITIAL_SHARE_PRICE;

    uint64 public collectionPeriod;
    uint64 public sellOrderDuration;
    uint64 public buyOrderDuration;

    uint256 public currentEpochId;
    uint256 public reservedRedemptionQuote;

    string private _tokenName;
    string private _tokenSymbol;

    ComponentConfig[] private _components;

    mapping(uint256 epochId => EpochState) public epochs;
    mapping(uint256 epochId => mapping(address receiver => uint256 amountQ)) public queuedSubscriptions;
    mapping(uint256 epochId => mapping(address receiver => uint256 shares)) public queuedRedemptions;
    mapping(uint256 epochId => mapping(address token => EpochComponentState)) private _epochComponentStates;

    modifier onlyKeeper() {
        _checkOwnerOrRoles(KEEPER_ROLE);
        _;
    }

    constructor(
        ICore core,
        ITWAMM twamm,
        PriceFetcher priceFetcher,
        IERC20 quoteToken,
        string memory tokenName_,
        string memory tokenSymbol_,
        address owner_,
        uint256 initialSharePrice_,
        uint64 collectionPeriod_,
        uint64 sellOrderDuration_,
        uint64 buyOrderDuration_,
        ComponentConfig[] memory initialComponents
    ) UsesCore(core) BaseLocker(core) {
        if (owner_ == address(0) || address(twamm) == address(0) || address(priceFetcher) == address(0)) {
            revert ZeroAddress();
        }
        if (address(quoteToken) == address(0)) revert ZeroAddress();
        if (initialSharePrice_ == 0) revert InvalidInitialSharePrice();

        _initializeOwner(owner_);

        QUOTE_TOKEN = quoteToken;
        PRICE_FETCHER = priceFetcher;
        TWAMM = twamm;
        INITIAL_SHARE_PRICE = initialSharePrice_;

        _tokenName = tokenName_;
        _tokenSymbol = tokenSymbol_;

        _setEpochParameters(collectionPeriod_, sellOrderDuration_, buyOrderDuration_);
        _setComponents(initialComponents);

        currentEpochId = 1;
        epochs[currentEpochId].collectionStart = uint64(block.timestamp);
        epochs[currentEpochId].phase = EpochPhase.Collection;
    }

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    function componentCount() external view returns (uint256) {
        return _components.length;
    }

    function getComponent(uint256 index) external view returns (ComponentConfig memory) {
        return _components[index];
    }

    function getEpochComponentState(uint256 epochId, address token) external view returns (EpochComponentState memory) {
        return _epochComponentStates[epochId][token];
    }

    function getEpochState(uint256 epochId) external view returns (EpochState memory) {
        return epochs[epochId];
    }

    function setKeeper(address keeper, bool allowed) external onlyOwner {
        if (keeper == address(0)) revert ZeroAddress();
        if (allowed) {
            _grantRoles(keeper, KEEPER_ROLE);
        } else {
            _removeRoles(keeper, KEEPER_ROLE);
        }
    }

    function setEpochParameters(uint64 collectionPeriod_, uint64 sellOrderDuration_, uint64 buyOrderDuration_)
        external
        onlyOwner
    {
        _setEpochParameters(collectionPeriod_, sellOrderDuration_, buyOrderDuration_);
    }

    function setComponents(ComponentConfig[] calldata newComponents) external onlyOwner {
        if (epochs[currentEpochId].phase != EpochPhase.Collection) revert PreviousEpochStillOpen();
        _setComponents(newComponents);
    }

    function queueSubscription(uint256 amountQ, address receiver) external nonReentrant {
        if (amountQ == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        EpochState storage epoch = epochs[currentEpochId];
        if (epoch.phase != EpochPhase.Collection) revert CollectionPhaseOnly();

        SafeTransferLib.safeTransferFrom(address(QUOTE_TOKEN), msg.sender, address(this), amountQ);

        queuedSubscriptions[currentEpochId][receiver] += amountQ;
        epoch.totalSubscriptionsQuote += amountQ;

        emit SubscriptionQueued(currentEpochId, msg.sender, receiver, amountQ);
    }

    function queueRedemption(uint256 shares, address receiver) external nonReentrant {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        EpochState storage epoch = epochs[currentEpochId];
        if (epoch.phase != EpochPhase.Collection) revert CollectionPhaseOnly();

        _spendAllowance(msg.sender, address(this), shares);
        _transfer(msg.sender, address(this), shares);

        queuedRedemptions[currentEpochId][receiver] += shares;
        epoch.totalRedemptionShares += shares;

        emit RedemptionQueued(currentEpochId, msg.sender, receiver, shares);
    }

    function closeEpoch() external onlyKeeper nonReentrant {
        EpochState storage epoch = epochs[currentEpochId];
        if (epoch.phase != EpochPhase.Collection) revert CollectionPhaseOnly();
        if (block.timestamp < uint256(epoch.collectionStart) + collectionPeriod) revert EpochNotReadyToClose();

        uint256 shareSupply = totalSupply();
        if (shareSupply == 0 && epoch.totalSubscriptionsQuote == 0) revert NoCapital();

        uint64 collectionEnd = uint64(block.timestamp);
        uint256 portfolioQuote = _portfolioQuoteBalance(epoch.totalSubscriptionsQuote);
        uint256 navQuote = portfolioQuote;
        uint256 postFlowAumQuote;

        for (uint256 i = 0; i < _components.length; ++i) {
            ComponentConfig memory component = _components[i];
            EpochComponentState storage componentState = _epochComponentStates[currentEpochId][component.token];

            (uint256 priceX128, uint128 observedLiquidity) =
                _getPriceX128(component.token, epoch.collectionStart, collectionEnd);
            if (observedLiquidity < component.minOracleLiquidity) {
                revert InsufficientOracleLiquidity(component.token, observedLiquidity, component.minOracleLiquidity);
            }

            uint256 closeBalance = IERC20(component.token).balanceOf(address(this));
            uint256 closeValueQuote = _quoteAmountFromPrice(closeBalance, priceX128);

            componentState.priceX128 = priceX128;
            componentState.oracleLiquidity = observedLiquidity;
            componentState.closeBalance = closeBalance;
            componentState.closeValueQuote = closeValueQuote;

            navQuote += closeValueQuote;
        }

        uint256 sharePriceQuote =
            shareSupply == 0 ? INITIAL_SHARE_PRICE : FixedPointMathLib.fullMulDiv(navQuote, 1e18, shareSupply);
        uint256 totalRedemptionQuote =
            shareSupply == 0 ? 0 : FixedPointMathLib.fullMulDiv(epoch.totalRedemptionShares, sharePriceQuote, 1e18);
        uint256 totalMintedShares = epoch.totalSubscriptionsQuote == 0
            ? 0
            : FixedPointMathLib.fullMulDiv(epoch.totalSubscriptionsQuote, 1e18, sharePriceQuote);

        postFlowAumQuote = navQuote + epoch.totalSubscriptionsQuote - totalRedemptionQuote;

        epoch.collectionEnd = collectionEnd;
        epoch.navQuote = navQuote;
        epoch.sharePriceQuote = sharePriceQuote;
        epoch.postFlowAumQuote = postFlowAumQuote;
        epoch.totalRedemptionQuote = totalRedemptionQuote;
        epoch.totalMintedShares = totalMintedShares;
        epoch.phase = EpochPhase.Execution;
        epoch.rebalanceStage = RebalanceStage.None;

        for (uint256 i = 0; i < _components.length; ++i) {
            ComponentConfig memory component = _components[i];
            EpochComponentState storage componentState = _epochComponentStates[currentEpochId][component.token];

            uint256 targetValueQuote = FixedPointMathLib.fullMulDiv(postFlowAumQuote, component.weightX18, WEIGHT_SCALE);
            componentState.targetValueQuote = targetValueQuote;

            if (componentState.closeValueQuote > targetValueQuote) {
                uint256 sellValueQuote = componentState.closeValueQuote - targetValueQuote;
                componentState.plannedSellAmount = FixedPointMathLib.min(
                    componentState.closeBalance, _baseAmountFromPrice(sellValueQuote, componentState.priceX128)
                );
                componentState.plannedBuyValueQuote = 0;
            } else {
                componentState.plannedSellAmount = 0;
                componentState.plannedBuyValueQuote = targetValueQuote - componentState.closeValueQuote;
            }
        }

        emit EpochClosed(
            currentEpochId, epoch.collectionStart, collectionEnd, navQuote, sharePriceQuote, postFlowAumQuote
        );
    }

    function startRebalance() external onlyKeeper nonReentrant {
        EpochState storage epoch = epochs[currentEpochId];
        if (epoch.phase != EpochPhase.Execution) revert ExecutionPhaseOnly();
        if (epoch.rebalanceStage != RebalanceStage.None) revert RebalanceAlreadyStarted();

        if (_openSellOrders(epoch)) {
            epoch.rebalanceStage = RebalanceStage.Sell;
            return;
        }

        if (_openBuyOrders(epoch)) {
            epoch.rebalanceStage = RebalanceStage.Buy;
            return;
        }

        epoch.rebalanceStage = RebalanceStage.Ready;
    }

    function continueRebalance() external onlyKeeper nonReentrant {
        EpochState storage epoch = epochs[currentEpochId];
        if (epoch.phase != EpochPhase.Execution) revert ExecutionPhaseOnly();

        if (epoch.rebalanceStage == RebalanceStage.None) revert RebalanceNotStarted();

        if (epoch.rebalanceStage == RebalanceStage.Sell) {
            if (!_collectMaturedOrders(epoch, false)) return;

            if (_openBuyOrders(epoch)) {
                epoch.rebalanceStage = RebalanceStage.Buy;
            } else {
                epoch.rebalanceStage = RebalanceStage.Ready;
            }
            return;
        }

        if (epoch.rebalanceStage == RebalanceStage.Buy) {
            if (_collectMaturedOrders(epoch, true)) {
                epoch.rebalanceStage = RebalanceStage.Ready;
            }
            return;
        }

        revert RebalanceNotReady();
    }

    function settleEpoch() external onlyKeeper nonReentrant {
        EpochState storage epoch = epochs[currentEpochId];
        if (epoch.phase != EpochPhase.Execution) revert ExecutionPhaseOnly();
        if (epoch.rebalanceStage != RebalanceStage.Ready) revert RebalanceNotReady();

        epoch.remainingSubscriptionQuote = epoch.totalSubscriptionsQuote;
        epoch.remainingMintedShares = epoch.totalMintedShares;
        epoch.remainingRedemptionShares = epoch.totalRedemptionShares;
        epoch.remainingRedemptionQuote = epoch.totalRedemptionQuote;
        epoch.phase = EpochPhase.Settled;

        if (epoch.totalRedemptionShares != 0) {
            _burn(address(this), epoch.totalRedemptionShares);
        }

        if (epoch.totalMintedShares != 0) {
            _mint(address(this), epoch.totalMintedShares);
        }

        reservedRedemptionQuote += epoch.totalRedemptionQuote;

        emit EpochSettled(currentEpochId, epoch.totalMintedShares, epoch.totalRedemptionQuote);

        unchecked {
            currentEpochId++;
        }
        epochs[currentEpochId].collectionStart = uint64(block.timestamp);
        epochs[currentEpochId].phase = EpochPhase.Collection;
    }

    function claimShares(uint256 epochId, address receiver) external nonReentrant returns (uint256 claimedShares) {
        if (receiver == address(0)) revert ZeroAddress();

        EpochState storage epoch = epochs[epochId];
        if (epoch.phase != EpochPhase.Settled) revert RebalanceNotReady();

        uint256 subscriptionAmount = queuedSubscriptions[epochId][msg.sender];
        if (subscriptionAmount == 0) revert NothingToClaim();

        uint256 remainingSubscriptions = epoch.remainingSubscriptionQuote;
        if (subscriptionAmount == remainingSubscriptions) {
            claimedShares = epoch.remainingMintedShares;
        } else {
            claimedShares =
                FixedPointMathLib.fullMulDiv(subscriptionAmount, epoch.remainingMintedShares, remainingSubscriptions);
        }

        queuedSubscriptions[epochId][msg.sender] = 0;
        epoch.remainingSubscriptionQuote = remainingSubscriptions - subscriptionAmount;
        epoch.remainingMintedShares -= claimedShares;

        if (claimedShares != 0) {
            _transfer(address(this), receiver, claimedShares);
        }

        emit SharesClaimed(epochId, msg.sender, receiver, claimedShares);
    }

    function claimQuote(uint256 epochId, address receiver) external nonReentrant returns (uint256 claimedQuote) {
        if (receiver == address(0)) revert ZeroAddress();

        EpochState storage epoch = epochs[epochId];
        if (epoch.phase != EpochPhase.Settled) revert RebalanceNotReady();

        uint256 redemptionShares = queuedRedemptions[epochId][msg.sender];
        if (redemptionShares == 0) revert NothingToClaim();

        uint256 remainingShares = epoch.remainingRedemptionShares;
        if (redemptionShares == remainingShares) {
            claimedQuote = epoch.remainingRedemptionQuote;
        } else {
            claimedQuote =
                FixedPointMathLib.fullMulDiv(redemptionShares, epoch.remainingRedemptionQuote, remainingShares);
        }

        queuedRedemptions[epochId][msg.sender] = 0;
        epoch.remainingRedemptionShares = remainingShares - redemptionShares;
        epoch.remainingRedemptionQuote -= claimedQuote;
        reservedRedemptionQuote -= claimedQuote;

        if (claimedQuote != 0) {
            SafeTransferLib.safeTransfer(address(QUOTE_TOKEN), receiver, claimedQuote);
        }

        emit QuoteClaimed(epochId, msg.sender, receiver, claimedQuote);
    }

    function previewSharesClaim(uint256 epochId, address account) external view returns (uint256) {
        EpochState storage epoch = epochs[epochId];
        uint256 subscriptionAmount = queuedSubscriptions[epochId][account];
        if (subscriptionAmount == 0 || epoch.remainingSubscriptionQuote == 0) return 0;

        if (subscriptionAmount == epoch.remainingSubscriptionQuote) {
            return epoch.remainingMintedShares;
        }
        return
            FixedPointMathLib.fullMulDiv(
                subscriptionAmount, epoch.remainingMintedShares, epoch.remainingSubscriptionQuote
            );
    }

    function previewQuoteClaim(uint256 epochId, address account) external view returns (uint256) {
        EpochState storage epoch = epochs[epochId];
        uint256 redemptionShares = queuedRedemptions[epochId][account];
        if (redemptionShares == 0 || epoch.remainingRedemptionShares == 0) return 0;

        if (redemptionShares == epoch.remainingRedemptionShares) {
            return epoch.remainingRedemptionQuote;
        }
        return
            FixedPointMathLib.fullMulDiv(
                redemptionShares, epoch.remainingRedemptionQuote, epoch.remainingRedemptionShares
            );
    }

    function portfolioQuoteBalance() external view returns (uint256) {
        return _portfolioQuoteBalance(epochs[currentEpochId].totalSubscriptionsQuote);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_OPEN_ORDER) {
            (, bytes32 salt, OrderKey memory orderKey, int112 saleRateDelta) =
                abi.decode(data, (uint256, bytes32, OrderKey, int112));

            uint256 amountToCommit = uint256(
                int256(
                    CORE.updateSaleRate({twamm: TWAMM, salt: salt, orderKey: orderKey, saleRateDelta: saleRateDelta})
                )
            );
            FlashAccountantLib.pay(ACCOUNTANT, orderKey.sellToken(), amountToCommit);

            return abi.encode(amountToCommit);
        }

        if (callType == CALL_TYPE_COLLECT_ORDER) {
            (, bytes32 salt, OrderKey memory orderKey) = abi.decode(data, (uint256, bytes32, OrderKey));

            uint128 proceeds = CORE.collectProceeds(TWAMM, salt, orderKey);
            if (proceeds != 0) {
                FlashAccountantLib.withdraw(ACCOUNTANT, orderKey.buyToken(), address(this), proceeds);
            }

            return abi.encode(uint256(proceeds));
        }

        revert InvalidLockCall();
    }

    function _setEpochParameters(uint64 collectionPeriod_, uint64 sellOrderDuration_, uint64 buyOrderDuration_)
        internal
    {
        if (collectionPeriod_ == 0) revert InvalidCollectionPeriod();
        if (sellOrderDuration_ != 0 && sellOrderDuration_ < 256) revert InvalidOrderDuration();
        if (buyOrderDuration_ != 0 && buyOrderDuration_ < 256) revert InvalidOrderDuration();

        collectionPeriod = collectionPeriod_;
        sellOrderDuration = sellOrderDuration_;
        buyOrderDuration = buyOrderDuration_;

        emit EpochParametersUpdated(collectionPeriod_, sellOrderDuration_, buyOrderDuration_);
    }

    function _setComponents(ComponentConfig[] memory newComponents) internal {
        uint256 totalWeight;
        uint256 length = newComponents.length;
        if (length == 0) revert ZeroComponents();

        delete _components;

        for (uint256 i = 0; i < length; ++i) {
            ComponentConfig memory component = newComponents[i];
            if (component.token == address(0)) revert ZeroAddress();
            if (component.token == address(QUOTE_TOKEN)) revert QuoteTokenCannotBeComponent();
            if (component.weightX18 == 0) revert ZeroAmount();

            for (uint256 j = 0; j < i; ++j) {
                if (newComponents[j].token == component.token) revert DuplicateComponent();
            }

            totalWeight += component.weightX18;
            _components.push(component);
        }

        if (totalWeight != WEIGHT_SCALE) revert WeightsMustSumToOne();

        emit ComponentsUpdated();
    }

    function _openSellOrders(EpochState storage epoch) internal returns (bool openedAny) {
        if (sellOrderDuration == 0) return false;

        (uint64 startTime, uint64 endTime) = _computeOrderWindow(sellOrderDuration);
        epoch.sellStart = startTime;
        epoch.sellEnd = endTime;

        for (uint256 i = 0; i < _components.length; ++i) {
            ComponentConfig memory component = _components[i];
            EpochComponentState storage componentState = _epochComponentStates[currentEpochId][component.token];
            uint256 plannedSellAmount = componentState.plannedSellAmount;
            if (plannedSellAmount == 0) continue;

            bytes32 salt = _orderSalt(currentEpochId, component.token, false);
            uint256 openedAmount = _openOrder(component, false, plannedSellAmount, startTime, endTime, salt);
            if (openedAmount == 0) continue;

            componentState.sellOrderSalt = salt;
            componentState.openedSellAmount = openedAmount;
            componentState.sellOrderStatus = OrderStatus.Open;
            openedAny = true;

            emit RebalanceOrderOpened(currentEpochId, component.token, false, salt, openedAmount, startTime, endTime);
        }
    }

    function _openBuyOrders(EpochState storage epoch) internal returns (bool openedAny) {
        if (buyOrderDuration == 0) return false;

        uint256 totalDeficitQuote;
        uint256 budgetToSpend;
        uint256[] memory deficits = new uint256[](_components.length);

        for (uint256 i = 0; i < _components.length; ++i) {
            ComponentConfig memory component = _components[i];
            EpochComponentState storage componentState = _epochComponentStates[currentEpochId][component.token];

            uint256 currentBalance = IERC20(component.token).balanceOf(address(this));
            uint256 currentValueQuote = _quoteAmountFromPrice(currentBalance, componentState.priceX128);

            if (componentState.targetValueQuote > currentValueQuote) {
                uint256 deficitQuote = componentState.targetValueQuote - currentValueQuote;
                deficits[i] = deficitQuote;
                totalDeficitQuote += deficitQuote;
            }
        }

        if (totalDeficitQuote == 0) return false;

        budgetToSpend = FixedPointMathLib.min(_availableRebalanceQuote(), totalDeficitQuote);
        if (budgetToSpend == 0) return false;

        (uint64 startTime, uint64 endTime) = _computeOrderWindow(buyOrderDuration);
        epoch.buyStart = startTime;
        epoch.buyEnd = endTime;

        uint256 remainingBudget = budgetToSpend;
        uint256 remainingDeficitQuote = totalDeficitQuote;

        for (uint256 i = 0; i < _components.length; ++i) {
            uint256 deficitQuote = deficits[i];
            if (deficitQuote == 0) continue;

            ComponentConfig memory component = _components[i];
            EpochComponentState storage componentState = _epochComponentStates[currentEpochId][component.token];

            uint256 buyQuoteAmount = deficitQuote == remainingDeficitQuote
                ? remainingBudget
                : FixedPointMathLib.fullMulDiv(deficitQuote, remainingBudget, remainingDeficitQuote);

            remainingBudget -= buyQuoteAmount;
            remainingDeficitQuote -= deficitQuote;

            if (buyQuoteAmount == 0) continue;

            bytes32 salt = _orderSalt(currentEpochId, component.token, true);
            uint256 openedAmount = _openOrder(component, true, buyQuoteAmount, startTime, endTime, salt);
            if (openedAmount == 0) continue;

            componentState.buyOrderSalt = salt;
            componentState.openedBuyQuoteAmount = openedAmount;
            componentState.buyOrderStatus = OrderStatus.Open;
            openedAny = true;

            emit RebalanceOrderOpened(currentEpochId, component.token, true, salt, openedAmount, startTime, endTime);
        }
    }

    function _collectMaturedOrders(EpochState storage epoch, bool isBuyOrder) internal returns (bool allCollected) {
        allCollected = true;
        uint64 endTime = isBuyOrder ? epoch.buyEnd : epoch.sellEnd;

        for (uint256 i = 0; i < _components.length; ++i) {
            ComponentConfig memory component = _components[i];
            EpochComponentState storage componentState = _epochComponentStates[currentEpochId][component.token];
            OrderStatus status = isBuyOrder ? componentState.buyOrderStatus : componentState.sellOrderStatus;
            if (status != OrderStatus.Open) continue;

            bytes32 salt = isBuyOrder ? componentState.buyOrderSalt : componentState.sellOrderSalt;
            OrderKey memory orderKey =
                _createOrderKey(component, isBuyOrder, isBuyOrder ? epoch.buyStart : epoch.sellStart, endTime);

            TWAMM.executeVirtualOrdersAndGetCurrentOrderInfo(address(this), salt, orderKey);

            if (block.timestamp < endTime) {
                allCollected = false;
                continue;
            }

            uint256 proceeds = _collectOrder(salt, orderKey);
            if (isBuyOrder) {
                componentState.boughtComponentAmount = proceeds;
                componentState.buyOrderStatus = OrderStatus.Collected;
            } else {
                componentState.sellProceedsQuote = proceeds;
                componentState.sellOrderStatus = OrderStatus.Collected;
            }

            emit RebalanceOrderCollected(currentEpochId, component.token, isBuyOrder, salt, proceeds);
        }
    }

    function _openOrder(
        ComponentConfig memory component,
        bool isBuyOrder,
        uint256 sellAmount,
        uint64 startTime,
        uint64 endTime,
        bytes32 salt
    ) internal returns (uint256 openedAmount) {
        if (sellAmount == 0) return 0;

        uint256 duration = endTime - startTime;
        uint256 saleRate = computeSaleRate(sellAmount, duration);
        if (saleRate == 0 || saleRate > uint256(uint112(type(int112).max))) revert InvalidOrderAmount();

        OrderKey memory orderKey = _createOrderKey(component, isBuyOrder, startTime, endTime);
        openedAmount = abi.decode(
            lock(abi.encode(CALL_TYPE_OPEN_ORDER, salt, orderKey, SafeCastLib.toInt112(saleRate))), (uint256)
        );
    }

    function _collectOrder(bytes32 salt, OrderKey memory orderKey) internal returns (uint256 proceeds) {
        proceeds = abi.decode(lock(abi.encode(CALL_TYPE_COLLECT_ORDER, salt, orderKey)), (uint256));
    }

    function _computeOrderWindow(uint64 requestedDuration) internal view returns (uint64 startTime, uint64 endTime) {
        uint256 startTimeRaw = nextValidTime(block.timestamp, block.timestamp);
        uint256 endTimeRaw = nextValidTime(block.timestamp, startTimeRaw + requestedDuration - 1);
        if (startTimeRaw == 0 || endTimeRaw == 0 || endTimeRaw <= startTimeRaw || endTimeRaw > type(uint64).max) {
            revert InvalidOrderDuration();
        }

        startTime = uint64(startTimeRaw);
        endTime = uint64(endTimeRaw);
    }

    function _createOrderKey(ComponentConfig memory component, bool isBuyOrder, uint64 startTime, uint64 endTime)
        internal
        view
        returns (OrderKey memory orderKey)
    {
        address tokenA = component.token;
        address tokenB = address(QUOTE_TOKEN);
        bool quoteIsToken1 = tokenB > tokenA;

        orderKey = OrderKey({
            token0: tokenA < tokenB ? tokenA : tokenB,
            token1: tokenA < tokenB ? tokenB : tokenA,
            config: createOrderConfig({
                _fee: component.twammFee,
                _isToken1: isBuyOrder ? quoteIsToken1 : !quoteIsToken1,
                _startTime: startTime,
                _endTime: endTime
            })
        });
    }

    function _orderSalt(uint256 epochId, address token, bool isBuyOrder) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(epochId, token, isBuyOrder));
    }

    function _getPriceX128(address baseToken, uint64 startTime, uint64 endTime)
        internal
        view
        returns (uint256 priceX128, uint128 liquidity)
    {
        if (baseToken == address(QUOTE_TOKEN)) return (Q128, type(uint128).max);

        PriceFetcher.PeriodAverage memory average =
            PRICE_FETCHER.getAveragesOverPeriod(baseToken, address(QUOTE_TOKEN), startTime, endTime);
        uint256 sqrtRatio = tickToSqrtRatio(average.tick).toFixed();
        return (FixedPointMathLib.fullMulDivN(sqrtRatio, sqrtRatio, 128), average.liquidity);
    }

    function _quoteAmountFromPrice(uint256 amountBase, uint256 priceX128) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(amountBase, priceX128, Q128);
    }

    function _baseAmountFromPrice(uint256 amountQuote, uint256 priceX128) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(amountQuote, Q128, priceX128);
    }

    function _availableRebalanceQuote() internal view returns (uint256) {
        return QUOTE_TOKEN.balanceOf(address(this)) - reservedRedemptionQuote;
    }

    function _portfolioQuoteBalance(uint256 pendingSubscriptions) internal view returns (uint256) {
        return QUOTE_TOKEN.balanceOf(address(this)) - reservedRedemptionQuote - pendingSubscriptions;
    }
}
