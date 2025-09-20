// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Counts, createCounts} from "../../src/types/counts.sol";

contract CountsTest is Test {
    function test_conversionToAndFrom(Counts counts) public pure {
        assertEq(
            Counts.unwrap(
                createCounts({
                    _index: counts.index(),
                    _count: counts.count(),
                    _capacity: counts.capacity(),
                    _lastTimestamp: counts.lastTimestamp()
                })
            ),
            Counts.unwrap(counts)
        );
    }

    function test_conversionFromAndTo(uint32 index, uint32 count, uint32 capacity, uint32 lastTimestamp) public pure {
        Counts counts = createCounts({_index: index, _count: count, _capacity: capacity, _lastTimestamp: lastTimestamp});
        assertEq(counts.index(), index);
        assertEq(counts.count(), count);
        assertEq(counts.capacity(), capacity);
        assertEq(counts.lastTimestamp(), lastTimestamp);
    }

    function test_conversionFromAndToDirtyBits(
        bytes32 indexDirty,
        bytes32 countDirty,
        bytes32 capacityDirty,
        bytes32 lastTimestampDirty
    ) public pure {
        uint32 index;
        uint32 count;
        uint32 capacity;
        uint32 lastTimestamp;

        assembly ("memory-safe") {
            index := indexDirty
            count := countDirty
            capacity := capacityDirty
            lastTimestamp := lastTimestampDirty
        }

        Counts counts = createCounts({_index: index, _count: count, _capacity: capacity, _lastTimestamp: lastTimestamp});
        assertEq(counts.index(), index, "index");
        assertEq(counts.count(), count, "count");
        assertEq(counts.capacity(), capacity, "capacity");
        assertEq(counts.lastTimestamp(), lastTimestamp, "lastTimestamp");
    }
}
