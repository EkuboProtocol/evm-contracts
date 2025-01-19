// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract Permittable {
    function permit(address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        SafeTransferLib.permit2(token, msg.sender, address(this), amount, deadline, v, r, s);
    }
}
