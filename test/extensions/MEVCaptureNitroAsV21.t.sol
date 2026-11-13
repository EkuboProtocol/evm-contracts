// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {MEVCaptureV21Test} from "./MEVCaptureV21.t.sol";
import {MEVCaptureV21RulesTest} from "./MEVCaptureV21Rules.t.sol";
import {ARB_SYS_TIMESTAMP_CLOCK} from "./MEVCaptureNitroHelpers.sol";

// The whole MEV Capture v2.1 suite, run against MEVCaptureNitro with an ArbSys mock that answers with
// `block.timestamp`, so that one clock unit is one second as in v2.1. Each contract below inherits every test of the
// v2.1 suite it names and changes only what is deployed and the gas price of its transactions.

uint256 constant BASE_FEE = 0.02 gwei;
uint64 constant PRIORITY_FREE = 0.05 gwei;
// 10 bps per gwei of priority fee, as a 0.64 number per wei
uint64 constant PRIORITY_SLOPE = 18446744;
// 10 bps
uint64 constant PRIORITY_CAP = 18446744073709551;
// charged PRIORITY_SLOPE * 0.3 gwei, which is 3 bps
uint256 constant CHARGED_TIP = PRIORITY_FREE + 0.3 gwei;

// Priority surcharge disabled, and the transaction pays a large tip: every result must equal v2.1's.

contract MEVCaptureNitroDisabledPriorityTest is MEVCaptureV21Test {
    function _variant() internal pure override returns (Variant memory v) {
        (v.nitro, v.arbSysCode) = (true, ARB_SYS_TIMESTAMP_CLOCK);
        (v.baseFee, v.gasPrice) = (BASE_FEE, BASE_FEE + 100 gwei);
    }
}

contract MEVCaptureNitroDisabledPriorityRulesTest is MEVCaptureV21RulesTest {
    function _variant() internal pure override returns (Variant memory v) {
        (v.nitro, v.arbSysCode) = (true, ARB_SYS_TIMESTAMP_CLOCK);
        (v.baseFee, v.gasPrice) = (BASE_FEE, BASE_FEE + 100 gwei);
    }
}

// Priority surcharge enabled, and the transaction pays exactly the free allowance: every result must equal v2.1's.

contract MEVCaptureNitroFreePriorityTest is MEVCaptureV21Test {
    function _variant() internal pure override returns (Variant memory v) {
        (v.nitro, v.arbSysCode) = (true, ARB_SYS_TIMESTAMP_CLOCK);
        (v.priorityFree, v.prioritySlope, v.priorityCap) = (PRIORITY_FREE, PRIORITY_SLOPE, PRIORITY_CAP);
        (v.baseFee, v.gasPrice) = (BASE_FEE, BASE_FEE + PRIORITY_FREE);
    }
}

contract MEVCaptureNitroFreePriorityRulesTest is MEVCaptureV21RulesTest {
    function _variant() internal pure override returns (Variant memory v) {
        (v.nitro, v.arbSysCode) = (true, ARB_SYS_TIMESTAMP_CLOCK);
        (v.priorityFree, v.prioritySlope, v.priorityCap) = (PRIORITY_FREE, PRIORITY_SLOPE, PRIORITY_CAP);
        (v.baseFee, v.gasPrice) = (BASE_FEE, BASE_FEE + PRIORITY_FREE);
    }
}

// Priority surcharge enabled, and the transaction pays a tip that is charged 3 bps on every away segment. The
// reference model adds the same rate, so every rule of v2.1 is checked with the priority surcharge present.

contract MEVCaptureNitroChargedPriorityTest is MEVCaptureV21Test {
    function _variant() internal pure override returns (Variant memory v) {
        (v.nitro, v.arbSysCode) = (true, ARB_SYS_TIMESTAMP_CLOCK);
        (v.priorityFree, v.prioritySlope, v.priorityCap) = (PRIORITY_FREE, PRIORITY_SLOPE, PRIORITY_CAP);
        (v.baseFee, v.gasPrice) = (BASE_FEE, BASE_FEE + CHARGED_TIP);
    }
}

contract MEVCaptureNitroChargedPriorityRulesTest is MEVCaptureV21RulesTest {
    function _variant() internal pure override returns (Variant memory v) {
        (v.nitro, v.arbSysCode) = (true, ARB_SYS_TIMESTAMP_CLOCK);
        (v.priorityFree, v.prioritySlope, v.priorityCap) = (PRIORITY_FREE, PRIORITY_SLOPE, PRIORITY_CAP);
        (v.baseFee, v.gasPrice) = (BASE_FEE, BASE_FEE + CHARGED_TIP);
    }
}
