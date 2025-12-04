// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {logicalIndexToStorageIndex} from "../extensions/Oracle.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {IOracle} from "../interfaces/extensions/IOracle.sol";
import {Counts} from "../types/counts.sol";
import {Snapshot} from "../types/snapshot.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";

/// @title Oracle Library
/// @notice Library providing helper methods for accessing Oracle data
library OracleLib {
    using ExposedStorageLib for *;

    /// @notice Gets the counts and metadata for snapshots of a token
    /// @param oracle The oracle contract instance
    /// @param token The token address
    /// @return c The counts data for the token
    function counts(IOracle oracle, address token) internal view returns (Counts c) {
        c = Counts.wrap(oracle.sload(bytes32(uint256(uint160(token)))));
    }

    /// @notice Gets a specific snapshot for a token at a given index
    /// @param oracle The oracle contract instance
    /// @param token The token address
    /// @param index The snapshot index
    /// @return s The snapshot data at the given index
    function snapshots(IOracle oracle, address token, uint256 index) internal view returns (Snapshot s) {
        s = Snapshot.wrap(oracle.sload(bytes32((uint256(uint160(token)) << 32) | uint256(index))));
    }

    function getEarliestSnapshotTimestamp(IOracle oracle, address token) internal view returns (uint256) {
        unchecked {
            if (token == NATIVE_TOKEN_ADDRESS) return 0;

            Counts c = counts(oracle, token);
            if (c.count() == 0) {
                // if there are no snapshots, return a timestamp that will never be considered valid
                return type(uint256).max;
            }

            Snapshot snapshot = snapshots(oracle, token, logicalIndexToStorageIndex(c.index(), c.count(), 0));
            return block.timestamp - (uint32(block.timestamp) - snapshot.timestamp());
        }
    }

    function getMaximumObservationPeriod(IOracle oracle, address token) internal view returns (uint32) {
        unchecked {
            uint256 earliest = getEarliestSnapshotTimestamp(oracle, token);
            if (earliest > block.timestamp) return 0;
            return uint32(block.timestamp - earliest);
        }
    }
}
