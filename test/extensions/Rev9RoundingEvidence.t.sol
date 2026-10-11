// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {computeFee, amountBeforeFee} from "../../src/math/fee.sol";

/// Evidence for EKU-946 design rev 9 §(b-main) rounding bounds R2/R3 (EKU-1587 finding 1), using the
/// unmodified fee libraries on `main` (98d1be1). Pure arithmetic; not the extension implementation.
contract Rev9RoundingEvidenceTest is Test {
    uint64 constant FEE_25PCT = uint64(1 << 62);
    // 0.64 total-fee cap of the design (50%); init requires poolFee < MAX_FEE
    uint64 constant MAX_FEE = uint64(1 << 63);

    // R3, one step: G = amountBeforeFee(N, fee) inverts exactly: G - computeFee(G, fee) == N.
    function test_R3_oneStepInverseIsExact(uint128 n, uint64 fee) public pure {
        n = uint128(bound(n, 0, type(uint64).max));
        uint128 g = amountBeforeFee(n, fee);
        assertEq(g - computeFee(g, fee), n, "one-step inverse must be exact");
    }

    // R3, n steps: the single inverse of the summed gross input overestimates the summed curve
    // input by an integer in [0, n-1]. EKU-1587 vector: four steps of N_i = 1 at 25% -> 6 vs 4.
    function test_R3_multiStepInverseVector() public pure {
        uint128 sumG;
        for (uint256 i = 0; i < 4; i++) {
            sumG += amountBeforeFee(1, FEE_25PCT);
        }
        assertEq(sumG, 8);
        assertEq(sumG - computeFee(sumG, FEE_25PCT), 6, "aggregate inverse overestimates by 2 wei");
    }

    function test_R3_multiStepInverseBand(uint64[8] memory ns, uint64 fee) public pure {
        fee = uint64(bound(fee, 0, MAX_FEE - 1));
        uint128 sumN;
        uint128 sumG;
        for (uint256 i = 0; i < 8; i++) {
            sumN += ns[i];
            sumG += amountBeforeFee(ns[i], fee);
        }
        uint128 inv = sumG - computeFee(sumG, fee);
        assertGe(inv, sumN, "inverse never underestimates");
        assertLe(inv - sumN, 7, "inverse overestimates by at most n-1");
    }

    // R2 (fixed endpoints, constant liquidity): one added cut costs at most amountBeforeFee(1, fee) + 1
    // = ceil(1/q) + 1 gross input wei, because the per-step curve ceilings can sum to N + 1 and the
    // gross-up is applied per step. EKU-1587 vector: 25% fee, two 1-unit halves of a 1-unit whole.
    function test_R2_addedCutVector25pct() public pure {
        uint128 whole = amountBeforeFee(1, FEE_25PCT);
        uint128 split = amountBeforeFee(1, FEE_25PCT) + amountBeforeFee(1, FEE_25PCT);
        assertEq(whole, 2);
        assertEq(split, 4);
        assertEq(split - whole, 2, "one added cut costs 2 input wei at 25%");
        assertLe(split - whole, amountBeforeFee(1, FEE_25PCT) + 1, "within ceil(1/q) + 1");
    }

    function test_R2_addedCutAllowance(uint64 n1, uint64 n2, bool extraCeil, uint64 fee) public pure {
        fee = uint64(bound(fee, 0, MAX_FEE - 1));
        // per-step curve ceilings sum to either N or N + 1 relative to the whole-step ceiling
        uint128 whole = uint128(n1) + uint128(n2);
        if (extraCeil) {
            vm.assume(whole > 0);
            whole -= 1;
        }
        uint128 split = amountBeforeFee(n1, fee) + amountBeforeFee(n2, fee);
        uint128 wholeG = amountBeforeFee(whole, fee);
        assertGe(split, wholeG, "cutting never reduces gross input");
        assertLe(split - wholeG, amountBeforeFee(1, fee) + 1, "per-cut allowance ceil(1/q) + 1");
    }

    // The allowance in rev 9 is stated as ceil(1/q) + 1 <= ceil(2/q); check the stated inequality.
    function test_R2_allowanceLeCeilTwoOverQ(uint64 fee) public pure {
        assertLe(amountBeforeFee(1, fee) + 1, amountBeforeFee(2, fee));
    }

    // R1/R2 net exact-in output at a fixed rate: one added cut changes net output by at most 2 wei
    // (1 from the floored raw output, 1 from the ceiled surcharge).
    function test_R2_netOutputPerCut(uint64 out1, uint64 out2, bool lostFloor, uint64 sur) public pure {
        uint128 whole = uint128(out1) + uint128(out2);
        if (lostFloor) {
            whole += 1;
        }
        uint128 netSplit = (out1 - computeFee(out1, sur)) + (out2 - computeFee(out2, sur));
        uint128 netWhole = whole - computeFee(whole, sur);
        assertGe(netWhole, netSplit, "cutting never increases net output");
        assertLe(netWhole - netSplit, 2, "net output changes by at most 2 wei per added cut");
    }
}
