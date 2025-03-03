// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

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
    }

    function test_exp2(int128 x) public {
        x = int128(bound(x, type(int128).min, 0x400000000000000000));

        exp2(x);
    }
}
