// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Exchequer} from "../exchequer/Exchequer.sol";
import {ExchequerAuctions} from "../exchequer/ExchequerAuctions.sol";
import {IExposedStorage} from "../interfaces/IExposedStorage.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {ExchequerAuctionsStorageLayout as L} from "./ExchequerAuctionsStorageLayout.sol";
import {ExchequerLib} from "./ExchequerLib.sol";
import {ExchequerMath} from "./ExchequerMath.sol";

/// @title Exchequer Auctions Library
/// @notice Exposed-storage readers for the auctions: state, and the prices a buyer would pay
/// @dev Readers must use ExchequerAuctionsStorageLayout so they match the contract's manual slots.
///      Prices are computed with the same `ExchequerMath` the contract charges with.
library ExchequerAuctionsLib {
    using ExposedStorageLib for IExposedStorage;
    using ExchequerLib for Exchequer;

    /// @notice Multiple of yesterday's close at which the license day opens (§8: twice)
    uint256 internal constant LICENSE_OPEN_MULTIPLE = 2;

    /// @notice Multiple of yesterday's close at which the charter day opens (§8: three times)
    uint256 internal constant CHARTER_OPEN_MULTIPLE = 3;

    /// PARAMETERS AND STATE

    function bank(ExchequerAuctions auctions) internal view returns (Exchequer) {
        return Exchequer(payable(address(uint160(uint256(_word(auctions, L.BANK_SLOT))))));
    }

    function licensesPerDay(ExchequerAuctions auctions) internal view returns (uint256) {
        return uint256(_word(auctions, L.LICENSES_PER_DAY_SLOT));
    }

    function licenseFloorYieldDays(ExchequerAuctions auctions) internal view returns (uint256) {
        return uint256(_word(auctions, L.LICENSE_FLOOR_YIELD_DAYS_SLOT));
    }

    function licenseFloorMinimum(ExchequerAuctions auctions) internal view returns (uint256) {
        return uint256(_word(auctions, L.LICENSE_FLOOR_MINIMUM_SLOT));
    }

    function maxChartersPerDay(ExchequerAuctions auctions) internal view returns (uint256) {
        return uint256(_word(auctions, L.MAX_CHARTERS_PER_DAY_SLOT));
    }

    function chartersPerDay(ExchequerAuctions auctions) internal view returns (uint256 perDay) {
        (, perDay) = L.unpackPriceAndDay(_word(auctions, L.CHARTER_POLICY_SLOT));
    }

    function charterReservePrice(ExchequerAuctions auctions) internal view returns (uint256 reserve) {
        (reserve,) = L.unpackPriceAndDay(_word(auctions, L.CHARTER_POLICY_SLOT));
    }

    function licenseLastClose(ExchequerAuctions auctions) internal view returns (uint256 price, uint256 day) {
        (price, day) = L.unpackPriceAndDay(_word(auctions, L.LICENSE_LAST_SLOT));
    }

    function charterLastClose(ExchequerAuctions auctions) internal view returns (uint256 price, uint256 day) {
        (price, day) = L.unpackPriceAndDay(_word(auctions, L.CHARTER_LAST_SLOT));
    }

    function licensesSoldOnDay(ExchequerAuctions auctions, uint256 day) internal view returns (uint256 sold) {
        (sold,) = L.unpackTwo128(_s(auctions).sload(L.soldOnDaySlot(day)));
    }

    function chartersSoldOnDay(ExchequerAuctions auctions, uint256 day) internal view returns (uint256 sold) {
        (, sold) = L.unpackTwo128(_s(auctions).sload(L.soldOnDaySlot(day)));
    }

    /// THE LICENSE AUCTION

    /// @notice The license floor: about two days of one branch's yield (§8)
    function licenseFloor(ExchequerAuctions auctions) internal view returns (uint256 floorPrice) {
        floorPrice = bank(auctions).dailyYieldPerShare() * licenseFloorYieldDays(auctions);
        uint256 minimum = licenseFloorMinimum(auctions);
        if (floorPrice < minimum) floorPrice = minimum;
    }

    /// @notice Price at which today's license auction opened, or would open on its first sale
    function licenseStartPrice(ExchequerAuctions auctions) internal view returns (uint256) {
        (bytes32 last, bytes32 open) = _s(auctions).sload(L.slot(L.LICENSE_LAST_SLOT), L.slot(L.LICENSE_OPEN_SLOT));
        return
            ExchequerMath.auctionStartPrice(last, open, licenseFloor(auctions), LICENSE_OPEN_MULTIPLE, block.timestamp);
    }

    /// @notice The current license price, falling along the curve of eq 7.1
    function licensePrice(ExchequerAuctions auctions) internal view returns (uint256) {
        return ExchequerMath.dutchPrice(licenseStartPrice(auctions), licenseFloor(auctions), block.timestamp % 1 days);
    }

    /// @notice Licenses still available today
    function licensesRemaining(ExchequerAuctions auctions) internal view returns (uint256) {
        uint256 perDay = licensesPerDay(auctions);
        uint256 sold = licensesSoldOnDay(auctions, block.timestamp / 1 days);
        return sold >= perDay ? 0 : perDay - sold;
    }

    /// THE CHARTER AUCTION

    /// @notice Price at which today's charter auction opened, or would open on its first sale
    function charterStartPrice(ExchequerAuctions auctions) internal view returns (uint256) {
        (bytes32 last, bytes32 open) = _s(auctions).sload(L.slot(L.CHARTER_LAST_SLOT), L.slot(L.CHARTER_OPEN_SLOT));
        return ExchequerMath.auctionStartPrice(
            last, open, charterReservePrice(auctions), CHARTER_OPEN_MULTIPLE, block.timestamp
        );
    }

    /// @notice The current charter price, falling along the same curve
    function charterPrice(ExchequerAuctions auctions) internal view returns (uint256) {
        return
            ExchequerMath.dutchPrice(
                charterStartPrice(auctions), charterReservePrice(auctions), block.timestamp % 1 days
            );
    }

    /// @notice Charters still available today
    function chartersRemaining(ExchequerAuctions auctions) internal view returns (uint256) {
        uint256 perDay = chartersPerDay(auctions);
        uint256 sold = chartersSoldOnDay(auctions, block.timestamp / 1 days);
        return sold >= perDay ? 0 : perDay - sold;
    }

    /// INTERNAL

    function _s(ExchequerAuctions auctions) private pure returns (IExposedStorage) {
        return IExposedStorage(address(auctions));
    }

    function _word(ExchequerAuctions auctions, uint256 index) private view returns (bytes32) {
        return _s(auctions).sload(L.slot(index));
    }
}
