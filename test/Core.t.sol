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

    function payCallback(uint256, address token) external {
        uint256 amount;
        assembly ("memory-safe") {
            amount := calldataload(68)
        }
        IERC20(token).transfer(address(core), amount);
    }

    function locked(uint256) external {
        uint256 length;
        assembly ("memory-safe") {
            length := calldatasize()
        }
        // saving or loading 1 token
        if (length == 164) {
            address saveTo;
            address token;
            bytes32 salt;
            uint128 amount;
            assembly ("memory-safe") {
                saveTo := calldataload(36)
                token := calldataload(68)
                salt := calldataload(100)
                amount := calldataload(132)
            }
            if (saveTo == address(0)) {
                core.load(token, salt, amount);
                core.withdraw(token, address(this), amount);
            } else {
                core.save(token, salt, amount);
                core.pay(token, amount);
            }
        } else if (length == 228) {
            address saveTo;
            address token0;
            address token1;
            bytes32 salt;
            uint128 amount0;
            uint128 amount1;
            assembly ("memory-safe") {
                saveTo := calldataload(36)
                token0 := calldataload(68)
                token1 := calldataload(100)
                salt := calldataload(132)
                amount0 := calldataload(164)
                amount1 := calldataload(196)
            }
            if (saveTo == address(0)) {
                core.updateSavedBalances(token0, token1, bytes32(0), -int128(amount0), -int128(amount1));
                core.withdraw(token0, address(this), amount0);
                core.withdraw(token1, address(this), amount1);
            } else {
                core.updateSavedBalances(token0, token1, bytes32(0), int128(amount0), int128(amount1));

                (bool success,) =
                    address(core).call(abi.encodeWithSelector(core.startPayments.selector, token0, token1));
                assertTrue(success);

                IERC20(token0).transfer(address(core), amount0);
                IERC20(token1).transfer(address(core), amount1);

                (success,) = address(core).call(abi.encodeWithSelector(core.completePayments.selector, token0, token1));
                assertTrue(success);
            }
        } else {
            revert();
        }
    }

    function test_save_single_token() public {
        (bool success,) = address(core).call(
            abi.encodeWithSelector(core.lock.selector, address(this), address(token0), bytes32(0), 100)
        );
        assertTrue(success);
        assertEq(core.savedBalances(address(this), address(token0), bytes32(0)), 100);

        (success,) =
            address(core).call(abi.encodeWithSelector(core.lock.selector, address(0), address(token0), bytes32(0), 50));
        assertTrue(success);
        assertEq(core.savedBalances(address(this), address(token0), bytes32(0)), 50);
    }

    function test_save_two_tokens() public {
        (bool success,) = address(core).call(
            abi.encodeWithSelector(
                core.lock.selector, address(this), address(token0), address(token1), bytes32(0), 100, 75
            )
        );
        assertTrue(success);
        assertEq(core.savedBalances(address(this), address(token0), bytes32(0)), 0);
        assertEq(core.savedBalances(address(this), address(token1), bytes32(0)), 0);
        (uint128 s0, uint128 s1) = core.savedBalances(address(this), address(token0), address(token1), bytes32(0));
        assertEq(s0, 100);
        assertEq(s1, 75);

        (s0, s1) = core.savedBalances(address(this), address(token0), address(token1), bytes32(uint256(1)));
        assertEq(s0, 0);
        assertEq(s1, 0);

        (success,) = address(core).call(
            abi.encodeWithSelector(core.lock.selector, address(0), address(token0), address(token1), bytes32(0), 51, 60)
        );
        assertTrue(success);
        (s0, s1) = core.savedBalances(address(this), address(token0), address(token1), bytes32(0));
        assertEq(s0, 49);
        assertEq(s1, 15);
    }

    function test_save_load_cannot_overflow_token0() public {
        (bool success,) = address(core).call(
            abi.encodeWithSelector(
                core.lock.selector, address(this), address(token0), address(token1), bytes32(0), type(int128).max, 1
            )
        );
        assertTrue(success);

        (success,) = address(core).call(
            abi.encodeWithSelector(
                core.lock.selector, address(this), address(token0), address(token1), bytes32(0), type(int128).max, 0
            )
        );
        assertFalse(success);
        (uint128 s0, uint128 s1) = core.savedBalances(address(this), address(token0), address(token1), bytes32(0));
        assertEq(s0, type(uint128).max);
        assertEq(s1, 1);
    }

    function test_save_load_cannot_overflow_token1() public {
        (bool success,) = address(core).call(
            abi.encodeWithSelector(
                core.lock.selector, address(this), address(token0), address(token1), bytes32(0), 1, type(uint128).max
            )
        );
        assertTrue(success);

        (success,) = address(core).call(
            abi.encodeWithSelector(
                core.lock.selector, address(this), address(token0), address(token1), bytes32(0), 0, 1
            )
        );
        assertFalse(success);
        (uint128 s0, uint128 s1) = core.savedBalances(address(this), address(token0), address(token1), bytes32(0));
        assertEq(s0, 1);
        assertEq(s1, type(uint128).max);
    }

    function test_load_must_comes_from_owner() public {
        address owner = address(0xdeadbeef);
        (bool success,) = address(core).call(
            abi.encodeWithSelector(core.lock.selector, owner, address(token0), address(token1), bytes32(0), 100, 100)
        );
        assertTrue(success);

        (uint128 s0, uint128 s1) = core.savedBalances(owner, address(token0), address(token1), bytes32(0));
        assertEq(s0, 100, "saved balance0");
        assertEq(s1, 100, "saved balance1");

        (success,) = address(core).call(
            abi.encodeWithSelector(core.lock.selector, address(0), address(token0), address(token1), bytes32(0), 1, 1)
        );
        assertFalse(success);
    }

    function test_cannot_load_before_save_token0() public {
        (bool success,) = address(core).call(
            abi.encodeWithSelector(core.lock.selector, address(0), address(token0), address(token1), bytes32(0), 1, 0)
        );
        assertFalse(success);
    }

    function test_cannot_load_before_save_token1() public {
        (bool success,) = address(core).call(
            abi.encodeWithSelector(core.lock.selector, address(0), address(token0), address(token1), bytes32(0), 0, 1)
        );
        assertFalse(success);
    }

    function test_cannot_load_before_save() public {
        (bool success,) =
            address(core).call(abi.encodeWithSelector(core.lock.selector, address(0), address(token0), bytes32(0), 1));
        assertFalse(success);
    }

    function test_cannot_update_saved_balance_same_token() public {
        vm.expectRevert(ICore.SavedBalanceTokensNotSorted.selector);
        core.updateSavedBalances(address(0), address(0), bytes32(0), 0, 0);
    }

    function test_cannot_update_saved_balance_token1_gt_token0() public {
        vm.expectRevert(ICore.SavedBalanceTokensNotSorted.selector);
        core.updateSavedBalances(address(1), address(0), bytes32(0), 0, 0);
    }

    function test_cannot_load_same_token() public {
        (bool success,) = address(core).call(
            abi.encodeWithSelector(core.lock.selector, address(0), address(token0), address(token0), bytes32(0), 1, 1)
        );
        assertFalse(success);
    }

    function test_cannot_load_same_token_no_op() public {
        (bool success,) = address(core).call(
            abi.encodeWithSelector(core.lock.selector, address(0), address(token0), address(token0), bytes32(0), 0, 0)
        );
        assertFalse(success);
    }

    function test_salt_separates_balances() public {
        (bool success,) = address(core).call(
            abi.encodeWithSelector(core.lock.selector, address(0xdeadbeef), address(token0), bytes32(uint256(1)), 1)
        );
        assertTrue(success);

        (success,) = address(core).call(
            abi.encodeWithSelector(core.lock.selector, address(0), address(token0), bytes32(uint256(2)), 1)
        );
        assertFalse(success);
    }
}
