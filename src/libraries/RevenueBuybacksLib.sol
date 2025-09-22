// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

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
}
