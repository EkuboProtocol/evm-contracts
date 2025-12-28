// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {
    PositionId,
    createPositionId,
    BoundsOrder,
    MinMaxBounds,
    BoundsTickSpacing,
    StableswapMustBeFullRange
} from "../../src/types/positionId.sol";
import {createFullRangePoolConfig, createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../../src/math/constants.sol";

contract PositionIdTest is Test {
    /// forge-config: default.allow_internal_expect_revert = true
    function test_validate() public {
        createPositionId({_salt: bytes24(0), _tickLower: -1, _tickUpper: 1})
            .validate(createConcentratedPoolConfig(0, 1, address(0)));
        createPositionId({_salt: bytes24(0), _tickLower: -2, _tickUpper: 2})
            .validate(createConcentratedPoolConfig(0, 2, address(0)));
        createPositionId({_salt: bytes24(0), _tickLower: MIN_TICK, _tickUpper: MAX_TICK})
            .validate(createConcentratedPoolConfig(0, MAX_TICK_SPACING, address(0)));
        createPositionId({_salt: bytes24(0), _tickLower: MIN_TICK, _tickUpper: MAX_TICK})
            .validate(createFullRangePoolConfig(0, address(0)));

        // Stableswap pools (including full range) require positions to be exactly min/max tick
        vm.expectRevert(StableswapMustBeFullRange.selector);
        createPositionId({_salt: bytes24(0), _tickLower: -2, _tickUpper: 2})
            .validate(createFullRangePoolConfig(0, address(0)));

        vm.expectRevert(BoundsOrder.selector);
        createPositionId({_salt: bytes24(0), _tickLower: -1, _tickUpper: -1})
            .validate(createConcentratedPoolConfig(0, 1, address(0)));

        vm.expectRevert(BoundsOrder.selector);
        createPositionId({_salt: bytes24(0), _tickLower: 1, _tickUpper: -1})
            .validate(createConcentratedPoolConfig(0, 1, address(0)));

        vm.expectRevert(MinMaxBounds.selector);
        createPositionId({_salt: bytes24(0), _tickLower: MIN_TICK - 1, _tickUpper: MAX_TICK})
            .validate(createConcentratedPoolConfig(0, 1, address(0)));

        vm.expectRevert(MinMaxBounds.selector);
        createPositionId({_salt: bytes24(0), _tickLower: MIN_TICK, _tickUpper: MAX_TICK + 1})
            .validate(createConcentratedPoolConfig(0, 1, address(0)));

        vm.expectRevert(BoundsTickSpacing.selector);
        createPositionId({_salt: bytes24(0), _tickLower: 1, _tickUpper: 0})
            .validate(createConcentratedPoolConfig(0, 2, address(0)));

        vm.expectRevert(BoundsTickSpacing.selector);
        createPositionId({_salt: bytes24(0), _tickLower: 0, _tickUpper: 1})
            .validate(createConcentratedPoolConfig(0, 2, address(0)));
    }

    function test_conversionToAndFrom(PositionId id) public pure {
        assertEq(
            PositionId.unwrap(
                createPositionId({_salt: id.salt(), _tickLower: id.tickLower(), _tickUpper: id.tickUpper()})
            ),
            PositionId.unwrap(id)
        );
    }

    function test_conversionFromAndTo(bytes24 salt, int32 tickLower, int32 tickUpper) public pure {
        PositionId id = createPositionId({_salt: salt, _tickLower: tickLower, _tickUpper: tickUpper});
        assertEq(id.salt(), salt);
        assertEq(id.tickLower(), tickLower);
        assertEq(id.tickUpper(), tickUpper);
    }

    function test_conversionFromAndToDirtyBits(bytes32 saltDirty, bytes32 tickLowerDirty, bytes32 tickUpperDirty)
        public
        pure
    {
        bytes24 salt;
        int32 tickLower;
        int32 tickUpper;

        assembly ("memory-safe") {
            salt := saltDirty
            tickLower := tickLowerDirty
            tickUpper := tickUpperDirty
        }

        PositionId id = createPositionId({_salt: salt, _tickLower: tickLower, _tickUpper: tickUpper});
        assertEq(id.salt(), salt);
        assertEq(id.tickLower(), tickLower);
        assertEq(id.tickUpper(), tickUpper);
    }
}
