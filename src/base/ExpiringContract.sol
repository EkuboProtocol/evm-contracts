// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

abstract contract ExpiringContract {
    error ContractHasExpired();

    // The time after which the contract will no longer allow swaps or position updates with non-negative liquidity delta
    uint256 public immutable expirationTime;

    constructor(uint256 _expirationTime) {
        expirationTime = _expirationTime;
    }

    modifier expiresIff(bool enforce) {
        if (enforce && block.timestamp > expirationTime) revert ContractHasExpired();
        _;
    }

    modifier expires() {
        if (block.timestamp > expirationTime) revert ContractHasExpired();
        _;
    }
}
