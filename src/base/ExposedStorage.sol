// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {IExposedStorage} from "../interfaces/IExposedStorage.sol";

/// @title ExposedStorage
/// @notice Abstract contract that implements storage exposure functionality
/// @dev This contract provides the implementation for the IExposedStorage interface,
///      allowing inheriting contracts to expose their storage slots via view functions.
///      Uses inline assembly for efficient storage access.
abstract contract ExposedStorage is IExposedStorage {
    /// @inheritdoc IExposedStorage
    /// @dev Uses inline assembly to efficiently read multiple storage slots specified in calldata.
    ///      Each slot value is loaded using the SLOAD opcode and stored in memory.
    function sload() external view {
        assembly ("memory-safe") {
            for { let i := 4 } lt(i, calldatasize()) { i := add(i, 32) } { mstore(sub(i, 4), sload(calldataload(i))) }
            return(0, sub(calldatasize(), 4))
        }
    }

    /// @inheritdoc IExposedStorage
    /// @dev Uses inline assembly to efficiently read multiple transient storage slots specified in calldata.
    ///      Each slot value is loaded using the TLOAD opcode and stored in memory.
    function tload() external view {
        assembly ("memory-safe") {
            for { let i := 4 } lt(i, calldatasize()) { i := add(i, 32) } { mstore(sub(i, 4), tload(calldataload(i))) }
            return(0, sub(calldatasize(), 4))
        }
    }
}
