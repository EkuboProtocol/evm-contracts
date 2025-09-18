// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    PositionId,
    createPositionId,
    BoundsOrder,
    MinMaxBounds,
    BoundsTickSpacing,
    FullRangeOnlyPool
} from "../../src/types/positionId.sol";
import {MIN_TICK, MAX_TICK, FULL_RANGE_ONLY_TICK_SPACING, MAX_TICK_SPACING} from "../../src/math/constants.sol";

contract PositionIdTest is Test {
    /// forge-config: default.allow_internal_expect_revert = true
    function test_validateBounds() public {
        createPositionId({_salt: bytes24(0), _tickLower: -1, _tickUpper: 1}).validateBounds(1);
        createPositionId({_salt: bytes24(0), _tickLower: -2, _tickUpper: 2}).validateBounds(2);
        createPositionId({_salt: bytes24(0), _tickLower: MIN_TICK, _tickUpper: MAX_TICK}).validateBounds(
            MAX_TICK_SPACING
        );
        createPositionId({_salt: bytes24(0), _tickLower: MIN_TICK, _tickUpper: MAX_TICK}).validateBounds(
            FULL_RANGE_ONLY_TICK_SPACING
        );

        vm.expectRevert(FullRangeOnlyPool.selector);
        createPositionId({_salt: bytes24(0), _tickLower: -2, _tickUpper: 2}).validateBounds(
            FULL_RANGE_ONLY_TICK_SPACING
        );

        vm.expectRevert(BoundsOrder.selector);
        createPositionId({_salt: bytes24(0), _tickLower: -1, _tickUpper: -1}).validateBounds(1);

        vm.expectRevert(BoundsOrder.selector);
        createPositionId({_salt: bytes24(0), _tickLower: 1, _tickUpper: -1}).validateBounds(1);

        vm.expectRevert(MinMaxBounds.selector);
        createPositionId({_salt: bytes24(0), _tickLower: MIN_TICK - 1, _tickUpper: MAX_TICK}).validateBounds(1);

        vm.expectRevert(MinMaxBounds.selector);
        createPositionId({_salt: bytes24(0), _tickLower: MIN_TICK, _tickUpper: MAX_TICK + 1}).validateBounds(1);

        vm.expectRevert(BoundsTickSpacing.selector);
        createPositionId({_salt: bytes24(0), _tickLower: 1, _tickUpper: 0}).validateBounds(2);

        vm.expectRevert(BoundsTickSpacing.selector);
        createPositionId({_salt: bytes24(0), _tickLower: 0, _tickUpper: 1}).validateBounds(2);
    }

    function check_conversionToAndFrom(PositionId id) public {
        assertEq(
            PositionId.unwrap(
                createPositionId({_salt: id.salt(), _tickLower: id.tickLower(), _tickUpper: id.tickUpper()})
            ),
            PositionId.unwrap(id)
        );
    }
}
