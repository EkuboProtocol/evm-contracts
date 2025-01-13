// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

struct CallPoints {
    bool beforeInitializePool;
    bool afterInitializePool;
    bool beforeSwap;
    bool afterSwap;
    bool beforeUpdatePosition;
    bool afterUpdatePosition;
    bool beforeCollectFees;
    bool afterCollectFees;
}

using {eq} for CallPoints global;

function eq(CallPoints memory a, CallPoints memory b) pure returns (bool) {
    return (
        a.beforeInitializePool == b.beforeInitializePool && a.afterInitializePool == b.afterInitializePool
            && a.beforeSwap == b.beforeSwap && a.afterSwap == b.afterSwap
            && a.beforeUpdatePosition == b.beforeUpdatePosition && a.afterUpdatePosition == b.afterUpdatePosition
            && a.beforeCollectFees == b.beforeCollectFees && a.afterCollectFees == b.afterCollectFees
    );
}

function byteToCallPoints(uint8 b) pure returns (CallPoints memory result) {
    // note the order of bytes does not match the struct order of elements because we are matching the cairo implementation
    // which for legacy reasons has the fields in this order
    result = CallPoints({
        beforeInitializePool: (b & 1) != 0,
        afterInitializePool: (b & 128) != 0,
        beforeSwap: (b & 64) != 0,
        afterSwap: (b & 32) != 0,
        beforeUpdatePosition: (b & 16) != 0,
        afterUpdatePosition: (b & 8) != 0,
        beforeCollectFees: (b & 4) != 0,
        afterCollectFees: (b & 2) != 0
    });
}

function shouldCallBeforeInitializePool(address a) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(152, a), 1)
    }
}

function shouldCallAfterInitializePool(address a) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(159, a), 1)
    }
}

function shouldCallBeforeSwap(address a) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(158, a), 1)
    }
}

function shouldCallAfterSwap(address a) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(157, a), 1)
    }
}

function shouldCallBeforeUpdatePosition(address a) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(156, a), 1)
    }
}

function shouldCallAfterUpdatePosition(address a) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(155, a), 1)
    }
}

function shouldCallBeforeCollectFees(address a) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(154, a), 1)
    }
}

function shouldCallAfterCollectFees(address a) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(153, a), 1)
    }
}
