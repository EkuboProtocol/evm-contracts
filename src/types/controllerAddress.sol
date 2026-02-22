// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type ControllerAddress is address;

using {isEoa} for ControllerAddress global;

function isEoa(ControllerAddress controller) pure returns (bool result) {
    assembly ("memory-safe") {
        result := iszero(shr(159, controller))
    }
}
