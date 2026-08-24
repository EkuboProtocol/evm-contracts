// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {BaseLocker} from "../base/BaseLocker.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ExposedStorageLib} from "../libraries/ExposedStorageLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {ExchequerAuctionsStorageLayout as AL} from "../libraries/ExchequerAuctionsStorageLayout.sol";
import {ExchequerStorageLayout as L} from "../libraries/ExchequerStorageLayout.sol";
import {
    ExchequerMath,
    ExchequerParameters,
    EXIT_BUCKETS,
    FOUNDING_BANK_SUPPLY,
    GENESIS_LIQUIDITY,
    POL_SALT,
    POL_SHARE_BPS,
    BUYBACK_SALT,
    VAULT_SHARE_BPS,
    WAD
} from "../libraries/ExchequerMath.sol";
import {ICore} from "../interfaces/ICore.sol";
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";
import {IRevenueBuybacks} from "../interfaces/IRevenueBuybacks.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {maxLiquidity} from "../math/liquidity.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {CallPoints} from "../types/callPoints.sol";
import {Locker} from "../types/locker.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolState} from "../types/poolState.sol";
import {PositionId, createPositionId} from "../types/positionId.sol";
import {StorageSlot} from "../types/storageSlot.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";

import {BankToken, IBankShareHook} from "./BankToken.sol";
import {IssueToken} from "./IssueToken.sol";

