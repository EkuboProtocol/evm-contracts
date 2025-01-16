// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Core, CoreLib, IExtension, UpdatePositionParameters, SwapParameters} from "../src/Core.sol";
import {PoolKey, PositionKey, Bounds} from "../src/types/keys.sol";
import {CallPoints, byteToCallPoints} from "../src/types/callPoints.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, tickToSqrtRatio} from "../src/math/ticks.sol";

contract MockExtension is IExtension {
    function register(Core core, CallPoints calldata expectedCallPoints) external {
        core.registerExtension(expectedCallPoints);
    }

    event BeforeInitializePoolCalled(address caller, PoolKey key, int32 tick);

    function beforeInitializePool(address caller, PoolKey calldata key, int32 tick) external {
        emit BeforeInitializePoolCalled(caller, key, tick);
    }

    event AfterInitializePoolCalled(address caller, PoolKey key, int32 tick, uint256 sqrtRatio);

    function afterInitializePool(address caller, PoolKey calldata key, int32 tick, uint256 sqrtRatio) external {
        emit AfterInitializePoolCalled(caller, key, tick, sqrtRatio);
    }

    event BeforeUpdatePositionCalled(address locker, PoolKey key, UpdatePositionParameters params);

    function beforeUpdatePosition(address locker, PoolKey memory poolKey, UpdatePositionParameters memory params)
        external
    {
        emit BeforeUpdatePositionCalled(locker, poolKey, params);
    }

    event AfterUpdatePositionCalled(
        address locker, PoolKey key, UpdatePositionParameters params, int128 delta0, int128 delta1
    );

    function afterUpdatePosition(
        address locker,
        PoolKey memory poolKey,
        UpdatePositionParameters memory params,
        int128 delta0,
        int128 delta1
    ) external {
        emit AfterUpdatePositionCalled(locker, poolKey, params, delta0, delta1);
    }

    event BeforeSwapCalled(address locker, PoolKey key, SwapParameters params);

    function beforeSwap(address locker, PoolKey memory poolKey, SwapParameters memory params) external {
        emit BeforeSwapCalled(locker, poolKey, params);
    }

    event AfterSwapCalled(address locker, PoolKey key, SwapParameters params, int128 delta0, int128 delta1);

    function afterSwap(
        address locker,
        PoolKey memory poolKey,
        SwapParameters memory params,
        int128 delta0,
        int128 delta1
    ) external {
        emit AfterSwapCalled(locker, poolKey, params, delta0, delta1);
    }

    event BeforeCollectFeesCalled(address locker, PoolKey key, bytes32 salt, Bounds bounds);

    function beforeCollectFees(address locker, PoolKey memory poolKey, bytes32 salt, Bounds memory bounds) external {
        emit BeforeCollectFeesCalled(locker, poolKey, salt, bounds);
    }

    event AfterCollectFeesCalled(
        address locker, PoolKey key, bytes32 salt, Bounds bounds, uint128 amount0, uint128 amount1
    );

    function afterCollectFees(
        address locker,
        PoolKey memory poolKey,
        bytes32 salt,
        Bounds memory bounds,
        uint128 amount0,
        uint128 amount1
    ) external {
        emit AfterCollectFeesCalled(locker, poolKey, salt, bounds, amount0, amount1);
    }
}

contract CoreTest is Test {
    using CoreLib for Core;

    address public owner = address(0xdeadbeef);
    Core public core;

    function setUp() public {
        core = new Core(owner);
    }

    function test_owner() public view {
        assertEq(core.owner(), owner);
    }

    function createAndRegisterExtension(CallPoints memory callPoints) private returns (address) {
        address impl = address(new MockExtension());
        uint8 b = callPoints.toUint8();
        address actual = address((uint160(b) << 152) + 0xdeadbeef);
        vm.etch(actual, impl.code);
        MockExtension(actual).register(core, callPoints);
        return actual;
    }

    function test_registerExtension(uint8 b) public {
        b = uint8(bound(b, 1, type(uint8).max));

        address impl = address(new MockExtension());
        address actual = address((uint160(b) << 152) + 0xdeadbeef);
        vm.etch(actual, impl.code);

        vm.expectRevert(Core.FailedRegisterInvalidCallPoints.selector, address(core));
        MockExtension(actual).register(core, byteToCallPoints(0));
        // b + 1 will always be different
        unchecked {
            vm.expectRevert(Core.FailedRegisterInvalidCallPoints.selector, address(core));
            MockExtension(actual).register(core, byteToCallPoints(b + 1));
        }

        vm.expectEmit(address(core));
        emit Core.ExtensionRegistered(actual);

        MockExtension(actual).register(core, byteToCallPoints(b));

        // double register fails
        vm.expectRevert(Core.ExtensionAlreadyRegistered.selector, address(core));
        MockExtension(actual).register(core, byteToCallPoints(b));
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
        emit Core.PoolInitialized(key, tick, tickToSqrtRatio(tick));

        if (callPoints.afterInitializePool) {
            vm.expectEmit(extension);
            emit MockExtension.AfterInitializePoolCalled(address(this), key, tick, tickToSqrtRatio(tick));
        }

        // call under test
        core.initializePool(key, tick);

        (uint192 _sqrtRatio, int32 _tick) = core.poolPrice(key.toPoolId());
        assertEq(_sqrtRatio, tickToSqrtRatio(tick));
        assertEq(_tick, tick);

        vm.expectRevert(Core.PoolAlreadyInitialized.selector);
        core.initializePool(key, tick);
    }
}
