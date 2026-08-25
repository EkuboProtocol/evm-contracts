// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC20} from "solady/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {Exchequer} from "../exchequer/Exchequer.sol";
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {ExchequerStorageLayout as L} from "./ExchequerStorageLayout.sol";
import {ExchequerMath, ExchequerParameters, EXIT_BUCKETS, ISSUANCE_BUDGET, WAD} from "./ExchequerMath.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionId} from "../types/positionId.sol";
import {StorageSlot} from "../types/storageSlot.sol";

/// @title Exchequer Library
/// @notice Exposed-storage readers for the Exchequer, and every derived quantity a caller might
///         want. The bank itself keeps no view functions: everything here is computed from its
///         storage with the same `ExchequerMath` it uses to settle, so a projection can never
///         disagree with a settlement.
/// @dev Readers must use ExchequerStorageLayout so they match the bank's manual storage slots.
library ExchequerLib {
    using ExposedStorageLib for IExposedStorage;

    /// PARAMETERS AND ADDRESSES

    /// @notice Every constructor parameter, recovered from the storage mirror
    /// @dev The launch multiplier is not needed after construction and is not mirrored
    function parameters(Exchequer bank) internal view returns (ExchequerParameters memory p) {
        IExposedStorage s = _s(bank);
        (bytes32 a, bytes32 b, bytes32 c) =
            s.sload(L.slot(L.PARAMETERS_A_SLOT), L.slot(L.PARAMETERS_B_SLOT), L.slot(L.PARAMETERS_C_SLOT));
        (bytes32 d, bytes32 e) = s.sload(L.slot(L.PARAMETERS_D_SLOT), L.slot(L.PARAMETERS_E_SLOT));

        (p.baseIssuancePerDay, p.minNetFlow) = L.unpackTwo128(a);
        (p.multiplierMin, p.multiplierMax, p.multiplierCutStep, p.multiplierRaiseStep) = L.unpackFour64(b);
        (p.epochLength, p.tradingFee, p.polReferenceWindow, p.redistributionStreamLength, p.tickSpacing) =
            L.unpackParametersC(c);
        (p.resolutionFeeFloor, p.resolutionFeeCeiling, p.exitPressureSaturation,) = L.unpackFour64(d);
        p.exitPressureDenominatorFloor = uint128(uint256(e));
    }

    function owner(Exchequer bank) internal view returns (address) {
        return _address(bank, L.OWNER_SLOT);
    }

    function teamRecipient(Exchequer bank) internal view returns (address) {
        return _address(bank, L.TEAM_RECIPIENT_SLOT);
    }

    function expansionVault(Exchequer bank) internal view returns (address) {
        return _address(bank, L.EXPANSION_VAULT_SLOT);
    }

    function auctions(Exchequer bank) internal view returns (address) {
        return _address(bank, L.AUCTIONS_SLOT);
    }

    function issueToken(Exchequer bank) internal view returns (address) {
        return _address(bank, L.ISSUE_TOKEN_SLOT);
    }

    function bankToken(Exchequer bank) internal view returns (address) {
        return _address(bank, L.BANK_TOKEN_SLOT);
    }

    function reserveAsset(Exchequer bank) internal view returns (address) {
        return _address(bank, L.RESERVE_ASSET_SLOT);
    }

    /// STATE

    function policy(Exchequer bank)
        internal
        view
        returns (uint64 multiplier_, uint64 epochStartTime_, uint64 lastAccrualTime_, bool initialized_)
    {
        return L.unpackPolicy(_word(bank, L.POLICY_SLOT));
    }

    function multiplier(Exchequer bank) internal view returns (uint64 m) {
        (m,,,) = policy(bank);
    }

    function epochStartTime(Exchequer bank) internal view returns (uint64 t) {
        (, t,,) = policy(bank);
    }

    function lastAccrualTime(Exchequer bank) internal view returns (uint64 t) {
        (,, t,) = policy(bank);
    }

    function initialized(Exchequer bank) internal view returns (bool yes) {
        (,,, yes) = policy(bank);
    }

    function issuanceGrowthPerShareX128(Exchequer bank) internal view returns (uint256) {
        return uint256(_word(bank, L.ISSUANCE_GROWTH_PER_SHARE_X128_SLOT));
    }

    function cumulativeIssuance(Exchequer bank) internal view returns (uint256) {
        return uint256(_word(bank, L.CUMULATIVE_ISSUANCE_SLOT));
    }

    function totalLedgerBalance(Exchequer bank) internal view returns (uint256) {
        return uint256(_word(bank, L.TOTAL_LEDGER_BALANCE_SLOT));
    }

    function ledgerBalance(Exchequer bank, address holder) internal view returns (uint256) {
        return uint256(_s(bank).sload(L.holderSlot(holder)));
    }

    function growthSnapshotX128(Exchequer bank, address holder) internal view returns (uint256) {
        return uint256(_s(bank).sload(L.holderSlot(holder).next()));
    }

    /// @notice Net flow of the epoch in progress, and of the two most recently completed epochs
    function netFlows(Exchequer bank) internal view returns (int256 current, int128 previous, int128 beforePrevious) {
        (bytes32 flow, bytes32 history) = _s(bank).sload(L.slot(L.EPOCH_FLOW_SLOT), L.slot(L.FLOW_HISTORY_SLOT));
        (uint128 ethIn, uint128 ethOut) = L.unpackTwo128(flow);
        current = int256(uint256(ethIn)) - int256(uint256(ethOut));
        (previous, beforePrevious) = L.unpackSigned128Pair(history);
    }

    function savedEth(Exchequer bank) internal view returns (uint128 v) {
        (v,) = L.unpackTwo128(_word(bank, L.FEE_ETH_SLOT));
    }

    function epochRevenueEth(Exchequer bank) internal view returns (uint128 v) {
        (, v) = L.unpackTwo128(_word(bank, L.FEE_ETH_SLOT));
    }

    function pendingExpansionEth(Exchequer bank) internal view returns (uint128 v) {
        (v,) = L.unpackTwo128(_word(bank, L.VAULT_ETH_SLOT));
    }

    function pendingContractionEth(Exchequer bank) internal view returns (uint128 v) {
        (, v) = L.unpackTwo128(_word(bank, L.VAULT_ETH_SLOT));
    }

    function pendingPolEth(Exchequer bank) internal view returns (uint128 v) {
        (v,) = L.unpackTwo128(_word(bank, L.POL_ETH_SLOT));
    }

    function pendingTeamEth(Exchequer bank) internal view returns (uint128 v) {
        (, v) = L.unpackTwo128(_word(bank, L.POL_ETH_SLOT));
    }

    function streamRemaining(Exchequer bank) internal view returns (uint128 v) {
        (v,) = L.unpackStream(_word(bank, L.STREAM_SLOT));
    }

    function streamEndTime(Exchequer bank) internal view returns (uint64 v) {
        (, v) = L.unpackStream(_word(bank, L.STREAM_SLOT));
    }

    function buybackBidLowerTick(Exchequer bank) internal view returns (int32 v) {
        (v,) = L.unpackBuyback(_word(bank, L.BUYBACK_SLOT));
    }

    function buybackBidActive(Exchequer bank) internal view returns (bool v) {
        (, v) = L.unpackBuyback(_word(bank, L.BUYBACK_SLOT));
    }

    function foundingBankMinted(Exchequer bank) internal view returns (uint256) {
        return uint256(_word(bank, L.FOUNDING_BANK_MINTED_SLOT));
    }

    /// @notice System-wide withdrawals over the trailing window: `W` in eq 9.1
    /// @dev Bucketed by calendar day, so the window covers between six and seven days of history
    function trailingWithdrawals(Exchequer bank) internal view returns (uint256 total) {
        uint256 today = block.timestamp / 1 days;
        uint256 last = uint256(_word(bank, L.LAST_BUCKET_DAY_SLOT));
        if (today - last >= EXIT_BUCKETS) return 0;

        unchecked {
            for (uint256 i; i < EXIT_BUCKETS; ++i) {
                uint256 day = today - i;
                // Buckets for days after the last write still hold data from a previous cycle
                if (day > last) continue;
                total += uint256(_s(bank).sload(L.withdrawalBucketSlot(day % EXIT_BUCKETS)));
            }
        }
    }

    /// DERIVED

    /// @notice Base issuance that would be credited if `accrue` were called right now
    function pendingIssuance(Exchequer bank) internal view returns (uint256) {
        (uint256 base,) = _pendingCredit(bank, parameters(bank));
        return base;
    }

    /// @notice Redistributed fees that would be released if `accrue` were called right now
    function pendingStreamRelease(Exchequer bank) internal view returns (uint256) {
        (, uint256 streamed) = _pendingCredit(bank, parameters(bank));
        return streamed;
    }

    /// @notice The issuance growth accumulator brought up to the current block
    function currentGrowthPerShareX128(Exchequer bank) internal view returns (uint256) {
        (uint256 base, uint256 streamed) = _pendingCredit(bank, parameters(bank));
        uint256 credit = base + streamed;
        uint256 growth = issuanceGrowthPerShareX128(bank);
        if (credit == 0) return growth;
        unchecked {
            return growth + FixedPointMathLib.fullMulDiv(credit, 1 << 128, _bankSupply(bank));
        }
    }

    /// @notice A holder's full ledger balance, including issuance not yet accrued or settled
    function balanceAtBank(Exchequer bank, address holder) internal view returns (uint256) {
        uint256 growth = currentGrowthPerShareX128(bank);
        StorageSlot holderSlot = L.holderSlot(holder);
        (bytes32 ledger, bytes32 snapshot) = _s(bank).sload(holderSlot, holderSlot.next());
        unchecked {
            uint256 pending = growth == uint256(snapshot)
                ? 0
                : FixedPointMathLib.fullMulDivN(
                    growth - uint256(snapshot), ERC20(bankToken(bank)).balanceOf(holder), 128
                );
            return uint256(ledger) + pending;
        }
    }

    /// @notice Everything still held at the bank, brought up to the current block: `D` in eq 9.1
    function currentTotalLedgerBalance(Exchequer bank) internal view returns (uint256) {
        unchecked {
            return totalLedgerBalance(bank) + pendingIssuance(bank);
        }
    }

    /// @notice The resolution fee a marginal exit would pay right now, in 1e18 fixed point
    function resolutionFeeRate(Exchequer bank) internal view returns (uint256) {
        return resolutionFeeRateFor(bank, 0);
    }

    /// @notice The resolution fee an exit of `exiting` would pay right now, in 1e18 fixed point
    function resolutionFeeRateFor(Exchequer bank, uint256 exiting) internal view returns (uint256) {
        return ExchequerMath.resolutionFeeRate(
            parameters(bank), trailingWithdrawals(bank), exiting, currentTotalLedgerBalance(bank)
        );
    }

    /// @notice The multiplier as of the current block, including boundaries not yet settled
    function currentMultiplier(Exchequer bank) internal view returns (uint256 m) {
        (uint64 stored, uint64 epochStart, uint64 last,) = policy(bank);
        if (last == 0 || block.timestamp == last) return stored;
        (int256 current, int128 previous,) = netFlows(bank);
        (, m,,) = ExchequerMath.walk(parameters(bank), stored, epochStart, last, current, previous, block.timestamp);
    }

    /// @notice The bank's reference price as a tick, brought up to the current block
    function referenceTick(Exchequer bank) internal view returns (int32) {
        (bytes32 referenceWord, bytes32 c) = _s(bank).sload(L.slot(L.REFERENCE_SLOT), L.slot(L.PARAMETERS_C_SLOT));
        (int64 refX24, int32 lastTick, uint32 lastTime) = L.unpackReference(referenceWord);
        (,, uint32 window,,) = L.unpackParametersC(c);
        return int32(ExchequerMath.foldedReferenceX24(refX24, lastTick, lastTime, window, block.timestamp) >> 24);
    }

    /// @notice Daily issuance accruing to one whole $BANK at the multiplier in force
    /// @dev The license auction floor is a multiple of this (§8). Once the budget is spent there is
    ///      no yield to price, whatever the rate says.
    function dailyYieldPerShare(Exchequer bank) internal view returns (uint256) {
        uint256 supply = _bankSupply(bank);
        if (supply == 0) return 0;

        ExchequerParameters memory p = parameters(bank);
        uint256 perDay = uint256(p.baseIssuancePerDay) * currentMultiplier(bank) / WAD;
        (uint256 base,) = _pendingCredit(bank, p);
        uint256 headroom = ISSUANCE_BUDGET - cumulativeIssuance(bank) - base;
        if (perDay > headroom) perDay = headroom;

        return FixedPointMathLib.fullMulDiv(perDay, 1e18, supply);
    }

    /// POSITIONS

    function poolKey(Exchequer bank) internal view returns (PoolKey memory) {
        return ExchequerMath.poolKey(issueToken(bank), parameters(bank).tickSpacing, address(bank));
    }

    function polPositionId(Exchequer bank) internal view returns (PositionId) {
        return ExchequerMath.polPositionId(parameters(bank).tickSpacing);
    }

    function polBidPositionId(Exchequer bank, int32 lowerTick) internal view returns (PositionId) {
        return ExchequerMath.polBidPositionId(lowerTick, parameters(bank).tickSpacing);
    }

    function buybackPositionId(Exchequer bank) internal view returns (PositionId) {
        return ExchequerMath.buybackPositionId(buybackBidLowerTick(bank), parameters(bank).tickSpacing);
    }

    function polBidGrid(Exchequer bank) internal view returns (int32) {
        return ExchequerMath.polBidGrid(parameters(bank).tickSpacing);
    }

    /// INTERNAL

    function _s(Exchequer bank) private pure returns (IExposedStorage) {
        return IExposedStorage(address(bank));
    }

    function _word(Exchequer bank, uint256 index) private view returns (bytes32) {
        return _s(bank).sload(L.slot(index));
    }

    function _address(Exchequer bank, uint256 index) private view returns (address) {
        return address(uint160(uint256(_word(bank, index))));
    }

    function _bankSupply(Exchequer bank) private view returns (uint256) {
        return ERC20(bankToken(bank)).totalSupply();
    }

    /// @dev Base issuance and stream release that `accrue` would credit right now
    function _pendingCredit(Exchequer bank, ExchequerParameters memory p)
        private
        view
        returns (uint256 base, uint256 streamed)
    {
        (uint64 stored, uint64 epochStart, uint64 last,) = policy(bank);
        if (last == 0 || block.timestamp == last) return (0, 0);
        if (_bankSupply(bank) == 0) return (0, 0);

        (int256 current, int128 previous,) = netFlows(bank);
        (uint256 weightedSeconds,,,) =
            ExchequerMath.walk(p, stored, epochStart, last, current, previous, block.timestamp);
        base = ExchequerMath.baseIssuance(weightedSeconds, p.baseIssuancePerDay, cumulativeIssuance(bank));

        (uint128 remaining, uint64 end) = L.unpackStream(_word(bank, L.STREAM_SLOT));
        streamed = ExchequerMath.streamRelease(remaining, end, last, block.timestamp);
    }
}
