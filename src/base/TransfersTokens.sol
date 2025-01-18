// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "../interfaces/ICore.sol";

// Helper methods for simplifying transfer of tokens related to ICore
abstract contract TransfersTokens {
    function transferToken(address token, address recipient, uint256 amount) internal {
        if (token == NATIVE_TOKEN_ADDRESS) {
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(token, recipient, amount);
        }
    }

    function transferTokenFrom(address token, address spender, address recipient, uint256 amount) internal {
        assert(NATIVE_TOKEN_ADDRESS != token);
        SafeTransferLib.safeTransferFrom(token, spender, recipient, amount);
    }
}
