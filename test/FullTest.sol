// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ICore, IExtension, UpdatePositionParameters} from "../src/interfaces/ICore.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {Core} from "../src/Core.sol";
import {Positions} from "../src/Positions.sol";
import {PoolKey, toConfig} from "../src/types/poolKey.sol";
import {PositionKey, Bounds} from "../src/types/positionKey.sol";
import {CallPoints, byteToCallPoints} from "../src/types/callPoints.sol";
import {TestToken} from "./TestToken.sol";
import {Router} from "../src/Router.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";

contract MockExtension is IExtension {
    function register(ICore core, CallPoints calldata expectedCallPoints) external {
        core.registerExtension(expectedCallPoints);
    }

    event BeforeInitializePoolCalled(address caller, PoolKey poolKey, int32 tick);

    function beforeInitializePool(address caller, PoolKey calldata key, int32 tick) external {
        emit BeforeInitializePoolCalled(caller, key, tick);
    }

    event AfterInitializePoolCalled(address caller, PoolKey poolKey, int32 tick, SqrtRatio sqrtRatio);

    function afterInitializePool(address caller, PoolKey calldata key, int32 tick, SqrtRatio sqrtRatio) external {
        emit AfterInitializePoolCalled(caller, key, tick, sqrtRatio);
    }

    event BeforeUpdatePositionCalled(address locker, PoolKey poolKey, UpdatePositionParameters params);

    function beforeUpdatePosition(address locker, PoolKey memory poolKey, UpdatePositionParameters memory params)
        external
    {
        emit BeforeUpdatePositionCalled(locker, poolKey, params);
    }

    event AfterUpdatePositionCalled(
        address locker, PoolKey poolKey, UpdatePositionParameters params, int128 delta0, int128 delta1
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

    event BeforeSwapCalled(
        address locker, PoolKey poolKey, int128 amount, bool isToken1, SqrtRatio sqrtRatioLimit, uint256 skipAhead
    );

    function beforeSwap(
        address locker,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) external {
        emit BeforeSwapCalled(locker, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);
    }

    event AfterSwapCalled(
        address locker,
        PoolKey poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead,
        int128 delta0,
        int128 delta1
    );

    function afterSwap(
        address locker,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead,
        int128 delta0,
        int128 delta1
    ) external {
        emit AfterSwapCalled(locker, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead, delta0, delta1);
    }

    event BeforeCollectFeesCalled(address locker, PoolKey poolKey, bytes32 salt, Bounds bounds);

    function beforeCollectFees(address locker, PoolKey memory poolKey, bytes32 salt, Bounds memory bounds) external {
        emit BeforeCollectFeesCalled(locker, poolKey, salt, bounds);
    }

    event AfterCollectFeesCalled(
        address locker, PoolKey poolKey, bytes32 salt, Bounds bounds, uint128 amount0, uint128 amount1
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

abstract contract FullTest is Test {
    address immutable owner = makeAddr("owner");
    Core core;
    Positions positions;
    Router router;

    TestToken token0;
    TestToken token1;

    function setUp() public virtual {
        core = new Core();
        positions = new Positions(core, owner, 0, 1);
        router = new Router(core);
        TestToken tokenA = new TestToken(address(this));
        TestToken tokenB = new TestToken(address(this));
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function coolAllContracts() internal virtual {
        vm.cool(address(core));
        vm.cool(address(positions));
        vm.cool(address(router));
        vm.cool(address(token0));
        vm.cool(address(token1));
        vm.cool(address(this));
    }

    function createAndRegisterExtension(CallPoints memory callPoints) internal returns (address) {
        address impl = address(new MockExtension());
        uint8 b = callPoints.toUint8();
        address actual = address((uint160(b) << 152) + 0xdeadbeef);
        vm.etch(actual, impl.code);
        MockExtension(actual).register(core, callPoints);
        return actual;
    }

    function createPool(int32 tick, uint64 fee, uint32 tickSpacing) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(tick, fee, tickSpacing, CallPoints(false, false, false, false, false, false, false, false));
    }

    function createPool(int32 tick, uint64 fee, uint32 tickSpacing, CallPoints memory callPoints)
        internal
        returns (PoolKey memory poolKey)
    {
        address extension = (callPoints.isValid()) ? createAndRegisterExtension(callPoints) : address(0);
        poolKey = createPool(tick, fee, tickSpacing, extension);
    }

    // creates a pool of token1/ETH
    function createETHPool(int32 tick, uint64 fee, uint32 tickSpacing) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(NATIVE_TOKEN_ADDRESS, address(token1), tick, fee, tickSpacing, address(0));
    }

    function createPool(int32 tick, uint64 fee, uint32 tickSpacing, address extension)
        internal
        returns (PoolKey memory poolKey)
    {
        poolKey = createPool(address(token0), address(token1), tick, fee, tickSpacing, extension);
    }

    function createPool(address _token0, address _token1, int32 tick, uint64 fee, uint32 tickSpacing, address extension)
        internal
        returns (PoolKey memory poolKey)
    {
        poolKey = PoolKey({token0: _token0, token1: _token1, config: toConfig(fee, tickSpacing, extension)});
        core.initializePool(poolKey, tick);
    }

    function createPosition(PoolKey memory poolKey, Bounds memory bounds, uint128 amount0, uint128 amount1)
        internal
        returns (uint256 id, uint128 liquidity)
    {
        uint256 value;
        if (poolKey.token0 == NATIVE_TOKEN_ADDRESS) {
            value = amount0;
        } else {
            TestToken(poolKey.token0).approve(address(positions), amount0);
        }
        TestToken(poolKey.token1).approve(address(positions), amount1);

        (id, liquidity,,) = positions.mintAndDeposit{value: value}(poolKey, bounds, amount0, amount1, 0);
    }

    function advanceTime(uint32 by) internal returns (uint256 next) {
        next = vm.getBlockTimestamp() + by;
        vm.warp(next);
    }

    receive() external payable {}
}
