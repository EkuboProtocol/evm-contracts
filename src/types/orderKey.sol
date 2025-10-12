// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {PoolKey} from "./poolKey.sol";
import {OrderConfig} from "./orderConfig.sol";
import {OrderId} from "./orderId.sol";

using {toOrderId, toPoolKey, buyToken, sellToken} for OrderKey global;

/// @notice Order key structure identifying a TWAMM order
/// @dev Contains all parameters needed to uniquely identify an order
struct OrderKey {
    /// @notice Address of token0 (must be < token1)
    address token0;
    /// @notice Address of token1 (must be > token0)
    address token1;
    /// @notice Packed configuration containing fee, isToken1, start, and end time
    OrderConfig config;
}

/// @notice Extracts the buy token from an order key
/// @param ok The order key
/// @return r The buy token
function buyToken(OrderKey memory ok) pure returns (address r) {
    bool _isToken0 = !ok.config.isToken1();
    assembly ("memory-safe") {
        r := mload(add(ok, mul(_isToken0, 0x20)))
    }
}

/// @notice Extracts the sell token from an order key
/// @param ok The order key
/// @return r The sell token
function sellToken(OrderKey memory ok) pure returns (address r) {
    bool _isToken1 = ok.config.isToken1();
    assembly ("memory-safe") {
        r := mload(add(ok, mul(_isToken1, 0x20)))
    }
}

/// @notice Computes the order ID from an order key
/// @param orderKey The order key
/// @return id The computed order ID
function toOrderId(OrderKey memory orderKey) pure returns (OrderId id) {
    assembly ("memory-safe") {
        id := keccak256(orderKey, 96)
    }
}

/// @notice Converts an OrderKey to its corresponding PoolKey
/// @dev Reconstructs the full pool config from the truncated config in OrderConfig
/// @param orderKey The order key containing sell/buy tokens and truncated pool config
/// @param twamm The TWAMM contract address to use as the extension
/// @return poolKey The corresponding pool key for the order
function toPoolKey(OrderKey memory orderKey, address twamm) pure returns (PoolKey memory poolKey) {
    assembly ("memory-safe") {
        mcopy(poolKey, orderKey, 64)
    }
    poolKey.config = orderKey.config.toPoolConfig(twamm);
}
