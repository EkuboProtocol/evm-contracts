// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {Locker} from "../../src/types/locker.sol";

contract LockerTest is Test {
    function test_parse(uint256 id, address addr) public pure {
        // Bound id to valid range (must fit in 96 bits when incremented)
        id = bound(id, 0, type(uint96).max - 1);

        // Create a Locker by packing the values manually
        bytes32 packed = bytes32((uint256(id + 1) << 160) | uint256(uint160(addr)));
        Locker locker = Locker.wrap(packed);

        // Test parse method
        (uint256 parsedId, address parsedAddr) = locker.parse();
        assertEq(parsedId, id);
        assertEq(parsedAddr, addr);
    }

    function test_id(uint256 id, address addr) public pure {
        // Bound id to valid range (must fit in 96 bits when incremented)
        id = bound(id, 0, type(uint96).max - 1);

        // Create a Locker by packing the values manually
        bytes32 packed = bytes32((uint256(id + 1) << 160) | uint256(uint160(addr)));
        Locker locker = Locker.wrap(packed);

        // Test id method
        assertEq(locker.id(), id);
    }

    function test_addr(uint256 id, address addr) public pure {
        // Bound id to valid range (must fit in 96 bits when incremented)
        id = bound(id, 0, type(uint96).max - 1);

        // Create a Locker by packing the values manually
        bytes32 packed = bytes32((uint256(id + 1) << 160) | uint256(uint160(addr)));
        Locker locker = Locker.wrap(packed);

        // Test addr method
        assertEq(locker.addr(), addr);
    }

    function test_consistency_between_methods(uint256 id, address addr) public pure {
        // Bound id to valid range (must fit in 96 bits when incremented)
        id = bound(id, 0, type(uint96).max - 1);

        // Create a Locker by packing the values manually
        bytes32 packed = bytes32((uint256(id + 1) << 160) | uint256(uint160(addr)));
        Locker locker = Locker.wrap(packed);

        // Test that individual methods match parse method
        (uint256 parsedId, address parsedAddr) = locker.parse();
        assertEq(locker.id(), parsedId);
        assertEq(locker.addr(), parsedAddr);
    }

    function test_zero_values() public pure {
        // Test with zero values
        bytes32 packed = bytes32((uint256(1) << 160)); // id=0 means stored as 1
        Locker locker = Locker.wrap(packed);

        assertEq(locker.id(), 0);
        assertEq(locker.addr(), address(0));

        (uint256 parsedId, address parsedAddr) = locker.parse();
        assertEq(parsedId, 0);
        assertEq(parsedAddr, address(0));
    }

    function test_max_values() public pure {
        // Test with maximum values
        uint256 maxId = type(uint96).max - 1; // -1 because we store id+1
        address maxAddr = address(type(uint160).max);

        bytes32 packed = bytes32((uint256(maxId + 1) << 160) | uint256(uint160(maxAddr)));
        Locker locker = Locker.wrap(packed);

        assertEq(locker.id(), maxId);
        assertEq(locker.addr(), maxAddr);

        (uint256 parsedId, address parsedAddr) = locker.parse();
        assertEq(parsedId, maxId);
        assertEq(parsedAddr, maxAddr);
    }
}
