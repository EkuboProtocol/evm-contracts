// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

// This address should never be used by any other chain but also has lots of zeroes so it still works well with calldata compression
// We also know this address will always be token0
address constant NATIVE_TOKEN_ADDRESS = address(0x0000000000000000000000000000eeEEee000000);

// Helper methods for simplifying transfer of tokens
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
