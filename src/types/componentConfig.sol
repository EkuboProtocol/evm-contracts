// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

type ComponentConfig is bytes32;

using {token, weight, twammFee, parse} for ComponentConfig global;

function token(ComponentConfig config) pure returns (address r) {
    assembly ("memory-safe") {
        r := shr(96, config)
    }
}

function weight(ComponentConfig config) pure returns (uint32 r) {
    assembly ("memory-safe") {
        r := and(config, 0xffffffff)
    }
}

function twammFee(ComponentConfig config) pure returns (uint64 r) {
    assembly ("memory-safe") {
        r := and(shr(32, config), 0xffffffffffffffff)
    }
}

function parse(ComponentConfig config) pure returns (address t, uint32 w, uint64 f) {
    assembly ("memory-safe") {
        t := shr(96, config)
        w := and(config, 0xffffffff)
        f := and(shr(32, config), 0xffffffffffffffff)
    }
}

function createComponentConfig(address _token, uint32 _weight, uint64 _twammFee) pure returns (ComponentConfig c) {
    assembly ("memory-safe") {
        c := or(shl(96, _token), or(shl(32, and(_twammFee, 0xffffffffffffffff)), and(_weight, 0xffffffff)))
    }
}
