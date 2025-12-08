// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {Test} from "forge-std/Test.sol";
import {OracleStorageLayout} from "../../src/libraries/OracleStorageLayout.sol";
import {StorageSlot} from "../../src/types/storageSlot.sol";

contract OracleStorageLayoutTest is Test {
    function check_noStorageLayoutCollisions_countsSlot_countsSlot(address tokenA, address tokenB) public pure {
        vm.assume(tokenA != tokenB);

        bytes32 slotA = StorageSlot.unwrap(OracleStorageLayout.countsSlot(tokenA));
        bytes32 slotB = StorageSlot.unwrap(OracleStorageLayout.countsSlot(tokenB));

        assertNotEq(slotA, slotB);
    }

    function check_noStorageLayoutCollisions_countsSlot_snapshotSlot(
        address countsToken,
        address snapshotToken,
        uint256 index
    ) public pure {
        vm.assume(countsToken != snapshotToken);
        index = bound(index, 0, type(uint32).max);

        bytes32 counts = StorageSlot.unwrap(OracleStorageLayout.countsSlot(countsToken));
        bytes32 snapshot = StorageSlot.unwrap(OracleStorageLayout.snapshotSlot(snapshotToken, index));

        assertNotEq(counts, snapshot);
    }

    function check_noStorageLayoutCollisions_snapshotSlot_snapshotSlot(address token, uint256 index0, uint256 index1)
        public
        pure
    {
        index0 = bound(index0, 0, type(uint32).max);
        index1 = bound(index1, 0, type(uint32).max);
        vm.assume(index0 != index1);

        bytes32 snapshot0 = StorageSlot.unwrap(OracleStorageLayout.snapshotSlot(token, index0));
        bytes32 snapshot1 = StorageSlot.unwrap(OracleStorageLayout.snapshotSlot(token, index1));

        assertNotEq(snapshot0, snapshot1);
    }
}
