// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {TWAMM} from "../extensions/TWAMM.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";

// Common storage getters we need for external contracts are defined here instead of in the core contract
library TWAMMLib {
    using ExposedStorageLib for *;

    function ordersState(TWAMM twamm, bytes32 poolId)
        internal
        view
        returns (uint32 lastVirtualOrderExecutionTime, uint112 saleRateToken0, uint112 saleRateToken1)
    {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 0)
            key := keccak256(0, 64)
        }

        bytes32 s = twamm.unsafeRead(key);

        assembly ("memory-safe") {
            lastVirtualOrderExecutionTime := and(s, 0xffffffff)
            saleRateToken0 := and(shr(32, s), 0xffffffffffffffffffffffffffff)
            saleRateToken1 := shr(144, s)
        }
    }
}