/// @title Exchequer
/// @notice The issuing authority of the Exchequer economy: it reads net flow through the one
///         canonical ETH/$ISSUE market, sets the issuance rate, and routes fees.
/// @dev See docs/exchequer.md for the mapping from the whitepaper to this implementation.
///
///      The bank exposes no view functions. Every parameter and every word of state is readable
///      through `sload`, laid out by `ExchequerStorageLayout`, and every derived quantity is
///      computed by `ExchequerLib` with the same `ExchequerMath` the bank settles with. What
///      remains here is the minimum set of state transitions the economy needs.
///
///      Swaps must arrive through `Core.forward`, which is what lets the bank charge its fee in ETH
///      on both buys and sells. The bank itself never swaps: protocol-owned liquidity and buybacks
///      are both placed as standing bids below the market, so there is nothing to sandwich.
contract Exchequer is BaseExtension, BaseForwardee, BaseLocker, ExposedStorage, IBankShareHook {
    using CoreLib for ICore;
    using FlashAccountantLib for *;
    using ExposedStorageLib for IExposedStorage;

    /// @dev Saved balance salt under which the bank's unrouted fee ETH sits in Core
    bytes32 private constant FEE_SALT = bytes32(0);

    uint256 private constant CALL_TYPE_GENESIS = 0;
    uint256 private constant CALL_TYPE_SWEEP = 1;
    uint256 private constant CALL_TYPE_COMPOUND = 2;
    uint256 private constant CALL_TYPE_DEFEND = 3;

    // Hot-path values are immutables, mirrored once into storage so that a reader with only
    // `sload` can recover them. None of them has a getter.
    IssueToken private immutable ISSUE_TOKEN;
    BankToken private immutable BANK_TOKEN;
    address private immutable RESERVE_ASSET;
    PoolId private immutable POOL_ID;
    uint128 private immutable BASE_ISSUANCE_PER_DAY;
    uint128 private immutable MIN_NET_FLOW;
    uint64 private immutable MULTIPLIER_MIN;
    uint64 private immutable MULTIPLIER_MAX;
    uint64 private immutable MULTIPLIER_CUT_STEP;
    uint64 private immutable MULTIPLIER_RAISE_STEP;
    uint32 private immutable EPOCH_LENGTH;
    uint64 private immutable TRADING_FEE;
    uint32 private immutable TICK_SPACING;
    uint64 private immutable RESOLUTION_FEE_FLOOR;
    uint64 private immutable RESOLUTION_FEE_CEILING;
    uint64 private immutable EXIT_PRESSURE_SATURATION;
    uint128 private immutable EXIT_PRESSURE_DENOMINATOR_FLOOR;
    uint32 private immutable POL_REFERENCE_WINDOW;
    uint32 private immutable REDISTRIBUTION_STREAM_LENGTH;

    error Unauthorized();
    error SwapMustHappenThroughForward();
    error OnlyGenesisMayInitializeThePool();
    error IncorrectPoolKey();
    error GenesisAlreadyRan();
    error GenesisDidNotAbsorbSupply();
    error TokensNotBoundToBank();
    error VaultNotOwnedByBank();
    error VaultBuysWrongAsset();
    error AuctionsNotForThisBank();
    error AuctionsOnly();
    error BankTokenOnly();
    error OnlyCoreMaySendEth();
    error InvalidWithdrawalAmount();
    error FoundingSupplyExceeded();
    error NothingToCompound();
    error NothingToDefend();
    error NothingToFlush();
    error BidExceededAvailableAmounts();
    error InvalidParameters();

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
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
    event Flushed(uint128 expansion, uint128 team);
    event Compounded(int32 lowerTick, uint128 eth, uint128 liquidity);
    event BuybackSettled(int32 lowerTick, uint128 ethRecovered, uint256 issueBurned);
    event BuybackBidsPlaced(int32 lowerTick, uint128 eth, uint128 liquidity);
    event Genesis(int32 tick, uint128 ethAdded, uint256 issueAdded, uint256 issueBurned);

    /// @param core The Ekubo Core singleton
    /// @param owner Holder of the policy knobs, able to renounce irreversibly
    /// @param reserveAsset The tokenized gold (or comparable) asset the expansion vault accumulates
    /// @param issue The currency, deployed ahead of the bank and bound to it before genesis
    /// @param bankToken The share, likewise
    /// @param params Every monetary parameter the whitepaper leaves blank
    constructor(
        ICore core,
        address owner,
        address reserveAsset,
        IssueToken issue,
        BankToken bankToken,
        ExchequerParameters memory params
    ) BaseExtension(core) BaseForwardee(core) BaseLocker(core) {
        if (
            params.multiplierMin == 0 || params.multiplierMin > params.multiplierLaunch
                || params.multiplierLaunch > params.multiplierMax || params.epochLength == 0
                || params.resolutionFeeFloor > params.resolutionFeeCeiling || params.resolutionFeeCeiling > WAD
                || params.exitPressureSaturation == 0 || params.exitPressureSaturation > WAD
                || params.baseIssuancePerDay == 0 || params.tickSpacing == 0 || params.polReferenceWindow == 0
                || params.redistributionStreamLength == 0 || reserveAsset == NATIVE_TOKEN_ADDRESS
        ) revert InvalidParameters();

        ISSUE_TOKEN = issue;
        BANK_TOKEN = bankToken;
        RESERVE_ASSET = reserveAsset;
        // The pool charges no fee of its own; the bank takes the whole trading fee, in ETH.
        POOL_ID = ExchequerMath.poolKey(address(issue), params.tickSpacing, address(this)).toPoolId();

        BASE_ISSUANCE_PER_DAY = params.baseIssuancePerDay;
        MIN_NET_FLOW = params.minNetFlow;
        MULTIPLIER_MIN = params.multiplierMin;
        MULTIPLIER_MAX = params.multiplierMax;
        MULTIPLIER_CUT_STEP = params.multiplierCutStep;
        MULTIPLIER_RAISE_STEP = params.multiplierRaiseStep;
        EPOCH_LENGTH = params.epochLength;
        TRADING_FEE = params.tradingFee;
        TICK_SPACING = params.tickSpacing;
        RESOLUTION_FEE_FLOOR = params.resolutionFeeFloor;
        RESOLUTION_FEE_CEILING = params.resolutionFeeCeiling;
        EXIT_PRESSURE_SATURATION = params.exitPressureSaturation;
        EXIT_PRESSURE_DENOMINATOR_FLOOR = params.exitPressureDenominatorFloor;
        POL_REFERENCE_WINDOW = params.polReferenceWindow;
        REDISTRIBUTION_STREAM_LENGTH = params.redistributionStreamLength;

        // The storage mirror, written once
        _storeAddress(L.OWNER_SLOT, owner);
        _storeAddress(L.TEAM_RECIPIENT_SLOT, owner);
        _storeAddress(L.ISSUE_TOKEN_SLOT, address(issue));
        _storeAddress(L.BANK_TOKEN_SLOT, address(bankToken));
        _storeAddress(L.RESERVE_ASSET_SLOT, reserveAsset);
        L.slot(L.PARAMETERS_A_SLOT).store(L.packTwo128(params.baseIssuancePerDay, params.minNetFlow));
        L.slot(L.PARAMETERS_B_SLOT)
            .store(
                L.packFour64(
                    params.multiplierMin, params.multiplierMax, params.multiplierCutStep, params.multiplierRaiseStep
                )
            );
        L.slot(L.PARAMETERS_C_SLOT)
            .store(
                L.packParametersC(
                    params.epochLength,
                    params.tradingFee,
                    params.polReferenceWindow,
                    params.redistributionStreamLength,
                    params.tickSpacing
                )
            );
        L.slot(L.PARAMETERS_D_SLOT)
            .store(
                L.packFour64(params.resolutionFeeFloor, params.resolutionFeeCeiling, params.exitPressureSaturation, 0)
            );
        L.slot(L.PARAMETERS_E_SLOT).store(bytes32(uint256(params.exitPressureDenominatorFloor)));
        L.slot(L.POLICY_SLOT).store(L.packPolicy(params.multiplierLaunch, 0, 0, false));

        emit OwnershipTransferred(address(0), owner);
    }

    /// OWNERSHIP

    modifier onlyOwner() {
        if (msg.sender != _loadAddress(L.OWNER_SLOT)) revert Unauthorized();
        _;
    }

    /// @notice Hands the policy knobs to `newOwner`
    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(msg.sender, newOwner);
        _storeAddress(L.OWNER_SLOT, newOwner);
    }

    /// @notice Gives the policy knobs up forever: the bank then answers to no board
    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(msg.sender, address(0));
        _storeAddress(L.OWNER_SLOT, address(0));
    }

    /// EXTENSION CALL POINTS

    /// @inheritdoc BaseExtension
    function getCallPoints() internal pure override returns (CallPoints memory) {
        return exchequerCallPoints();
    }

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
        (uint64 m, uint64 epochStart, uint64 last, bool initialized) = L.unpackPolicy(L.slot(L.POLICY_SLOT).load());
        if (last == 0 || block.timestamp == last) return;

        (bytes32 flowWord, bytes32 historyWord) = L.slot(L.EPOCH_FLOW_SLOT).loadTwo();
        int256 currentFlow;
        {
            (uint128 ethIn, uint128 ethOut) = L.unpackTwo128(flowWord);
            currentFlow = int256(uint256(ethIn)) - int256(uint256(ethOut));
        }
        (int128 prevFlow, int128 prevPrevFlow) = L.unpackSigned128Pair(historyWord);

        (uint256 weightedSeconds, uint256 nextM, uint256 nextEpochStart, uint256 rolls) =
            ExchequerMath.walk(_parameters(), m, epochStart, last, currentFlow, prevFlow, block.timestamp);

        if (rolls != 0) {
            // Fee routing follows the epoch that just closed alone: the fast lever (§4)
            bool expansion = ExchequerMath.isExpansion(currentFlow, MIN_NET_FLOW);
            _routeRevenue(expansion);

            // Every epoch after the first saw no interaction, hence no flow
            if (rolls == 1) {
                (prevPrevFlow, prevFlow) = (prevFlow, SafeCastLib.toInt128(currentFlow));
            } else if (rolls == 2) {
                (prevPrevFlow, prevFlow) = (SafeCastLib.toInt128(currentFlow), 0);
            } else {
                (prevPrevFlow, prevFlow) = (0, 0);
            }
            L.slot(L.EPOCH_FLOW_SLOT).storeTwo(bytes32(0), L.packSigned128Pair(prevFlow, prevPrevFlow));

            emit EpochRolled(uint64(nextEpochStart), currentFlow, rolls, uint64(nextM), expansion);
        }

        _bookIssuance(weightedSeconds, last, BANK_TOKEN.totalSupply());
        L.slot(L.POLICY_SLOT)
            .store(L.packPolicy(uint64(nextM), uint64(nextEpochStart), uint64(block.timestamp), initialized));
    }

    /// @notice Credits `weightedSeconds` worth of base issuance, plus whatever the redistribution
    ///         stream has released since `last`, across every outstanding share
    function _bookIssuance(uint256 weightedSeconds, uint256 last, uint256 supply) private {
        if (supply == 0) return;

        uint256 cumulative = uint256(L.slot(L.CUMULATIVE_ISSUANCE_SLOT).load());
        uint256 amount = ExchequerMath.baseIssuance(weightedSeconds, BASE_ISSUANCE_PER_DAY, cumulative);
        if (amount != 0) {
            L.slot(L.CUMULATIVE_ISSUANCE_SLOT).store(bytes32(cumulative + amount));
            _addTotalLedger(amount);
        }

        (uint128 remaining, uint64 end) = L.unpackStream(L.slot(L.STREAM_SLOT).load());
        uint256 streamed = ExchequerMath.streamRelease(remaining, end, last, block.timestamp);
        if (streamed != 0) {
            unchecked {
                L.slot(L.STREAM_SLOT).store(L.packStream(remaining - uint128(streamed), end));
            }
        }

        uint256 credit = amount + streamed;
        if (credit == 0) return;

        StorageSlot growthSlot = L.slot(L.ISSUANCE_GROWTH_PER_SHARE_X128_SLOT);
        uint256 growth = uint256(growthSlot.load()) + FixedPointMathLib.fullMulDiv(credit, 1 << 128, supply);
        growthSlot.store(bytes32(growth));

        emit Accrued(amount, streamed, growth);
    }

    /// @notice Splits the epoch's protocol ETH 70/15/15 and assigns the vault share by regime (§11)
    function _routeRevenue(bool expansion) private {
        StorageSlot feeSlot = L.slot(L.FEE_ETH_SLOT);
        (uint128 saved, uint128 revenue) = L.unpackTwo128(feeSlot.load());
        if (revenue == 0) return;
        feeSlot.store(L.packTwo128(saved, 0));

        unchecked {
            uint128 toVault = uint128((uint256(revenue) * VAULT_SHARE_BPS) / 10000);
            uint128 toPol = uint128((uint256(revenue) * POL_SHARE_BPS) / 10000);
            uint128 toTeam = revenue - toVault - toPol;

            StorageSlot vaultSlot = L.slot(L.VAULT_ETH_SLOT);
            (uint128 pendingExpansion, uint128 pendingContraction) = L.unpackTwo128(vaultSlot.load());
            if (expansion) pendingExpansion += toVault;
            else pendingContraction += toVault;
            vaultSlot.store(L.packTwo128(pendingExpansion, pendingContraction));

            StorageSlot polSlot = L.slot(L.POL_ETH_SLOT);
            (uint128 pendingPol, uint128 pendingTeam) = L.unpackTwo128(polSlot.load());
            polSlot.store(L.packTwo128(pendingPol + toPol, pendingTeam + toTeam));

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

        StorageSlot fromSlot = L.holderSlot(from);
        uint256 fromLedger = uint256(fromSlot.load());
        uint256 moved = FixedPointMathLib.fullMulDiv(fromLedger, amount, balance);
        if (moved == 0) return;

        StorageSlot toSlot = L.holderSlot(to);
        unchecked {
            fromSlot.store(bytes32(fromLedger - moved));
            toSlot.store(bytes32(uint256(toSlot.load()) + moved));
        }
        emit LedgerMoved(from, to, moved);
    }

    /// @notice Moves `holder`'s share of issuance growth into their settled ledger balance
    function _settle(address holder) private {
        if (holder == address(0)) return;

        uint256 growth = uint256(L.slot(L.ISSUANCE_GROWTH_PER_SHARE_X128_SLOT).load());
        StorageSlot holderSlot = L.holderSlot(holder);
        StorageSlot snapshotSlot = holderSlot.next();
        uint256 snapshot = uint256(snapshotSlot.load());
        if (snapshot == growth) return;

        snapshotSlot.store(bytes32(growth));

        uint256 balance = BANK_TOKEN.balanceOf(holder);
        if (balance == 0) return;

        unchecked {
            holderSlot.store(
                bytes32(uint256(holderSlot.load()) + FixedPointMathLib.fullMulDivN(growth - snapshot, balance, 128))
            );
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

        StorageSlot holderSlot = L.holderSlot(msg.sender);
        uint256 accrued = uint256(holderSlot.load());
        // Pro rata rule: retiring one branch of ten liquidates one tenth of the balance
        released = FixedPointMathLib.fullMulDiv(accrued, bankAmount, balance);

        // Priced at the margin, with this exit's own size in the window: lumping an exit into one
        // call must never be cheaper than splitting it
        uint256 totalLedger = uint256(L.slot(L.TOTAL_LEDGER_BALANCE_SLOT).load());
        uint256 feeRate = ExchequerMath.resolutionFeeRate(_parameters(), _trailingWithdrawals(), released, totalLedger);
        uint256 fee = FixedPointMathLib.fullMulDiv(released, feeRate, WAD);
        uint256 burned = fee / 2;
        uint256 redistributed = fee - burned;
        minted = released - fee;

        unchecked {
            holderSlot.store(bytes32(accrued - released));
            totalLedger -= released;
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

        (uint128 streamRemaining, uint64 streamEnd) = L.unpackStream(L.slot(L.STREAM_SLOT).load());
        if (remainingSupply != 0) {
            if (redistributed != 0) {
                // Paid to every banker who stays, streamed so that staying is measured in time
                uint256 end = ExchequerMath.streamEndAfterDeposit(
                    streamRemaining, streamEnd, redistributed, REDISTRIBUTION_STREAM_LENGTH, block.timestamp
                );
                L.slot(L.STREAM_SLOT)
                    .store(L.packStream(SafeCastLib.toUint128(streamRemaining + redistributed), uint64(end)));
                totalLedger += redistributed;
                emit RedistributionStreamed(redistributed, uint64(end));
            }
        } else {
            // Nobody stayed, so there is nobody to pay, now or from an earlier stream
            uint256 orphaned = redistributed + streamRemaining;
            if (streamRemaining != 0) {
                totalLedger -= streamRemaining;
                L.slot(L.STREAM_SLOT).store(bytes32(0));
            }
            if (orphaned != 0) {
                ISSUE_TOKEN.mint(address(this), orphaned);
                ISSUE_TOKEN.burn(orphaned);
            }
        }
        L.slot(L.TOTAL_LEDGER_BALANCE_SLOT).store(bytes32(totalLedger));

        if (minted != 0) ISSUE_TOKEN.mint(recipient, minted);

        emit Withdrawn(msg.sender, bankAmount, released, feeRate, burned, redistributed);
    }

    /// @notice System-wide withdrawals over the trailing window: `W` in eq 9.1
    function _trailingWithdrawals() private view returns (uint256 total) {
        uint256 today = block.timestamp / 1 days;
        uint256 last = uint256(L.slot(L.LAST_BUCKET_DAY_SLOT).load());
        if (today - last >= EXIT_BUCKETS) return 0;

        unchecked {
            for (uint256 i; i < EXIT_BUCKETS; ++i) {
                uint256 day = today - i;
                // Buckets for days after the last write still hold data from a previous cycle
                if (day > last) continue;
                total += uint256(L.withdrawalBucketSlot(day % EXIT_BUCKETS).load());
            }
        }
    }

    /// @notice Books a withdrawal into today's bucket, expiring anything that fell out of the window
    function _recordWithdrawal(uint256 amount) private {
        uint256 today = block.timestamp / 1 days;
        StorageSlot lastSlot = L.slot(L.LAST_BUCKET_DAY_SLOT);
        uint256 last = uint256(lastSlot.load());

        unchecked {
            if (today != last) {
                uint256 gap = today - last;
                if (gap >= EXIT_BUCKETS) {
                    for (uint256 i; i < EXIT_BUCKETS; ++i) {
                        L.withdrawalBucketSlot(i).store(bytes32(0));
                    }
                } else {
                    for (uint256 i = 1; i <= gap; ++i) {
                        L.withdrawalBucketSlot((last + i) % EXIT_BUCKETS).store(bytes32(0));
                    }
                }
                lastSlot.store(bytes32(today));
            }

            StorageSlot bucket = L.withdrawalBucketSlot(today % EXIT_BUCKETS);
            bucket.store(bytes32(uint256(bucket.load()) + amount));
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
        if (PoolId.unwrap(key.toPoolId()) != PoolId.unwrap(POOL_ID)) revert IncorrectPoolKey();
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

        // Net flow is read on the pool-facing delta, before the fee. Booking the fee as inflow would
        // let a round trip register its own two fees as capital entering, which is the cheapest
        // possible way to buy an expansion epoch.
        int128 poolDelta = balanceUpdate.delta0();
        {
            StorageSlot flowSlot = L.slot(L.EPOCH_FLOW_SLOT);
            (uint128 ethIn, uint128 ethOut) = L.unpackTwo128(flowSlot.load());
            unchecked {
                if (poolDelta > 0) ethIn += uint128(poolDelta);
                else if (poolDelta < 0) ethOut += uint128(uint256(-int256(poolDelta)));
            }
            flowSlot.store(L.packTwo128(ethIn, ethOut));
        }

        int128 ethDelta = SafeCastLib.toInt128(int256(poolDelta) + int256(uint256(feeAmount)));
        balanceUpdate = createPoolBalanceUpdate(ethDelta, balanceUpdate.delta1());

        if (feeAmount != 0) {
            CORE.updateSavedBalances(key.token0, key.token1, FEE_SALT, int256(uint256(feeAmount)), 0);
            StorageSlot feeSlot = L.slot(L.FEE_ETH_SLOT);
            (uint128 saved, uint128 revenue) = L.unpackTwo128(feeSlot.load());
            unchecked {
                feeSlot.store(L.packTwo128(saved + feeAmount, revenue + feeAmount));
            }
            emit TradingFeeCollected(feeAmount, ethDelta);
        }
    }

    /// @notice Records the pool tick after a trade, folding in the price that prevailed until now
    function _observe(int32 tickAfter) private {
        StorageSlot slot = L.slot(L.REFERENCE_SLOT);
        (int64 refX24, int32 lastTick, uint32 lastTime) = L.unpackReference(slot.load());
        if (block.timestamp != lastTime) {
            refX24 = int64(
                ExchequerMath.foldedReferenceX24(refX24, lastTick, lastTime, POL_REFERENCE_WINDOW, block.timestamp)
            );
            lastTime = uint32(block.timestamp);
        }
        slot.store(L.packReference(refX24, tickAfter, lastTime));
    }

    /// @notice The bank's reference price as a tick, brought up to the current block
    function _referenceTick() private view returns (int32) {
        (int64 refX24, int32 lastTick, uint32 lastTime) = L.unpackReference(L.slot(L.REFERENCE_SLOT).load());
        return int32(
            ExchequerMath.foldedReferenceX24(refX24, lastTick, lastTime, POL_REFERENCE_WINDOW, block.timestamp) >> 24
        );
    }

    /// FEE ENGINE

    /// @notice Opens `amount` of new branches for an auction buyer, booking any ETH paid into the
    ///         same fee engine as trading fees (§2). Auctions only.
    /// @dev The bank does not know what the auctions should have charged; it books what arrives.
    ///      That the price was real rests on the auctions' own policy: a nonzero reserve while any
    ///      charter supply is offered, and a hard cap on that supply. A bug there is a mint bug here.
    function openBranches(address recipient, uint256 amount) external payable {
        if (msg.sender != _loadAddress(L.AUCTIONS_SLOT)) revert AuctionsOnly();
        accrue();
        if (msg.value != 0) {
            StorageSlot feeSlot = L.slot(L.FEE_ETH_SLOT);
            (uint128 saved, uint128 revenue) = L.unpackTwo128(feeSlot.load());
            feeSlot.store(L.packTwo128(saved, revenue + SafeCastLib.toUint128(msg.value)));
        }
        BANK_TOKEN.mint(recipient, amount);
    }

    /// @notice Delivers routed ETH to the expansion vault and the team. Permissionless.
    /// @dev The vault always accepts ETH. The team's delivery is attempted and, if the recipient
    ///      refuses it, simply left pending, so no recipient can ever hold up the vault.
    function flush() external returns (uint128 expansion, uint128 team) {
        accrue();
        _sweep();

        StorageSlot vaultSlot = L.slot(L.VAULT_ETH_SLOT);
        uint128 pendingContraction;
        (expansion, pendingContraction) = L.unpackTwo128(vaultSlot.load());

        StorageSlot polSlot = L.slot(L.POL_ETH_SLOT);
        uint128 pendingPol;
        (pendingPol, team) = L.unpackTwo128(polSlot.load());

        if (expansion == 0 && team == 0) revert NothingToFlush();

        if (expansion != 0) {
            vaultSlot.store(L.packTwo128(0, pendingContraction));
            SafeTransferLib.safeTransferETH(_loadAddress(L.EXPANSION_VAULT_SLOT), expansion);
        }

        if (team != 0) {
            polSlot.store(L.packTwo128(pendingPol, 0));
            (bool delivered,) = _loadAddress(L.TEAM_RECIPIENT_SLOT).call{value: team}("");
            if (!delivered) {
                polSlot.store(L.packTwo128(pendingPol, team));
                team = 0;
            }
        }

        emit Flushed(expansion, team);
    }

    /// @notice Places accumulated POL ETH as permanent protocol-owned bids. Permissionless.
    /// @dev The ETH goes in as single-sided liquidity from the first grid tick above
    ///      `max(spot, reference)` up to the top of the range: a standing bid for $ISSUE at every
    ///      price below the market. No swap happens, so there is nothing to sandwich, and the bank
    ///      pays no premium: it buys only when sellers come down to it. Because the bids never sit
    ///      above the reference, a pump in front of this call finds nothing to sell into. Buckets
    ///      accumulate on a grid, each with no withdrawal path.
    /// @return liquidity Liquidity added to the bucket
    /// @return lowerTick Lower tick of the bucket the ETH went into
    function compound() external returns (uint128 liquidity, int32 lowerTick) {
        accrue();
        _sweep();

        StorageSlot polSlot = L.slot(L.POL_ETH_SLOT);
        (uint128 amount, uint128 pendingTeam) = L.unpackTwo128(polSlot.load());
        if (amount == 0) revert NothingToCompound();
        polSlot.store(L.packTwo128(0, pendingTeam));

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

        StorageSlot vaultSlot = L.slot(L.VAULT_ETH_SLOT);
        (uint128 pendingExpansion, uint128 amount) = L.unpackTwo128(vaultSlot.load());
        vaultSlot.store(L.packTwo128(pendingExpansion, 0));

        (liquidity, lowerTick, issueBurned) =
            abi.decode(lock(abi.encode(CALL_TYPE_DEFEND, amount)), (uint128, int32, uint256));
    }

    /// @notice Draws all fee ETH out of Core so the pending buckets are backed by real balance
    function _sweep() private {
        StorageSlot feeSlot = L.slot(L.FEE_ETH_SLOT);
        (uint128 saved, uint128 revenue) = L.unpackTwo128(feeSlot.load());
        if (saved == 0) return;
        feeSlot.store(L.packTwo128(0, revenue));
        lock(abi.encode(CALL_TYPE_SWEEP, saved));
    }

    /// GENESIS AND ADMINISTRATION

    /// @notice Wires in the vault and the auctions, initializes the one market, and locks the
    ///         genesis liquidity into it forever. One shot.
    /// @param tick Starting tick of the pool
    /// @param vault The expansion vault: must be owned by this bank and buy the reserve asset
    /// @param auctions The auctions: must open branches for this bank, in this bank's currency
    function initialize(int32 tick, address vault, address auctions) external payable onlyOwner {
        (uint64 m,,, bool initialized) = L.unpackPolicy(L.slot(L.POLICY_SLOT).load());
        if (initialized) revert GenesisAlreadyRan();

        // Both tokens must answer to this bank and no other before a single unit exists
        if (ISSUE_TOKEN.minter() != address(this) || BANK_TOKEN.bank() != address(this)) revert TokensNotBoundToBank();
        // A mis-wired vault would strand every expansion epoch
        if (Ownable(vault).owner() != address(this)) revert VaultNotOwnedByBank();
        if (IRevenueBuybacks(vault).BUY_TOKEN() != RESERVE_ASSET) revert VaultBuysWrongAsset();
        // The auctions are read through their exposed storage, as everything else is
        (bytes32 auctionsBank, bytes32 auctionsIssue) =
            IExposedStorage(auctions).sload(AL.slot(AL.BANK_SLOT), AL.slot(AL.ISSUE_TOKEN_SLOT));
        if (
            address(uint160(uint256(auctionsBank))) != address(this)
                || address(uint160(uint256(auctionsIssue))) != address(ISSUE_TOKEN)
        ) revert AuctionsNotForThisBank();

        _storeAddress(L.EXPANSION_VAULT_SLOT, vault);
        _storeAddress(L.AUCTIONS_SLOT, auctions);
        L.slot(L.POLICY_SLOT).store(L.packPolicy(m, uint64(block.timestamp), uint64(block.timestamp), true));
        L.slot(L.LAST_BUCKET_DAY_SLOT).store(bytes32(block.timestamp / 1 days));

        ISSUE_TOKEN.mint(address(this), GENESIS_LIQUIDITY);

        lock(abi.encode(CALL_TYPE_GENESIS, tick, msg.value));
    }

    /// @notice Configures the expansion vault's TWAMM order duration and fee tier
    /// @dev The vault is owned by the bank, so this is the only way to configure it, and the only
    ///      thing the bank can do to it. Nothing can pull what the vault has bought anywhere but
    ///      here, and once the bank's owner renounces the configuration is frozen.
    function configureExpansionVault(uint32 targetOrderDuration, uint32 minOrderDuration, uint64 fee)
        external
        onlyOwner
    {
        IRevenueBuybacks(_loadAddress(L.EXPANSION_VAULT_SLOT))
            .configure(NATIVE_TOKEN_ADDRESS, targetOrderDuration, minOrderDuration, fee);
    }

    /// @notice Updates the recipient of the 15% team share
    function setTeamRecipient(address recipient) external onlyOwner {
        _storeAddress(L.TEAM_RECIPIENT_SLOT, recipient);
    }

    /// @notice Mints part of the free founding distribution, capped at `FOUNDING_BANK_SUPPLY` (§6)
    /// @dev Typically pointed at `Incentives` for a one-per-wallet merkle claim
    function mintFoundingBank(address recipient, uint256 amount) external onlyOwner {
        StorageSlot slot = L.slot(L.FOUNDING_BANK_MINTED_SLOT);
        uint256 minted = uint256(slot.load()) + amount;
        if (minted > FOUNDING_BANK_SUPPLY) revert FoundingSupplyExceeded();
        slot.store(bytes32(minted));
        BANK_TOKEN.mint(recipient, amount);
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
            PoolKey memory key = _poolKey();
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
        PoolKey memory key = _poolKey();
        CORE.initializePool(key, tick);

        L.slot(L.REFERENCE_SLOT).store(L.packReference(int64(tick) << 24, tick, uint32(block.timestamp)));

        PoolState state = CORE.poolState(POOL_ID);
        uint128 issueAmount = SafeCastLib.toUint128(GENESIS_LIQUIDITY);
        uint128 liquidity = maxLiquidity(
            state.sqrtRatio(),
            tickToSqrtRatio(ExchequerMath.polTickLower(TICK_SPACING)),
            tickToSqrtRatio(ExchequerMath.polTickUpper(TICK_SPACING)),
            ethAmount,
            issueAmount
        );

        uint128 amount0;
        uint128 amount1;
        if (liquidity != 0) {
            PoolBalanceUpdate update = CORE.updatePosition(
                key, ExchequerMath.polPositionId(TICK_SPACING), SafeCastLib.toInt128(int256(uint256(liquidity)))
            );
            amount0 = uint128(update.delta0());
            amount1 = uint128(update.delta1());
            if (amount0 > ethAmount || amount1 > issueAmount) revert BidExceededAvailableAmounts();
        }

        // Genesis is one shot and the supply is minted once, so a seed the chosen tick cannot pair
        // with the whole 100,000,000 is refused rather than silently burned
        uint256 leftoverIssue = GENESIS_LIQUIDITY - amount1;
        if (liquidity == 0 || leftoverIssue > GENESIS_LIQUIDITY / 1_000_000) revert GenesisDidNotAbsorbSupply();

        if (amount0 != 0) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount0);
        if (amount1 != 0) ACCOUNTANT.pay(address(ISSUE_TOKEN), amount1);

        // Rounding dust is destroyed rather than left mintable
        if (leftoverIssue != 0) ISSUE_TOKEN.burn(leftoverIssue);

        unchecked {
            uint128 leftoverEth = ethAmount - amount0;
            if (leftoverEth != 0) _addPendingPol(leftoverEth);
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
            if (leftover != 0) _addPendingPol(leftover);
        }

        emit Compounded(lowerTick, placed, liquidity);
    }

    /// @notice Settles the previous buyback bucket and places the next one
    function _defend(uint128 newEth) private returns (uint128 liquidity, int32 lowerTick, uint256 issueBurned) {
        PoolKey memory key = _poolKey();
        StorageSlot buybackSlot = L.slot(L.BUYBACK_SLOT);
        (int32 oldLower, bool active) = L.unpackBuyback(buybackSlot.load());

        uint128 recovered;
        if (active) {
            // A bucket the price has not reached holds only ETH, so there is nothing to settle
            if (newEth == 0 && CORE.poolState(POOL_ID).tick() < oldLower) revert NothingToDefend();

            PositionId oldId = ExchequerMath.buybackPositionId(oldLower, TICK_SPACING);
            uint128 oldLiquidity = CORE.poolPositions(POOL_ID, address(this), oldId).liquidity;
            if (oldLiquidity != 0) {
                PoolBalanceUpdate update =
                    CORE.updatePosition(key, oldId, -SafeCastLib.toInt128(int256(uint256(oldLiquidity))));
                recovered = uint128(uint256(-int256(update.delta0())));
                issueBurned = uint256(-int256(update.delta1()));
            }
            buybackSlot.store(L.packBuyback(oldLower, false));

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
            buybackSlot.store(L.packBuyback(lowerTick, true));
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
            if (leftover != 0) {
                StorageSlot vaultSlot = L.slot(L.VAULT_ETH_SLOT);
                (uint128 pendingExpansion, uint128 pendingContraction) = L.unpackTwo128(vaultSlot.load());
                vaultSlot.store(L.packTwo128(pendingExpansion, pendingContraction + leftover));
            }
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
        PoolState state = CORE.poolState(POOL_ID);
        int32 upper = ExchequerMath.polTickUpper(TICK_SPACING);

        lowerTick =
            ExchequerMath.bidLowerTick(state.tick(), _referenceTick(), ExchequerMath.polBidGrid(TICK_SPACING), upper);
        if (ethAmount == 0) return (0, lowerTick, 0);

        liquidity = maxLiquidity(state.sqrtRatio(), tickToSqrtRatio(lowerTick), tickToSqrtRatio(upper), ethAmount, 0);
        if (liquidity == 0) return (0, lowerTick, 0);

        PoolBalanceUpdate update = CORE.updatePosition(
            _poolKey(), createPositionId(salt, lowerTick, upper), SafeCastLib.toInt128(int256(uint256(liquidity)))
        );

        amount0 = uint128(update.delta0());
        if (update.delta1() != 0 || amount0 > ethAmount) revert BidExceededAvailableAmounts();
    }

    /// STORAGE HELPERS

    function _parameters() private view returns (ExchequerParameters memory p) {
        p.baseIssuancePerDay = BASE_ISSUANCE_PER_DAY;
        p.minNetFlow = MIN_NET_FLOW;
        p.multiplierMin = MULTIPLIER_MIN;
        p.multiplierMax = MULTIPLIER_MAX;
        p.multiplierCutStep = MULTIPLIER_CUT_STEP;
        p.multiplierRaiseStep = MULTIPLIER_RAISE_STEP;
        p.epochLength = EPOCH_LENGTH;
        p.resolutionFeeFloor = RESOLUTION_FEE_FLOOR;
        p.resolutionFeeCeiling = RESOLUTION_FEE_CEILING;
        p.exitPressureSaturation = EXIT_PRESSURE_SATURATION;
        p.exitPressureDenominatorFloor = EXIT_PRESSURE_DENOMINATOR_FLOOR;
    }

    function _poolKey() private view returns (PoolKey memory) {
        return ExchequerMath.poolKey(address(ISSUE_TOKEN), TICK_SPACING, address(this));
    }

    function _loadAddress(uint256 index) private view returns (address) {
        return address(uint160(uint256(L.slot(index).load())));
    }

    function _storeAddress(uint256 index, address value) private {
        L.slot(index).store(bytes32(uint256(uint160(value))));
    }

    function _addTotalLedger(uint256 amount) private {
        StorageSlot slot = L.slot(L.TOTAL_LEDGER_BALANCE_SLOT);
        slot.store(bytes32(uint256(slot.load()) + amount));
    }

    function _addPendingPol(uint128 amount) private {
        StorageSlot slot = L.slot(L.POL_ETH_SLOT);
        (uint128 pendingPol, uint128 pendingTeam) = L.unpackTwo128(slot.load());
        slot.store(L.packTwo128(pendingPol + amount, pendingTeam));
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
