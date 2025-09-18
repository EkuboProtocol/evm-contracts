// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";

using {validateBounds, toPositionId} for PositionKey global;

// todo: this should fit a single bytes32 word, if we just make room in the salt
struct PositionKey {
    bytes32 salt;
    int32 tickLower;
    int32 tickUpper;
}

error BoundsOrder();
error MinMaxBounds();
error BoundsTickSpacing();
error FullRangeOnlyPool();

function validateBounds(PositionKey memory positionKey, uint32 tickSpacing) pure {
    if (tickSpacing == FULL_RANGE_ONLY_TICK_SPACING) {
        if (positionKey.tickLower != MIN_TICK || positionKey.tickUpper != MAX_TICK) revert FullRangeOnlyPool();
    } else {
        if (positionKey.tickLower >= positionKey.tickUpper) revert BoundsOrder();
        if (positionKey.tickLower < MIN_TICK || positionKey.tickUpper > MAX_TICK) revert MinMaxBounds();
        int32 spacing = int32(tickSpacing);
        if (positionKey.tickLower % spacing != 0 || positionKey.tickUpper % spacing != 0) revert BoundsTickSpacing();
    }
}

function toPositionId(PositionKey memory key, address owner) pure returns (bytes32 result) {
    assembly ("memory-safe") {
        let freeMem := mload(0x40)
        mcopy(freeMem, key, 96)
        mstore(add(freeMem, 96), owner)
        result := keccak256(freeMem, 128)
    }
}
