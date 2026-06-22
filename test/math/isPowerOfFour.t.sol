// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";

import {isPowerOfFour} from "../../src/math/isPowerOfFour.sol";

contract IsPowerOfFourTest is Test {
    function test_isPowerOfFour_examples() public pure {
        assertFalse(isPowerOfFour(0));
        assertTrue(isPowerOfFour(1));
        assertFalse(isPowerOfFour(2));
        assertFalse(isPowerOfFour(3));
        assertTrue(isPowerOfFour(4));
        assertFalse(isPowerOfFour(8));
        assertTrue(isPowerOfFour(16));
        assertFalse(isPowerOfFour(type(uint256).max));
    }

    function test_isPowerOfFour_matchesReference(uint256 value) public pure {
        assertEq(isPowerOfFour(value), _referenceIsPowerOfFour(value));
    }

    function test_isPowerOfFour_acceptsAllRepresentablePowers(uint8 exponent) public pure {
        exponent = uint8(bound(exponent, 0, 127));
        assertTrue(isPowerOfFour(uint256(1) << (uint256(exponent) * 2)));
    }

    function _referenceIsPowerOfFour(uint256 value) private pure returns (bool) {
        if (value == 0) return false;
        while (value % 4 == 0) {
            value /= 4;
        }
        return value == 1;
    }
}
