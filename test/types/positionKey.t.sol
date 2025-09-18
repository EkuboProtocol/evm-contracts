// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    PositionKey,
    BoundsOrder,
    MinMaxBounds,
    BoundsTickSpacing,
    FullRangeOnlyPool
} from "../../src/types/positionKey.sol";
import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING, MAX_TICK_SPACING} from "../../src/math/constants.sol";

contract PositionKeyTest is Test {
    /// forge-config: default.allow_internal_expect_revert = true
    function test_validateBounds() public {
        PositionKey({salt: bytes32(0), tickLower: -1, tickUpper: 1}).validateBounds(1);
        PositionKey({salt: bytes32(0), tickLower: -2, tickUpper: 2}).validateBounds(2);
        PositionKey({salt: bytes32(0), tickLower: MIN_TICK, tickUpper: MAX_TICK}).validateBounds(MAX_TICK_SPACING);
        PositionKey({salt: bytes32(0), tickLower: MIN_TICK, tickUpper: MAX_TICK}).validateBounds(
            FULL_RANGE_ONLY_TICK_SPACING
        );

        vm.expectRevert(FullRangeOnlyPool.selector);
        PositionKey({salt: bytes32(0), tickLower: -2, tickUpper: 2}).validateBounds(FULL_RANGE_ONLY_TICK_SPACING);

        vm.expectRevert(BoundsOrder.selector);
        PositionKey({salt: bytes32(0), tickLower: -1, tickUpper: -1}).validateBounds(1);

        vm.expectRevert(BoundsOrder.selector);
        PositionKey({salt: bytes32(0), tickLower: 1, tickUpper: -1}).validateBounds(1);

        vm.expectRevert(MinMaxBounds.selector);
        PositionKey({salt: bytes32(0), tickLower: MIN_TICK - 1, tickUpper: MAX_TICK}).validateBounds(1);

        vm.expectRevert(MinMaxBounds.selector);
        PositionKey({salt: bytes32(0), tickLower: MIN_TICK, tickUpper: MAX_TICK + 1}).validateBounds(1);

        vm.expectRevert(BoundsTickSpacing.selector);
        PositionKey({salt: bytes32(0), tickLower: 1, tickUpper: 0}).validateBounds(2);

        vm.expectRevert(BoundsTickSpacing.selector);
        PositionKey({salt: bytes32(0), tickLower: 0, tickUpper: 1}).validateBounds(2);
    }

    function test_toPositionId_changesWithSalt(address owner, PositionKey memory positionKey) public pure {
        bytes32 id = positionKey.toPositionId(owner);
        unchecked {
            positionKey.salt = bytes32(uint256(positionKey.salt) + 1);
        }
        assertNotEq(positionKey.toPositionId(owner), id);
    }

    function test_toPositionId_changesWithDifferentLowerBounds(address owner, PositionKey memory positionKey)
        public
        pure
    {
        bytes32 id = positionKey.toPositionId(owner);
        unchecked {
            positionKey.tickLower += 1;
        }
        assertNotEq(positionKey.toPositionId(owner), id);
    }

    function test_toPositionId_changesWithDifferentUpperBounds(address owner, PositionKey memory positionKey)
        public
        pure
    {
        bytes32 id = positionKey.toPositionId(owner);
        unchecked {
            positionKey.tickUpper += 1;
        }
        assertNotEq(positionKey.toPositionId(owner), id);
    }

    function check_toPositionId_aligns_with_eq(
        address owner0,
        address owner1,
        PositionKey memory p0,
        PositionKey memory p1
    ) public pure {
        bytes32 p0Id = p0.toPositionId(owner0);
        bytes32 p1Id = p1.toPositionId(owner1);

        assertEq(
            owner0 == owner1 && p0.salt == p1.salt && p0.tickLower == p1.tickLower && p0.tickUpper == p1.tickUpper,
            p0Id == p1Id
        );
    }
}
