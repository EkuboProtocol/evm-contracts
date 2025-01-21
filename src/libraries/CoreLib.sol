// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ICore} from "../interfaces/ICore.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";

// Common storage getters we need for external contracts are defined here instead of in the core contract
library CoreLib {
    using ExposedStorageLib for *;

    function poolPrice(ICore core, bytes32 poolId) internal view returns (uint192 sqrtRatio, int32 tick) {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 2)
            key := keccak256(0, 64)
        }

        bytes32 result = core.unsafeRead(key);

        assembly ("memory-safe") {
            sqrtRatio := and(result, 0xffffffffffffffffffffffffffffffffffffffffffffffff)
            tick := shr(192, result)
        }
    }

    function poolLiquidity(ICore core, bytes32 poolId) internal view returns (uint128 liquidity) {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 3)
            key := keccak256(0, 64)
        }

        bytes32 result = core.unsafeRead(key);

        assembly ("memory-safe") {
            liquidity := and(result, 0xffffffffffffffffffffffffffffffff)
        }
    }
}
