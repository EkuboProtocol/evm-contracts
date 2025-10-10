// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {ICore, IExtension} from "../src/interfaces/ICore.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {Core} from "../src/Core.sol";
import {Positions} from "../src/Positions.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolConfig, createFullRangePoolConfig, createConcentratedPoolConfig} from "../src/types/poolConfig.sol";
import {PositionId} from "../src/types/positionId.sol";
import {CallPoints, byteToCallPoints} from "../src/types/callPoints.sol";
import {TestToken} from "./TestToken.sol";
import {Router} from "../src/Router.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {PoolState} from "../src/types/poolState.sol";
import {SwapParameters} from "../src/types/swapParameters.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";
import {Locker} from "../src/types/locker.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";

contract MockExtension is IExtension, BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

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

    event BeforeUpdatePositionCalled(Locker locker, PoolKey poolKey, PositionId positionId, int128 liquidityDelta);

    function beforeUpdatePosition(Locker locker, PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        external
    {
        emit BeforeUpdatePositionCalled(locker, poolKey, positionId, liquidityDelta);
    }

    event AfterUpdatePositionCalled(
        Locker locker,
        PoolKey poolKey,
        PositionId positionId,
        int128 liquidityDelta,
        int128 delta0,
        int128 delta1,
        PoolState stateAfter
    );

    function afterUpdatePosition(
        Locker locker,
        PoolKey memory poolKey,
        PositionId positionId,
        int128 liquidityDelta,
        PoolBalanceUpdate balanceUpdate,
        PoolState stateAfter
    ) external {
        (int128 delta0, int128 delta1) = balanceUpdate.parse();
        emit AfterUpdatePositionCalled(locker, poolKey, positionId, liquidityDelta, delta0, delta1, stateAfter);
    }

    event BeforeSwapCalled(
        Locker locker, PoolKey poolKey, int128 amount, bool isToken1, SqrtRatio sqrtRatioLimit, uint256 skipAhead
    );

    function beforeSwap(Locker locker, PoolKey memory poolKey, SwapParameters params) external {
        emit BeforeSwapCalled(
            locker, poolKey, params.amount(), params.isToken1(), params.sqrtRatioLimit(), params.skipAhead()
        );
    }

    event AfterSwapCalled(
        Locker locker,
        PoolKey poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead,
        int128 delta0,
        int128 delta1,
        PoolState stateAfter
    );

    function afterSwap(
        Locker locker,
        PoolKey memory poolKey,
        SwapParameters params,
        PoolBalanceUpdate balanceUpdate,
        PoolState stateAfter
    ) external {
        (int128 delta0, int128 delta1) = balanceUpdate.parse();
        emit AfterSwapCalled(
            locker,
            poolKey,
            params.amount(),
            params.isToken1(),
            params.sqrtRatioLimit(),
            params.skipAhead(),
            delta0,
            delta1,
            stateAfter
        );
    }

    event BeforeCollectFeesCalled(Locker locker, PoolKey poolKey, PositionId positionId);

    function beforeCollectFees(Locker locker, PoolKey memory poolKey, PositionId positionId) external {
        emit BeforeCollectFeesCalled(locker, poolKey, positionId);
    }

    event AfterCollectFeesCalled(
        Locker locker, PoolKey poolKey, PositionId positionId, uint128 amount0, uint128 amount1
    );

    function afterCollectFees(
        Locker locker,
        PoolKey memory poolKey,
        PositionId positionId,
        uint128 amount0,
        uint128 amount1
    ) external {
        emit AfterCollectFeesCalled(locker, poolKey, positionId, amount0, amount1);
    }

    function accumulateFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) external {
        lock(abi.encode(msg.sender, poolKey, amount0, amount1));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address sender, PoolKey memory poolKey, uint128 amount0, uint128 amount1) =
            abi.decode(data, (address, PoolKey, uint128, uint128));

        ICore(payable(ACCOUNTANT)).accumulateAsFees(poolKey, amount0, amount1);
        if (amount0 != 0) {
            if (poolKey.token0 == NATIVE_TOKEN_ADDRESS) {
                SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount0);
            } else {
                ACCOUNTANT.payFrom(sender, poolKey.token0, amount0);
            }
        }
        if (amount1 != 0) {
            ACCOUNTANT.payFrom(sender, poolKey.token1, amount1);
        }
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

    function createAndRegisterExtension() internal returns (MockExtension) {
        return createAndRegisterExtension(byteToCallPoints(0xff));
    }

    function createAndRegisterExtension(CallPoints memory callPoints) internal returns (MockExtension) {
        address impl = address(new MockExtension(core));
        uint8 b = callPoints.toUint8();
        address actual = address((uint160(b) << 152) + 0xdeadbeef);
        vm.etch(actual, impl.code);
        MockExtension(actual).register(core, callPoints);
        return MockExtension(actual);
    }

    function createPool(int32 tick, uint64 fee, uint32 tickSpacing) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(tick, fee, tickSpacing, CallPoints(false, false, false, false, false, false, false, false));
    }

    function createFullRangePool(int32 tick, uint64 fee) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(address(token0), address(token1), tick, createFullRangePoolConfig(fee, address(0)));
    }

    function createFullRangePool(int32 tick, uint64 fee, address extension) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(address(token0), address(token1), tick, createFullRangePoolConfig(fee, extension));
    }

    function createPool(int32 tick, uint64 fee, uint32 tickSpacing, CallPoints memory callPoints)
        internal
        returns (PoolKey memory poolKey)
    {
        address extension = callPoints.isValid() ? address(createAndRegisterExtension(callPoints)) : address(0);
        poolKey = createPool(tick, fee, tickSpacing, address(extension));
    }

    function createFullRangeETHPool(int32 tick, uint64 fee) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(NATIVE_TOKEN_ADDRESS, address(token1), tick, createFullRangePoolConfig(fee, address(0)));
    }

    // creates a pool of token1/ETH
    function createETHPool(int32 tick, uint64 fee, uint32 tickSpacing) internal returns (PoolKey memory poolKey) {
        poolKey = createPool(
            NATIVE_TOKEN_ADDRESS, address(token1), tick, createConcentratedPoolConfig(fee, tickSpacing, address(0))
        );
    }

    function createPool(int32 tick, uint64 fee, uint32 tickSpacing, address extension)
        internal
        returns (PoolKey memory poolKey)
    {
        poolKey = createPool(
            address(token0), address(token1), tick, createConcentratedPoolConfig(fee, tickSpacing, extension)
        );
    }

    function createPool(address _token0, address _token1, int32 tick, PoolConfig config)
        internal
        returns (PoolKey memory poolKey)
    {
        poolKey = PoolKey({token0: _token0, token1: _token1, config: config});
        core.initializePool(poolKey, tick);
    }

    function createPosition(PoolKey memory poolKey, int32 tickLower, int32 tickUpper, uint128 amount0, uint128 amount1)
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

        (id, liquidity,,) = positions.mintAndDeposit{value: value}(poolKey, tickLower, tickUpper, amount0, amount1, 0);
    }

    function advanceTime(uint32 by) internal returns (uint256 next) {
        next = vm.getBlockTimestamp() + by;
        vm.warp(next);
    }

    receive() external payable {}
}
