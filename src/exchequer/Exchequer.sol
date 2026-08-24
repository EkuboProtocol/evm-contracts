// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {BaseLocker} from "../base/BaseLocker.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {ICore} from "../interfaces/ICore.sol";
import {IRevenueBuybacks} from "../interfaces/IRevenueBuybacks.sol";
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {maxLiquidity} from "../math/liquidity.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {CallPoints} from "../types/callPoints.sol";
import {Locker} from "../types/locker.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PoolConfig, createConcentratedPoolConfig} from "../types/poolConfig.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolState} from "../types/poolState.sol";
import {Position} from "../types/position.sol";
import {PositionId, createPositionId} from "../types/positionId.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";

import {BankToken, IBankShareHook} from "./BankToken.sol";
import {IssueToken} from "./IssueToken.sol";

/// @notice Every monetary parameter the whitepaper redacts, supplied at construction
struct ExchequerParameters {
    /// @notice $ISSUE issued per day at a multiplier of exactly 1 (whitepaper §5)
    uint128 baseIssuancePerDay;
    /// @notice Multiplier floor, in 1e18 fixed point
    uint64 multiplierMin;
    /// @notice Multiplier ceiling, in 1e18 fixed point
    uint64 multiplierMax;
    /// @notice Multiplier at launch, in 1e18 fixed point
    uint64 multiplierLaunch;
    /// @notice Amount the multiplier falls per contraction epoch, in 1e18 fixed point
    uint64 multiplierCutStep;
    /// @notice Amount the multiplier rises per expansion epoch, in 1e18 fixed point
    uint64 multiplierRaiseStep;
    /// @notice Epoch length in seconds (whitepaper §4)
    uint32 epochLength;
    /// @notice Trading fee as a 0.64 fixed point fraction, always charged in ETH
    uint64 tradingFee;
    /// @notice Concentrated tick spacing of the one canonical pool
    uint32 tickSpacing;
    /// @notice Resolution fee at zero exit pressure, in 1e18 fixed point (whitepaper §9)
    uint64 resolutionFeeFloor;
    /// @notice Resolution fee at or above saturation, in 1e18 fixed point
    uint64 resolutionFeeCeiling;
    /// @notice Exit pressure at which the resolution fee reaches its ceiling, in 1e18 fixed point
    uint64 exitPressureSaturation;
    /// @notice Lower bound on the exit pressure denominator, per eq 9.1
    uint128 exitPressureDenominatorFloor;
    /// @notice Seconds a price must prevail to fully replace the bank's reference price
    uint32 polReferenceWindow;
    /// @notice Seconds over which the redistributed half of each resolution fee is streamed
    uint32 redistributionStreamLength;
    /// @notice Least net ETH inflow, in wei, for an epoch to count as expansion
    uint128 minNetFlow;
}

