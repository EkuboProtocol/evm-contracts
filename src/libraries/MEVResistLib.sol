// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {MEVResist} from "../extensions/MEVResist.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";

library MEVResistLib {
    using ExposedStorageLib for *;

    function poolState(MEVResist mevResist, bytes32 poolId)
        internal
        view
        returns (uint32 lastUpdateTime, int32 tickLast, uint96 fees0, uint96 fees1)
    {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 0)
            key := keccak256(0, 64)
        }

        bytes32 s = mevResist.sload(key);

        assembly ("memory-safe") {
            lastUpdateTime := and(s, 0xffffffff)
            tickLast := and(shr(32, s), 0xffffffff)
            fees0 := and(shr(64, s), 0xffffffffffffffffffffffff)
            fees1 := shr(160, s)
        }
    }
}
