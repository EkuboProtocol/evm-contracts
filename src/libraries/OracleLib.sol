// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Oracle, logicalIndexToStorageIndex} from "../extensions/Oracle.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";

library OracleLib {
    function getEarliestSnapshotTimestamp(Oracle oracle, address token) internal view returns (uint256) {
        unchecked {
            if (token == NATIVE_TOKEN_ADDRESS) return 0;

            (uint32 index, uint32 count,,) = oracle.counts(token);
            if (count == 0) {
                // if there are no snapshots, return a timestamp that will never be considered valid
                return type(uint256).max;
            }

            (uint32 timestamp,,) = oracle.snapshots(token, logicalIndexToStorageIndex(index, count, 0));
            return block.timestamp - (uint32(block.timestamp) - timestamp);
        }
    }

    function getMaximumObservationPeriod(Oracle oracle, address token) internal view returns (uint32) {
        unchecked {
            uint256 earliest = getEarliestSnapshotTimestamp(oracle, token);
            if (earliest > block.timestamp) return 0;
            return uint32(block.timestamp - earliest);
        }
    }
}