/// @title Exchequer
/// @notice The issuing authority of the Exchequer economy: it reads net flow through the one
///         canonical ETH/$ISSUE market, sets the issuance rate, and routes fees.
/// @dev See docs/exchequer.md for the mapping from the whitepaper to this implementation and
///      for the mechanisms deliberately dropped when charters and branches collapsed into one
///      fungible share.
///
///      Swaps must arrive through `Core.forward`, which is what lets the bank charge its fee in ETH
///      on both buys and sells. The bank itself never swaps: protocol-owned liquidity and buybacks
///      are both placed as standing bids below the market, so there is nothing to sandwich.
contract Exchequer is BaseExtension, BaseForwardee, BaseLocker, Ownable, IBankShareHook {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    /// @notice The only pre-mint: protocol-owned liquidity locked into the pool forever (§3)
    uint256 public constant GENESIS_LIQUIDITY = 100_000_000e18;

    /// @notice Cumulative base issuance available across all time (§3)
    uint256 public constant ISSUANCE_BUDGET = 900_000_000e18;

    /// @notice Total $BANK mintable through the free founding distribution (§6)
    uint256 public constant FOUNDING_BANK_SUPPLY = 1_000e18;

    /// @notice Share of protocol ETH routed to the active vault, in basis points (§11)
    uint256 public constant VAULT_SHARE_BPS = 7000;

    /// @notice Share of protocol ETH routed to protocol-owned liquidity, in basis points (§11)
    uint256 public constant POL_SHARE_BPS = 1500;

    /// @dev Fixed point scale for the multiplier and every fee fraction
    uint256 private constant WAD = 1e18;

    /// @dev Number of daily buckets in the trailing exit pressure window (§9)
    uint256 private constant EXIT_BUCKETS = 7;

    /// @dev Saved balance salt under which the bank's unrouted fee ETH sits in Core
    bytes32 private constant FEE_SALT = bytes32(0);

    /// @dev Salt of every protocol-owned liquidity position: the genesis range and each bid bucket
    bytes24 private constant POL_SALT = bytes24(0);

    /// @dev Salt of the single active buyback bid bucket
    bytes24 private constant BUYBACK_SALT = bytes24(uint192(1));

    uint256 private constant CALL_TYPE_GENESIS = 0;
    uint256 private constant CALL_TYPE_SWEEP = 1;
    uint256 private constant CALL_TYPE_COMPOUND = 2;
    uint256 private constant CALL_TYPE_DEFEND = 3;

    /// @notice The currency
    IssueToken public immutable ISSUE_TOKEN;

    /// @notice The branch share. One whole token is one branch.
    BankToken public immutable BANK_TOKEN;

    /// @notice The hard reserve asset the expansion vault accumulates, fixed at construction (§11)
    address public immutable RESERVE_ASSET;

    /// @notice Configuration of the one canonical ETH/$ISSUE pool
    PoolConfig public immutable POOL_CONFIG;

    /// @notice Lower bound of the protocol-owned liquidity position, the lowest aligned tick
    int32 public immutable POL_TICK_LOWER;

    /// @notice Upper bound of the protocol-owned liquidity position, the highest aligned tick
    int32 public immutable POL_TICK_UPPER;

    /// @notice Spacing of the grid on which bid buckets are placed, ten tick spacings
    int32 public immutable POL_BID_GRID;

    uint128 public immutable BASE_ISSUANCE_PER_DAY;
    uint64 public immutable MULTIPLIER_MIN;
    uint64 public immutable MULTIPLIER_MAX;
    uint64 public immutable MULTIPLIER_CUT_STEP;
    uint64 public immutable MULTIPLIER_RAISE_STEP;
    uint32 public immutable EPOCH_LENGTH;
    uint64 public immutable TRADING_FEE;
    uint64 public immutable RESOLUTION_FEE_FLOOR;
    uint64 public immutable RESOLUTION_FEE_CEILING;
    uint64 public immutable EXIT_PRESSURE_SATURATION;
    uint128 public immutable EXIT_PRESSURE_DENOMINATOR_FLOOR;
    uint32 public immutable POL_REFERENCE_WINDOW;
    uint32 public immutable REDISTRIBUTION_STREAM_LENGTH;
    uint128 public immutable MIN_NET_FLOW;

    /// @notice The policy multiplier in force, in 1e18 fixed point (§5)
    uint64 public multiplier;

    /// @notice Start of the epoch currently in progress
    uint64 public epochStartTime;

    /// @notice Timestamp through which issuance has been accrued
    uint64 public lastAccrualTime;

    /// @notice Cumulative $ISSUE per whole $BANK, in Q128
    uint256 public issuanceGrowthPerShareX128;

    /// @notice Cumulative base issuance credited so far, capped at `ISSUANCE_BUDGET`
    uint256 public cumulativeIssuance;

    /// @notice Everything still held at the bank as a ledger entry: `D` in eq 9.1
    uint256 public totalLedgerBalance;

    /// @notice Settled ledger balance of each holder, in $ISSUE
    mapping(address holder => uint256 balance) public ledgerBalance;

    /// @notice Issuance growth already settled into `ledgerBalance` for each holder
    mapping(address holder => uint256 snapshot) public growthSnapshotX128;

    /// @notice Fee ETH held inside Core under this contract's saved balance
    uint128 public savedEth;

    /// @notice Protocol ETH earned this epoch and not yet routed by regime
    uint128 public epochRevenueEth;

    /// @notice ETH awaiting delivery to the expansion vault
    uint128 public pendingExpansionEth;

    /// @notice ETH awaiting placement as buyback bids
    uint128 public pendingContractionEth;

    /// @notice ETH awaiting conversion into protocol-owned liquidity
    uint128 public pendingPolEth;

    /// @notice ETH awaiting delivery to the team recipient
    uint128 public pendingTeamEth;

    /// @notice The expansion vault, which stacks hard reserves
    address public expansionVault;

    /// @notice Redistributed resolution fees not yet released to the bankers who stayed
    uint128 public streamRemaining;

    /// @notice Time at which `streamRemaining` will have been fully released
    uint64 public streamEndTime;

    /// @notice Lower tick of the active buyback bid bucket, meaningful when `buybackBidActive`
    int32 public buybackBidLowerTick;

    /// @notice Whether a buyback bid bucket is currently placed
    bool public buybackBidActive;

    /// @notice The daily Dutch auctions, the only address permitted to open new branches
    address public auctions;

    /// @notice Recipient of the 15% team share
    address public teamRecipient;

    /// @notice $BANK minted so far through the free founding distribution
    uint256 public foundingBankMinted;

    /// @notice Whether genesis has run
    bool public initialized;

    uint128 private _epochEthIn;
    uint128 private _epochEthOut;
    int128 private _prevNetFlow;
    int128 private _prevPrevNetFlow;

    uint64 private _lastBucketDay;
    uint256[EXIT_BUCKETS] private _withdrawalBuckets;

    // The bank's own price reference, packed into one slot. Every trade in this economy passes
    // through the bank, so it can be its own oracle: a time-weighted tick that a single block
    // cannot move, below which the bank never places a bid.
    int64 private _referenceTickX24;
    int32 private _lastObservedTick;
    uint32 private _lastObservationTime;

    error SwapMustHappenThroughForward();
    error OnlyGenesisMayInitializeThePool();
    error IncorrectPoolKey();
    error GenesisAlreadyRan();
    error NotInitialized();
    error AlreadySet();
    error AuctionsOnly();
    error BankTokenOnly();
    error OnlyCoreMaySendEth();
    error InvalidWithdrawalAmount();
    error FoundingSupplyExceeded();
    error NothingToCompound();
    error NothingToDefend();
    error NothingToCollect();
    error NoRoomAboveThePrice();
    error UnknownVault();
    error NothingToFlush();
    error CompoundExceededAvailableAmounts();
    error InvalidParameters();

    event Accrued(uint256 issued, uint256 streamed, uint256 growthPerShareX128);
    event RedistributionStreamed(uint256 amount, uint64 endTime);
    event LedgerMoved(address indexed from, address indexed to, uint256 amount);
    event EpochRolled(
        uint64 epochStart, int256 closedEpochNetFlow, uint256 boundariesCrossed, uint64 multiplier, bool expansion
    );
    event RevenueRouted(uint128 toVault, uint128 toPol, uint128 toTeam, bool expansion);
    event TradingFeeCollected(uint128 amount, int128 ethDelta);
    event Withdrawn(
        address indexed holder,
        uint256 bankRetired,
        uint256 released,
        uint256 feeRate,
        uint256 burned,
        uint256 redistributed
    );
    event Flushed(uint128 expansion);
    event TeamShareCollected(uint128 amount);
    event Compounded(int32 lowerTick, uint128 eth, uint128 liquidity);
    event BuybackSettled(int32 lowerTick, uint128 ethRecovered, uint256 issueBurned);
    event BuybackBidsPlaced(int32 lowerTick, uint128 eth, uint128 liquidity);
    event PriceObserved(int32 tick, int32 referenceTick);
    event Genesis(int32 tick, uint128 ethAdded, uint256 issueAdded, uint256 issueBurned);
    event ReservesBurned(uint256 amount);

    /// @param core The Ekubo Core singleton
    /// @param owner Holder of the four policy knobs, able to renounce irreversibly
    /// @param reserveAsset The tokenized gold (or comparable) asset the expansion vault accumulates
    /// @param params Every monetary parameter the whitepaper leaves blank
    constructor(ICore core, address owner, address reserveAsset, ExchequerParameters memory params)
        BaseExtension(core)
        BaseForwardee(core)
        BaseLocker(core)
    {
        if (
            params.multiplierMin == 0 || params.multiplierMin > params.multiplierLaunch
                || params.multiplierLaunch > params.multiplierMax || params.epochLength == 0
                || params.resolutionFeeFloor > params.resolutionFeeCeiling || params.resolutionFeeCeiling > WAD
                || params.exitPressureSaturation == 0 || params.exitPressureSaturation > WAD
                || params.baseIssuancePerDay == 0 || params.tickSpacing == 0 || params.polReferenceWindow == 0
                || params.redistributionStreamLength == 0
        ) revert InvalidParameters();

        _initializeOwner(owner);

        RESERVE_ASSET = reserveAsset;
        teamRecipient = owner;

        BASE_ISSUANCE_PER_DAY = params.baseIssuancePerDay;
        MULTIPLIER_MIN = params.multiplierMin;
        MULTIPLIER_MAX = params.multiplierMax;
        MULTIPLIER_CUT_STEP = params.multiplierCutStep;
        MULTIPLIER_RAISE_STEP = params.multiplierRaiseStep;
        EPOCH_LENGTH = params.epochLength;
        TRADING_FEE = params.tradingFee;
        RESOLUTION_FEE_FLOOR = params.resolutionFeeFloor;
        RESOLUTION_FEE_CEILING = params.resolutionFeeCeiling;
        EXIT_PRESSURE_SATURATION = params.exitPressureSaturation;
        EXIT_PRESSURE_DENOMINATOR_FLOOR = params.exitPressureDenominatorFloor;
        POL_REFERENCE_WINDOW = params.polReferenceWindow;
        REDISTRIBUTION_STREAM_LENGTH = params.redistributionStreamLength;
        MIN_NET_FLOW = params.minNetFlow;

        multiplier = params.multiplierLaunch;

        ISSUE_TOKEN = new IssueToken();
        BANK_TOKEN = new BankToken();

        // The pool charges no fee of its own; the bank takes the whole trading fee, in ETH.
        POOL_CONFIG = createConcentratedPoolConfig(0, params.tickSpacing, address(this));

        int32 spacing = int32(params.tickSpacing);
        POL_TICK_LOWER = (MIN_TICK / spacing) * spacing;
        POL_TICK_UPPER = (MAX_TICK / spacing) * spacing;
        POL_BID_GRID = spacing * 10;
    }

    /// @inheritdoc BaseExtension
    function getCallPoints() internal pure override returns (CallPoints memory) {
        return exchequerCallPoints();
    }

    /// @notice The one canonical market: ETH against $ISSUE
    function poolKey() public view returns (PoolKey memory key) {
        key.token0 = NATIVE_TOKEN_ADDRESS;
        key.token1 = address(ISSUE_TOKEN);
        key.config = POOL_CONFIG;
    }

    /// @notice The full-range genesis position, which has no withdrawal path
    function polPositionId() public view returns (PositionId) {
        return createPositionId(POL_SALT, POL_TICK_LOWER, POL_TICK_UPPER);
    }

    /// @notice A protocol-owned bid bucket, which likewise has no withdrawal path
    function polBidPositionId(int32 lowerTick) public view returns (PositionId) {
        return createPositionId(POL_SALT, lowerTick, POL_TICK_UPPER);
    }

    /// @notice The active buyback bid bucket
    function buybackPositionId() public view returns (PositionId) {
        return createPositionId(BUYBACK_SALT, buybackBidLowerTick, POL_TICK_UPPER);
    }

    /// EXTENSION CALL POINTS

    /// @inheritdoc BaseExtension
    /// @dev There is exactly one market in this economy and only genesis may open it. Core does not
    ///      call this hook when the initializer is the extension itself, so every call that arrives
    ///      here is someone else, whether with the canonical key or another: refused either way.
    function beforeInitializePool(address, PoolKey calldata, int32) external pure override {
        revert OnlyGenesisMayInitializeThePool();
    }

    /// @inheritdoc BaseExtension
    /// @dev Forces every trade through `Core.forward` so the bank can take its ETH fee and read flow
    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override {
        revert SwapMustHappenThroughForward();
    }

    /// @inheritdoc BaseForwardee
    /// @dev The payload matches `Ve33`'s, so the stock `Router` drives this pool unmodified when it
    ///      is deployed with this contract as its ve33 address
    function handleForwardData(Locker, bytes memory data) internal override returns (bytes memory result) {
        (PoolKey memory key, SwapParameters params) = abi.decode(data, (PoolKey, SwapParameters));
        (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) = _swap(key, params);
        result = abi.encode(balanceUpdate, stateAfter);
    }

    /// ISSUANCE

    /// @notice Advances issuance to the current block and rolls every epoch boundary crossed
    /// @dev Permissionless and idempotent within a block. Called by every swap, every $BANK balance
    ///      change and every withdrawal, so the economy never needs a keeper.
    function accrue() public {
        uint256 last = lastAccrualTime;
        if (last == 0 || block.timestamp == last) return;

        int256 currentFlow = int256(uint256(_epochEthIn)) - int256(uint256(_epochEthOut));

        (uint256 weightedSeconds, uint256 m, uint256 epochStart, uint256 rolls) =
            _walk(multiplier, epochStart_(), last, currentFlow, _prevNetFlow);

        if (rolls != 0) {
            // Fee routing follows the epoch that just closed alone: the fast lever (§4)
            bool expansion = _isExpansion(currentFlow);
            _routeRevenue(expansion);

            _epochEthIn = 0;
            _epochEthOut = 0;

            // Every epoch after the first saw no interaction, hence no flow
            if (rolls == 1) {
                _prevPrevNetFlow = _prevNetFlow;
                _prevNetFlow = SafeCastLib.toInt128(currentFlow);
            } else if (rolls == 2) {
                _prevPrevNetFlow = SafeCastLib.toInt128(currentFlow);
                _prevNetFlow = 0;
            } else {
                _prevPrevNetFlow = 0;
                _prevNetFlow = 0;
            }

            epochStartTime = uint64(epochStart);
            multiplier = uint64(m);

            emit EpochRolled(uint64(epochStart), currentFlow, rolls, uint64(m), expansion);
        }

        _bookIssuance(weightedSeconds, last, BANK_TOKEN.totalSupply());
        lastAccrualTime = uint64(block.timestamp);
    }

    /// @dev Reads `epochStartTime` as a word, kept separate so `accrue` stays within stack limits
    function epochStart_() private view returns (uint256) {
        return epochStartTime;
    }

    /// @notice Walks the epoch clock forward to now without writing anything
    /// @dev The single source of truth for how much issuance a span of time is worth, shared by
    ///      `accrue` and by the views, so a projection can never disagree with a settlement
    /// @param m Multiplier in force at `last`
    /// @param epochStart Start of the epoch in progress at `last`
    /// @param last Timestamp through which issuance has already been accrued
    /// @param currentFlow Net flow of the epoch in progress
    /// @param prevFlow Net flow of the previously completed epoch
    /// @return weightedSeconds Sum over segments of (duration) * (multiplier in force)
    /// @return finalM Multiplier in force at the current block
    /// @return finalEpochStart Start of the epoch in progress at the current block
    /// @return rolls Number of epoch boundaries crossed
    function _walk(uint256 m, uint256 epochStart, uint256 last, int256 currentFlow, int256 prevFlow)
        private
        view
        returns (uint256 weightedSeconds, uint256 finalM, uint256 finalEpochStart, uint256 rolls)
    {
        uint256 epochLength = EPOCH_LENGTH;

        unchecked {
            uint256 epochEnd = epochStart + epochLength;

            if (block.timestamp >= epochEnd) {
                weightedSeconds += (epochEnd - last) * m;

                // Issuance follows the two most recently completed epochs: the slow lever (§4)
                m = _nextMultiplier(m, currentFlow + prevFlow);
                prevFlow = currentFlow;
                epochStart = epochEnd;
                rolls = 1;

                // Nothing touched the bank at any later boundary, so those epochs saw zero flow
                uint256 skipped = (block.timestamp - epochStart) / epochLength;

                // The first two still carry pre-gap flow in their signal, so they roll individually
                uint256 individual = skipped < 2 ? skipped : 2;
                for (uint256 i; i < individual; ++i) {
                    weightedSeconds += epochLength * m;
                    m = _nextMultiplier(m, prevFlow);
                    prevFlow = 0;
                    epochStart += epochLength;
                }
                rolls += individual;

                uint256 remaining = skipped - individual;
                if (remaining != 0) {
                    // Every remaining epoch has a zero signal, so the multiplier is cut each time.
                    // Closed form, so catching up after months of silence stays O(1).
                    (uint256 sumM, uint256 mAfter) = _decayMultiplier(m, remaining);
                    weightedSeconds += epochLength * sumM;
                    m = mAfter;
                    epochStart += remaining * epochLength;
                    rolls += remaining;
                }

                last = epochStart;
            }

            weightedSeconds += (block.timestamp - last) * m;
        }

        finalM = m;
        finalEpochStart = epochStart;
    }

    /// @notice Whether a net flow is large enough to count as expansion
    /// @dev §4 says the signal is "denominated in real capital", which a pure sign test is not: a
    ///      one-wei buy would make an epoch expansionary. Anything below `MIN_NET_FLOW` is treated
    ///      as zero, and zero is a contraction, per §5.
    function _isExpansion(int256 flow) private view returns (bool) {
        return flow > 0 && uint256(flow) >= MIN_NET_FLOW;
    }

    /// @notice The multiplier for the next epoch given the trailing two-epoch signal
    /// @dev A zero or sub-threshold signal is a contraction, per §5
    function _nextMultiplier(uint256 m, int256 signal) private view returns (uint256 next) {
        unchecked {
            if (_isExpansion(signal)) {
                uint256 raised = m + MULTIPLIER_RAISE_STEP;
                next = raised > MULTIPLIER_MAX ? MULTIPLIER_MAX : raised;
            } else {
                next = m > uint256(MULTIPLIER_MIN) + MULTIPLIER_CUT_STEP ? m - MULTIPLIER_CUT_STEP : MULTIPLIER_MIN;
            }
        }
    }

    /// @notice Sum of the multiplier over `count` consecutive contraction epochs, and its end value
    /// @dev The multiplier falls by `MULTIPLIER_CUT_STEP` per epoch and holds at the floor
    function _decayMultiplier(uint256 m, uint256 count) private view returns (uint256 sum, uint256 mAfter) {
        uint256 floor_ = MULTIPLIER_MIN;
        uint256 cut = MULTIPLIER_CUT_STEP;
        uint256 span = m - floor_;

        if (cut == 0) return (m * count, m);

        unchecked {
            // Number of whole steps the multiplier can take before reaching the floor
            uint256 steps = span / cut;
            uint256 remainder = span % cut;

            uint256 full = count < steps ? count : steps;
            sum = full * (floor_ + span) - cut * ((full * (full - 1)) / 2);

            if (count > full) {
                // The step at index `steps` lands `remainder` above the floor; every later one is at it
                sum += floor_ * (count - full) + remainder;
            }

            if (count < steps) {
                mAfter = floor_ + span - count * cut;
            } else if (count == steps) {
                mAfter = floor_ + remainder;
            } else {
                mAfter = floor_;
            }
        }
    }

    /// @notice Credits `weightedSeconds` worth of base issuance, plus whatever the redistribution
    ///         stream has released since `last`, across every outstanding share
    function _bookIssuance(uint256 weightedSeconds, uint256 last, uint256 supply) private {
        if (supply == 0) return;

        uint256 amount = _baseIssuance(weightedSeconds);
        if (amount != 0) {
            cumulativeIssuance += amount;
            totalLedgerBalance += amount;
        }

        uint256 streamed = _streamRelease(last);
        if (streamed != 0) {
            unchecked {
                streamRemaining -= uint128(streamed);
            }
        }

        uint256 credit = amount + streamed;
        if (credit == 0) return;

        uint256 growth = issuanceGrowthPerShareX128 + FixedPointMathLib.fullMulDiv(credit, 1 << 128, supply);
        issuanceGrowthPerShareX128 = growth;

        emit Accrued(amount, streamed, growth);
    }

    /// @notice Base issuance owed for `weightedSeconds`, capped at what is left of the budget
    function _baseIssuance(uint256 weightedSeconds) private view returns (uint256 amount) {
        if (weightedSeconds == 0) return 0;
        amount = FixedPointMathLib.fullMulDiv(weightedSeconds, BASE_ISSUANCE_PER_DAY, WAD * 1 days);
        unchecked {
            uint256 headroom = ISSUANCE_BUDGET - cumulativeIssuance;
            if (amount > headroom) amount = headroom;
        }
    }

    /// @notice Share of the redistribution stream released between `last` and now
    /// @dev Linear over the remaining life of the stream. Half of every resolution fee is paid to
    ///      the bankers who stayed, and paying it over `REDISTRIBUTION_STREAM_LENGTH` rather than at
    ///      once means "stayed" is measured in time: a share bought in front of a large exit and
    ///      sold behind it collects nothing.
    function _streamRelease(uint256 last) private view returns (uint256) {
        uint256 remaining = streamRemaining;
        if (remaining == 0) return 0;

        uint256 end = streamEndTime;
        if (block.timestamp >= end) return remaining;

        unchecked {
            return (remaining * (block.timestamp - last)) / (end - last);
        }
    }

    /// @notice Splits the epoch's protocol ETH 70/15/15 and assigns the vault share by regime (§11)
    function _routeRevenue(bool expansion) private {
        uint128 revenue = epochRevenueEth;
        if (revenue == 0) return;
        epochRevenueEth = 0;

        unchecked {
            uint128 toVault = uint128((uint256(revenue) * VAULT_SHARE_BPS) / 10000);
            uint128 toPol = uint128((uint256(revenue) * POL_SHARE_BPS) / 10000);
            uint128 toTeam = revenue - toVault - toPol;

            if (expansion) pendingExpansionEth += toVault;
            else pendingContractionEth += toVault;
            pendingPolEth += toPol;
            pendingTeamEth += toTeam;

            emit RevenueRouted(toVault, toPol, toTeam, expansion);
        }
    }

    /// @inheritdoc IBankShareHook
    /// @dev The settled ledger travels with the shares. Without this a holder could park all but
    ///      one wei of their shares elsewhere, retire that wei against the whole ledger, and take
    ///      the shares back: value extracted, vehicle kept. With it, the whitepaper's §12 holds
    ///      literally: "the seat moves whole, branches and balance included."
    function settleTransfer(address from, address to, uint256 amount) external {
        if (msg.sender != address(BANK_TOKEN)) revert BankTokenOnly();
        accrue();
        _settle(from);
        _settle(to);

        if (from == address(0) || to == address(0) || from == to || amount == 0) return;

        // The token reverts an over-balance transfer after this hook; nothing to move in that case
        uint256 balance = BANK_TOKEN.balanceOf(from);
        if (balance == 0 || amount > balance) return;

        uint256 moved = FixedPointMathLib.fullMulDiv(ledgerBalance[from], amount, balance);
        if (moved == 0) return;

        unchecked {
            ledgerBalance[from] -= moved;
            ledgerBalance[to] += moved;
        }
        emit LedgerMoved(from, to, moved);
    }

    /// @notice Moves `holder`'s share of issuance growth into their settled ledger balance
    function _settle(address holder) private {
        if (holder == address(0)) return;

        uint256 growth = issuanceGrowthPerShareX128;
        uint256 snapshot = growthSnapshotX128[holder];
        if (snapshot == growth) return;

        growthSnapshotX128[holder] = growth;

        uint256 balance = BANK_TOKEN.balanceOf(holder);
        if (balance == 0) return;

        unchecked {
            ledgerBalance[holder] += FixedPointMathLib.fullMulDivN(growth - snapshot, balance, 128);
        }
    }

    /// @notice Base issuance that would be credited if `accrue` were called right now
    /// @dev Projected through the same walk `accrue` uses, so a view can never disagree with a
    ///      settlement, and a caller reading this after a week of silence sees the real number
    function pendingIssuance() public view returns (uint256 amount) {
        uint256 last = lastAccrualTime;
        if (last == 0 || block.timestamp == last) return 0;
        if (BANK_TOKEN.totalSupply() == 0) return 0;

        (uint256 weightedSeconds,,,) = _walk(
            multiplier, epochStartTime, last, int256(uint256(_epochEthIn)) - int256(uint256(_epochEthOut)), _prevNetFlow
        );

        amount = _baseIssuance(weightedSeconds);
    }

    /// @notice Redistributed fees that would be released if `accrue` were called right now
    function pendingStreamRelease() public view returns (uint256) {
        uint256 last = lastAccrualTime;
        if (last == 0 || block.timestamp == last) return 0;
        if (BANK_TOKEN.totalSupply() == 0) return 0;
        return _streamRelease(last);
    }

    /// @notice The issuance growth accumulator brought up to the current block
    function currentGrowthPerShareX128() public view returns (uint256) {
        uint256 credit = pendingIssuance() + pendingStreamRelease();
        if (credit == 0) return issuanceGrowthPerShareX128;

        unchecked {
            return issuanceGrowthPerShareX128 + FixedPointMathLib.fullMulDiv(credit, 1 << 128, BANK_TOKEN.totalSupply());
        }
    }

    /// @notice A holder's full ledger balance, including issuance not yet accrued or settled
    function balanceAtBank(address holder) public view returns (uint256) {
        unchecked {
            uint256 growth = currentGrowthPerShareX128();
            uint256 snapshot = growthSnapshotX128[holder];
            uint256 pending = growth == snapshot
                ? 0
                : FixedPointMathLib.fullMulDivN(growth - snapshot, BANK_TOKEN.balanceOf(holder), 128);
            return ledgerBalance[holder] + pending;
        }
    }

    /// @notice Everything still held at the bank, brought up to the current block: `D` in eq 9.1
    function currentTotalLedgerBalance() public view returns (uint256) {
        unchecked {
            return totalLedgerBalance + pendingIssuance();
        }
    }

    /// WITHDRAWING

    /// @notice Retires `bankAmount` of branches and liquidates exactly that fraction of the caller's
    ///         ledger balance into $ISSUE, less the resolution fee (§9)
    /// @param bankAmount Quantity of $BANK to retire
    /// @param recipient Recipient of the released currency
    /// @return released Ledger balance liquidated, before the fee
    /// @return minted $ISSUE actually minted to `recipient`
    function withdraw(uint256 bankAmount, address recipient) external returns (uint256 released, uint256 minted) {
        accrue();
        _settle(msg.sender);

        uint256 balance = BANK_TOKEN.balanceOf(msg.sender);
        if (bankAmount == 0 || bankAmount > balance) revert InvalidWithdrawalAmount();

        uint256 accrued = ledgerBalance[msg.sender];
        // Pro rata rule: retiring one branch of ten liquidates one tenth of the balance
        released = FixedPointMathLib.fullMulDiv(accrued, bankAmount, balance);

        uint256 feeRate = resolutionFeeRate();
        uint256 fee = FixedPointMathLib.fullMulDiv(released, feeRate, WAD);
        uint256 burned = fee / 2;
        uint256 redistributed = fee - burned;
        minted = released - fee;

        unchecked {
            ledgerBalance[msg.sender] = accrued - released;
            totalLedgerBalance -= released;
        }
        _recordWithdrawal(released);

        // Retires the vehicle that produced the yield. Re-enters `settleTransfer`, which no-ops
        // because this block already accrued and settled the caller, and a burn moves no ledger.
        BANK_TOKEN.burn(msg.sender, bankAmount);

        uint256 remainingSupply = BANK_TOKEN.totalSupply();

        // Minted then destroyed, so the burn is real under eq 3.2 rather than mere un-issuance
        if (burned != 0) {
            ISSUE_TOKEN.mint(address(this), burned);
            ISSUE_TOKEN.burn(burned);
        }

        if (remainingSupply != 0) {
            if (redistributed != 0) {
                // Paid to every banker who stays, streamed so that staying is measured in time
                streamRemaining += SafeCastLib.toUint128(redistributed);
                uint64 end = uint64(block.timestamp + REDISTRIBUTION_STREAM_LENGTH);
                streamEndTime = end;
                totalLedgerBalance += redistributed;
                emit RedistributionStreamed(redistributed, end);
            }
        } else {
            // Nobody stayed, so there is nobody to pay, now or from an earlier stream
            uint256 orphaned = redistributed + streamRemaining;
            if (streamRemaining != 0) {
                totalLedgerBalance -= streamRemaining;
                streamRemaining = 0;
            }
            if (orphaned != 0) {
                ISSUE_TOKEN.mint(address(this), orphaned);
                ISSUE_TOKEN.burn(orphaned);
            }
        }

        if (minted != 0) ISSUE_TOKEN.mint(recipient, minted);

        emit Withdrawn(msg.sender, bankAmount, released, feeRate, burned, redistributed);
    }

    /// @notice The resolution fee in force right now, in 1e18 fixed point (eq 9.1)
    /// @dev Quadratic between the floor and the ceiling, saturating once `EXIT_PRESSURE_SATURATION`
    ///      of the bank has tried to leave inside the trailing window
    function resolutionFeeRate() public view returns (uint256 rate) {
        uint256 w = trailingWithdrawals();
        if (w == 0) return RESOLUTION_FEE_FLOOR;

        uint256 denominator = currentTotalLedgerBalance() + w;
        if (denominator < EXIT_PRESSURE_DENOMINATOR_FLOOR) denominator = EXIT_PRESSURE_DENOMINATOR_FLOOR;

        uint256 pressure = FixedPointMathLib.fullMulDiv(w, WAD, denominator);
        uint256 x = pressure >= EXIT_PRESSURE_SATURATION
            ? WAD
            : FixedPointMathLib.fullMulDiv(pressure, WAD, EXIT_PRESSURE_SATURATION);

        unchecked {
            rate = RESOLUTION_FEE_FLOOR
                + FixedPointMathLib.fullMulDiv(uint256(RESOLUTION_FEE_CEILING) - RESOLUTION_FEE_FLOOR, x * x, WAD * WAD);
        }
    }

    /// @notice System-wide withdrawals over the trailing window: `W` in eq 9.1
    /// @dev Bucketed by calendar day, so the window covers between six and seven days of history
    function trailingWithdrawals() public view returns (uint256 total) {
        uint256 today = block.timestamp / 1 days;
        uint256 last = _lastBucketDay;
        if (today - last >= EXIT_BUCKETS) return 0;

        unchecked {
            for (uint256 i; i < EXIT_BUCKETS; ++i) {
                uint256 day = today - i;
                // Buckets for days after the last write still hold data from a previous cycle
                if (day > last) continue;
                total += _withdrawalBuckets[day % EXIT_BUCKETS];
            }
        }
    }

    /// @notice Books a withdrawal into today's bucket, expiring anything that fell out of the window
    function _recordWithdrawal(uint256 amount) private {
        uint256 today = block.timestamp / 1 days;
        uint256 last = _lastBucketDay;

        unchecked {
            if (today != last) {
                uint256 gap = today - last;
                if (gap >= EXIT_BUCKETS) {
                    for (uint256 i; i < EXIT_BUCKETS; ++i) {
                        _withdrawalBuckets[i] = 0;
                    }
                } else {
                    for (uint256 i = 1; i <= gap; ++i) {
                        _withdrawalBuckets[(last + i) % EXIT_BUCKETS] = 0;
                    }
                }
                _lastBucketDay = uint64(today);
            }

            _withdrawalBuckets[today % EXIT_BUCKETS] += amount;
        }
    }

    /// SWAPS

    /// @notice Executes a swap, taking the trading fee in ETH and recording the resulting net flow
    /// @dev The fee is always denominated in ETH on both buys and sells, and is always arranged so
    ///      the trader's specified amount stays exact
    function _swap(PoolKey memory key, SwapParameters params)
        private
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        _checkPoolKey(key);
        accrue();

        uint64 tradingFee = TRADING_FEE;
        bool ethSpecified = !params.isToken1();
        bool exactOut = params.isExactOut();
        uint128 feeAmount;

        if (ethSpecified && !exactOut) {
            // Exact input ETH: take the fee off the top, so the pool swaps what is left
            uint128 amountIn = uint128(params.amount());
            feeAmount = computeFee(amountIn, tradingFee);
            uint128 offered = amountIn - feeAmount;
            params = createSwapParameters(
                params.sqrtRatioLimit(), SafeCastLib.toInt128(int256(uint256(offered))), false, params.skipAhead()
            );
            (balanceUpdate, stateAfter) = CORE.swap(0, key, params);

            // A swap stopped by its price limit consumes less than was offered, and the trader owes
            // a fee only on what actually traded
            uint128 consumed = uint128(balanceUpdate.delta0());
            if (consumed != offered) feeAmount = amountBeforeFee(consumed, tradingFee) - consumed;
        } else if (ethSpecified && exactOut) {
            // Exact output ETH: gross the request up, so the trader still receives what they asked
            uint128 amountOut = uint128(uint256(-int256(params.amount())));
            uint128 gross = amountBeforeFee(amountOut, tradingFee);
            feeAmount = gross - amountOut;
            params = createSwapParameters(
                params.sqrtRatioLimit(), -SafeCastLib.toInt128(int256(uint256(gross))), false, params.skipAhead()
            );
            (balanceUpdate, stateAfter) = CORE.swap(0, key, params);

            // Likewise, a partly filled request pays only on the ETH the pool actually released
            uint128 released = uint128(uint256(-int256(balanceUpdate.delta0())));
            if (released != gross) feeAmount = computeFee(released, tradingFee);
        } else {
            (balanceUpdate, stateAfter) = CORE.swap(0, key, params);

            int128 delta0 = balanceUpdate.delta0();
            if (delta0 > 0) {
                // ETH is the input side, so the fee is charged on top of it
                feeAmount = amountBeforeFee(uint128(delta0), tradingFee) - uint128(delta0);
            } else if (delta0 < 0) {
                // ETH is the output side, so the fee comes out of the payout
                feeAmount = computeFee(uint128(uint256(-int256(delta0))), tradingFee);
            }
        }

        _observe(stateAfter.tick());

        int128 ethDelta = SafeCastLib.toInt128(int256(balanceUpdate.delta0()) + int256(uint256(feeAmount)));
        balanceUpdate = createPoolBalanceUpdate(ethDelta, balanceUpdate.delta1());

        // Net flow is read on the trader-facing delta, because that is the capital that moved
        unchecked {
            if (ethDelta > 0) _epochEthIn += uint128(ethDelta);
            else if (ethDelta < 0) _epochEthOut += uint128(uint256(-int256(ethDelta)));
        }

        if (feeAmount != 0) {
            CORE.updateSavedBalances(key.token0, key.token1, FEE_SALT, int256(uint256(feeAmount)), 0);
            unchecked {
                savedEth += feeAmount;
                epochRevenueEth += feeAmount;
            }
            emit TradingFeeCollected(feeAmount, ethDelta);
        }
    }

    /// FEE ENGINE

    /// @notice Books ETH from the charter auction into the same fee engine as trading fees (§2)
    function receiveRevenue() external payable {
        if (msg.sender != auctions) revert AuctionsOnly();
        accrue();
        unchecked {
            epochRevenueEth += SafeCastLib.toUint128(msg.value);
        }
    }

    /// @notice Delivers routed ETH to the expansion vault. Permissionless.
    function flush() external returns (uint128 expansion) {
        accrue();
        _sweep();

        expansion = pendingExpansionEth;
        if (expansion == 0) revert NothingToFlush();
        pendingExpansionEth = 0;

        SafeTransferLib.safeTransferETH(expansionVault, expansion);
        emit Flushed(expansion);
    }

    /// @notice Delivers the team's share. Permissionless, and separate from `flush` so a recipient
    ///         that cannot receive ETH can never hold up the vault.
    function collectTeamShare() external returns (uint128 amount) {
        accrue();
        _sweep();

        amount = pendingTeamEth;
        if (amount == 0) revert NothingToCollect();
        pendingTeamEth = 0;

        SafeTransferLib.safeTransferETH(teamRecipient, amount);
        emit TeamShareCollected(amount);
    }

    /// @notice Burns any $ISSUE the bank happens to hold. Permissionless.
    /// @dev Buybacks burn inline in `defend`; this catches anything sent to the bank directly.
    function burnReserves() external returns (uint256 amount) {
        amount = ISSUE_TOKEN.balanceOf(address(this));
        if (amount != 0) {
            ISSUE_TOKEN.burn(amount);
            emit ReservesBurned(amount);
        }
    }

    /// @notice Places accumulated POL ETH as permanent protocol-owned bids. Permissionless.
    /// @dev The ETH goes in as single-sided liquidity from the first grid tick above
    ///      `max(spot, referenceTick())` up to the top of the range: a standing bid for $ISSUE at
    ///      every price below the market. No swap happens, so there is nothing to sandwich, and
    ///      the bank pays no premium: it buys only when sellers come down to it. Because the bids
    ///      never sit above the reference, a pump in front of this call finds nothing to sell into.
    ///      Buckets accumulate on a grid, each with no withdrawal path.
    /// @return liquidity Liquidity added to the bucket
    /// @return lowerTick Lower tick of the bucket the ETH went into
    function compound() external returns (uint128 liquidity, int32 lowerTick) {
        accrue();
        _sweep();

        uint128 amount = pendingPolEth;
        if (amount == 0) revert NothingToCompound();
        pendingPolEth = 0;

        (liquidity, lowerTick) = abi.decode(lock(abi.encode(CALL_TYPE_COMPOUND, amount)), (uint128, int32));
    }

    /// @notice Turns contraction ETH into a standing bid for $ISSUE, and burns whatever the previous
    ///         bid bucket bought. Permissionless.
    /// @dev The whitepaper's contraction vault buys on the open market in rate-limited steps. Here
    ///      the bank *is* the market, so it defends in it directly: contraction ETH is placed as a
    ///      bid bucket just below the market, sellers who push the price down into it are bought
    ///      out, and the next call withdraws the bucket, burns every $ISSUE it acquired, and re-bids
    ///      the remaining ETH from the current price. Defense is never a market order, so it cannot
    ///      be baited, and it executes exactly when there is sell pressure to absorb.
    /// @return liquidity Liquidity in the freshly placed bucket
    /// @return lowerTick Lower tick of the freshly placed bucket
    /// @return issueBurned $ISSUE the previous bucket bought and this call destroyed
    function defend() external returns (uint128 liquidity, int32 lowerTick, uint256 issueBurned) {
        accrue();
        _sweep();

        uint128 amount = pendingContractionEth;
        pendingContractionEth = 0;

        (liquidity, lowerTick, issueBurned) =
            abi.decode(lock(abi.encode(CALL_TYPE_DEFEND, amount)), (uint128, int32, uint256));
    }

    /// @notice Draws all fee ETH out of Core so the pending buckets are backed by real balance
    function _sweep() private {
        uint128 saved = savedEth;
        if (saved == 0) return;
        savedEth = 0;
        lock(abi.encode(CALL_TYPE_SWEEP, saved));
    }

    /// GENESIS AND ADMINISTRATION

    /// @notice Initializes the one market and locks the genesis liquidity into it forever
    /// @param tick Starting tick of the pool
    function initialize(int32 tick) external payable onlyOwner {
        if (initialized) revert GenesisAlreadyRan();
        if (expansionVault == address(0)) revert NotInitialized();
        initialized = true;

        epochStartTime = uint64(block.timestamp);
        lastAccrualTime = uint64(block.timestamp);
        _lastBucketDay = uint64(block.timestamp / 1 days);

        ISSUE_TOKEN.mint(address(this), GENESIS_LIQUIDITY);

        lock(abi.encode(CALL_TYPE_GENESIS, tick, msg.value));
    }

    /// @notice Wires in the expansion vault. One shot.
    function setExpansionVault(address vault) external onlyOwner {
        if (expansionVault != address(0)) revert AlreadySet();
        expansionVault = vault;
    }

    /// @notice Wires in the auction contract, the only address that may open new branches. One shot.
    function setAuctions(address _auctions) external onlyOwner {
        if (auctions != address(0)) revert AlreadySet();
        auctions = _auctions;
    }

    /// @notice Configures the expansion vault's TWAMM order duration and fee tier
    /// @dev The vault is owned by the bank, so this is the only way to configure it, and the only
    ///      thing the bank can do to it. Nothing can pull what the vault has bought anywhere but
    ///      here, and once the bank's owner renounces the configuration is frozen.
    function configureExpansionVault(uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee)
        external
        onlyOwner
    {
        address vault = expansionVault;
        if (vault == address(0)) revert UnknownVault();
        IRevenueBuybacks(vault).configure(NATIVE_TOKEN_ADDRESS, targetOrderDuration, minOrderDuration, fee);
    }

    /// @notice Updates the recipient of the 15% team share
    function setTeamRecipient(address recipient) external onlyOwner {
        teamRecipient = recipient;
    }

    /// @notice Mints part of the free founding distribution, capped at `FOUNDING_BANK_SUPPLY` (§6)
    /// @dev Typically pointed at `Incentives` for a one-per-wallet merkle claim
    function mintFoundingBank(address recipient, uint256 amount) external onlyOwner {
        uint256 minted = foundingBankMinted + amount;
        if (minted > FOUNDING_BANK_SUPPLY) revert FoundingSupplyExceeded();
        foundingBankMinted = minted;
        BANK_TOKEN.mint(recipient, amount);
    }

    /// @notice Opens `amount` of new branches for an auction buyer
    function mintShares(address recipient, uint256 amount) external {
        if (msg.sender != auctions) revert AuctionsOnly();
        BANK_TOKEN.mint(recipient, amount);
    }

    /// VIEWS

    /// @notice Daily issuance accruing to one whole $BANK at the multiplier in force
    /// @dev The license auction floor is a multiple of this (§8)
    function dailyYieldPerShare() external view returns (uint256) {
        uint256 supply = BANK_TOKEN.totalSupply();
        if (supply == 0) return 0;
        return FixedPointMathLib.fullMulDiv(uint256(BASE_ISSUANCE_PER_DAY) * currentMultiplier() / WAD, 1e18, supply);
    }

    /// @notice The multiplier as of the current block, including boundaries not yet settled
    /// @dev Storage lags across an un-accrued epoch boundary, so pricing off `multiplier` directly
    ///      would quote the first caller of a quiet day at yesterday's rate
    function currentMultiplier() public view returns (uint256 m) {
        uint256 last = lastAccrualTime;
        if (last == 0 || block.timestamp == last) return multiplier;

        (, m,,) = _walk(
            multiplier, epochStartTime, last, int256(uint256(_epochEthIn)) - int256(uint256(_epochEthOut)), _prevNetFlow
        );
    }

    /// @notice The bank's reference price as a tick, brought up to the current block
    /// @dev A time-weighted average of the pool tick: every observed price pulls the reference toward
    ///      itself in proportion to how long it prevailed, and a price that lasts a full
    ///      `POL_REFERENCE_WINDOW` replaces it outright. A price that exists only inside one block
    ///      has prevailed for zero seconds and moves nothing, which is what lets `compound` and
    ///      `defend` place bids in the same block as a pump without ever bidding above it.
    function referenceTick() public view returns (int32) {
        return int32(_foldedReferenceX24() >> 24);
    }

    /// @notice Folds the time the last observed tick has prevailed into the reference
    function _foldedReferenceX24() private view returns (int256 refX24) {
        refX24 = _referenceTickX24;
        uint256 elapsed = block.timestamp - _lastObservationTime;
        if (elapsed == 0) return refX24;

        uint256 window = POL_REFERENCE_WINDOW;
        if (elapsed > window) elapsed = window;

        int256 target = int256(_lastObservedTick) << 24;
        refX24 += ((target - refX24) * int256(elapsed)) / int256(window);
    }

    /// @notice Records the pool tick after a trade, folding in the price that prevailed until now
    function _observe(int32 tickAfter) private {
        if (block.timestamp != _lastObservationTime) {
            int256 folded = _foldedReferenceX24();
            _referenceTickX24 = int64(folded);
            _lastObservationTime = uint32(block.timestamp);
        }
        if (tickAfter != _lastObservedTick) {
            _lastObservedTick = tickAfter;
            emit PriceObserved(tickAfter, int32(_referenceTickX24 >> 24));
        }
    }

    /// @notice Net flow of the epoch in progress, and of the two most recently completed epochs
    function netFlows() external view returns (int256 current, int128 previous, int128 beforePrevious) {
        current = int256(uint256(_epochEthIn)) - int256(uint256(_epochEthOut));
        previous = _prevNetFlow;
        beforePrevious = _prevPrevNetFlow;
    }

    /// LOCK HANDLING

    /// @inheritdoc BaseLocker
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType;
        assembly ("memory-safe") {
            callType := mload(add(data, 0x20))
        }

        if (callType == CALL_TYPE_SWEEP) {
            (, uint128 amount) = abi.decode(data, (uint256, uint128));
            PoolKey memory key = poolKey();
            CORE.updateSavedBalances(key.token0, key.token1, FEE_SALT, -int256(uint256(amount)), 0);
            ACCOUNTANT.withdraw(NATIVE_TOKEN_ADDRESS, address(this), amount);
            result = "";
        } else if (callType == CALL_TYPE_COMPOUND) {
            (, uint128 amount) = abi.decode(data, (uint256, uint128));
            (uint128 liquidity, int32 lowerTick) = _compound(amount);
            result = abi.encode(liquidity, lowerTick);
        } else if (callType == CALL_TYPE_DEFEND) {
            (, uint128 amount) = abi.decode(data, (uint256, uint128));
            (uint128 liquidity, int32 lowerTick, uint256 issueBurned) = _defend(amount);
            result = abi.encode(liquidity, lowerTick, issueBurned);
        } else {
            (, int32 tick, uint256 value) = abi.decode(data, (uint256, int32, uint256));
            _genesis(tick, SafeCastLib.toUint128(value));
            result = "";
        }
    }

    /// @notice Initializes the pool and locks the genesis position, which can never be withdrawn
    function _genesis(int32 tick, uint128 ethAmount) private {
        PoolKey memory key = poolKey();
        CORE.initializePool(key, tick);

        _referenceTickX24 = int64(tick) << 24;
        _lastObservedTick = tick;
        _lastObservationTime = uint32(block.timestamp);

        (, uint128 amount0, uint128 amount1) =
            _addGenesisLiquidity(key, ethAmount, SafeCastLib.toUint128(GENESIS_LIQUIDITY));

        if (amount0 != 0) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount0);
        if (amount1 != 0) ACCOUNTANT.pay(address(ISSUE_TOKEN), amount1);

        // Whatever the chosen tick could not absorb is destroyed rather than left mintable
        uint256 leftoverIssue = GENESIS_LIQUIDITY - amount1;
        if (leftoverIssue != 0) ISSUE_TOKEN.burn(leftoverIssue);

        unchecked {
            uint128 leftoverEth = ethAmount - amount0;
            if (leftoverEth != 0) pendingPolEth += leftoverEth;
        }

        emit Genesis(tick, amount0, amount1, leftoverIssue);
    }

    /// @notice Places `amount` of POL ETH as a bid bucket that can never be withdrawn
    function _compound(uint128 amount) private returns (uint128 liquidity, int32 lowerTick) {
        uint128 placed;
        (liquidity, lowerTick, placed) = _placeBids(POL_SALT, amount);
        if (liquidity == 0) revert NothingToCompound();

        SafeTransferLib.safeTransferETH(address(ACCOUNTANT), placed);

        unchecked {
            // Rounding dust waits for the next call
            uint128 leftover = amount - placed;
            if (leftover != 0) pendingPolEth += leftover;
        }

        emit Compounded(lowerTick, placed, liquidity);
    }

    /// @notice Settles the previous buyback bucket and places the next one
    function _defend(uint128 newEth) private returns (uint128 liquidity, int32 lowerTick, uint256 issueBurned) {
        PoolKey memory key = poolKey();
        PoolId poolId = key.toPoolId();

        uint128 recovered;
        if (buybackBidActive) {
            int32 oldLower = buybackBidLowerTick;
            // A bucket the price has not reached holds only ETH, so there is nothing to settle
            if (newEth == 0 && CORE.poolState(poolId).tick() < oldLower) revert NothingToDefend();

            PositionId oldId = createPositionId(BUYBACK_SALT, oldLower, POL_TICK_UPPER);
            uint128 oldLiquidity = CORE.poolPositions(poolId, address(this), oldId).liquidity;
            if (oldLiquidity != 0) {
                PoolBalanceUpdate update =
                    CORE.updatePosition(key, oldId, -SafeCastLib.toInt128(int256(uint256(oldLiquidity))));
                recovered = uint128(uint256(-int256(update.delta0())));
                issueBurned = uint256(-int256(update.delta1()));
            }
            buybackBidActive = false;

            emit BuybackSettled(oldLower, recovered, issueBurned);
        } else if (newEth == 0) {
            revert NothingToDefend();
        }

        // Everything the bids bought is destroyed
        if (issueBurned != 0) {
            ACCOUNTANT.withdraw(address(ISSUE_TOKEN), address(this), uint128(issueBurned));
            ISSUE_TOKEN.burn(issueBurned);
        }

        uint128 available = newEth + recovered;
        uint128 placed;
        (liquidity, lowerTick, placed) = _placeBids(BUYBACK_SALT, available);
        if (liquidity != 0) {
            buybackBidLowerTick = lowerTick;
            buybackBidActive = true;
            emit BuybackBidsPlaced(lowerTick, placed, liquidity);
        }

        // The bank is owed `recovered` by the accountant and owes it `placed`; settle the difference
        if (placed > recovered) {
            SafeTransferLib.safeTransferETH(address(ACCOUNTANT), placed - recovered);
        } else if (recovered > placed) {
            ACCOUNTANT.withdraw(NATIVE_TOKEN_ADDRESS, address(this), recovered - placed);
        }

        unchecked {
            uint128 leftover = available - placed;
            if (leftover != 0) pendingContractionEth += leftover;
        }
    }

    /// @notice Adds `ethAmount` as single-sided liquidity from the next grid tick above the market
    /// @dev ETH is token0, and token0 liquidity sits above the current tick, where it is sold for
    ///      $ISSUE as the price rises through it, which in this pool means as $ISSUE cheapens. A
    ///      bucket is therefore a standing bid for $ISSUE at every price below the market.
    function _placeBids(bytes24 salt, uint128 ethAmount)
        private
        returns (uint128 liquidity, int32 lowerTick, uint128 amount0)
    {
        PoolKey memory key = poolKey();
        PoolState state = CORE.poolState(key.toPoolId());

        lowerTick = _bidLowerTick(state.tick());
        if (ethAmount == 0) return (0, lowerTick, 0);

        liquidity =
            maxLiquidity(state.sqrtRatio(), tickToSqrtRatio(lowerTick), tickToSqrtRatio(POL_TICK_UPPER), ethAmount, 0);
        if (liquidity == 0) return (0, lowerTick, 0);

        PoolBalanceUpdate update = CORE.updatePosition(
            key, createPositionId(salt, lowerTick, POL_TICK_UPPER), SafeCastLib.toInt128(int256(uint256(liquidity)))
        );

        amount0 = uint128(update.delta0());
        if (update.delta1() != 0 || amount0 > ethAmount) revert CompoundExceededAvailableAmounts();
    }

    /// @notice The first grid tick strictly above both the market and the bank's reference
    /// @dev Never below the reference, so a same-block pump cannot pull a bid up to meet it
    function _bidLowerTick(int32 spot) private view returns (int32) {
        int256 floorTick = int256(spot);
        int256 anchor = referenceTick();
        if (anchor > floorTick) floorTick = anchor;

        int256 grid = POL_BID_GRID;
        // Floor division, so that negative ticks round toward the lower grid line as well
        int256 line = floorTick / grid;
        if (floorTick < 0 && floorTick % grid != 0) line -= 1;

        int256 lowerTick = (line + 1) * grid;
        if (lowerTick >= POL_TICK_UPPER) revert NoRoomAboveThePrice();
        return int32(lowerTick);
    }

    /// @notice Adds as much of `ethAmount` and `issueAmount` as the full-range genesis position can take
    function _addGenesisLiquidity(PoolKey memory key, uint128 ethAmount, uint128 issueAmount)
        private
        returns (uint128 liquidity, uint128 amount0, uint128 amount1)
    {
        PoolState state = CORE.poolState(key.toPoolId());

        liquidity = maxLiquidity(
            state.sqrtRatio(), tickToSqrtRatio(POL_TICK_LOWER), tickToSqrtRatio(POL_TICK_UPPER), ethAmount, issueAmount
        );
        if (liquidity == 0) return (0, 0, 0);

        PoolBalanceUpdate update =
            CORE.updatePosition(key, polPositionId(), SafeCastLib.toInt128(int256(uint256(liquidity))));

        amount0 = uint128(update.delta0());
        amount1 = uint128(update.delta1());
        if (amount0 > ethAmount || amount1 > issueAmount) revert CompoundExceededAvailableAmounts();
    }

    /// @notice Rejects any pool but the single canonical ETH/$ISSUE market
    function _checkPoolKey(PoolKey memory key) private view {
        if (
            key.token0 != NATIVE_TOKEN_ADDRESS || key.token1 != address(ISSUE_TOKEN)
                || PoolConfig.unwrap(key.config) != PoolConfig.unwrap(POOL_CONFIG)
        ) revert IncorrectPoolKey();
    }

    /// @dev Only Core returns ETH here, when fee balances are drawn out of saved balances
    receive() external payable {
        if (msg.sender != address(CORE)) revert OnlyCoreMaySendEth();
    }
}

/// @notice The Core hooks enabled by `Exchequer`
function exchequerCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        // so that no second pool can adopt this extension
        beforeInitializePool: true,
        afterInitializePool: false,
        // so that every trade arrives through forward, where the ETH fee is taken
        beforeSwap: true,
        afterSwap: false,
        beforeUpdatePosition: false,
        afterUpdatePosition: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}
