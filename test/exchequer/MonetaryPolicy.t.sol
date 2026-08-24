// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ExchequerBase} from "./ExchequerBase.sol";
import {amountBeforeFee} from "../../src/math/fee.sol";

contract MonetaryPolicyTest is ExchequerBase {
    uint256 internal constant BRANCH = 1e18;

    /// @dev Forty silent epochs from the launch multiplier issue this much, whichever path is taken:
    ///      one day at 1.0x, then 0.75x, then 0.5x, then thirty-seven days pinned to the 0.25x floor
    uint256 internal constant FORTY_SILENT_EPOCHS_ISSUANCE = 11_500_000e18;

    function setUp() public override {
        super.setUp();
        giveShares(alice, BRANCH);
    }

    /// @dev Crosses exactly one epoch boundary and settles the rollover
    function _rollOneEpoch() internal {
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();
    }

    function test_launch_multiplier_is_neutral() public view {
        assertEq(bank.multiplier(), 1e18, "policy starts neutral");
    }

    function test_inflows_raise_the_rate() public {
        buy(trader, 1 ether);
        _rollOneEpoch();

        assertEq(bank.multiplier(), 1.0625e18, "one raise step");
    }

    function test_a_good_epoch_counts_twice_because_the_signal_trails_two_epochs() public {
        buy(trader, 1 ether);
        _rollOneEpoch();
        assertEq(bank.multiplier(), 1.0625e18, "first raise, from this epoch");

        // Nothing happens, but the signal still carries the previous epoch's inflow
        _rollOneEpoch();
        assertEq(bank.multiplier(), 1.125e18, "second raise, from the trailing epoch");

        // Now both trailing epochs are empty, so the signal is zero and the rate is cut
        _rollOneEpoch();
        assertEq(bank.multiplier(), 0.875e18, "a zero signal is a contraction");
    }

    function test_dust_cannot_buy_the_policy_signal() public {
        // A dust buy is booked as inflow but is below the dead band
        buy(trader, 1e12);
        (int256 flow,,) = bank.netFlows();
        assertGt(flow, 0, "the dust registered");

        _rollOneEpoch();
        assertEq(bank.multiplier(), 0.75e18, "and still counted as a contraction");

        // The trailing two-epoch sum just under the threshold is likewise nothing; at it, real
        // capital into the pool, it counts
        buy(trader, uint128(MIN_NET_FLOW) - 2);
        _rollOneEpoch();
        assertEq(bank.multiplier(), 0.5e18, "below the band");

        buy(trader, amountBeforeFee(uint128(MIN_NET_FLOW), TRADING_FEE));
        _rollOneEpoch();
        assertEq(bank.multiplier(), 0.5625e18, "at the band");
    }

    function test_dust_cannot_flip_fee_routing() public {
        buy(trader, 1 ether);
        vm.warp(bank.epochStartTime() + bank.EPOCH_LENGTH());
        bank.accrue();

        // A dust buy in a quiet epoch: revenue is routed to defense, not to reserves
        buy(trader, 1e12);
        uint128 fees = bank.epochRevenueEth();
        uint128 contractionBefore = bank.pendingContractionEth();
        _rollOneEpoch();

        assertEq(bank.pendingContractionEth() - contractionBefore, (uint256(fees) * 70) / 100, "contraction");
    }

    function test_silence_is_treated_as_contraction() public {
        _rollOneEpoch();
        assertEq(bank.multiplier(), 0.75e18, "cut by a full step");
    }

    function test_the_bank_turns_defensive_faster_than_it_turns_generous() public {
        uint256 raisesToCeiling;
        while (bank.multiplier() < bank.MULTIPLIER_MAX()) {
            buy(trader, 0.01 ether);
            _rollOneEpoch();
            if (++raisesToCeiling > 200) break;
        }
        assertEq(bank.multiplier(), bank.MULTIPLIER_MAX(), "reaches the ceiling");
        assertEq(raisesToCeiling, 48, "3.0 of headroom at 0.0625 a step");

        uint256 cutsToFloor;
        while (bank.multiplier() > bank.MULTIPLIER_MIN()) {
            _rollOneEpoch();
            if (++cutsToFloor > 200) break;
        }
        assertEq(bank.multiplier(), bank.MULTIPLIER_MIN(), "reaches the floor");
        // Fifteen cuts of 0.25, plus one epoch spent clamped at the ceiling while the trailing
        // signal still carried the final inflow
        assertEq(cutsToFloor, 16, "ceiling to floor in sixteen epochs");

        assertLt(cutsToFloor, raisesToCeiling, "cuts are immediate, raises must be earned");
    }

    function test_the_multiplier_clamps_at_both_ends() public {
        for (uint256 i; i < 40; ++i) {
            _rollOneEpoch();
        }
        assertEq(bank.multiplier(), bank.MULTIPLIER_MIN(), "never below the floor");

        for (uint256 i; i < 200; ++i) {
            buy(trader, 0.01 ether);
            _rollOneEpoch();
        }
        assertEq(bank.multiplier(), bank.MULTIPLIER_MAX(), "never above the ceiling");
    }

    function test_stepping_through_forty_silent_epochs() public {
        uint64 startEpoch = bank.epochStartTime();

        for (uint256 i; i < 40; ++i) {
            _rollOneEpoch();
        }

        assertEq(bank.multiplier(), bank.MULTIPLIER_MIN(), "decayed to the floor");
        assertEq(bank.epochStartTime(), startEpoch + 40 * uint256(bank.EPOCH_LENGTH()), "epoch clock is exact");
        assertEq(bank.cumulativeIssuance(), FORTY_SILENT_EPOCHS_ISSUANCE, "arithmetic series of cuts");
    }

    function test_jumping_forty_silent_epochs_matches_stepping_through_them() public {
        uint64 startEpoch = bank.epochStartTime();

        // One call takes the closed-form path rather than looping
        vm.warp(startEpoch + 40 * uint256(bank.EPOCH_LENGTH()));
        bank.accrue();

        assertEq(bank.multiplier(), bank.MULTIPLIER_MIN(), "same multiplier as stepping");
        assertEq(bank.epochStartTime(), startEpoch + 40 * uint256(bank.EPOCH_LENGTH()), "same epoch clock");
        assertEq(bank.cumulativeIssuance(), FORTY_SILENT_EPOCHS_ISSUANCE, "same cumulative issuance");
    }

    function testFuzz_jumping_never_overstates_issuance(uint16 epochs) public {
        // Three cuts of 0.25 take the launch multiplier to the floor, so start there
        epochs = uint16(bound(epochs, 3, 500));

        uint64 startEpoch = bank.epochStartTime();
        vm.warp(startEpoch + uint256(epochs) * bank.EPOCH_LENGTH());
        bank.accrue();

        // Every silent epoch runs at the floor or below the launch multiplier, so the total can
        // never exceed what an uncut rate would have issued
        assertLe(bank.cumulativeIssuance(), uint256(epochs) * 1_000_000e18, "cuts only reduce issuance");
        assertGe(bank.cumulativeIssuance(), uint256(epochs) * 250_000e18, "never below the floor rate");
        assertEq(bank.multiplier(), bank.MULTIPLIER_MIN(), "silence always ends at the floor");
    }
}
