// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

contract Core {
    error DelegateCallOnly();

    address public owner;

    constructor(address _owner) {
        owner = _owner;
    }

    function lock(bytes calldata data) external {}
}
