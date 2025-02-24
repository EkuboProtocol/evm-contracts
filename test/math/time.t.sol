// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {toDuration, isTimeValid} from "../../src/math/time.sol";

contract TimeTest is Test {
    function test_isTimeValid_true_examples() {
        assertTrue(isTimeValid({currentTime: 100, time: 112}));
    }
}
