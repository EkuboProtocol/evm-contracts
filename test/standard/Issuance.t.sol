// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {StandardBase} from "./StandardBase.sol";
import {CentralBank} from "../../src/standard/CentralBank.sol";

contract IssuanceTest is StandardBase {
    /// @dev One whole share is one branch
    uint256 internal constant BRANCH = 1e18;

    function test_issuance_streams_second_by_second() public {
        giveShares(alice, BRANCH);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        bank.accrue();
        uint256 afterOneHour = bank.balanceAtBank(alice);

        vm.warp(vm.getBlockTimestamp() + 1 hours);
        bank.accrue();
        uint256 afterTwoHours = bank.balanceAtBank(alice);

        assertApproxEqRel(afterOneHour, uint256(1_000_000e18) / 24, 1e12, "an hour is a 24th of the daily issue");
        assertApproxEqRel(afterTwoHours, afterOneHour * 2, 1e12, "the stream is linear in time");
    }

    function test_a_new_branch_earns_from_the_moment_it_opens() public {
        giveShares(alice, BRANCH);
        vm.warp(vm.getBlockTimestamp() + 12 hours);

        // Bob opens a branch halfway through the day
        giveShares(bob, BRANCH);
        assertEq(bank.balanceAtBank(bob), 0, "bob earns nothing before opening");

        vm.warp(vm.getBlockTimestamp() + 12 hours);
        bank.accrue();

        uint256 aliceBalance = bank.balanceAtBank(alice);
        uint256 bobBalance = bank.balanceAtBank(bob);

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

        assertApproxEqRel(bank.balanceAtBank(alice), bank.balanceAtBank(bob) * 3, 1e12, "three branches to one");
    }

    function test_nothing_is_issued_while_no_branches_exist() public {
        vm.warp(vm.getBlockTimestamp() + 30 days);
        bank.accrue();

        assertEq(bank.cumulativeIssuance(), 0, "no issuance without branches");
        assertEq(bank.issuanceGrowthPerShareX128(), 0, "no growth to credit");

        // The budget was not consumed by the silence
        giveShares(alice, BRANCH);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        bank.accrue();
        assertGt(bank.balanceAtBank(alice), 0, "the first banker still earns");
    }

    function test_transferring_shares_moves_future_yield_but_not_past_earnings() public {
        giveShares(alice, BRANCH);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        vm.prank(alice);
        bankToken.transfer(bob, BRANCH);

        uint256 aliceAtTransfer = bank.balanceAtBank(alice);
        assertGt(aliceAtTransfer, 0, "alice keeps what she already earned");
        assertEq(bank.balanceAtBank(bob), 0, "bob starts from zero");

        vm.warp(vm.getBlockTimestamp() + 1 days);
        bank.accrue();

        assertEq(bank.balanceAtBank(alice), aliceAtTransfer, "alice earns nothing more");
        assertGt(bank.balanceAtBank(bob), 0, "bob earns from here forward");
    }

    function test_issuance_stops_at_the_budget() public {
        giveShares(alice, BRANCH);

        // At 1M/day and a floor multiplier of 0.25x, the 900M budget cannot outlast this
        vm.warp(vm.getBlockTimestamp() + 20_000 days);
        bank.accrue();

        assertEq(bank.cumulativeIssuance(), bank.ISSUANCE_BUDGET(), "the budget is exactly exhausted");

        uint256 before = bank.balanceAtBank(alice);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        bank.accrue();
        assertEq(bank.balanceAtBank(alice), before, "base issuance has stopped permanently");
    }

    function test_the_budget_and_genesis_exactly_fill_the_hard_cap() public view {
        assertEq(bank.ISSUANCE_BUDGET() + bank.GENESIS_LIQUIDITY(), issue.HARD_CAP(), "900M + 100M = 1B");
    }

    function test_accrue_is_idempotent_within_a_block() public {
        giveShares(alice, BRANCH);
        vm.warp(vm.getBlockTimestamp() + 1 days);

        bank.accrue();
        uint256 growth = bank.issuanceGrowthPerShareX128();
        bank.accrue();
        bank.accrue();

        assertEq(bank.issuanceGrowthPerShareX128(), growth, "repeat calls change nothing");
    }
}
