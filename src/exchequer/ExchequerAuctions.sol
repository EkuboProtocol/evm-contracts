// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

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
contract ExchequerAuctions is Ownable {
    /// @dev One whole share, which is one branch
    uint256 private constant ONE_SHARE = 1e18;

    /// @dev Fixed point scale
    uint256 private constant WAD = 1e18;

    /// @notice The issuing authority
    Exchequer public immutable BANK;

    /// @notice The currency licenses are paid in
    IssueToken public immutable ISSUE_TOKEN;

    /// @notice Licenses offered per day (§7)
    uint256 public immutable LICENSES_PER_DAY;

    /// @notice Days of one branch's yield that the license floor is worth (§8)
    uint256 public immutable LICENSE_FLOOR_YIELD_DAYS;

    /// @notice Absolute lower bound on the license floor, so a day can never open at zero
    uint256 public immutable LICENSE_FLOOR_MINIMUM;

    /// @notice Multiple of yesterday's close at which the license day opens (§8: twice)
    uint256 public constant LICENSE_OPEN_MULTIPLE = 2;

    /// @notice Multiple of yesterday's close at which the charter day opens (§8: three times)
    uint256 public constant CHARTER_OPEN_MULTIPLE = 3;

    /// @notice Licenses sold on each day, capped at `LICENSES_PER_DAY`
    mapping(uint256 day => uint256 sold) public licensesSoldOnDay;

    /// @notice Charters sold on each day, capped at `chartersPerDay`
    mapping(uint256 day => uint256 sold) public chartersSoldOnDay;

    /// @notice Price of the last license sold, which sets tomorrow's open
    uint256 public licenseLastClose;

    /// @notice Day on which the last license sold
    uint256 public licenseLastCloseDay;

    /// @notice Price of the last charter sold, which sets tomorrow's open
    uint256 public charterLastClose;

    /// @notice Day on which the last charter sold
    uint256 public charterLastCloseDay;

    /// @notice Price at which the license auction opened on `licenseOpenDay`
    uint256 public licenseDayOpen;

    /// @notice Day whose license open is recorded in `licenseDayOpen`
    uint256 public licenseOpenDay;

    /// @notice Price at which the charter auction opened on `charterOpenDay`
    uint256 public charterDayOpen;

    /// @notice Day whose charter open is recorded in `charterDayOpen`
    uint256 public charterOpenDay;

    /// @notice Charters offered per day. Starts at zero and is policy-controlled (§8).
    uint256 public chartersPerDay;

    /// @notice Admin-set reserve price of the charter auction (§8)
    uint256 public charterReservePrice;

    error InvalidCount();
    error SoldOutForToday();
    error PriceExceededLimit();
    error InsufficientPayment();
    error CharterAuctionDisabled();

    event LicensesPurchased(address indexed buyer, uint256 count, uint256 unitPrice, uint256 burned);
    event ChartersPurchased(address indexed buyer, uint256 count, uint256 unitPrice, uint256 paid);
    event CharterPolicyUpdated(uint256 chartersPerDay, uint256 reservePrice);

    /// @param owner Administrator of the charter auction's supply and reserve price
    /// @param bank The central bank, which mints the shares these auctions sell
    /// @param licensesPerDay Licenses offered each day
    /// @param licenseFloorYieldDays Days of one branch's yield the license floor is worth
    /// @param licenseFloorMinimum Absolute lower bound on the license floor
    constructor(
        address owner,
        Exchequer bank,
        uint256 licensesPerDay,
        uint256 licenseFloorYieldDays,
        uint256 licenseFloorMinimum
    ) {
        _initializeOwner(owner);
        BANK = bank;
        ISSUE_TOKEN = bank.ISSUE_TOKEN();
        LICENSES_PER_DAY = licensesPerDay;
        LICENSE_FLOOR_YIELD_DAYS = licenseFloorYieldDays;
        LICENSE_FLOOR_MINIMUM = licenseFloorMinimum;
    }

    /// THE LICENSE AUCTION, PAID IN $ISSUE AND BURNED

    /// @notice The license floor: about two days of one branch's yield (§8)
    /// @dev Scales with the issuance rate, so licenses cost more when the rate is high
    function licenseFloor() public view returns (uint256 floorPrice) {
        floorPrice = BANK.dailyYieldPerShare() * LICENSE_FLOOR_YIELD_DAYS;
        if (floorPrice < LICENSE_FLOOR_MINIMUM) floorPrice = LICENSE_FLOOR_MINIMUM;
    }

    /// @notice Price at which today's license auction opened
    /// @dev Pinned by the day's first sale, so later sales in the same day decay from the same open
    function licenseStartPrice() public view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        if (licenseOpenDay == today) return licenseDayOpen;

        uint256 floorPrice = licenseFloor();
        // If yesterday sold nothing, the day opens at twice the floor
        uint256 anchor = licenseLastCloseDay + 1 == today ? licenseLastClose : floorPrice;
        uint256 start = anchor * LICENSE_OPEN_MULTIPLE;
        return start < floorPrice ? floorPrice : start;
    }

    /// @notice The current license price, falling along the curve of eq 7.1
    function licensePrice() public view returns (uint256) {
        return _dutchPrice(licenseStartPrice(), licenseFloor(), block.timestamp % 1 days);
    }

    /// @notice Licenses still available today
    function licensesRemaining() public view returns (uint256) {
        uint256 sold = licensesSoldOnDay[block.timestamp / 1 days];
        return sold >= LICENSES_PER_DAY ? 0 : LICENSES_PER_DAY - sold;
    }

    /// @notice Buys `count` expansion licenses at the current price, burning the payment
    /// @param count Number of licenses, each of which opens one branch
    /// @param maxUnitPrice Highest unit price the caller will accept
    /// @return unitPrice Price actually paid per license
    function buyLicenses(uint256 count, uint256 maxUnitPrice) external returns (uint256 unitPrice) {
        if (count == 0) revert InvalidCount();
        if (count > licensesRemaining()) revert SoldOutForToday();

        uint256 day = block.timestamp / 1 days;
        if (licenseOpenDay != day) {
            licenseDayOpen = licenseStartPrice();
            licenseOpenDay = day;
        }

        unitPrice = licensePrice();
        if (unitPrice > maxUnitPrice) revert PriceExceededLimit();

        licensesSoldOnDay[day] += count;
        // The last, and therefore lowest, price that sold becomes tomorrow's reference
        licenseLastClose = unitPrice;
        licenseLastCloseDay = day;

        uint256 total = unitPrice * count;
        if (total != 0) {
            SafeTransferLib.safeTransferFrom(address(ISSUE_TOKEN), msg.sender, address(this), total);
            ISSUE_TOKEN.burn(total);
        }

        BANK.mintShares(msg.sender, count * ONE_SHARE);

        emit LicensesPurchased(msg.sender, count, unitPrice, total);
    }

    /// THE CHARTER AUCTION, PAID IN ETH AND ROUTED TO THE FEE ENGINE

    /// @notice Price at which today's charter auction opened
    /// @dev Pinned by the day's first sale, as for licenses
    function charterStartPrice() public view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        if (charterOpenDay == today) return charterDayOpen;

        uint256 floorPrice = charterReservePrice;
        uint256 anchor = charterLastCloseDay + 1 == today ? charterLastClose : floorPrice;
        uint256 start = anchor * CHARTER_OPEN_MULTIPLE;
        return start < floorPrice ? floorPrice : start;
    }

    /// @notice The current charter price, falling along the same curve
    function charterPrice() public view returns (uint256) {
        return _dutchPrice(charterStartPrice(), charterReservePrice, block.timestamp % 1 days);
    }

    /// @notice Charters still available today
    function chartersRemaining() public view returns (uint256) {
        uint256 perDay = chartersPerDay;
        uint256 sold = chartersSoldOnDay[block.timestamp / 1 days];
        return sold >= perDay ? 0 : perDay - sold;
    }

    /// @notice Buys `count` charters at the current price, routing the ETH into the fee engine
    /// @dev The share mints to the buyer in the same transaction, first branch included
    /// @param count Number of charters to buy
    /// @param maxUnitPrice Highest unit price the caller will accept
    /// @return unitPrice Price actually paid per charter
    function buyCharters(uint256 count, uint256 maxUnitPrice) external payable returns (uint256 unitPrice) {
        if (chartersPerDay == 0) revert CharterAuctionDisabled();
        if (count == 0) revert InvalidCount();
        if (count > chartersRemaining()) revert SoldOutForToday();

        uint256 day = block.timestamp / 1 days;
        if (charterOpenDay != day) {
            charterDayOpen = charterStartPrice();
            charterOpenDay = day;
        }

        unitPrice = charterPrice();
        if (unitPrice > maxUnitPrice) revert PriceExceededLimit();

        uint256 total = unitPrice * count;
        if (msg.value < total) revert InsufficientPayment();

        chartersSoldOnDay[day] += count;
        charterLastClose = unitPrice;
        charterLastCloseDay = day;

        BANK.mintShares(msg.sender, count * ONE_SHARE);

        if (total != 0) BANK.receiveRevenue{value: total}();

        uint256 refund = msg.value - total;
        if (refund != 0) SafeTransferLib.safeTransferETH(msg.sender, refund);

        emit ChartersPurchased(msg.sender, count, unitPrice, total);
    }

    /// @notice Sets the charter auction's daily supply and reserve price
    /// @dev The only policy knobs the whitepaper leaves to an administrator
    function setCharterPolicy(uint256 perDay, uint256 reservePrice) external onlyOwner {
        chartersPerDay = perDay;
        charterReservePrice = reservePrice;
        emit CharterPolicyUpdated(perDay, reservePrice);
    }

    /// THE SHARED CURVE

    /// @notice Falling-price curve of eq 7.1: `P(t) = P_start * (P_floor / P_start) ^ (t / 24h)`
    /// @dev The floor exists only to prevent literal-zero sales; buyers set the price
    function _dutchPrice(uint256 startPrice, uint256 floorPrice, uint256 elapsed) internal pure returns (uint256) {
        if (startPrice <= floorPrice) return floorPrice;
        if (elapsed >= 1 days) return floorPrice;
        // A zero floor makes the geometric decay undefined, so the price simply holds
        if (floorPrice == 0) return startPrice;

        int256 ratio = int256(FixedPointMathLib.fullMulDiv(floorPrice, WAD, startPrice));
        if (ratio <= 0) return floorPrice;

        int256 exponent = int256(FixedPointMathLib.fullMulDiv(elapsed, WAD, 1 days));
        uint256 factor = uint256(FixedPointMathLib.powWad(ratio, exponent));

        uint256 price = FixedPointMathLib.fullMulDiv(startPrice, factor, WAD);
        return price < floorPrice ? floorPrice : price;
    }
}
