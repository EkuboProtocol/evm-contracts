// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ExchequerBase} from "./ExchequerBase.sol";
import {ExchequerAuctions} from "../../src/exchequer/ExchequerAuctions.sol";
import {GENESIS_LIQUIDITY, ISSUANCE_BUDGET} from "../../src/libraries/ExchequerMath.sol";
import {Exchequer} from "../../src/exchequer/Exchequer.sol";

contract IssuanceTest is ExchequerBase {
    /// @dev One whole share is one branch
    uint256 internal constant BRANCH = 1e18;

    function test_issuance_streams_second_by_second() public {
        giveShares(alice, BRANCH);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        bank.accrue();
        uint256 afterOneHour = lens.balanceAtBank(bank, alice);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        bank.accrue();
        uint256 afterTwoHours = lens.balanceAtBank(bank, alice);

        assertApproxEqRel(afterOneHour, uint256(1_000_000e18) / 24, 1e12, "an hour is a 24th of the daily issue");
        assertApproxEqRel(afterTwoHours, afterOneHour * 2, 1e12, "the stream is linear in time");
    }

    function test_a_new_branch_earns_from_the_moment_it_opens() public {
        giveShares(alice, BRANCH);
        vm.warp(vm.getBlockTimestamp() + 12 hours);

        // Bob opens a branch halfway through the day
        giveShares(bob, BRANCH);
        assertEq(lens.balanceAtBank(bank, bob), 0, "bob earns nothing before opening");

        vm.warp(vm.getBlockTimestamp() + 12 hours);
        bank.accrue();

        uint256 aliceBalance = lens.balanceAtBank(bank, alice);
        uint256 bobBalance = lens.balanceAtBank(bank, bob);

        // Alice held the only branch for 12h, then half of two for 12h: 0.5 + 0.25 of a day
        // Bob held half of two branches for 12h: 0.25 of a day
        assertApproxEqRel(bobBalance, uint256(1_000_000e18) / 4, 1e12, "bob takes a quarter day's issue");
        assertApproxEqRel(aliceBalance, bobBalance * 3, 1e12, "alice takes three times bob's share");
    }

    function test_issuance_splits_pro_rata_by_branch_count() public {
        giveShares(alice, 3 * BRANCH);
        giveShares(bob, BRANCH);

        vm.warp(vm.getBlockTimestamp() + 1 days);
        bank.accrue();

        assertApproxEqRel(
            lens.balanceAtBank(bank, alice), lens.balanceAtBank(bank, bob) * 3, 1e12, "three branches to one"
        );
    }

    function test_nothing_is_issued_while_no_branches_exist() public {
        vm.warp(vm.getBlockTimestamp() + 30 days);
        bank.accrue();

        assertEq(lens.cumulativeIssuance(bank), 0, "no issuance without branches");
        assertEq(lens.issuanceGrowthPerShareX128(bank), 0, "no growth to credit");

        // The budget was not consumed by the silence
        giveShares(alice, BRANCH);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bank.accrue();
        assertGt(lens.balanceAtBank(bank, alice), 0, "the first banker still earns");
    }

    function test_a_seat_sale_moves_the_balance_with_the_seat() public {
        giveShares(alice, 2 * BRANCH);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        uint256 aliceBefore = lens.balanceAtBank(bank, alice);
        assertGt(aliceBefore, 0, "alice has earned a day");

        // Alice sells one of her two branches: half the balance goes with it (§12)
        vm.prank(alice);
        bankToken.transfer(bob, BRANCH);

        assertApproxEqAbs(lens.balanceAtBank(bank, alice), aliceBefore / 2, 1, "alice keeps her branch's half");
        assertApproxEqAbs(lens.balanceAtBank(bank, bob), aliceBefore / 2, 1, "bob's branch brought its half");

        vm.warp(vm.getBlockTimestamp() + 1 days);
        bank.accrue();

        assertApproxEqAbs(
            lens.balanceAtBank(bank, alice), lens.balanceAtBank(bank, bob), 2, "and both earn alike from here"
        );
    }

    function test_issuance_stops_at_the_budget() public {
        giveShares(alice, BRANCH);

        // At 1M/day and a floor multiplier of 0.25x, the 900M budget cannot outlast this
        vm.warp(vm.getBlockTimestamp() + 20_000 days);
        bank.accrue();

        assertEq(lens.cumulativeIssuance(bank), ISSUANCE_BUDGET, "the budget is exactly exhausted");

        uint256 before = lens.balanceAtBank(bank, alice);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        bank.accrue();
        assertEq(lens.balanceAtBank(bank, alice), before, "base issuance has stopped permanently");
    }

    function test_daily_yield_reports_nothing_once_the_budget_is_spent() public {
        giveShares(alice, BRANCH);
        assertGt(lens.dailyYieldPerShare(bank), 0, "yield while the budget lasts");

        vm.warp(vm.getBlockTimestamp() + 20_000 days);
        assertEq(lens.dailyYieldPerShare(bank), 0, "and none once it is spent, before or after accrual");
        bank.accrue();
        assertEq(lens.dailyYieldPerShare(bank), 0, "so licenses cannot be priced off phantom yield");
    }

    function test_the_budget_and_genesis_exactly_fill_the_hard_cap() public view {
        assertEq(ISSUANCE_BUDGET + GENESIS_LIQUIDITY, issue.HARD_CAP(), "900M + 100M = 1B");
    }

    function test_accrue_is_idempotent_within_a_block() public {
        giveShares(alice, BRANCH);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        bank.accrue();
        uint256 growth = lens.issuanceGrowthPerShareX128(bank);
        bank.accrue();
        bank.accrue();

        assertEq(lens.issuanceGrowthPerShareX128(bank), growth, "repeat calls change nothing");
    }
}
