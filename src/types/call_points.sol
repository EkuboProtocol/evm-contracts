// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

struct CallPoints {
    bool before_initialize_pool;
    bool after_initialize_pool;
    bool before_swap;
    bool after_swap;
    bool before_update_position;
    bool after_update_position;
    bool before_collect_fees;
    bool after_collect_fees;
}

function byteToCallPoints(uint8 b) pure returns (CallPoints memory result) {
    // note the order of bytes does not match the struct order of elements because we are matching the cairo implementation
    // which for legacy reasons has the fields in this order
    result = CallPoints({
        before_initialize_pool: (b & 1) != 0,
        after_initialize_pool: (b & 128) != 0,
        before_swap: (b & 64) != 0,
        after_swap: (b & 32) != 0,
        before_update_position: (b & 16) != 0,
        after_update_position: (b & 8) != 0,
        before_collect_fees: (b & 4) != 0,
        after_collect_fees: (b & 2) != 0
    });
}
