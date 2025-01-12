// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {OwnedUpgradeable} from "./base/OwnedUpgradeable.sol";
import {CallPoints, byteToCallPoints} from "./types/call_points.sol";

contract Core is OwnedUpgradeable {
    mapping(address => bool) public isExtensionRegistered;

    // Extensions must call this function to become registered. The call points are validated against the caller address
    function registerExtension(CallPoints memory expectedCallPoints) external onlyProxy {
        uint8 b;
        assembly ("memory-safe") {
            b := and(shr(160, caller()), 0xff)
        }
        CallPoints memory computed = byteToCallPoints(b);
        if (!computed.eq(expectedCallPoints)) {}
        isExtensionRegistered[msg.sender] = true;
    }

    // The entrypoint for all operations on the core contract
    function lock(bytes calldata data) external onlyProxy {}
}
