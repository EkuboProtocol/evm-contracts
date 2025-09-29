// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {SqrtRatio} from "./sqrtRatio.sol";

type SwapParameters is bytes32;

using {sqrtRatioLimit, amount, isToken1, skipAhead, isExactOut, isPriceIncreasing} for SwapParameters global;

function sqrtRatioLimit(SwapParameters params) pure returns (SqrtRatio r) {
    assembly ("memory-safe") {
        r := shr(160, params)
    }
}

function amount(SwapParameters params) pure returns (int128 a) {
    assembly ("memory-safe") {
        a := signextend(15, shr(32, params))
    }
}

function isExactOut(SwapParameters params) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(159, params), 1)
    }
}

function isPriceIncreasing(SwapParameters params) pure returns (bool yes) {
    assembly ("memory-safe") {
        let sign := and(shr(159, params), 1)
        yes := xor(sign, and(shr(31, params), 1))
    }
}

function isToken1(SwapParameters params) pure returns (bool t) {
    assembly ("memory-safe") {
        t := and(shr(31, params), 1)
    }
}

function skipAhead(SwapParameters params) pure returns (uint256 s) {
    assembly ("memory-safe") {
        s := and(params, 0x7fffffff)
    }
}

function createSwapParameters(SqrtRatio _sqrtRatioLimit, int128 _amount, bool _isToken1, uint256 _skipAhead)
    pure
    returns (SwapParameters p)
{
    assembly ("memory-safe") {
        // p = (sqrtRatioLimit << 160) | (amount << 32) | (isToken1 << 31) | skipAhead
        // Mask each field to ensure dirty bits don't interfere
        // For isToken1, use iszero(iszero()) to convert any non-zero value to 1
        p :=
            or(
                shl(160, _sqrtRatioLimit),
                or(
                    shl(32, and(_amount, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)),
                    or(shl(31, iszero(iszero(_isToken1))), and(_skipAhead, 0x7fffffff))
                )
            )
    }
}
