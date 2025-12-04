// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {Test} from "forge-std/Test.sol";
import {exp2} from "../../src/math/exp2.sol";

contract ExpTest is Test {
    function test_gas() public {
        vm.startSnapshotGas("exp2(0)");
        exp2(0);
        vm.stopSnapshotGas();

        vm.startSnapshotGas("exp2(1)");
        exp2(1 << 64);
        vm.stopSnapshotGas();

        vm.startSnapshotGas("exp2(10)");
        exp2(10 << 64);
        vm.stopSnapshotGas();

        vm.startSnapshotGas("exp2(63)");
        exp2((63 << 64) - 1);
        vm.stopSnapshotGas();

        vm.startSnapshotGas("exp2(63.999...)");
        exp2(0x400000000000000000 - 1);
        vm.stopSnapshotGas();
    }

    function test_exp2_examples_positive() public pure {
        // https://www.wolframalpha.com/input?i=floor%28+2+**+0.5+*+2**64+%29
        assertEq(exp2(1 << 62), 21936999301089678046);
        assertEq(exp2(1 << 63), 26087635650665564424);
        assertEq(exp2(0), 1 << 64);
        assertEq(exp2(1 << 64), 2 << 64);
        assertEq(exp2((3 << 64) / 2), 52175271301331128849);
        assertEq(exp2(2 << 64), 4 << 64);
        assertEq(exp2(4 << 64), 16 << 64);
        assertEq(exp2(8 << 64), 256 << 64);
        assertEq(exp2(16 << 64), 65536 << 64);
        assertEq(exp2(63 << 64), 9223372036854775808 << 64);
        // 2**63.5
        // https://www.wolframalpha.com/input?i=floor%28%282**63.5%29*2**64%29
        assertEq(exp2((127 << 64) / 2), 240615969168004511545033772477625056927);

        // approximately equal to 2**64
        assertEq(exp2(0x400000000000000000 - 1), 340282366920938463450588298786565555714);
    }

    function test_exp2_monotonically_increasing(uint256 x) public pure {
        x = bound(x, 0, (1 << 70) - 2);
        assertGe(exp2(x + 1), exp2(x));
    }

    function test_exp2_greater_than_one(uint256 x) public pure {
        x = bound(x, 0, (1 << 70) - 1);
        assertGe(exp2(x), 1 << 64);
    }
}
