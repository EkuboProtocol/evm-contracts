// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {OwnedUpgradeable} from "./base/OwnedUpgradeable.sol";

contract Core is OwnedUpgradeable {
    // The entrypoint for all operations on the core contract
    function lock(bytes calldata data) external onlyProxy {}
}
