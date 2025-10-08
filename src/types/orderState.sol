// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

type OrderState is bytes32;

using {lastUpdateTime, saleRate, amountSold, parse} for OrderState global;

/// @notice Extracts the last update time from order state
/// @param state The order state
/// @return time The last update time value, bounded by uint32
function lastUpdateTime(OrderState state) pure returns (uint256 time) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
    }
}

/// @notice Extracts the sale rate from order state
/// @param state The order state
/// @return rate The sale rate value, bounded by uint112
function saleRate(OrderState state) pure returns (uint256 rate) {
    assembly ("memory-safe") {
        rate := shr(144, shl(112, state))
    }
}

/// @notice Extracts the amount sold from order state
/// @param state The order state
/// @return amount The amount sold value, bounded by uint112
function amountSold(OrderState state) pure returns (uint256 amount) {
    assembly ("memory-safe") {
        amount := shr(144, state)
    }
}

/// @notice Parses all components from order state
/// @param state The order state
/// @return time The last update time value, bounded by uint32
/// @return rate The sale rate value, bounded by uint112
/// @return amount The amount sold value, bounded by uint112
function parse(OrderState state) pure returns (uint256 time, uint256 rate, uint256 amount) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
        rate := shr(144, shl(112, state))
        amount := shr(144, state)
    }
}

function createOrderState(uint32 _lastUpdateTime, uint112 _saleRate, uint112 _amountSold) pure returns (OrderState s) {
    assembly ("memory-safe") {
        // s = (lastUpdateTime) | (saleRate << 32) | (amountSold << 144)
        s :=
            or(
                or(and(_lastUpdateTime, 0xffffffff), shl(32, shr(144, shl(144, _saleRate)))),
                shl(144, shr(144, shl(144, _amountSold)))
            )
    }
}
