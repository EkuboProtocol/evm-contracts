// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {StorageSlot} from "../types/storageSlot.sol";

/// @title Revenue Buybacks Storage Layout
/// @notice Helpers for computing storage slots used by RevenueBuybacks
library RevenueBuybacksStorageLayout {
    // Hash of "RevenueBuybacks#REVENUE_BUYBACKS_STATE".
    // We namespace the per-token state under this offset so inherited contracts can add
    // their own storage without colliding with revenue buybacks state.
    bytes32 internal constant REVENUE_BUYBACKS_STATE_OFFSET =
        0xc6db6d24c7fc1ab060ee7ff7c368e32e8e9b63547557d8d4162bdbdf2af91213;

    function stateSlot(address token) internal pure returns (StorageSlot slot) {
        assembly ("memory-safe") {
            mstore(0x00, token)
            mstore(0x20, REVENUE_BUYBACKS_STATE_OFFSET)
            slot := keccak256(0x00, 0x40)
        }
    }
}
