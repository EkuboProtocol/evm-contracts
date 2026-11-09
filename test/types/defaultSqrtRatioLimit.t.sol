// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio, MIN_SQRT_RATIO_RAW, MAX_SQRT_RATIO_RAW} from "../../src/types/sqrtRatio.sol";

contract DefaultSqrtRatioLimitHelper {
    function normalize(uint256 word) external pure returns (uint256 result, uint256 direction) {
        SwapParameters params = SwapParameters.wrap(bytes32(word));
        bool increasing = params.isPriceIncreasing();
        assembly ("memory-safe") {
            direction := increasing
        }
        result = uint256(SwapParameters.unwrap(params.withDefaultSqrtRatioLimit()));
    }

    function packDirty(uint256 limitBits, uint256 amountBits, uint256 tokenBits, uint256 skip, uint256 feeBits)
        external
        pure
        returns (uint256 packed, uint256 normalized)
    {
        SqrtRatio limit;
        int128 amount;
        bool token1;
        uint16 fee;
        assembly ("memory-safe") {
            limit := limitBits
            amount := amountBits
            token1 := tokenBits
            fee := feeBits
        }
        SwapParameters params = createSwapParameters(limit, amount, token1, skip, fee);
        packed = uint256(SwapParameters.unwrap(params));
        normalized = uint256(SwapParameters.unwrap(params.withDefaultSqrtRatioLimit()));
    }
}

contract DefaultSqrtRatioLimitTest is Test {
    DefaultSqrtRatioLimitHelper internal helper = new DefaultSqrtRatioLimitHelper();

    // Use field decoding and a conditional, independently of the assembly selector.
    function referenceWord(uint256 word) internal pure returns (uint256) {
        if (uint96(word >> 160) != 0) return word;
        bool exactOut = int128(uint128(word >> 32)) < 0;
        bool token1 = uint32(word) >= uint32(1 << 31);
        uint256 limit = exactOut != token1 ? MAX_SQRT_RATIO_RAW : MIN_SQRT_RATIO_RAW;
        return word | (limit << 160);
    }

    function checkWord(uint256 word) internal view {
        (uint256 result, uint256 direction) = helper.normalize(word);
        assertEq(result, referenceWord(word), "complete word");
        assertEq(uint160(result), uint160(word), "all low 160 bits");
        assertEq(direction, ((word >> 159) & 1) ^ ((word >> 31) & 1), "clean direction");
        assertLe(direction, 1);
        (uint256 again,) = helper.normalize(result);
        assertEq(again, result, "idempotent");
        if (word >> 160 != 0) assertEq(result, word, "nonzero limit including invalid encodings");
    }

    function testFuzz_completeWord(uint256 word) public view {
        checkWord(word);
    }

    function testFuzz_zeroLimit(uint160 lowBits) public view {
        checkWord(lowBits);
    }

    function testFuzz_dirtyPacking(
        uint256 limitBits,
        uint256 amountBits,
        uint256 tokenBits,
        uint16 skip,
        uint256 feeBits
    ) public view {
        uint256 boundedSkip = uint256(skip) & 0x7fff;
        (uint256 packed, uint256 normalized) = helper.packDirty(limitBits, amountBits, tokenBits, boundedSkip, feeBits);
        uint256 expected = (uint256(uint96(limitBits)) << 160) | (uint256(uint128(amountBits)) << 32)
            | ((tokenBits != 0 ? uint256(1) : 0) << 31) | (boundedSkip << 16) | uint16(feeBits);
        assertEq(packed, expected, "dirty fields cannot overlap");
        assertEq(normalized, referenceWord(expected), "packed normalization");
    }

    function test_directedBoundaries() public view {
        int128[5] memory amounts = [type(int128).min, int128(-1), int128(0), int128(1), type(int128).max];
        uint96[9] memory limits = [
            uint96(0),
            uint96(1),
            MIN_SQRT_RATIO_RAW - 1,
            MIN_SQRT_RATIO_RAW,
            MIN_SQRT_RATIO_RAW + 1,
            MAX_SQRT_RATIO_RAW - 1,
            MAX_SQRT_RATIO_RAW,
            MAX_SQRT_RATIO_RAW + 1,
            type(uint96).max
        ];
        uint16[7] memory fees =
            [uint16(0), uint16(1), uint16(195), uint16(196), uint16(197), uint16(32768), uint16(65535)];
        for (uint256 a; a < amounts.length; a++) {
            for (uint256 l; l < limits.length; l++) {
                for (uint256 f; f < fees.length; f++) {
                    for (uint256 bits; bits < 4; bits++) {
                        uint256 word = (uint256(limits[l]) << 160) | (uint256(uint128(amounts[a])) << 32)
                            | ((bits & 1) << 31) | ((bits > 1 ? uint256(0x7fff) : 0) << 16) | fees[f];
                        checkWord(word);
                    }
                }
            }
        }
    }

    function test_negativeControl_unmaskedDirection() public pure {
        // Amount 1 leaves a high bit in an unmasked token-side extraction.
        uint256 word = (uint256(1) << 32) | 65535;
        uint256 dirtyDirection = (word >> 159) ^ (word >> 31);
        uint256 badLimit = MIN_SQRT_RATIO_RAW ^ (dirtyDirection * (MIN_SQRT_RATIO_RAW ^ MAX_SQRT_RATIO_RAW));
        assertNotEq(word | (badLimit << 160), referenceWord(word));
        assertNotEq(referenceWord(word) ^ 1, referenceWord(word), "minimum-fee corruption is visible");
    }
}
