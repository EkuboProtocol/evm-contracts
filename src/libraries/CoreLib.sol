// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ICore} from "../interfaces/ICore.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {Position} from "../types/position.sol";

// Common storage getters we need for external contracts are defined here instead of in the core contract
library CoreLib {
    using ExposedStorageLib for *;

    function protocolFeesCollected(ICore core, address token) internal view returns (uint256 amountCollected) {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, token)
            mstore(32, 1)
            key := keccak256(0, 64)
        }

        amountCollected = uint256(core.unsafeRead(key));
    }

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

    function poolPositions(ICore core, bytes32 poolId, bytes32 positionId)
        internal
        view
        returns (Position memory position)
    {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 5)
            let b := keccak256(0, 64)
            mstore(0, positionId)
            mstore(32, b)
            key := keccak256(0, 64)
        }

        position.liquidity = uint128(uint256(core.unsafeRead(key)));
        position.feesPerLiquidityInsideLast = FeesPerLiquidity(
            uint256(core.unsafeRead(bytes32(uint256(key) + 1))), uint256(core.unsafeRead(bytes32(uint256(key) + 2)))
        );
    }

    function savedBalances(ICore core, address owner, address token, bytes32 salt)
        internal
        view
        returns (uint256 savedBalance)
    {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, owner)
            mstore(32, 9)
            key := keccak256(0, 64)
            mstore(0, token)
            mstore(32, key)
            key := keccak256(0, 64)
            mstore(0, salt)
            mstore(32, key)
            key := keccak256(0, 64)
        }

        savedBalance = uint256(core.unsafeRead(key));
    }
}
