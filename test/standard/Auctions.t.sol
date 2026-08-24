// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {StandardBase} from "./StandardBase.sol";
import {StandardAuctions} from "../../src/standard/StandardAuctions.sol";

contract AuctionsTest is StandardBase {
    uint256 internal constant BRANCH = 1e18;

    function setUp() public override {
        super.setUp();

        // The whole founding distribution, so one branch's yield is a tractable number
        giveShares(alice, 1_000 * BRANCH);

        // Start every auction test at an exact day boundary
        vm.warp(((vm.getBlockTimestamp() / 1 days) + 1) * 1 days);

        // Alice retires a tenth of her bank so she has currency to bid with
        vm.prank(alice);
        bank.withdraw(100 * BRANCH, alice);

        vm.prank(alice);
        issue.approve(address(auctions), type(uint256).max);
    }

    /// THE LICENSE AUCTION

    function test_the_floor_is_two_days_of_one_branchs_yield() public view {
        assertEq(auctions.licenseFloor(), bank.dailyYieldPerShare() * 2, "two days of yield");
    }

    function test_a_fresh_day_opens_at_twice_the_floor() public view {
        assertEq(auctions.licenseStartPrice(), auctions.licenseFloor() * 2, "nothing sold yesterday");
        assertEq(auctions.licensePrice(), auctions.licenseStartPrice(), "at the open, price is the open");
    }

    function test_the_price_decays_to_the_floor_across_the_day() public {
        uint256 open = auctions.licensePrice();

        vm.warp(vm.getBlockTimestamp() + 12 hours);
        uint256 midday = auctions.licensePrice();

        // The floor tracks the issuance rate, which the epoch boundary just cut, so the curve's
        // endpoints have to be read at the same instant as the price being checked
        assertApproxEqRel(
            midday * midday, auctions.licenseStartPrice() * auctions.licenseFloor(), 1e12, "exponential decay"
        );

        vm.warp(vm.getBlockTimestamp() + 11 hours + 59 minutes);
        uint256 late = auctions.licensePrice();

        assertLt(midday, open, "the price falls");
        assertLt(late, midday, "and keeps falling");
        assertApproxEqRel(late, auctions.licenseFloor(), 0.01e18, "approaching the floor");
    }

    function test_buying_a_license_burns_the_payment_and_opens_a_branch() public {
        uint256 price = auctions.licensePrice();
        uint256 burnedBefore = issue.totalBurned();
        uint256 sharesBefore = bankToken.balanceOf(alice);

        vm.prank(alice);
        uint256 paid = auctions.buyLicenses(1, type(uint256).max);

        assertEq(paid, price, "paid the posted price");
        assertEq(issue.totalBurned() - burnedBefore, price, "every token spent this way is burned");
        assertEq(bankToken.balanceOf(alice) - sharesBefore, BRANCH, "one new branch");
    }

    function test_expansion_shrinks_the_float() public {
        uint256 supplyBefore = issue.totalSupply();
        uint256 ceilingBefore = issue.maxSupply();

        vm.prank(alice);
        auctions.buyLicenses(1, type(uint256).max);

        assertLt(issue.totalSupply(), supplyBefore, "the float shrank");
        assertLt(issue.maxSupply(), ceilingBefore, "permanently");
    }

    function test_the_daily_supply_is_capped() public {
        // Earn and retire enough to clear a hundred licenses, then bid late in the day when the
        // decaying price has come down to meet the floor
        vm.warp(((vm.getBlockTimestamp() / 1 days) + 3) * 1 days);
        vm.prank(alice);
        bank.withdraw(100 * BRANCH, alice);
        vm.warp(vm.getBlockTimestamp() + 23 hours);

        assertEq(auctions.licensesRemaining(), 100, "a hundred a day");

        vm.prank(alice);
        auctions.buyLicenses(100, type(uint256).max);

        assertEq(auctions.licensesRemaining(), 0, "sold out");

        vm.prank(alice);
        vm.expectRevert(StandardAuctions.SoldOutForToday.selector);
        auctions.buyLicenses(1, type(uint256).max);
    }

    function test_unsold_licenses_do_not_roll_over() public {
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(auctions.licensesRemaining(), 100, "tomorrow starts fresh, not at two hundred");
    }

    function test_tomorrow_opens_at_twice_todays_close() public {
        vm.warp(vm.getBlockTimestamp() + 20 hours);

        vm.prank(alice);
        uint256 close = auctions.buyLicenses(1, type(uint256).max);

        vm.warp(((vm.getBlockTimestamp() / 1 days) + 1) * 1 days);

        assertEq(auctions.licenseStartPrice(), close * 2, "twice yesterday's close");
    }

    function test_a_second_sale_in_the_same_day_decays_from_the_same_open() public {
        // Earn a few more days of issuance so two licenses are affordable
        vm.warp(((vm.getBlockTimestamp() / 1 days) + 3) * 1 days);
        vm.prank(alice);
        bank.withdraw(100 * BRANCH, alice);

        uint256 open = auctions.licenseStartPrice();

        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(alice);
        uint256 first = auctions.buyLicenses(1, type(uint256).max);

        // The day's open is pinned by its first sale, so it does not collapse to twice the floor
        assertEq(auctions.licenseStartPrice(), open, "the open holds for the day");

        vm.warp(vm.getBlockTimestamp() + 2 hours);
        vm.prank(alice);
        uint256 second = auctions.buyLicenses(1, type(uint256).max);

        assertLt(second, first, "later in the day is cheaper");
        assertGt(second, auctions.licenseFloor(), "but still above the floor");
        assertEq(auctions.licenseLastClose(), second, "the last sale sets tomorrow's anchor");
    }

    function test_a_day_with_no_sales_reopens_from_the_floor() public {
        vm.warp(vm.getBlockTimestamp() + 20 hours);
        vm.prank(alice);
        auctions.buyLicenses(1, type(uint256).max);

        // Skip a whole day without a sale
        vm.warp(((vm.getBlockTimestamp() / 1 days) + 2) * 1 days);

        assertEq(auctions.licenseStartPrice(), auctions.licenseFloor() * 2, "back to twice the floor");
    }

    function test_a_buyer_can_bound_the_price_they_accept() public {
        uint256 price = auctions.licensePrice();

        vm.prank(alice);
        vm.expectRevert(StandardAuctions.PriceExceededLimit.selector);
        auctions.buyLicenses(1, price - 1);
    }

    function test_the_floor_scales_with_the_issuance_rate() public {
        uint256 floorAtLaunch = auctions.licenseFloor();

        // Drive the multiplier to its floor with sustained silence
        vm.warp(vm.getBlockTimestamp() + 40 days);
        bank.accrue();

        assertLt(auctions.licenseFloor(), floorAtLaunch, "a cheaper rate means cheaper licenses");
    }

    /// THE CHARTER AUCTION

    function test_the_charter_auction_starts_disabled() public {
        assertEq(auctions.chartersPerDay(), 0, "the count per day starts at zero");

        vm.expectRevert(StandardAuctions.CharterAuctionDisabled.selector);
        auctions.buyCharters{value: 1 ether}(1, type(uint256).max);
    }

    function test_only_the_owner_sets_charter_policy() public {
        vm.expectRevert();
        auctions.setCharterPolicy(5, 0.01 ether);
    }

    function test_a_charter_mints_a_bank_and_pays_the_fee_engine() public {
        vm.prank(owner);
        auctions.setCharterPolicy(5, 0.01 ether);

        uint256 price = auctions.charterPrice();
        assertEq(price, 0.03 ether, "opens at three times the reserve");

        uint128 revenueBefore = bank.epochRevenueEth();
        uint256 sharesBefore = bankToken.balanceOf(bob);

        vm.prank(bob);
        uint256 paid = auctions.buyCharters{value: price}(1, type(uint256).max);

        assertEq(bankToken.balanceOf(bob) - sharesBefore, BRANCH, "the first branch is included");
        assertEq(bank.epochRevenueEth() - revenueBefore, paid, "the ETH joined the fee engine");
    }

    function test_a_charter_buyer_is_refunded_the_difference() public {
        vm.prank(owner);
        auctions.setCharterPolicy(5, 0.01 ether);

        uint256 price = auctions.charterPrice();
        uint256 balanceBefore = bob.balance;

        vm.prank(bob);
        auctions.buyCharters{value: 1 ether}(1, type(uint256).max);

        assertEq(balanceBefore - bob.balance, price, "only the price was taken");
    }

    function test_charters_reprice_faster_than_licenses() public {
        vm.prank(owner);
        auctions.setCharterPolicy(5, 0.01 ether);

        vm.warp(vm.getBlockTimestamp() + 20 hours);
        vm.prank(bob);
        uint256 close = auctions.buyCharters{value: 1 ether}(1, type(uint256).max);

        vm.warp(((vm.getBlockTimestamp() / 1 days) + 1) * 1 days);

        // Scarce seats reprice into demand faster than a daily commodity: three times, not twice
        assertEq(auctions.charterStartPrice(), close * 3, "three times yesterday's close");
    }

    function test_the_charter_daily_supply_is_capped() public {
        vm.prank(owner);
        auctions.setCharterPolicy(2, 0.01 ether);

        vm.deal(bob, 100 ether);
        vm.prank(bob);
        auctions.buyCharters{value: 10 ether}(2, type(uint256).max);

        assertEq(auctions.chartersRemaining(), 0, "sold out for today");

        vm.prank(bob);
        vm.expectRevert(StandardAuctions.SoldOutForToday.selector);
        auctions.buyCharters{value: 10 ether}(1, type(uint256).max);
    }

    function test_only_the_auctions_contract_can_open_branches() public {
        vm.expectRevert();
        bank.mintShares(alice, BRANCH);
    }
}
