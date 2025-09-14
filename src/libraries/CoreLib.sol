// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ICore} from "../interfaces/ICore.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {Position} from "../types/position.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {PoolKey} from "../types/poolKey.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

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

        registered = uint256(core.sload(key)) != 0;
    }

    function poolState(ICore core, bytes32 poolId)
        internal
        view
        returns (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity)
    {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 1)
            key := keccak256(0, 64)
        }

        bytes32 p = core.sload(key);

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
            mstore(32, 3)
            let b := keccak256(0, 64)
            mstore(0, positionId)
            mstore(32, b)
            key := keccak256(0, 64)
        }

        (bytes32 v0, bytes32 v1, bytes32 v2) = core.sload(key, bytes32(uint256(key) + 1), bytes32(uint256(key) + 2));

        position.liquidity = uint128(uint256(v0));
        position.feesPerLiquidityInsideLast = FeesPerLiquidity(uint256(v1), uint256(v2));
    }

    function savedBalances(ICore core, address owner, address token0, address token1, bytes32 salt)
        internal
        view
        returns (uint128 savedBalance0, uint128 savedBalance1)
    {
        bytes32 key;
        assembly ("memory-safe") {
            let free := mload(0x40)
            mstore(free, owner)
            mstore(add(free, 0x20), token0)
            mstore(add(free, 0x40), token1)
            mstore(add(free, 0x60), salt)
            mstore(0, keccak256(free, 128))
            mstore(32, 7)
            key := keccak256(0, 64)
        }

        uint256 value = uint256(core.sload(key));

        savedBalance0 = uint128(value >> 128);
        savedBalance1 = uint128(value);
    }

    function poolTicks(ICore core, bytes32 poolId, int32 tick)
        internal
        view
        returns (int128 liquidityDelta, uint128 liquidityNet)
    {
        bytes32 key;
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 4)
            let b := keccak256(0, 64)
            mstore(0, tick)
            mstore(32, b)
            key := keccak256(0, 64)
        }

        bytes32 data = core.sload(key);

        // takes only least significant 128 bits
        liquidityDelta = int128(uint128(uint256(data)));
        // takes only most significant 128 bits
        liquidityNet = uint128(bytes16(data));
    }

    function swap(
        ICore core,
        uint256 value,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) internal returns (int128 delta0, int128 delta1) {
        (delta0, delta1) = core.swap_611415377{value: value}(poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);
    }
}
