// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

contract Core {
    error DelegateCallOnly();

    address public immutable owner;

    // slot 0 is always the code address
    address public codeAddress;

    constructor(address _owner) {
        owner = _owner;
    }

    modifier onlyDelegateCall() {
        if (codeAddress == address(this)) revert DelegateCallOnly();
        _;
    }

    function lock(bytes calldata data) external onlyDelegateCall {}
}
