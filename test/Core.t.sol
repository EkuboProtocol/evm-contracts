// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {FullTest, MockExtension} from "./FullTest.sol";
import {IFlashAccountant} from "../src/interfaces/IFlashAccountant.sol";
import {ICore, IExtension, UpdatePositionParameters} from "../src/interfaces/ICore.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {PositionKey, Bounds} from "../src/types/positionKey.sol";
import {CallPoints, byteToCallPoints} from "../src/types/callPoints.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../src/math/constants.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
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
        uint64 fee,
        int32 tick,
        uint32 tickSpacing,
        CallPoints memory callPoints
    ) public {
        token0 = address(uint160(bound(uint160(token0), 1, type(uint160).max - 1)));
        token1 = address(uint160(bound(uint160(token1), uint160(token0) + 1, type(uint160).max)));
        tickSpacing = uint32(bound(tickSpacing, uint256(1), uint256(MAX_TICK_SPACING)));
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));

        address extension = callPoints.isValid() ? createAndRegisterExtension(callPoints) : address(0);
        PoolKey memory key = PoolKey({token0: token0, token1: token1, config: toConfig(fee, tickSpacing, extension)});

        if (callPoints.beforeInitializePool) {
            vm.expectEmit(extension);
            emit MockExtension.BeforeInitializePoolCalled(address(this), key, tick);
        }
        vm.expectEmit(address(core));
        emit ICore.PoolInitialized(key.toPoolId(), key, tick, tickToSqrtRatio(tick));

        if (callPoints.afterInitializePool) {
            vm.expectEmit(extension);
            emit MockExtension.AfterInitializePoolCalled(address(this), key, tick, tickToSqrtRatio(tick));
        }

        // call under test
        core.initializePool(key, tick);

        (SqrtRatio _sqrtRatio, int32 _tick,) = core.poolState(key.toPoolId());
        assertTrue(_sqrtRatio == tickToSqrtRatio(tick));
        assertEq(_tick, tick);

        vm.expectRevert(ICore.PoolAlreadyInitialized.selector);
        core.initializePool(key, tick);
    }
}

