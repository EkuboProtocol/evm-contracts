// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ExchequerBase} from "./ExchequerBase.sol";
import {Exchequer} from "../../src/exchequer/Exchequer.sol";

contract WithdrawalsTest is ExchequerBase {
    uint256 internal constant BRANCH = 1e18;

    function test_retiring_one_branch_of_ten_liquidates_one_tenth() public {
        giveShares(alice, 10 * BRANCH);
        advanceDays(1);

        uint256 atBank = bank.balanceAtBank(alice);
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
        assertEq(bank.balanceAtBank(alice), 0, "and holds no ledger balance");

        advanceDays(1);
        assertEq(bank.balanceAtBank(alice), 0, "she earns nothing more");
        assertGt(bank.balanceAtBank(bob), 0, "bob still earns");
    }

    function test_a_quiet_week_pays_the_floor_fee() public {
        giveShares(alice, BRANCH);
        advanceDays(1);

        assertEq(bank.resolutionFeeRate(), bank.RESOLUTION_FEE_FLOOR(), "no exit pressure yet");

        vm.prank(alice);
        (uint256 released, uint256 minted) = bank.withdraw(BRANCH, alice);

        uint256 fee = released - minted;
        assertApproxEqRel(fee, released / 100, 1e12, "one percent");
        assertEq(issue.balanceOf(alice), minted, "the rest is minted to the banker");
    }

    function test_half_of_every_fee_is_burned_and_half_pays_those_who_stayed() public {
        giveShares(alice, BRANCH);
        giveShares(bob, BRANCH);
        advanceDays(1);

        uint256 bobBefore = bank.balanceAtBank(bob);
        uint256 burnedBefore = issue.totalBurned();

        vm.prank(alice);
        (uint256 released, uint256 minted) = bank.withdraw(BRANCH, alice);

        uint256 fee = released - minted;
        uint256 burned = issue.totalBurned() - burnedBefore;

        assertEq(burned, fee / 2, "half is destroyed");
        assertApproxEqAbs(bank.balanceAtBank(bob) - bobBefore, fee - burned, 2, "half pays the banker who stayed");
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

        uint256 quietRate = bank.resolutionFeeRate();
        assertEq(quietRate, bank.RESOLUTION_FEE_FLOOR(), "quiet");

        vm.prank(alice);
        bank.withdraw(BRANCH, alice);

        uint256 pressuredRate = bank.resolutionFeeRate();
        assertGt(pressuredRate, quietRate, "the door got more expensive");
        assertLe(pressuredRate, bank.RESOLUTION_FEE_CEILING(), "but never past the ceiling");
    }

    function test_a_bank_run_transfers_value_from_the_impatient_to_the_patient() public {
        giveShares(alice, 9 * BRANCH);
        giveShares(bob, BRANCH);
        advanceDays(7);

        uint256 bobBefore = bank.balanceAtBank(bob);

        // Alice runs for the door with ninety percent of the bank
        vm.prank(alice);
        (uint256 released, uint256 minted) = bank.withdraw(9 * BRANCH, alice);

        uint256 bobAfter = bank.balanceAtBank(bob);
        assertGt(bobAfter, bobBefore, "the banker who stayed is paid");

        uint256 fee = released - minted;
        assertApproxEqAbs(bobAfter - bobBefore, fee - fee / 2, 2, "with exactly half of what alice paid");
    }

    function test_the_fee_locks_at_the_moment_of_commitment() public {
        giveShares(alice, 2 * BRANCH);
        advanceDays(4);

        uint256 rateAtCall = bank.resolutionFeeRate();

        vm.prank(alice);
        (uint256 released, uint256 minted) = bank.withdraw(BRANCH, alice);

        // The rate rises because of this very withdrawal, but this exit paid the earlier rate
        assertGt(bank.resolutionFeeRate(), rateAtCall, "pressure rose afterwards");
        assertApproxEqRel(released - minted, (released * rateAtCall) / 1e18, 1e12, "priced at the locked rate");
    }

    function test_exit_pressure_decays_out_of_the_window() public {
        giveShares(alice, 2 * BRANCH);
        advanceDays(4);

        vm.prank(alice);
        bank.withdraw(BRANCH, alice);
        assertGt(bank.resolutionFeeRate(), bank.RESOLUTION_FEE_FLOOR(), "elevated");

        advanceDays(8);
        assertEq(bank.resolutionFeeRate(), bank.RESOLUTION_FEE_FLOOR(), "the window cleared");
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
        assertEq(bank.resolutionFeeRate(), bank.RESOLUTION_FEE_CEILING(), "at the ceiling, but open");
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
