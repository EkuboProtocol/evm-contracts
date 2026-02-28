// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";

type ControllerAddress is address;

using {isEoa, isSignatureValid} for ControllerAddress global;

function isEoa(ControllerAddress controller) pure returns (bool result) {
    assembly ("memory-safe") {
        result := iszero(shr(159, controller))
    }
}

function isSignatureValid(ControllerAddress controller, bytes32 digest, bytes memory signature)
    view
    returns (bool valid)
{
    if (controller.isEoa()) {
        return ECDSA.recover(digest, signature) == ControllerAddress.unwrap(controller);
    }
    return SignatureCheckerLib.isValidERC1271SignatureNow(ControllerAddress.unwrap(controller), digest, signature);
}
