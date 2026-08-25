// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ExchequerBase} from "./ExchequerBase.sol";
import {ExchequerAuctions} from "../../src/exchequer/ExchequerAuctions.sol";
import {GENESIS_LIQUIDITY, ISSUANCE_BUDGET} from "../../src/libraries/ExchequerMath.sol";
import {Exchequer} from "../../src/exchequer/Exchequer.sol";

contract WithdrawalsTest is ExchequerBase {
    uint256 internal constant BRANCH = 1e18;

    function test_retiring_one_branch_of_ten_liquidates_one_tenth() public {
        giveShares(alice, 10 * BRANCH);
        advanceDays(1);

        uint256 atBank = lens.balanceAtBank(bank, alice);
        assertApproxEqRel(atBank, 1_000_000e18, 1e12, "a day's issue");

        vm.prank(alice);
        (uint256 released,) = bank.withdraw(BRANCH, alice);

        assertApproxEqRel(released, atBank / 10, 1e12, "the pro rata rule");
        assertEq(bankToken.balanceOf(alice), 9 * BRANCH, "the vehicle is retired");
    }

    function test_you_cannot_extract_value_and_keep_the_vehicle() public {
        giveShares(alice, 2 * BRANCH);
        giveShares(bob, 2 * BRANCH);
        advanceDays(1);

        vm.prank(alice);
        bank.withdraw(2 * BRANCH, alice);

        assertEq(bankToken.balanceOf(alice), 0, "alice retired everything");
        assertEq(lens.balanceAtBank(bank, alice), 0, "and holds no ledger balance");

        advanceDays(1);
        assertEq(lens.balanceAtBank(bank, alice), 0, "she earns nothing more");
        assertGt(lens.balanceAtBank(bank, bob), 0, "bob still earns");
    }

    function test_a_quiet_week_pays_the_floor_fee() public {
        giveShares(alice, 100 * BRANCH);
        advanceDays(1);

        assertEq(lens.resolutionFeeRate(bank), lens.parameters(bank).resolutionFeeFloor, "no exit pressure yet");

        // Retiring one branch of a hundred is one percent of the bank: pressure barely registers
        vm.prank(alice);
        (uint256 released, uint256 minted) = bank.withdraw(BRANCH, alice);

        uint256 fee = released - minted;
        assertApproxEqRel(fee, released / 100, 0.05e18, "about one percent");
        assertEq(issue.balanceOf(alice), minted, "the rest is minted to the banker");
    }

    function test_a_whale_cannot_lump_out_at_the_floor() public {
        giveShares(alice, 9 * BRANCH);
        giveShares(bob, BRANCH);
        advanceDays(7);

        assertEq(lens.resolutionFeeRate(bank), lens.parameters(bank).resolutionFeeFloor, "quiet, at the margin");

        // Ninety percent of the bank leaving in one call is a run, and is priced as one
        vm.prank(alice);
        (uint256 released, uint256 minted) = bank.withdraw(9 * BRANCH, alice);

        assertApproxEqRel(
            released - minted, (released * lens.parameters(bank).resolutionFeeCeiling) / 1e18, 1e12, "the ceiling"
        );
    }

    function test_dust_exits_cannot_stretch_a_stream() public {
        giveShares(alice, BRANCH);
        giveShares(bob, BRANCH);
        advanceDays(7);

        vm.prank(alice);
        bank.withdraw(BRANCH, alice);
        uint64 end = lens.streamEndTime(bank);
        assertEq(end, vm.getBlockTimestamp() + 7 days, "a seven day stream");

        // Bob retires one wei of his branch every day for three days
        for (uint256 i; i < 3; ++i) {
            advanceDays(1);
            vm.prank(bob);
            bank.withdraw(1, bob);
        }

        // The weighted end has moved by the dust's weight, which is nothing
        assertLe(lens.streamEndTime(bank), end + 1 minutes, "the stream still ends on time");
    }

    function test_half_of_every_fee_is_burned_and_half_pays_those_who_stayed() public {
        giveShares(alice, BRANCH);
        giveShares(bob, BRANCH);
        advanceDays(1);

        // Book everything owed so far, so the counters below measure only what follows
        bank.accrue();
        uint256 bobBefore = lens.balanceAtBank(bank, bob);
        uint256 burnedBefore = issue.totalBurned();
        uint256 issuedBefore = lens.cumulativeIssuance(bank);

        vm.prank(alice);
        (uint256 released, uint256 minted) = bank.withdraw(BRANCH, alice);

        uint256 fee = released - minted;
        uint256 burned = issue.totalBurned() - burnedBefore;

        assertEq(burned, fee / 2, "half is destroyed");
        assertEq(lens.streamRemaining(bank), fee - burned, "half is owed to the banker who stayed");
        assertEq(lens.balanceAtBank(bank, bob), bobBefore, "but not yet paid");

        // Bob is the only banker left, so everything credited after this is his: the stream, plus
        // whatever base issuance the intervening days produced
        advanceDays(8);
        bank.accrue();
        uint256 baseIssued = lens.cumulativeIssuance(bank) - issuedBefore;

        assertEq(lens.streamRemaining(bank), 0, "the stream has finished");
        assertApproxEqAbs(
            lens.balanceAtBank(bank, bob) - bobBefore - baseIssued, fee - burned, 2, "and bob received it all"
        );
    }

    function test_the_redistribution_streams_linearly_over_the_window() public {
        giveShares(alice, BRANCH);
        giveShares(bob, BRANCH);
        advanceDays(1);

        bank.accrue();
        uint256 issuedBefore = lens.cumulativeIssuance(bank);
        uint256 bobBefore = lens.balanceAtBank(bank, bob);

        vm.prank(alice);
        (uint256 released, uint256 minted) = bank.withdraw(BRANCH, alice);
        uint256 redistributed = (released - minted) - (released - minted) / 2;

        // Half the window in: half the stream, on top of bob's base issuance
        vm.warp(vm.getBlockTimestamp() + 3.5 days);
        bank.accrue();
        uint256 baseIssued = lens.cumulativeIssuance(bank) - issuedBefore;
        assertApproxEqAbs(
            lens.balanceAtBank(bank, bob) - bobBefore - baseIssued, redistributed / 2, 2, "half way through the window"
        );
        assertApproxEqAbs(lens.streamRemaining(bank), redistributed / 2, 2, "half still to come");
    }

    function test_a_just_in_time_holder_cannot_capture_the_redistribution() public {
        giveShares(alice, BRANCH);
        giveShares(bob, BRANCH);
        advanceDays(7);

        // An attacker takes a large position in the block alice exits, and leaves in the same block
        address attacker = makeAddr("attacker");
        address carol = makeAddr("carol");
        giveShares(attacker, 100 * BRANCH);

        vm.prank(alice);
        (uint256 released, uint256 minted) = bank.withdraw(BRANCH, alice);
        assertGt(released - minted, 0, "a real fee was paid");

        vm.prank(attacker);
        bankToken.transfer(carol, 100 * BRANCH);

        assertEq(lens.balanceAtBank(bank, attacker), 0, "nothing was captured");

        // The stream pays whoever actually holds through the window
        advanceDays(8);
        bank.accrue();
        assertEq(lens.balanceAtBank(bank, attacker), 0, "still nothing");
        assertGt(lens.balanceAtBank(bank, carol), 0, "carol, who stayed, is paid");
        assertGt(lens.balanceAtBank(bank, bob), 0, "as is bob");
    }

    function test_the_burn_really_lowers_the_supply_ceiling() public {
        giveShares(alice, BRANCH);
        advanceDays(1);

        uint256 ceilingBefore = issue.maxSupply();

        vm.prank(alice);
        bank.withdraw(BRANCH, alice);

        assertLt(issue.maxSupply(), ceilingBefore, "eq 3.2: the ceiling only falls");
    }

    function test_the_supply_identity_holds_after_a_withdrawal() public {
        giveShares(alice, BRANCH);
        advanceDays(1);

        vm.prank(alice);
        bank.withdraw(BRANCH, alice);

        assertEq(issue.totalSupply(), issue.totalMinted() - issue.totalBurned(), "eq 3.1");
        assertLe(issue.totalMinted(), issue.HARD_CAP(), "the cumulative cap holds");
    }

    function test_heavy_exit_pressure_raises_the_fee_on_the_exiters() public {
        // Two bankers, a large ledger balance, then one of them empties most of it
        giveShares(alice, BRANCH);
        giveShares(bob, BRANCH);
        advanceDays(4);

        uint256 quietRate = lens.resolutionFeeRate(bank);
        assertEq(quietRate, lens.parameters(bank).resolutionFeeFloor, "quiet");

        vm.prank(alice);
        bank.withdraw(BRANCH, alice);

        uint256 pressuredRate = lens.resolutionFeeRate(bank);
        assertGt(pressuredRate, quietRate, "the door got more expensive");
        assertLe(pressuredRate, lens.parameters(bank).resolutionFeeCeiling, "but never past the ceiling");
    }

    function test_a_bank_run_transfers_value_from_the_impatient_to_the_patient() public {
        giveShares(alice, 9 * BRANCH);
        giveShares(bob, BRANCH);
        advanceDays(7);

        bank.accrue();
        uint256 bobBefore = lens.balanceAtBank(bank, bob);
        uint256 issuedBefore = lens.cumulativeIssuance(bank);

        // Alice runs for the door with ninety percent of the bank
        vm.prank(alice);
        (uint256 released, uint256 minted) = bank.withdraw(9 * BRANCH, alice);

        // Bob, the only banker left, collects half of what she paid over the following week
        advanceDays(8);
        bank.accrue();
        uint256 baseIssued = lens.cumulativeIssuance(bank) - issuedBefore;
        uint256 bobAfter = lens.balanceAtBank(bank, bob);

        uint256 fee = released - minted;
        assertApproxEqAbs(bobAfter - bobBefore - baseIssued, fee - fee / 2, 2, "exactly half of what alice paid");
    }

    function test_the_fee_locks_at_the_moment_of_commitment() public {
        giveShares(alice, 2 * BRANCH);
        advanceDays(4);

        // Half of alice's ledger is about to leave, and that size is part of its own price
        uint256 rateAtCall = lens.resolutionFeeRateFor(bank, lens.balanceAtBank(bank, alice) / 2);
        assertGt(rateAtCall, lens.resolutionFeeRate(bank), "an exit of this size is dearer than a marginal one");

        vm.prank(alice);
        (uint256 released, uint256 minted) = bank.withdraw(BRANCH, alice);

        assertApproxEqRel(released - minted, (released * rateAtCall) / 1e18, 1e12, "priced at the locked rate");
        assertEq(lens.resolutionFeeRate(bank), rateAtCall, "and the next marginal exit starts where this one ended");
    }

    function test_exit_pressure_decays_out_of_the_window() public {
        giveShares(alice, 2 * BRANCH);
        advanceDays(4);

        vm.prank(alice);
        bank.withdraw(BRANCH, alice);
        assertGt(lens.resolutionFeeRate(bank), lens.parameters(bank).resolutionFeeFloor, "elevated");

        advanceDays(8);
        assertEq(lens.resolutionFeeRate(bank), lens.parameters(bank).resolutionFeeFloor, "the window cleared");
    }

    function test_withdrawals_are_never_paused_at_any_fee_level() public {
        giveShares(alice, 100 * BRANCH);
        advanceDays(7);

        // Empty the bank in a single week, driving pressure past saturation
        for (uint256 i; i < 10; ++i) {
            vm.prank(alice);
            bank.withdraw(10 * BRANCH, alice);
        }

        assertEq(bankToken.balanceOf(alice), 0, "every exit went through");
        assertEq(lens.resolutionFeeRate(bank), lens.parameters(bank).resolutionFeeCeiling, "at the ceiling, but open");
    }

    function test_the_last_banker_out_burns_what_nobody_is_left_to_receive() public {
        giveShares(alice, BRANCH);
        advanceDays(1);

        uint256 burnedBefore = issue.totalBurned();

        vm.prank(alice);
        (uint256 released, uint256 minted) = bank.withdraw(BRANCH, alice);

        assertEq(bankToken.totalSupply(), 0, "nobody stayed");
        assertEq(issue.totalBurned() - burnedBefore, released - minted, "the whole fee burns");
    }

    function test_the_last_banker_out_also_burns_an_unfinished_stream() public {
        giveShares(alice, BRANCH);
        giveShares(bob, BRANCH);
        advanceDays(1);

        vm.prank(alice);
        bank.withdraw(BRANCH, alice);
        uint256 streaming = lens.streamRemaining(bank);
        assertGt(streaming, 0, "a stream is in flight");

        // Bob leaves a day later, before the stream has finished
        advanceDays(1);
        uint256 burnedBefore = issue.totalBurned();
        vm.prank(bob);
        (uint256 released, uint256 minted) = bank.withdraw(BRANCH, bob);

        assertEq(lens.streamRemaining(bank), 0, "nothing left in flight");
        assertGt(issue.totalBurned() - burnedBefore, released - minted, "his fee and the orphaned stream burned");
        // Per-share credits round down, so a wei or two of unclaimable dust can remain on the ledger
        assertLe(lens.totalLedgerBalance(bank), 2, "the ledger is empty but for dust");
    }

    function test_parking_shares_elsewhere_cannot_liquidate_more_than_their_share() public {
        giveShares(alice, 10 * BRANCH);
        advanceDays(1);

        uint256 ledger = lens.balanceAtBank(bank, alice);
        address parking = makeAddr("parking");

        // Park all but one wei of the shares, retire that wei, and take the shares back
        vm.startPrank(alice);
        bankToken.transfer(parking, 10 * BRANCH - 1);
        (uint256 released,) = bank.withdraw(1, alice);
        vm.stopPrank();
        vm.prank(parking);
        bankToken.transfer(alice, 10 * BRANCH - 1);

        // One wei of ten whole branches is worth one wei's share of the ledger, and the rest of the
        // ledger travelled with the parked shares and came back with them
        assertLe(released, ledger / (10 * BRANCH) + 1, "one wei's worth, no more");
        assertApproxEqAbs(lens.balanceAtBank(bank, alice), ledger - released, 2, "the balance is intact");
        assertEq(bankToken.balanceOf(alice), 10 * BRANCH - 1, "and so are the branches");
    }

    function test_cannot_withdraw_more_than_held() public {
        giveShares(alice, BRANCH);
        advanceDays(1);

        vm.prank(alice);
        vm.expectRevert(Exchequer.InvalidWithdrawalAmount.selector);
        bank.withdraw(BRANCH + 1, alice);
    }

    function test_cannot_withdraw_nothing() public {
        giveShares(alice, BRANCH);

        vm.prank(alice);
        vm.expectRevert(Exchequer.InvalidWithdrawalAmount.selector);
        bank.withdraw(0, alice);
    }
}
