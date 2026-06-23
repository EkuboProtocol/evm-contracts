// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";

import {MAX_VE_FEE, capFee} from "../../src/math/tickSpacingFee.sol";

contract TickSpacingFeeTest is Test {
    function test_capFee_examples() public pure {
        assertEq(capFee(0), 0);
        assertEq(capFee(MAX_VE_FEE - 1), MAX_VE_FEE - 1);
        assertEq(capFee(MAX_VE_FEE), MAX_VE_FEE);
        assertEq(capFee(MAX_VE_FEE + 1), MAX_VE_FEE);
        assertEq(capFee(type(uint64).max), MAX_VE_FEE);
    }

    function test_capFee(uint64 fee) public pure {
        uint64 capped = capFee(fee);

        assertLe(capped, MAX_VE_FEE);
        assertEq(capped, fee > MAX_VE_FEE ? MAX_VE_FEE : fee);
    }
}
