// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type TWAMMRecoverablePairConfig is bytes32;

using {
    collateralFactorBps,
    triggerHealthFactorX18,
    cancelHealthFactorX18,
    configured,
    parse
} for TWAMMRecoverablePairConfig global;

function collateralFactorBps(TWAMMRecoverablePairConfig config) pure returns (uint16 v) {
    assembly ("memory-safe") {
        v := and(config, 0xFFFF)
    }
}

function triggerHealthFactorX18(TWAMMRecoverablePairConfig config) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := and(shr(16, config), 0xFFFFFFFFFFFFFFFF)
    }
}

function cancelHealthFactorX18(TWAMMRecoverablePairConfig config) pure returns (uint64 v) {
    assembly ("memory-safe") {
        v := and(shr(80, config), 0xFFFFFFFFFFFFFFFF)
    }
}

function configured(TWAMMRecoverablePairConfig config) pure returns (bool v) {
    assembly ("memory-safe") {
        v := and(shr(144, config), 1)
    }
}

function parse(TWAMMRecoverablePairConfig config)
    pure
    returns (
        uint16 _collateralFactorBps,
        uint64 _triggerHealthFactorX18,
        uint64 _cancelHealthFactorX18,
        bool _configured
    )
{
    _collateralFactorBps = config.collateralFactorBps();
    _triggerHealthFactorX18 = config.triggerHealthFactorX18();
    _cancelHealthFactorX18 = config.cancelHealthFactorX18();
    _configured = config.configured();
}

function createTWAMMRecoverablePairConfig(
    uint16 _collateralFactorBps,
    uint64 _triggerHealthFactorX18,
    uint64 _cancelHealthFactorX18,
    bool _configured
) pure returns (TWAMMRecoverablePairConfig config) {
    assembly ("memory-safe") {
        config := or(
            or(or(_collateralFactorBps, shl(16, _triggerHealthFactorX18)), shl(80, _cancelHealthFactorX18)),
            shl(144, _configured)
        )
    }
}
