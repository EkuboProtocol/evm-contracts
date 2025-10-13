// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.30;

import {SqrtRatio, MIN_SQRT_RATIO_RAW, MAX_SQRT_RATIO_RAW} from "./sqrtRatio.sol";

type SwapParameters is bytes32;

using {
    sqrtRatioLimit,
    amount,
    isToken1,
    skipAhead,
    isExactOut,
    isPriceIncreasing,
    withDefaultSqrtRatioLimit
} for SwapParameters global;

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

function isExactOut(SwapParameters params) pure returns (bool yes) {
    assembly ("memory-safe") {
        yes := and(shr(159, params), 1)
    }
}

function isPriceIncreasing(SwapParameters params) pure returns (bool yes) {
    bool _isExactOut = params.isExactOut();
    bool _isToken1 = params.isToken1();
    assembly ("memory-safe") {
        yes := xor(_isExactOut, _isToken1)
    }
}

function withDefaultSqrtRatioLimit(SwapParameters params) pure returns (SwapParameters updated) {
    bool increasing = params.isPriceIncreasing();
    assembly ("memory-safe") {
        let replace := iszero(shr(160, params))
        let orMask :=
            shl(160, mul(replace, or(mul(increasing, MAX_SQRT_RATIO_RAW), mul(iszero(increasing), MIN_SQRT_RATIO_RAW))))
        updated := or(orMask, params)
    }
}
