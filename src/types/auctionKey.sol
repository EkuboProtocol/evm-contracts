// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {AuctionConfig} from "./auctionConfig.sol";
import {OrderKey} from "./orderKey.sol";
import {createOrderConfig} from "./orderConfig.sol";
import {PoolKey} from "./poolKey.sol";
import {createFullRangePoolConfig, createConcentratedPoolConfig} from "./poolConfig.sol";

using {sellToken, buyToken, toOrderKey, toLaunchPoolKey, toGraduationPoolKey} for AuctionKey global;

/// @notice Auction key structure identifying an auction
struct AuctionKey {
    /// @notice Address of token0 (must be < token1)
    address token0;
    /// @notice Address of token1 (must be > token0)
    address token1;
    /// @notice Packed auction configuration
    AuctionConfig config;
}

error InvalidTokenOrder();

/// @notice Extracts the sell token from an auction key
function sellToken(AuctionKey memory auctionKey) pure returns (address r) {
    bool sellingToken1 = auctionKey.config.isSellingToken1();
    assembly ("memory-safe") {
        r := mload(add(auctionKey, mul(sellingToken1, 0x20)))
    }
}

/// @notice Extracts the quote token (the purchased token) from an auction key
function buyToken(AuctionKey memory auctionKey) pure returns (address r) {
    bool sellingToken0 = !auctionKey.config.isSellingToken1();
    assembly ("memory-safe") {
        r := mload(add(auctionKey, mul(sellingToken0, 0x20)))
    }
}

/// @notice Converts an AuctionKey to its corresponding OrderKey
function toOrderKey(AuctionKey memory auctionKey) pure returns (OrderKey memory orderKey) {
    orderKey = OrderKey({
        token0: auctionKey.token0,
        token1: auctionKey.token1,
        config: createOrderConfig({
            _fee: 0,
            _isToken1: auctionKey.config.isSellingToken1(),
            _startTime: uint64(auctionKey.config.startTime()),
            _endTime: auctionKey.config.endTime()
        })
    });
}

/// @notice Converts an AuctionKey to its launch pool key
function toLaunchPoolKey(AuctionKey memory auctionKey, address twamm) pure returns (PoolKey memory poolKey) {
    poolKey = PoolKey({
        token0: auctionKey.token0,
        token1: auctionKey.token1,
        config: createFullRangePoolConfig({_fee: 0, _extension: twamm})
    });
}

/// @notice Converts an AuctionKey to its graduation pool key
function toGraduationPoolKey(AuctionKey memory auctionKey, address boostedFees) pure returns (PoolKey memory poolKey) {
    poolKey = PoolKey({
        token0: auctionKey.token0,
        token1: auctionKey.token1,
        config: createConcentratedPoolConfig(
            auctionKey.config.graduationPoolFee(), auctionKey.config.graduationPoolTickSpacing(), boostedFees
        )
    });
}

