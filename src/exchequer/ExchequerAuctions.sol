// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ExposedStorage} from "../base/ExposedStorage.sol";
import {ExchequerAuctionsStorageLayout as L} from "../libraries/ExchequerAuctionsStorageLayout.sol";
import {ExchequerLib} from "../libraries/ExchequerLib.sol";
import {ExchequerMath} from "../libraries/ExchequerMath.sol";
import {StorageSlot} from "../types/storageSlot.sol";

import {Exchequer} from "./Exchequer.sol";
import {IssueToken} from "./IssueToken.sol";

/// @title Exchequer Auctions
/// @notice The two daily falling-price Dutch auctions of the Exchequer economy (whitepaper §8)
/// @dev Both sales run on one mechanism: the price opens high, decays exponentially toward a floor
///      over 24 hours, and purchases execute instantly at the current price, first come first
///      served. There are no bids, no escrow, no refunds and nothing to snipe.
///
///      They differ only in what they are paid in and where the payment goes:
///
///      - **expansion licenses** are paid in $ISSUE, which is burned on receipt;
///      - **charters** are paid in ETH, which flows into the same fee engine as trading fees.
///
///      Both mint the same asset, because this implementation collapses the whitepaper's charter
///      NFT and its branches into one fungible share. One whole $BANK is one branch.
///
///      §7's per-charter limit of three licenses per day is not enforced. Over a freely transferable
///      share a per-address cap is evaded with a second address, so the daily supply cap is what
///      actually rations expansion. See docs/exchequer.md.
///
///      There is one authority in this economy. Charter policy is set by whoever owns the bank, so
///      the bank renouncing its owner freezes the auctions as well. The contract has no view
///      functions: state and prices are read through `sload` by `ExchequerAuctionsLib`.
contract ExchequerAuctions is ExposedStorage {
    using ExchequerLib for Exchequer;

    /// @dev One whole share, which is one branch
    uint256 private constant ONE_SHARE = 1e18;

    /// @dev Multiple of yesterday's close at which the license day opens (§8: twice)
    uint256 private constant LICENSE_OPEN_MULTIPLE = 2;

    /// @dev Multiple of yesterday's close at which the charter day opens (§8: three times)
    uint256 private constant CHARTER_OPEN_MULTIPLE = 3;

    Exchequer private immutable BANK;
    IssueToken private immutable ISSUE_TOKEN;
    uint256 private immutable LICENSES_PER_DAY;
    uint256 private immutable LICENSE_FLOOR_YIELD_DAYS;
    uint256 private immutable LICENSE_FLOOR_MINIMUM;
    uint256 private immutable MAX_CHARTERS_PER_DAY;

    error InvalidCount();
    error InvalidCharterPolicy();
    error Unauthorized();
    error SoldOutForToday();
    error PriceExceededLimit();
    error InsufficientPayment();
    error CharterAuctionDisabled();

    event LicensesPurchased(address indexed buyer, uint256 count, uint256 unitPrice, uint256 burned);
    event ChartersPurchased(address indexed buyer, uint256 count, uint256 unitPrice, uint256 paid);
    event CharterPolicyUpdated(uint256 chartersPerDay, uint256 reservePrice);

    /// @param bank The central bank, which opens the branches these auctions sell and whose owner
    ///             sets charter policy
    /// @param issue The currency licenses are paid in
    /// @param licensesPerDay Licenses offered each day
    /// @param licenseFloorYieldDays Days of one branch's yield the license floor is worth
    /// @param licenseFloorMinimum Absolute lower bound on the license floor
    /// @param maxChartersPerDay Most charters policy may ever offer in a day
    constructor(
        Exchequer bank,
        IssueToken issue,
        uint256 licensesPerDay,
        uint256 licenseFloorYieldDays,
        uint256 licenseFloorMinimum,
        uint256 maxChartersPerDay
    ) {
        BANK = bank;
        ISSUE_TOKEN = issue;
        LICENSES_PER_DAY = licensesPerDay;
        LICENSE_FLOOR_YIELD_DAYS = licenseFloorYieldDays;
        LICENSE_FLOOR_MINIMUM = licenseFloorMinimum;
        MAX_CHARTERS_PER_DAY = maxChartersPerDay;

        // The storage mirror, written once
        L.slot(L.BANK_SLOT).store(bytes32(uint256(uint160(address(bank)))));
        L.slot(L.ISSUE_TOKEN_SLOT).store(bytes32(uint256(uint160(address(issue)))));
        L.slot(L.LICENSES_PER_DAY_SLOT).store(bytes32(licensesPerDay));
        L.slot(L.LICENSE_FLOOR_YIELD_DAYS_SLOT).store(bytes32(licenseFloorYieldDays));
        L.slot(L.LICENSE_FLOOR_MINIMUM_SLOT).store(bytes32(licenseFloorMinimum));
        L.slot(L.MAX_CHARTERS_PER_DAY_SLOT).store(bytes32(maxChartersPerDay));
    }

    /// @dev Policy belongs to the bank's owner, and to nobody once that owner has renounced
    modifier onlyBankOwner() {
        if (msg.sender != BANK.owner()) revert Unauthorized();
        _;
    }

    /// THE LICENSE AUCTION, PAID IN $ISSUE AND BURNED

    /// @notice Buys `count` expansion licenses at the current price, burning the payment
    /// @param count Number of licenses, each of which opens one branch
    /// @param maxUnitPrice Highest unit price the caller will accept
    /// @return unitPrice Price actually paid per license
    function buyLicenses(uint256 count, uint256 maxUnitPrice) external returns (uint256 unitPrice) {
        if (count == 0) revert InvalidCount();

        uint256 day = block.timestamp / 1 days;
        StorageSlot soldSlot = L.soldOnDaySlot(day);
        (uint128 licensesSold, uint128 chartersSold) = L.unpackTwo128(soldSlot.load());
        if (licensesSold + count > LICENSES_PER_DAY) revert SoldOutForToday();

        // The floor is about two days of one branch's yield, so it scales with the issuance rate
        uint256 floorPrice = BANK.dailyYieldPerShare() * LICENSE_FLOOR_YIELD_DAYS;
        if (floorPrice < LICENSE_FLOOR_MINIMUM) floorPrice = LICENSE_FLOOR_MINIMUM;

        uint256 start = _pinnedStart(L.LICENSE_LAST_SLOT, L.LICENSE_OPEN_SLOT, floorPrice, LICENSE_OPEN_MULTIPLE, day);
        unitPrice = ExchequerMath.dutchPrice(start, floorPrice, block.timestamp % 1 days);
        if (unitPrice > maxUnitPrice) revert PriceExceededLimit();

        soldSlot.store(L.packTwo128(licensesSold + SafeCastLib.toUint128(count), chartersSold));
        // The last, and therefore lowest, price that sold becomes tomorrow's anchor
        L.slot(L.LICENSE_LAST_SLOT).store(L.packPriceAndDay(SafeCastLib.toUint128(unitPrice), uint64(day)));

        uint256 total = unitPrice * count;
        if (total != 0) {
            SafeTransferLib.safeTransferFrom(address(ISSUE_TOKEN), msg.sender, address(this), total);
            ISSUE_TOKEN.burn(total);
        }

        BANK.openBranches(msg.sender, count * ONE_SHARE);

        emit LicensesPurchased(msg.sender, count, unitPrice, total);
    }

    /// THE CHARTER AUCTION, PAID IN ETH AND ROUTED TO THE FEE ENGINE

    /// @notice Buys `count` charters at the current price, routing the ETH into the fee engine
    /// @dev The share mints to the buyer in the same transaction, first branch included
    /// @param count Number of charters to buy
    /// @param maxUnitPrice Highest unit price the caller will accept
    /// @return unitPrice Price actually paid per charter
    function buyCharters(uint256 count, uint256 maxUnitPrice) external payable returns (uint256 unitPrice) {
        (uint128 reservePrice, uint64 perDay) = L.unpackPriceAndDay(L.slot(L.CHARTER_POLICY_SLOT).load());
        if (perDay == 0) revert CharterAuctionDisabled();
        if (count == 0) revert InvalidCount();

        uint256 day = block.timestamp / 1 days;
        StorageSlot soldSlot = L.soldOnDaySlot(day);
        (uint128 licensesSold, uint128 chartersSold) = L.unpackTwo128(soldSlot.load());
        if (chartersSold + count > perDay) revert SoldOutForToday();

        uint256 start = _pinnedStart(L.CHARTER_LAST_SLOT, L.CHARTER_OPEN_SLOT, reservePrice, CHARTER_OPEN_MULTIPLE, day);
        unitPrice = ExchequerMath.dutchPrice(start, reservePrice, block.timestamp % 1 days);
        if (unitPrice > maxUnitPrice) revert PriceExceededLimit();

        uint256 total = unitPrice * count;
        if (msg.value < total) revert InsufficientPayment();

        soldSlot.store(L.packTwo128(licensesSold, chartersSold + SafeCastLib.toUint128(count)));
        L.slot(L.CHARTER_LAST_SLOT).store(L.packPriceAndDay(SafeCastLib.toUint128(unitPrice), uint64(day)));

        BANK.openBranches{value: total}(msg.sender, count * ONE_SHARE);

        uint256 refund = msg.value - total;
        if (refund != 0) SafeTransferLib.safeTransferETH(msg.sender, refund);

        emit ChartersPurchased(msg.sender, count, unitPrice, total);
    }

    /// @notice Sets the charter auction's daily supply and reserve price
    /// @dev The only policy knobs the whitepaper leaves to an administrator. A day's supply is
    ///      capped, and an open auction must carry a real reserve: a zero reserve would mint
    ///      shares for nothing.
    function setCharterPolicy(uint256 perDay, uint256 reservePrice) external onlyBankOwner {
        if (perDay > MAX_CHARTERS_PER_DAY || (perDay != 0 && reservePrice == 0)) revert InvalidCharterPolicy();
        L.slot(L.CHARTER_POLICY_SLOT)
            .store(L.packPriceAndDay(SafeCastLib.toUint128(reservePrice), SafeCastLib.toUint64(perDay)));
        emit CharterPolicyUpdated(perDay, reservePrice);
    }

    /// @notice Today's open, pinned by the first sale of the day so later sales decay from the same
    ///         open (§8: twice or three times yesterday's close, else the floor)
    function _pinnedStart(uint256 lastIndex, uint256 openIndex, uint256 floorPrice, uint256 multiple, uint256 day)
        private
        returns (uint256 start)
    {
        StorageSlot openSlot = L.slot(openIndex);
        bytes32 openWord = openSlot.load();
        start =
            ExchequerMath.auctionStartPrice(L.slot(lastIndex).load(), openWord, floorPrice, multiple, block.timestamp);
        if (uint256(openWord) >> 128 != day) {
            openSlot.store(L.packPriceAndDay(SafeCastLib.toUint128(start), uint64(day)));
        }
    }
}
