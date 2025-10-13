// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {IRevenueBuybacks} from "../interfaces/IRevenueBuybacks.sol";
import {BuybacksState} from "../types/buybacksState.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";

/// @title Oracle Library
/// @notice Library providing helper methods for accessing Oracle data
library RevenueBuybacksLib {
    using ExposedStorageLib for *;

    /// @notice Gets the counts and metadata for snapshots of a token
    /// @param rb The revenue buybacks contract
    /// @param token The token address
    /// @return s The state of the buybacks for the token
    function state(IRevenueBuybacks rb, address token) internal view returns (BuybacksState s) {
        s = BuybacksState.wrap(rb.sload(bytes32(uint256(uint160(token)))));
    }

    /// @notice Gets the counts and metadata for snapshots of a token
    /// @param rb The revenue buybacks contract
    /// @param tokenA The first of two addresses to lookup
    /// @param tokenB The second of two addresses to lookup
    /// @return sA The state of the buybacks for tokenA
    /// @return sB The state of the buybacks for tokenB
    function state(IRevenueBuybacks rb, address tokenA, address tokenB)
        internal
        view
        returns (BuybacksState sA, BuybacksState sB)
    {
        (bytes32 stateARaw, bytes32 stateBRaw) =
            rb.sload(bytes32(uint256(uint160(tokenA))), bytes32(uint256(uint160(tokenB))));
        sA = BuybacksState.wrap(stateARaw);
        sB = BuybacksState.wrap(stateBRaw);
    }
}
