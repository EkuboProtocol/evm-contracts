// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {MarketId} from "./marketId.sol";
import {MoneyMarketConfig} from "./moneyMarketConfig.sol";

using {toMarketId, validate} for MarketKey global;

/// @notice Unique identifier key for a money market containing collateral/debt token addresses and market configuration
struct MarketKey {
    address collateralToken;
    address debtToken;
    MoneyMarketConfig config;
}

error MarketTokensMustDiffer();

function validate(MarketKey memory key) pure {
    if (key.collateralToken == key.debtToken) revert MarketTokensMustDiffer();
}

function toMarketId(MarketKey memory key) pure returns (MarketId result) {
    address token0;
    address token1;
    (token0, token1) = key.collateralToken < key.debtToken
        ? (key.collateralToken, key.debtToken)
        : (key.debtToken, key.collateralToken);
    // Market identity is pair + TWAMM pool fee. Risk parameters in config can be updated over time for the same market.
    result = MarketId.wrap(keccak256(abi.encodePacked(token0, token1, key.config.poolFee())));
}
