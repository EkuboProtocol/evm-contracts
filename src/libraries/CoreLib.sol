// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ICore} from "../interfaces/ICore.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";
import {FeesPerLiquidity} from "../types/feesPerLiquidity.sol";
import {Position} from "../types/position.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {PoolKey} from "../types/poolKey.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

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
        returns (uint128 savedBalance)
    {
        bytes32 key = EfficientHashLib.hash(
            bytes32(uint256(uint160(owner))),
            bytes32(uint256(uint160(token))),
            bytes32(uint256(type(uint160).max)),
            salt
        );
        assembly ("memory-safe") {
            mstore(0, key)
            mstore(32, 8)
            key := keccak256(0, 64)
        }

        savedBalance = uint128(uint256(core.unsafeRead(key)) >> 128);
    }

    function savedBalances(ICore core, address owner, address token0, address token1, bytes32 salt)
        internal
        view
        returns (uint128 savedBalance0, uint128 savedBalance1)
    {
        bytes32 key = EfficientHashLib.hash(
            bytes32(uint256(uint160(owner))), bytes32(uint256(uint160(token0))), bytes32(uint256(uint160(token1))), salt
        );
        assembly ("memory-safe") {
            mstore(0, key)
            mstore(32, 8)
            key := keccak256(0, 64)
        }

        savedBalance0 = uint128(uint256(core.unsafeRead(key)) >> 128);
        savedBalance1 = uint128(uint256(core.unsafeRead(key)));
    }

    function savedBalances(
        ICore core,
        address owner,
        address token0,
        address token1,
        address token2,
        address token3,
        bytes32 salt
    ) internal view returns (uint64 savedBalance0, uint64 savedBalance1, uint64 savedBalance2, uint64 savedBalance3) {
        bytes32 key = EfficientHashLib.hash(
            bytes32(uint256(uint160(owner))),
            bytes32(uint256(uint160(token0))),
            bytes32(uint256(uint160(token1))),
            bytes32(uint256(uint160(token2))),
            bytes32(uint256(uint160(token3))),
            salt
        );
        assembly ("memory-safe") {
            mstore(0, key)
            mstore(32, 8)
            key := keccak256(0, 64)
        }

        savedBalance0 = uint64(uint256(core.unsafeRead(key)) >> 192);
        savedBalance1 = uint64(uint256(core.unsafeRead(key)) >> 128);
        savedBalance2 = uint64(uint256(core.unsafeRead(key)) >> 64);
        savedBalance3 = uint64(uint256(core.unsafeRead(key)));
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

    function save(ICore core, address owner, address token, bytes32 salt, uint128 amount) internal {
        core.save(owner, token, address(type(uint160).max), salt, amount, 0);
    }

    function load(ICore core, address token, bytes32 salt, uint128 amount) internal {
        core.load2(token, address(type(uint160).max), salt, amount, 0);
    }
}
