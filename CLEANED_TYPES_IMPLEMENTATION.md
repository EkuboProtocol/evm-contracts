# CleanedX Types Implementation

## Overview

This implementation adds `CleanedX` user-defined types to avoid redundant Solidity bit-clearing operations and enable local reasoning about value safety. This addresses issue #235.

## Problem

Solidity's codegen automatically inserts bit-clearing code for non-full-width types (e.g., `uint128`, `int32`) unless they're accessed in inline assembly. When values are extracted from storage using assembly (where upper bits are already zero), passing them to functions expecting narrower types causes redundant bit clearing.

## Solution

User-defined types wrapping `uint256` that encode the promise that upper bits are already cleared:

- `CleanedUint128` - wraps uint256, promises upper 128 bits are zero
- `CleanedInt128` - wraps uint256, promises value fits in int128
- `CleanedUint64` - wraps uint256, promises upper 192 bits are zero  
- `CleanedInt32` - wraps uint256, promises value fits in int32

## Implementation Details

### New Files

1. **`src/types/cleaned.sol`** - Defines the cleaned types and helper functions:
   - `castCleanedX()` - zero-cost cast from narrow type to cleaned wrapper
   - `castBoundedX()` - zero-cost cast from uint256 to narrow type (unchecked)
   - `cleanedX()` - extracts the narrow value from the wrapper
   - `wordX()` - returns the underlying uint256 word

2. **`test/types/cleaned.t.sol`** - Comprehensive test suite with 17 tests covering:
   - Round-trip conversions
   - Edge cases (max values, negative values)
   - Integration with packed storage patterns
   - Arithmetic operations

### Modified Files

1. **`src/types/poolState.sol`**
   - Added `parseCleaned()` function that returns `CleanedInt32` and `CleanedUint128`
   - Keeps original `parse()` for backward compatibility

2. **`src/Core.sol`**
   - Applied cleaned types to the `swap_1773245541()` function
   - Uses `parseCleaned()` to extract tick and liquidity
   - Works with `CleanedInt32` and `CleanedUint128` throughout the swap loop
   - Only casts to narrow types when calling external functions or storing

## Benefits

1. **Gas Efficiency**: Eliminates redundant bit-clearing operations in hot paths
2. **Local Reasoning**: Type system encodes the promise that values are clean
3. **Readability**: Makes it explicit when values are guaranteed to be within bounds
4. **Safety**: Maintains type safety while avoiding unnecessary operations

## Usage Pattern

```solidity
// Extract from storage with assembly (upper bits are zero)
(SqrtRatio sqrtRatio, CleanedInt32 tick, CleanedUint128 liquidity) = state.parseCleaned();

// Use cleaned types in calculations
if (liquidity.cleanedUint128() == 0) {
    // ...
}

// Pass to functions expecting narrow types
uint128 amount = amount0Delta(sqrtRatioA, sqrtRatioB, liquidity.cleanedUint128(), roundUp);

// Cast results back to cleaned types
CleanedUint128 feeAmount = castCleanedUint128(beforeFee - calculatedAmount);
```

## Testing

All 598 tests pass (581 existing + 17 new tests specifically for cleaned types).

```bash
forge test --match-contract CleanedTypesTest  # Run cleaned types tests
forge test                                     # Run full test suite
```

## Future Work

This implementation focuses on the Core swap function as suggested in the issue. The pattern can be extended to:

- Other functions in Core.sol
- Other contracts that work with packed storage
- Additional cleaned type sizes as needed

## Notes

- The cleaned types use assembly for zero-cost operations
- They're marked as `memory-safe` where appropriate
- The implementation maintains full backward compatibility
- Original functions remain unchanged for existing code
