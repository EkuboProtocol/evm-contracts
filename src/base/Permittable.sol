// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

// Contains a single method which allows a user to approve this contract via permit2
// Combining with Multicallable is highly recommended, so that the permit signature can be used to spend tokens in a single transaction
// Note this only allows the msg.sender to execute a permit. Our contracts are not intended for use with some types of contract based account abstraction.
contract Permittable {
    // Method is payable in case it is paired with other payable Multicallable calls
    function permit(address token, uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external payable {
        SafeTransferLib.permit2(token, msg.sender, address(this), amount, deadline, v, r, s);
    }
}
