// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import "forge-std/Test.sol";
import {
    CleanedUint128,
    CleanedInt128,
    CleanedUint64,
    CleanedInt32,
    castCleanedUint128,
    castCleanedInt128,
    castCleanedUint64,
    castCleanedInt32,
    castBoundedUint128,
    castBoundedInt128,
    castBoundedUint64,
    castBoundedInt32,
    cleanedUint128,
    cleanedInt128,
    cleanedUint64,
    cleanedInt32,
    wordUint128,
    wordInt128,
    wordUint64,
    wordInt32
} from "../../src/types/cleaned.sol";

contract CleanedTypesTest is Test {
    // ============ CleanedUint128 Tests ============

    function test_cleanedUint128_castFromNarrow(uint128 value) public pure {
        CleanedUint128 cleaned = castCleanedUint128(value);
        assertEq(cleaned.cleanedUint128(), value);
        assertEq(cleaned.wordUint128(), uint256(value));
    }

    function test_cleanedUint128_castToNarrow(uint128 value) public pure {
        // Simulate extracting a uint128 from storage (upper bits are zero)
        uint256 word = uint256(value);
        uint128 narrow = castBoundedUint128(word);
        assertEq(narrow, value);
    }

    function test_cleanedUint128_roundTrip(uint128 value) public pure {
        CleanedUint128 cleaned = castCleanedUint128(value);
        uint256 word = cleaned.wordUint128();
        uint128 result = castBoundedUint128(word);
        assertEq(result, value);
    }

    function test_cleanedUint128_maxValue() public pure {
        uint128 maxValue = type(uint128).max;
        CleanedUint128 cleaned = castCleanedUint128(maxValue);
        assertEq(cleaned.cleanedUint128(), maxValue);
        assertEq(cleaned.wordUint128(), uint256(maxValue));
    }

    // ============ CleanedInt128 Tests ============

    function test_cleanedInt128_castFromNarrow(int128 value) public pure {
        CleanedInt128 cleaned = castCleanedInt128(value);
        assertEq(cleaned.cleanedInt128(), value);
    }

    function test_cleanedInt128_castToNarrow(int128 value) public pure {
        // Simulate extracting an int128 from storage
        uint256 word;
        assembly {
            word := value
        }
        int128 narrow = castBoundedInt128(word);
        assertEq(narrow, value);
    }

    function test_cleanedInt128_roundTrip(int128 value) public pure {
        CleanedInt128 cleaned = castCleanedInt128(value);
        uint256 word = cleaned.wordInt128();
        int128 result = castBoundedInt128(word);
        assertEq(result, value);
    }

    function test_cleanedInt128_negativeValues(int128 value) public pure {
        vm.assume(value < 0);
        CleanedInt128 cleaned = castCleanedInt128(value);
        assertEq(cleaned.cleanedInt128(), value);
    }

    // ============ CleanedUint64 Tests ============

    function test_cleanedUint64_castFromNarrow(uint64 value) public pure {
        CleanedUint64 cleaned = castCleanedUint64(value);
        assertEq(cleaned.cleanedUint64(), value);
        assertEq(cleaned.wordUint64(), uint256(value));
    }

    function test_cleanedUint64_castToNarrow(uint64 value) public pure {
        uint256 word = uint256(value);
        uint64 narrow = castBoundedUint64(word);
        assertEq(narrow, value);
    }

    function test_cleanedUint64_roundTrip(uint64 value) public pure {
        CleanedUint64 cleaned = castCleanedUint64(value);
        uint256 word = cleaned.wordUint64();
        uint64 result = castBoundedUint64(word);
        assertEq(result, value);
    }

    // ============ CleanedInt32 Tests ============

    function test_cleanedInt32_castFromNarrow(int32 value) public pure {
        CleanedInt32 cleaned = castCleanedInt32(value);
        assertEq(cleaned.cleanedInt32(), value);
    }

    function test_cleanedInt32_castToNarrow(int32 value) public pure {
        uint256 word;
        assembly {
            word := value
        }
        int32 narrow = castBoundedInt32(word);
        assertEq(narrow, value);
    }

    function test_cleanedInt32_roundTrip(int32 value) public pure {
        CleanedInt32 cleaned = castCleanedInt32(value);
        uint256 word = cleaned.wordInt32();
        int32 result = castBoundedInt32(word);
        assertEq(result, value);
    }

    function test_cleanedInt32_tickRange() public pure {
        // Test with typical tick values used in the protocol
        int32 minTick = -887272;
        int32 maxTick = 887272;

        CleanedInt32 cleanedMin = castCleanedInt32(minTick);
        CleanedInt32 cleanedMax = castCleanedInt32(maxTick);

        assertEq(cleanedMin.cleanedInt32(), minTick);
        assertEq(cleanedMax.cleanedInt32(), maxTick);
    }

    // ============ Integration Tests ============

    function test_cleanedTypes_simulatePoolStateParse() public pure {
        // Simulate extracting values from a packed PoolState
        uint128 liquidity = 1000000000000000000;
        int32 tick = 100;

        // Pack into a word (simplified version of PoolState)
        uint256 packed;
        assembly {
            packed := or(shl(128, and(tick, 0xFFFFFFFF)), liquidity)
        }

        // Extract using assembly (simulating parseCleaned)
        CleanedInt32 extractedTick;
        CleanedUint128 extractedLiquidity;
        assembly {
            extractedTick := signextend(3, shr(128, packed))
            extractedLiquidity := and(packed, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }

        // Verify the extracted values
        assertEq(extractedTick.cleanedInt32(), tick);
        assertEq(extractedLiquidity.cleanedUint128(), liquidity);
    }

    function test_cleanedTypes_arithmeticOperations() public pure {
        // Demonstrate that cleaned types can be used in arithmetic
        CleanedUint128 a = castCleanedUint128(100);
        CleanedUint128 b = castCleanedUint128(200);

        // Perform arithmetic on the underlying words
        uint256 sum = a.wordUint128() + b.wordUint128();
        uint256 diff = b.wordUint128() - a.wordUint128();

        // Cast back to narrow types
        assertEq(castBoundedUint128(sum), 300);
        assertEq(castBoundedUint128(diff), 100);
    }
}
