// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ICore} from "../interfaces/ICore.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {Position} from "../types/position.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";

// Common storage getters we need for external contracts are defined here instead of in the core contract
library CoreLib {
    using ExposedStorageLib for *;

    function isExtensionRegistered(ICore core, address extension) internal view returns (bool registered) {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, extension)
            mstore(32, 0)
            key := keccak256(0, 64)
        }

        registered = uint256(core.unsafeRead(key)) != 0;
    }

    function protocolFeesCollected(ICore core, address token) internal view returns (uint256 amountCollected) {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, token)
            mstore(32, 1)
            key := keccak256(0, 64)
        }

        amountCollected = uint256(core.unsafeRead(key));
    }

    function poolState(ICore core, bytes32 poolId)
        internal
        view
        returns (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity)
    {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 2)
            key := keccak256(0, 64)
        }

        bytes32 p = core.unsafeRead(key);

        assembly ("memory-safe") {
            sqrtRatio := and(p, 0xffffffffffffffffffffffff)
            tick := and(shr(96, p), 0xffffffff)
            liquidity := shr(128, p)
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
            mstore(32, 4)
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
            mstore(32, 8)
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

    function poolTicks(ICore core, bytes32 poolId, int32 tick)
        internal
        view
        returns (int128 liquidityDelta, uint128 liquidityNet)
    {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 5)
            let b := keccak256(0, 64)
            mstore(0, tick)
            mstore(32, b)
            key := keccak256(0, 64)
        }

        bytes32 data = core.unsafeRead(key);

        // takes only least significant 128 bits
        liquidityDelta = int128(uint128(uint256(data)));
        // takes only most significant 128 bits
        liquidityNet = uint128(bytes16(data));
    }
}
