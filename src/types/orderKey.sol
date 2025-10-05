// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {PoolKey} from "./poolKey.sol";
import {OrderConfig} from "./orderConfig.sol";

using {toOrderId, toPoolKey, fee, startTime, endTime} for OrderKey global;

/// @notice Extracts the fee from an order key
/// @param ok The order key
/// @return r The fee
function fee(OrderKey memory ok) pure returns (uint64 r) {
    return ok.config.fee();
}

/// @notice Extracts the start time from an order key
/// @param ok The order key
/// @return r The start time
function startTime(OrderKey memory ok) pure returns (uint64 r) {
    return ok.config.startTime();
}

/// @notice Extracts the end time from an order key
/// @param ok The order key
/// @return r The end time
function endTime(OrderKey memory ok) pure returns (uint64 r) {
    return ok.config.endTime();
}

/// @notice Order key structure identifying a TWAMM order
/// @dev Contains all parameters needed to uniquely identify an order
struct OrderKey {
    /// @notice Token being sold
    address sellToken;
    /// @notice Token being bought
    address buyToken;
    /// @notice Packed configuration containing fee, start, and end time
    OrderConfig config;
}

/// @notice Computes the order ID from an order key
/// @param orderKey The order key
/// @return id The computed order ID
function toOrderId(OrderKey memory orderKey) pure returns (bytes32 id) {
    assembly ("memory-safe") {
        id := keccak256(orderKey, 96)
    }
}

/// @notice Converts an OrderKey to its corresponding PoolKey
/// @dev Determines the correct token ordering and constructs the pool key with TWAMM as extension
/// @param orderKey The order key containing sell/buy tokens and fee
/// @param twamm The TWAMM contract address to use as the extension
/// @return poolKey The corresponding pool key for the order
function toPoolKey(OrderKey memory orderKey, address twamm) pure returns (PoolKey memory poolKey) {
    uint256 _fee = orderKey.config.fee();

    assembly ("memory-safe") {
        poolKey := mload(0x40)

        let sellToken := mload(orderKey)
        let buyToken := mload(add(orderKey, 32))

        let xoredTokens := xor(sellToken, buyToken)
        let sellIsZero := gt(buyToken, sellToken)

        let token0 := xor(sellToken, mul(xoredTokens, iszero(sellIsZero)))
        let token1 := xor(sellToken, mul(xoredTokens, sellIsZero))

        mstore(poolKey, token0)
        mstore(add(poolKey, 32), token1)
        mstore(add(poolKey, 64), add(shl(96, twamm), shl(32, _fee)))

        // move free memory pointer forward 96 bytes
        mstore(0x40, add(poolKey, 96))
    }
}