contract SavedBalancesTest is FullTest {
    using FlashAccountantLib for *;
    using CoreLib for *;

    function locked(uint256) external {
        (address token0, address token1, bytes32 salt, int256 delta0, int256 delta1) =
            abi.decode(msg.data[36:], (address, address, bytes32, int256, int256));

        core.updateSavedBalances(token0, token1, salt, delta0, delta1);

        if (delta0 > 0) {
            core.pay(address(token0), uint128(int128(delta0)));
        } else if (delta0 < 0) {
            core.withdraw(address(token0), address(this), uint128(int128(-delta0)));
        }

        if (delta1 > 0) {
            core.pay(address(token1), uint128(int128(delta1)));
        } else {
            core.withdraw(address(token1), address(this), uint128(int128(-delta1)));
        }
    }

    function updateSavedBalances(address token0, address token1, bytes32 salt, int256 delta0, int256 delta1) internal {
        (bool success, bytes memory returnData) =
            address(core).call(abi.encodeWithSelector(core.lock.selector, token0, token1, salt, delta0, delta1));

        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }

    function test_save_two_tokens() public {
        updateSavedBalances(address(token0), address(token1), bytes32(0), 100, 75);
        (uint128 s0, uint128 s1) = core.savedBalances(address(this), address(token0), address(token1), bytes32(0));
        assertEq(s0, 100);
        assertEq(s1, 75);

        (s0, s1) = core.savedBalances(address(this), address(token0), address(token1), bytes32(uint256(1)));
        assertEq(s0, 0);
        assertEq(s1, 0);

        updateSavedBalances(address(token0), address(token1), bytes32(0), -51, -60);
        (s0, s1) = core.savedBalances(address(this), address(token0), address(token1), bytes32(0));
        assertEq(s0, 49);
        assertEq(s1, 15);
    }

    function test_save_and_load_any_balance(bytes32 salt, int128 delta0, int128 delta1) public {
        delta0 = int128(bound(delta0, 0, type(int128).max));
        delta1 = int128(bound(delta0, 0, type(int128).max));
        updateSavedBalances(address(token0), address(token1), salt, delta0, delta1);
        (uint128 s0, uint128 s1) = core.savedBalances(address(this), address(token0), address(token1), salt);
        assertEq(s0, uint128(delta0));
        assertEq(s1, uint128(delta1));

        updateSavedBalances(address(token0), address(token1), salt, -delta0, -delta1);
        (s0, s1) = core.savedBalances(address(this), address(token0), address(token1), salt);
        assertEq(s0, 0);
        assertEq(s1, 0);
    }

    function test_underflow_always_fails(bytes32 salt, int128 delta0, int128 delta1) public {
        delta0 = int128(bound(delta0, 0, type(int128).max));
        delta1 = int128(bound(delta0, 0, type(int128).max));
        updateSavedBalances(address(token0), address(token1), salt, delta0, delta1);

        vm.expectRevert(ICore.SavedBalanceOverflow.selector);
        updateSavedBalances(address(token0), address(token1), salt, (-delta0) - 1, (-delta1) - 1);

        vm.expectRevert(ICore.SavedBalanceOverflow.selector);
        updateSavedBalances(address(token0), address(token1), salt, (-delta0) - 1, 0);

        vm.expectRevert(ICore.SavedBalanceOverflow.selector);
        updateSavedBalances(address(token0), address(token1), salt, 0, (-delta1) - 1);
    }

    function test_overflow_always_fails(bytes32 salt, int128 delta0, int128 delta1) public {
        delta0 = int128(bound(delta0, 1, type(int128).max));
        delta1 = int128(bound(delta0, 1, type(int128).max));

        // first get it to max
        updateSavedBalances(address(token0), address(token1), salt, type(int128).max, type(int128).max);
        updateSavedBalances(address(token0), address(token1), salt, type(int128).max, type(int128).max);
        updateSavedBalances(address(token0), address(token1), salt, 1, 1);

        (uint128 s0, uint128 s1) = core.savedBalances(address(this), address(token0), address(token1), salt);
        assertEq(s0, type(uint128).max);
        assertEq(s1, type(uint128).max);

        vm.expectRevert(ICore.SavedBalanceOverflow.selector);
        updateSavedBalances(address(token0), address(token1), salt, delta0, delta1);

        vm.expectRevert(ICore.SavedBalanceOverflow.selector);
        updateSavedBalances(address(token0), address(token1), salt, delta0, 0);

        vm.expectRevert(ICore.SavedBalanceOverflow.selector);
        updateSavedBalances(address(token0), address(token1), salt, 0, 1);

        // this will never revert because the balance is max uint128
        updateSavedBalances(address(token0), address(token1), salt, -delta0, -delta1);
        (s0, s1) = core.savedBalances(address(this), address(token0), address(token1), salt);
        assertEq(s0, type(uint128).max - uint128(delta0));
        assertEq(s1, type(uint128).max - uint128(delta1));
    }

    function test_cannot_load_before_save_token0() public {
        vm.expectRevert();
        updateSavedBalances(address(token0), address(token1), bytes32(0), -1, 0);
    }

    function test_cannot_load_before_save_token1() public {
        vm.expectRevert();
        updateSavedBalances(address(token0), address(token1), bytes32(0), 0, -1);
    }

    function test_cannot_update_saved_balance_same_token() public {
        vm.expectRevert(ICore.SavedBalanceTokensNotSorted.selector);
        core.updateSavedBalances(address(0), address(0), bytes32(0), 0, 0);
    }

    function test_cannot_update_saved_balance_token1_gt_token0() public {
        vm.expectRevert(ICore.SavedBalanceTokensNotSorted.selector);
        core.updateSavedBalances(address(1), address(0), bytes32(0), 0, 0);
    }
}
