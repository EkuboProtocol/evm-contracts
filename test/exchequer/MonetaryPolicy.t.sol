// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ExchequerBase} from "./ExchequerBase.sol";
import {Exchequer} from "../../src/exchequer/Exchequer.sol";
import {ExchequerAuctions} from "../../src/exchequer/ExchequerAuctions.sol";
import {GENESIS_LIQUIDITY, ISSUANCE_BUDGET} from "../../src/libraries/ExchequerMath.sol";
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
        vm.warp(lens.epochStartTime(bank) + lens.parameters(bank).epochLength);
        bank.accrue();
    }

    function test_launch_multiplier_is_neutral() public view {
        assertEq(lens.multiplier(bank), 1e18, "policy starts neutral");
    }

    function test_inflows_raise_the_rate() public {
        buy(trader, 1 ether);
        _rollOneEpoch();

        assertEq(lens.multiplier(bank), 1.0625e18, "one raise step");
    }

    function test_a_good_epoch_counts_twice_because_the_signal_trails_two_epochs() public {
        buy(trader, 1 ether);
        _rollOneEpoch();
        assertEq(lens.multiplier(bank), 1.0625e18, "first raise, from this epoch");

        // Nothing happens, but the signal still carries the previous epoch's inflow
        _rollOneEpoch();
        assertEq(lens.multiplier(bank), 1.125e18, "second raise, from the trailing epoch");

        // Now both trailing epochs are empty, so the signal is zero and the rate is cut
        _rollOneEpoch();
        assertEq(lens.multiplier(bank), 0.875e18, "a zero signal is a contraction");
    }

    function test_dust_cannot_buy_the_policy_signal() public {
        // A dust buy is booked as inflow but is below the dead band
        buy(trader, 1e12);
        (int256 flow,,) = lens.netFlows(bank);
        assertGt(flow, 0, "the dust registered");

        _rollOneEpoch();
        assertEq(lens.multiplier(bank), 0.75e18, "and still counted as a contraction");

        // The trailing two-epoch sum just under the threshold is likewise nothing; at it, real
        // capital into the pool, it counts
        buy(trader, uint128(MIN_NET_FLOW) - 2);
        _rollOneEpoch();
        assertEq(lens.multiplier(bank), 0.5e18, "below the band");

        buy(trader, amountBeforeFee(uint128(MIN_NET_FLOW), TRADING_FEE));
        _rollOneEpoch();
        assertEq(lens.multiplier(bank), 0.5625e18, "at the band");
    }

    function test_dust_cannot_flip_fee_routing() public {
        buy(trader, 1 ether);
        vm.warp(lens.epochStartTime(bank) + lens.parameters(bank).epochLength);
        bank.accrue();

        // A dust buy in a quiet epoch: revenue is routed to defense, not to reserves
        buy(trader, 1e12);
        uint128 fees = lens.epochRevenueEth(bank);
        uint128 contractionBefore = lens.pendingContractionEth(bank);
        _rollOneEpoch();

        assertEq(lens.pendingContractionEth(bank) - contractionBefore, (uint256(fees) * 70) / 100, "contraction");
    }

    function test_silence_is_treated_as_contraction() public {
        _rollOneEpoch();
        assertEq(lens.multiplier(bank), 0.75e18, "cut by a full step");
    }

    function test_the_bank_turns_defensive_faster_than_it_turns_generous() public {
        uint256 raisesToCeiling;
        while (lens.multiplier(bank) < lens.parameters(bank).multiplierMax) {
            buy(trader, 0.01 ether);
            _rollOneEpoch();
            if (++raisesToCeiling > 200) break;
        }
        assertEq(lens.multiplier(bank), lens.parameters(bank).multiplierMax, "reaches the ceiling");
        assertEq(raisesToCeiling, 48, "3.0 of headroom at 0.0625 a step");

        uint256 cutsToFloor;
        while (lens.multiplier(bank) > lens.parameters(bank).multiplierMin) {
            _rollOneEpoch();
            if (++cutsToFloor > 200) break;
        }
        assertEq(lens.multiplier(bank), lens.parameters(bank).multiplierMin, "reaches the floor");
        // Fifteen cuts of 0.25, plus one epoch spent clamped at the ceiling while the trailing
        // signal still carried the final inflow
        assertEq(cutsToFloor, 16, "ceiling to floor in sixteen epochs");

        assertLt(cutsToFloor, raisesToCeiling, "cuts are immediate, raises must be earned");
    }

    function test_the_multiplier_clamps_at_both_ends() public {
        for (uint256 i; i < 40; ++i) {
            _rollOneEpoch();
        }
        assertEq(lens.multiplier(bank), lens.parameters(bank).multiplierMin, "never below the floor");

        for (uint256 i; i < 200; ++i) {
            buy(trader, 0.01 ether);
            _rollOneEpoch();
        }
        assertEq(lens.multiplier(bank), lens.parameters(bank).multiplierMax, "never above the ceiling");
    }

    function test_stepping_through_forty_silent_epochs() public {
        uint64 startEpoch = lens.epochStartTime(bank);

        for (uint256 i; i < 40; ++i) {
            _rollOneEpoch();
        }

        assertEq(lens.multiplier(bank), lens.parameters(bank).multiplierMin, "decayed to the floor");
        assertEq(
            lens.epochStartTime(bank),
            startEpoch + 40 * uint256(lens.parameters(bank).epochLength),
            "epoch clock is exact"
        );
        assertEq(lens.cumulativeIssuance(bank), FORTY_SILENT_EPOCHS_ISSUANCE, "arithmetic series of cuts");
    }

    function test_jumping_forty_silent_epochs_matches_stepping_through_them() public {
        uint64 startEpoch = lens.epochStartTime(bank);

        // One call takes the closed-form path rather than looping
        vm.warp(startEpoch + 40 * uint256(lens.parameters(bank).epochLength));
        bank.accrue();

        assertEq(lens.multiplier(bank), lens.parameters(bank).multiplierMin, "same multiplier as stepping");
        assertEq(
            lens.epochStartTime(bank), startEpoch + 40 * uint256(lens.parameters(bank).epochLength), "same epoch clock"
        );
        assertEq(lens.cumulativeIssuance(bank), FORTY_SILENT_EPOCHS_ISSUANCE, "same cumulative issuance");
    }

    function testFuzz_jumping_never_overstates_issuance(uint16 epochs) public {
        // Three cuts of 0.25 take the launch multiplier to the floor, so start there
        epochs = uint16(bound(epochs, 3, 500));

        uint64 startEpoch = lens.epochStartTime(bank);
        vm.warp(startEpoch + uint256(epochs) * lens.parameters(bank).epochLength);
        bank.accrue();

        // Every silent epoch runs at the floor or below the launch multiplier, so the total can
        // never exceed what an uncut rate would have issued
        assertLe(lens.cumulativeIssuance(bank), uint256(epochs) * 1_000_000e18, "cuts only reduce issuance");
        assertGe(lens.cumulativeIssuance(bank), uint256(epochs) * 250_000e18, "never below the floor rate");
        assertEq(lens.multiplier(bank), lens.parameters(bank).multiplierMin, "silence always ends at the floor");
    }
}
