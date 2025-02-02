// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FullTest, MockExtension} from "./FullTest.sol";
import {IFlashAccountant} from "../src/interfaces/IFlashAccountant.sol";
import {ICore, IExtension, UpdatePositionParameters, SwapParameters} from "../src/interfaces/ICore.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {PoolKey, PositionKey, Bounds} from "../src/types/keys.sol";
import {CallPoints, byteToCallPoints} from "../src/types/callPoints.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, tickToSqrtRatio} from "../src/math/ticks.sol";
import {Core} from "../src/Core.sol";

contract CoreTest is FullTest {
    using CoreLib for *;

    function test_owner() public view {
        assertEq(core.owner(), owner);
    }

    function test_castingAssumption() public pure {
        // we make this assumption on solidity behavior in the protocol fee collection
        unchecked {
            assertEq(uint128(-type(int128).min), uint128(uint256(-int256(type(int128).min))));
        }
    }

    function test_registerExtension(uint8 b) public {
        b = uint8(bound(b, 1, type(uint8).max));

        address impl = address(new MockExtension());
        address actual = address((uint160(b) << 152) + 0xdeadbeef);
        vm.etch(actual, impl.code);

        vm.expectRevert(ICore.FailedRegisterInvalidCallPoints.selector, address(core));
        MockExtension(actual).register(core, byteToCallPoints(0));
        // b + 1 will always be different
        unchecked {
            vm.expectRevert(ICore.FailedRegisterInvalidCallPoints.selector, address(core));
            MockExtension(actual).register(core, byteToCallPoints(b + 1));
        }

        vm.expectEmit(address(core));
        emit ICore.ExtensionRegistered(actual);
        MockExtension(actual).register(core, byteToCallPoints(b));

        // double register is revert
        vm.expectRevert(ICore.ExtensionAlreadyRegistered.selector, address(core));
        MockExtension(actual).register(core, byteToCallPoints(b));
    }

    function test_balanceSubtractionAssumption() public pure {
        unchecked {
            assertEq(
                uint256(0) - uint256(0x8000000000000000000000000000000000000000000000000000000000000000),
                0x8000000000000000000000000000000000000000000000000000000000000000
            );
            assertEq(
                uint256(1) - uint256(0x8000000000000000000000000000000000000000000000000000000000000000),
                0x8000000000000000000000000000000000000000000000000000000000000001
            );
        }
    }

    function test_cannotReceiveEthOutsideOfLockContext() public {
        (bool success, bytes memory revertData) = address(core).call{value: 1}("");
        assertFalse(success);
        assertEq(revertData, abi.encodePacked(IFlashAccountant.NotLocked.selector));
    }

    function test_initializePool(
        address token0,
        address token1,
        uint128 fee,
        int32 tick,
        uint32 tickSpacing,
        CallPoints memory callPoints
    ) public {
        token0 = address(uint160(bound(uint160(token0), 1, type(uint160).max - 1)));
        token1 = address(uint160(bound(uint160(token1), uint160(token0) + 1, type(uint160).max)));
        tickSpacing = uint32(bound(tickSpacing, uint256(1), uint256(MAX_TICK_SPACING)));
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));

        address extension = callPoints.isValid() ? createAndRegisterExtension(callPoints) : address(0);
        PoolKey memory key =
            PoolKey({token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing, extension: extension});

        if (callPoints.beforeInitializePool) {
            vm.expectEmit(extension);
            emit MockExtension.BeforeInitializePoolCalled(address(this), key, tick);
        }
        vm.expectEmit(address(core));
        emit ICore.PoolInitialized(key, tick, tickToSqrtRatio(tick));

        if (callPoints.afterInitializePool) {
            vm.expectEmit(extension);
            emit MockExtension.AfterInitializePoolCalled(address(this), key, tick, tickToSqrtRatio(tick));
        }

        // call under test
        core.initializePool(key, tick);

        (uint192 _sqrtRatio, int32 _tick) = core.poolPrice(key.toPoolId());
        assertEq(_sqrtRatio, tickToSqrtRatio(tick));
        assertEq(_tick, tick);

        vm.expectRevert(ICore.PoolAlreadyInitialized.selector);
        core.initializePool(key, tick);
    }
}
