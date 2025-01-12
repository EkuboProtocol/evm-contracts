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

using {eq} for CallPoints global;

function eq(CallPoints memory a, CallPoints memory b) pure returns (bool) {
    return (
        a.before_initialize_pool == b.before_initialize_pool && a.after_initialize_pool == b.after_initialize_pool
            && a.before_swap == b.before_swap && a.after_swap == b.after_swap
            && a.before_update_position == b.before_update_position && a.after_update_position == b.after_update_position
            && a.before_collect_fees == b.before_collect_fees && a.after_collect_fees == b.after_collect_fees
    );
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
