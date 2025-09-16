// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    PositionKey,
    Bounds,
    BoundsOrder,
    MinMaxBounds,
    BoundsTickSpacing,
    FullRangeOnlyPool
} from "../../src/types/positionKey.sol";
import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING, MAX_TICK_SPACING} from "../../src/math/constants.sol";

contract PositionKeyTest is Test {
    /// forge-config: default.allow_internal_expect_revert = true
    function test_validateBounds() public {
        Bounds({lower: -1, upper: 1}).validateBounds(1);
        Bounds({lower: -2, upper: 2}).validateBounds(2);
        Bounds({lower: MIN_TICK, upper: MAX_TICK}).validateBounds(MAX_TICK_SPACING);
        Bounds({lower: MIN_TICK, upper: MAX_TICK}).validateBounds(FULL_RANGE_ONLY_TICK_SPACING);

        vm.expectRevert(FullRangeOnlyPool.selector);
        Bounds({lower: -2, upper: 2}).validateBounds(FULL_RANGE_ONLY_TICK_SPACING);

        vm.expectRevert(BoundsOrder.selector);
        Bounds({lower: -1, upper: -1}).validateBounds(1);

        vm.expectRevert(BoundsOrder.selector);
        Bounds({lower: 1, upper: -1}).validateBounds(1);

        vm.expectRevert(MinMaxBounds.selector);
        Bounds({lower: MIN_TICK - 1, upper: MAX_TICK}).validateBounds(1);

        vm.expectRevert(MinMaxBounds.selector);
        Bounds({lower: MIN_TICK, upper: MAX_TICK + 1}).validateBounds(1);

        vm.expectRevert(BoundsTickSpacing.selector);
        Bounds({lower: 1, upper: 0}).validateBounds(2);

        vm.expectRevert(BoundsTickSpacing.selector);
        Bounds({lower: 0, upper: 1}).validateBounds(2);
    }

    function test_toPositionId_changesWithSalt(PositionKey memory positionKey) public pure {
        bytes32 id = positionKey.toPositionId();
        unchecked {
            positionKey.salt = bytes32(uint256(positionKey.salt) + 1);
        }
        assertNotEq(positionKey.toPositionId(), id);
    }

    function test_toPositionId_changesWithOwner(PositionKey memory positionKey) public pure {
        bytes32 id = positionKey.toPositionId();
        unchecked {
            positionKey.owner = address(uint160(positionKey.owner) + 1);
        }
        assertNotEq(positionKey.toPositionId(), id);
    }

    function test_toPositionId_doesNotChangeWithBoundsValue(PositionKey memory positionKey) public pure {
        bytes32 id = positionKey.toPositionId();
        positionKey.bounds = Bounds(positionKey.bounds.lower, positionKey.bounds.upper);
        assertEq(positionKey.toPositionId(), id);
    }

    function test_toPositionId_changesWithDifferentLowerBounds(PositionKey memory positionKey) public pure {
        bytes32 id = positionKey.toPositionId();
        unchecked {
            positionKey.bounds.lower += 1;
        }
        assertNotEq(positionKey.toPositionId(), id);
    }

    function test_toPositionId_changesWithDifferentUpperBounds(PositionKey memory positionKey) public pure {
        bytes32 id = positionKey.toPositionId();
        unchecked {
            positionKey.bounds.upper += 1;
        }
        assertNotEq(positionKey.toPositionId(), id);
    }

    function check_toPositionId_aligns_with_eq(PositionKey memory p0, PositionKey memory p1) public pure {
        bytes32 p0Id = p0.toPositionId();
        bytes32 p1Id = p1.toPositionId();

        assertEq(
            p0.salt == p1.salt && p0.owner == p1.owner && p0.bounds.lower == p1.bounds.lower
                && p0.bounds.upper == p1.bounds.upper,
            p0Id == p1Id
        );
    }
}
