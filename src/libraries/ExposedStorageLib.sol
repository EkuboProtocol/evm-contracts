// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {IExposedStorage} from "../interfaces/IExposedStorage.sol";

library ExposedStorageLib {
    function unsafeRead(IExposedStorage target, bytes32 slot) internal view returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0, 0xf4910a7300000000000000000000000000000000000000000000000000000000)
            mstore(4, slot)

            pop(staticcall(gas(), target, 0, 36, 0, 32))

            result := mload(0)
        }
    }

    function unsafeReadTransient(IExposedStorage target, bytes32 slot) internal view returns (bytes32 result) {
        assembly ("memory-safe") {
            mstore(0, 0xbd2e587d00000000000000000000000000000000000000000000000000000000)
            mstore(4, slot)

            pop(staticcall(gas(), target, 0, 36, 0, 32))

            result := mload(0)
        }
    }
}
