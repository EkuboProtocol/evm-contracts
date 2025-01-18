// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {Core, CoreLib, IExtension, UpdatePositionParameters, SwapParameters} from "../src/Core.sol";
import {Positions, ITokenURIGenerator} from "../src/Positions.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";
import {PoolKey, PositionKey, Bounds} from "../src/types/keys.sol";
import {CallPoints, byteToCallPoints} from "../src/types/callPoints.sol";
import {TestToken} from "./TestToken.sol";
import {Router} from "../src/Router.sol";
import {ETH_ADDRESS} from "../src/base/TransfersTokens.sol";

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

abstract contract FullTest is Test {
    address immutable owner = address(0xdeadbeefdeadbeef);
    ITokenURIGenerator tokenURIGenerator;
    Core core;
    Positions positions;
    Router router;

    TestToken token0;
    TestToken token1;

    function setUp() public virtual {
        core = new Core(owner);
        tokenURIGenerator = new BaseURLTokenURIGenerator(owner, "ekubo://positions/");
        positions = new Positions(core, tokenURIGenerator);
        router = new Router(core);
        TestToken tokenA = new TestToken();
        TestToken tokenB = new TestToken();
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function createAndRegisterExtension(CallPoints memory callPoints) internal returns (address) {
        address impl = address(new MockExtension());
        uint8 b = callPoints.toUint8();
        address actual = address((uint160(b) << 152) + 0xdeadbeef);
        vm.etch(actual, impl.code);
        MockExtension(actual).register(core, callPoints);
        return actual;
    }

    function createPool(int32 tick, uint128 fee, uint32 tickSpacing) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(tick, fee, tickSpacing, CallPoints(false, false, false, false, false, false, false, false));
    }

    function createPool(int32 tick, uint128 fee, uint32 tickSpacing, CallPoints memory callPoints)
        internal
        returns (PoolKey memory poolKey)
    {
        address extension = (callPoints.isValid()) ? createAndRegisterExtension(callPoints) : address(0);
        poolKey = createPool(tick, fee, tickSpacing, extension);
    }

    // creates a pool of token1/ETH
    function createETHPool(int32 tick, uint128 fee, uint32 tickSpacing) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(ETH_ADDRESS, address(token1), tick, fee, tickSpacing, address(0));
    }

    function createPool(int32 tick, uint128 fee, uint32 tickSpacing, address extension)
        internal
        returns (PoolKey memory poolKey)
    {
        poolKey = createPool(address(token0), address(token1), tick, fee, tickSpacing, extension);
    }

    function createPool(
        address _token0,
        address _token1,
        int32 tick,
        uint128 fee,
        uint32 tickSpacing,
        address extension
    ) internal returns (PoolKey memory poolKey) {
        poolKey = PoolKey({token0: _token0, token1: _token1, fee: fee, tickSpacing: tickSpacing, extension: extension});
        core.initializePool(poolKey, tick);
    }

    function createPosition(PoolKey memory poolKey, Bounds memory bounds, uint128 amount0, uint128 amount1)
        internal
        returns (uint256 id, uint128 liquidity)
    {
        uint256 value;
        if (poolKey.token0 == ETH_ADDRESS) {
            value = amount0;
        } else {
            TestToken(poolKey.token0).approve(address(positions), amount0);
        }
        TestToken(poolKey.token1).approve(address(positions), amount1);

        (id, liquidity) = positions.mintAndDeposit{value: value}(poolKey, bounds, amount0, amount1, 0);
    }
}
