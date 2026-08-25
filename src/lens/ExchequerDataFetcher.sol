// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Exchequer} from "../exchequer/Exchequer.sol";
import {ExchequerAuctions} from "../exchequer/ExchequerAuctions.sol";
import {ExchequerAuctionsLib} from "../libraries/ExchequerAuctionsLib.sol";
import {ExchequerLib} from "../libraries/ExchequerLib.sol";
import {ExchequerParameters} from "../libraries/ExchequerMath.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionId} from "../types/positionId.sol";

/// @title Exchequer Data Fetcher
/// @notice External views over `ExchequerLib` and `ExchequerAuctionsLib`, for callers that cannot
///         link a library: off-chain readers, and tests, which need every read in its own call
///         frame so that a warped clock is never folded away by the optimizer.
/// @dev Stateless; one deployment serves every bank.
contract ExchequerDataFetcher {
    using ExchequerLib for Exchequer;
    using ExchequerAuctionsLib for ExchequerAuctions;

    /// THE BANK: PARAMETERS AND ADDRESSES

    function parameters(Exchequer bank) external view returns (ExchequerParameters memory) {
        return bank.parameters();
    }

    function owner(Exchequer bank) external view returns (address) {
        return bank.owner();
    }

    function teamRecipient(Exchequer bank) external view returns (address) {
        return bank.teamRecipient();
    }

    function expansionVault(Exchequer bank) external view returns (address) {
        return bank.expansionVault();
    }

    function auctions(Exchequer bank) external view returns (address) {
        return bank.auctions();
    }

    function issueToken(Exchequer bank) external view returns (address) {
        return bank.issueToken();
    }

    function bankToken(Exchequer bank) external view returns (address) {
        return bank.bankToken();
    }

    function reserveAsset(Exchequer bank) external view returns (address) {
        return bank.reserveAsset();
    }

    /// THE BANK: STATE

    function multiplier(Exchequer bank) external view returns (uint64) {
        return bank.multiplier();
    }

    function epochStartTime(Exchequer bank) external view returns (uint64) {
        return bank.epochStartTime();
    }

    function lastAccrualTime(Exchequer bank) external view returns (uint64) {
        return bank.lastAccrualTime();
    }

    function initialized(Exchequer bank) external view returns (bool) {
        return bank.initialized();
    }

    function issuanceGrowthPerShareX128(Exchequer bank) external view returns (uint256) {
        return bank.issuanceGrowthPerShareX128();
    }

    function cumulativeIssuance(Exchequer bank) external view returns (uint256) {
        return bank.cumulativeIssuance();
    }

    function totalLedgerBalance(Exchequer bank) external view returns (uint256) {
        return bank.totalLedgerBalance();
    }

    function ledgerBalance(Exchequer bank, address holder) external view returns (uint256) {
        return bank.ledgerBalance(holder);
    }

    function growthSnapshotX128(Exchequer bank, address holder) external view returns (uint256) {
        return bank.growthSnapshotX128(holder);
    }

    function netFlows(Exchequer bank) external view returns (int256 current, int128 previous, int128 beforePrevious) {
        return bank.netFlows();
    }

    function savedEth(Exchequer bank) external view returns (uint128) {
        return bank.savedEth();
    }

    function epochRevenueEth(Exchequer bank) external view returns (uint128) {
        return bank.epochRevenueEth();
    }

    function pendingExpansionEth(Exchequer bank) external view returns (uint128) {
        return bank.pendingExpansionEth();
    }

    function pendingContractionEth(Exchequer bank) external view returns (uint128) {
        return bank.pendingContractionEth();
    }

    function pendingPolEth(Exchequer bank) external view returns (uint128) {
        return bank.pendingPolEth();
    }

    function pendingTeamEth(Exchequer bank) external view returns (uint128) {
        return bank.pendingTeamEth();
    }

    function streamRemaining(Exchequer bank) external view returns (uint128) {
        return bank.streamRemaining();
    }

    function streamEndTime(Exchequer bank) external view returns (uint64) {
        return bank.streamEndTime();
    }

    function buybackBidLowerTick(Exchequer bank) external view returns (int32) {
        return bank.buybackBidLowerTick();
    }

    function buybackBidActive(Exchequer bank) external view returns (bool) {
        return bank.buybackBidActive();
    }

    function foundingBankMinted(Exchequer bank) external view returns (uint256) {
        return bank.foundingBankMinted();
    }

    function trailingWithdrawals(Exchequer bank) external view returns (uint256) {
        return bank.trailingWithdrawals();
    }

    /// THE BANK: DERIVED

    function pendingIssuance(Exchequer bank) external view returns (uint256) {
        return bank.pendingIssuance();
    }

    function pendingStreamRelease(Exchequer bank) external view returns (uint256) {
        return bank.pendingStreamRelease();
    }

    function currentGrowthPerShareX128(Exchequer bank) external view returns (uint256) {
        return bank.currentGrowthPerShareX128();
    }

    function balanceAtBank(Exchequer bank, address holder) external view returns (uint256) {
        return bank.balanceAtBank(holder);
    }

    function currentTotalLedgerBalance(Exchequer bank) external view returns (uint256) {
        return bank.currentTotalLedgerBalance();
    }

    function resolutionFeeRate(Exchequer bank) external view returns (uint256) {
        return bank.resolutionFeeRate();
    }

    function resolutionFeeRateFor(Exchequer bank, uint256 exiting) external view returns (uint256) {
        return bank.resolutionFeeRateFor(exiting);
    }

    function currentMultiplier(Exchequer bank) external view returns (uint256) {
        return bank.currentMultiplier();
    }

    function referenceTick(Exchequer bank) external view returns (int32) {
        return bank.referenceTick();
    }

    function dailyYieldPerShare(Exchequer bank) external view returns (uint256) {
        return bank.dailyYieldPerShare();
    }

    function poolKey(Exchequer bank) external view returns (PoolKey memory) {
        return bank.poolKey();
    }

    function polPositionId(Exchequer bank) external view returns (PositionId) {
        return bank.polPositionId();
    }

    function polBidPositionId(Exchequer bank, int32 lowerTick) external view returns (PositionId) {
        return bank.polBidPositionId(lowerTick);
    }

    function buybackPositionId(Exchequer bank) external view returns (PositionId) {
        return bank.buybackPositionId();
    }

    function polBidGrid(Exchequer bank) external view returns (int32) {
        return bank.polBidGrid();
    }

    /// THE AUCTIONS

    function auctionsBank(ExchequerAuctions a) external view returns (Exchequer) {
        return a.bank();
    }

    function licensesPerDay(ExchequerAuctions a) external view returns (uint256) {
        return a.licensesPerDay();
    }

    function maxChartersPerDay(ExchequerAuctions a) external view returns (uint256) {
        return a.maxChartersPerDay();
    }

    function chartersPerDay(ExchequerAuctions a) external view returns (uint256) {
        return a.chartersPerDay();
    }

    function charterReservePrice(ExchequerAuctions a) external view returns (uint256) {
        return a.charterReservePrice();
    }

    function licenseLastClose(ExchequerAuctions a) external view returns (uint256 price, uint256 day) {
        return a.licenseLastClose();
    }

    function charterLastClose(ExchequerAuctions a) external view returns (uint256 price, uint256 day) {
        return a.charterLastClose();
    }

    function licensesSoldOnDay(ExchequerAuctions a, uint256 day) external view returns (uint256) {
        return a.licensesSoldOnDay(day);
    }

    function chartersSoldOnDay(ExchequerAuctions a, uint256 day) external view returns (uint256) {
        return a.chartersSoldOnDay(day);
    }

    function licenseFloor(ExchequerAuctions a) external view returns (uint256) {
        return a.licenseFloor();
    }

    function licenseStartPrice(ExchequerAuctions a) external view returns (uint256) {
        return a.licenseStartPrice();
    }

    function licensePrice(ExchequerAuctions a) external view returns (uint256) {
        return a.licensePrice();
    }

    function licensesRemaining(ExchequerAuctions a) external view returns (uint256) {
        return a.licensesRemaining();
    }

    function charterStartPrice(ExchequerAuctions a) external view returns (uint256) {
        return a.charterStartPrice();
    }

    function charterPrice(ExchequerAuctions a) external view returns (uint256) {
        return a.charterPrice();
    }

    function chartersRemaining(ExchequerAuctions a) external view returns (uint256) {
        return a.chartersRemaining();
    }
}
