// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CoreStorageLayout} from "./CoreStorageLayout.sol";

contract Core is CoreStorageLayout {
    constructor(address _owner) {
        owner = _owner;
    }

    function lock(bytes calldata data) external {}
}
