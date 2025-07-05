// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

using {toSavedBalanceId} for SavedBalanceKey global;

struct SavedBalanceKey {
    address owner;
    address token0;
    address token1;
    bytes32 salt;
}

function toSavedBalanceId(SavedBalanceKey calldata key) pure returns (bytes16 result) {
    assembly ("memory-safe") {
        let free := mload(0x40)
        calldatacopy(free, key, 128)
        result := shr(128, keccak256(free, 128))
    }
}
