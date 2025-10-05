// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

/// @title Cleaned Types
/// @notice User-defined types that encode the promise of having upper bits already cleared
/// @dev These types allow zero-cost casting and local reasoning about bit cleanliness,
///      avoiding redundant Solidity bit-clearing operations

// ============ CleanedUint128 ============

type CleanedUint128 is uint256;

using {cleanedUint128, wordUint128} for CleanedUint128 global;

/// @dev Unchecked zero-cost cast from uint128 to the cleaned wrapper type
function castCleanedUint128(uint128 v) pure returns (CleanedUint128 r) {
    assembly ("memory-safe") {
        r := v
    }
}

/// @dev Unchecked zero-cost cast from uint256 to uint128
/// @notice Only use when you know the upper 128 bits are zero
function castBoundedUint128(uint256 v) pure returns (uint128 r) {
    assembly ("memory-safe") {
        r := v
    }
}

/// @dev Returns the narrowed uint128 value
function cleanedUint128(CleanedUint128 v) pure returns (uint128 r) {
    assembly ("memory-safe") {
        r := v
    }
}

/// @dev Returns the underlying uint256 word
function wordUint128(CleanedUint128 v) pure returns (uint256) {
    return CleanedUint128.unwrap(v);
}

// ============ CleanedInt128 ============

type CleanedInt128 is uint256;

using {cleanedInt128, wordInt128} for CleanedInt128 global;

/// @dev Unchecked zero-cost cast from int128 to the cleaned wrapper type
function castCleanedInt128(int128 v) pure returns (CleanedInt128 r) {
    assembly ("memory-safe") {
        r := v
    }
}

/// @dev Unchecked zero-cost cast from uint256 to int128
/// @notice Only use when you know the value fits in int128
function castBoundedInt128(uint256 v) pure returns (int128 r) {
    assembly ("memory-safe") {
        r := v
    }
}

/// @dev Returns the narrowed int128 value
function cleanedInt128(CleanedInt128 v) pure returns (int128 r) {
    assembly ("memory-safe") {
        r := v
    }
}

/// @dev Returns the underlying uint256 word
function wordInt128(CleanedInt128 v) pure returns (uint256) {
    return CleanedInt128.unwrap(v);
}

// ============ CleanedUint64 ============

type CleanedUint64 is uint256;

using {cleanedUint64, wordUint64} for CleanedUint64 global;

/// @dev Unchecked zero-cost cast from uint64 to the cleaned wrapper type
function castCleanedUint64(uint64 v) pure returns (CleanedUint64 r) {
    assembly ("memory-safe") {
        r := v
    }
}

/// @dev Unchecked zero-cost cast from uint256 to uint64
/// @notice Only use when you know the upper 192 bits are zero
function castBoundedUint64(uint256 v) pure returns (uint64 r) {
    assembly ("memory-safe") {
        r := v
    }
}

/// @dev Returns the narrowed uint64 value
function cleanedUint64(CleanedUint64 v) pure returns (uint64 r) {
    assembly ("memory-safe") {
        r := v
    }
}

/// @dev Returns the underlying uint256 word
function wordUint64(CleanedUint64 v) pure returns (uint256) {
    return CleanedUint64.unwrap(v);
}

// ============ CleanedInt32 ============

type CleanedInt32 is uint256;

using {cleanedInt32, wordInt32} for CleanedInt32 global;

/// @dev Unchecked zero-cost cast from int32 to the cleaned wrapper type
function castCleanedInt32(int32 v) pure returns (CleanedInt32 r) {
    assembly ("memory-safe") {
        r := v
    }
}

/// @dev Unchecked zero-cost cast from uint256 to int32
/// @notice Only use when you know the value fits in int32
function castBoundedInt32(uint256 v) pure returns (int32 r) {
    assembly ("memory-safe") {
        r := v
    }
}

/// @dev Returns the narrowed int32 value
function cleanedInt32(CleanedInt32 v) pure returns (int32 r) {
    assembly ("memory-safe") {
        r := v
    }
}

/// @dev Returns the underlying uint256 word
function wordInt32(CleanedInt32 v) pure returns (uint256) {
    return CleanedInt32.unwrap(v);
}
