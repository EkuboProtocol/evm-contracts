// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {CallPoints, addressToCallPoints} from "../../src/types/callPoints.sol";
import {ExtensionCallPointsLib} from "../../src/libraries/ExtensionCallPointsLib.sol";
import {IExtension} from "../../src/interfaces/ICore.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolConfig, createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {PoolState, createPoolState} from "../../src/types/poolState.sol";
import {SwapParameters} from "../../src/types/swapParameters.sol";
import {Locker} from "../../src/types/locker.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";

contract ExtensionCallPointsLibTest is Test {
    using ExtensionCallPointsLib for *;

    function check_shouldCall(IExtension extension, Locker locker) public pure {
        CallPoints memory cp = addressToCallPoints(address(extension));
        bool skipSelfCall = address(extension) == locker.addr();
        assertEq(extension.shouldCallBeforeInitializePool(locker.addr()), cp.beforeInitializePool && !skipSelfCall);
        assertEq(extension.shouldCallAfterInitializePool(locker.addr()), cp.afterInitializePool && !skipSelfCall);
        assertEq(extension.shouldCallBeforeSwap(locker), cp.beforeSwap && !skipSelfCall);
        assertEq(extension.shouldCallAfterSwap(locker), cp.afterSwap && !skipSelfCall);
        assertEq(extension.shouldCallBeforeUpdatePosition(locker), cp.beforeUpdatePosition && !skipSelfCall);
        assertEq(extension.shouldCallAfterUpdatePosition(locker), cp.afterUpdatePosition && !skipSelfCall);
        assertEq(extension.shouldCallBeforeCollectFees(locker), cp.beforeCollectFees && !skipSelfCall);
        assertEq(extension.shouldCallAfterCollectFees(locker), cp.afterCollectFees && !skipSelfCall);
    }

    function test_maybeCallBeforeUpdatePosition() public {
        // Deploy MockExtension at address with beforeUpdatePosition bit set (bit 4 = 16)
        address extensionAddr = address(uint160(16) << 152); // Set bit 4 in top byte
        MockExtension extension = new MockExtension();
        vm.etch(extensionAddr, address(extension).code);
        extension = MockExtension(extensionAddr);

        Locker locker = Locker.wrap(bytes32(uint256(uint160(address(0x1234)))));
        PoolKey memory poolKey = PoolKey({
            token0: address(0x1111),
            token1: address(0x2222),
            config: createConcentratedPoolConfig(100, 60, address(0x3333))
        });
        PositionId positionId = createPositionId(bytes24(uint192(0x4444)), -100, 100);
        int128 liquidityDelta = 1000;

        // Test when extension should be called
        IExtension(address(extension)).maybeCallBeforeUpdatePosition(locker, poolKey, positionId, liquidityDelta);

        assertEq(extension.beforeUpdatePositionCalls(), 1);
        assertEq(Locker.unwrap(extension.lastLocker()), Locker.unwrap(locker));
        assertEq(extension.lastPoolKey().token0, poolKey.token0);
        assertEq(extension.lastPoolKey().token1, poolKey.token1);
        assertEq(PoolConfig.unwrap(extension.lastPoolKey().config), PoolConfig.unwrap(poolKey.config));
        assertEq(PositionId.unwrap(extension.lastPositionId()), PositionId.unwrap(positionId));
        assertEq(extension.lastLiquidityDelta(), liquidityDelta);

        // Test when extension should not be called (locker == extension)
        extension.reset();
        IExtension(address(extension))
            .maybeCallBeforeUpdatePosition(
                Locker.wrap(bytes32(uint256(uint160(address(extension))))), poolKey, positionId, liquidityDelta
            );
        assertEq(extension.beforeUpdatePositionCalls(), 0);
    }

    function test_maybeCallAfterUpdatePosition() public {
        // Deploy MockExtension at address with afterUpdatePosition bit set (bit 3 = 8)
        address extensionAddr = address(uint160(8) << 152); // Set bit 3 in top byte
        MockExtension extension = new MockExtension();
        vm.etch(extensionAddr, address(extension).code);
        extension = MockExtension(extensionAddr);

        Locker locker = Locker.wrap(bytes32(uint256(uint160(address(0x1234)))));
        PoolKey memory poolKey = PoolKey({
            token0: address(0x1111),
            token1: address(0x2222),
            config: createConcentratedPoolConfig(100, 60, address(0x3333))
        });
        PositionId positionId = createPositionId(bytes24(uint192(0x4444)), -100, 100);
        int128 liquidityDelta = 1000;
        int128 delta0 = 500;
        int128 delta1 = -300;
        PoolState stateAfter = createPoolState(SqrtRatio.wrap(100), 0, 2000);

        // Test when extension should be called
        PoolBalanceUpdate balanceUpdate = createPoolBalanceUpdate(delta0, delta1);
        IExtension(address(extension))
            .maybeCallAfterUpdatePosition(locker, poolKey, positionId, liquidityDelta, balanceUpdate, stateAfter);

        assertEq(extension.afterUpdatePositionCalls(), 1);
        assertEq(Locker.unwrap(extension.lastLocker()), Locker.unwrap(locker));
        assertEq(extension.lastPoolKey().token0, poolKey.token0);
        assertEq(extension.lastPoolKey().token1, poolKey.token1);
        assertEq(PoolConfig.unwrap(extension.lastPoolKey().config), PoolConfig.unwrap(poolKey.config));
        assertEq(PositionId.unwrap(extension.lastPositionId()), PositionId.unwrap(positionId));
        assertEq(extension.lastLiquidityDelta(), liquidityDelta);
        assertEq(extension.lastDelta0(), delta0);
        assertEq(extension.lastDelta1(), delta1);
        assertEq(PoolState.unwrap(extension.lastStateAfter()), PoolState.unwrap(stateAfter));

        // Test when extension should not be called (locker == extension)
        extension.reset();
        IExtension(address(extension))
            .maybeCallAfterUpdatePosition(
                Locker.wrap(bytes32(uint256(uint160(address(extension))))),
                poolKey,
                positionId,
                liquidityDelta,
                balanceUpdate,
                stateAfter
            );
        assertEq(extension.afterUpdatePositionCalls(), 0);
    }

    function test_maybeCallBeforeCollectFees() public {
        // Deploy MockExtension at address with beforeCollectFees bit set (bit 2 = 4)
        address extensionAddr = address(uint160(4) << 152); // Set bit 2 in top byte
        MockExtension extension = new MockExtension();
        vm.etch(extensionAddr, address(extension).code);
        extension = MockExtension(extensionAddr);

        Locker locker = Locker.wrap(bytes32(uint256(uint160(address(0x1234)))));
        PoolKey memory poolKey = PoolKey({
            token0: address(0x1111),
            token1: address(0x2222),
            config: createConcentratedPoolConfig(100, 60, address(0x3333))
        });
        PositionId positionId = createPositionId(bytes24(uint192(0x4444)), -100, 100);

        // Test when extension should be called
        IExtension(address(extension)).maybeCallBeforeCollectFees(locker, poolKey, positionId);

        assertEq(extension.beforeCollectFeesCalls(), 1);
        assertEq(Locker.unwrap(extension.lastLocker()), Locker.unwrap(locker));
        assertEq(extension.lastPoolKey().token0, poolKey.token0);
        assertEq(extension.lastPoolKey().token1, poolKey.token1);
        assertEq(PoolConfig.unwrap(extension.lastPoolKey().config), PoolConfig.unwrap(poolKey.config));
        assertEq(PositionId.unwrap(extension.lastPositionId()), PositionId.unwrap(positionId));

        // Test when extension should not be called (locker == extension)
        extension.reset();
        IExtension(address(extension))
            .maybeCallBeforeCollectFees(Locker.wrap(bytes32(uint256(uint160(address(extension))))), poolKey, positionId);
        assertEq(extension.beforeCollectFeesCalls(), 0);
    }

    function test_maybeCallAfterCollectFees() public {
        // Deploy MockExtension at address with afterCollectFees bit set (bit 1 = 2)
        address extensionAddr = address(uint160(2) << 152); // Set bit 1 in top byte
        MockExtension extension = new MockExtension();
        vm.etch(extensionAddr, address(extension).code);
        extension = MockExtension(extensionAddr);

        Locker locker = Locker.wrap(bytes32(uint256(uint160(address(0x1234)))));
        PoolKey memory poolKey = PoolKey({
            token0: address(0x1111),
            token1: address(0x2222),
            config: createConcentratedPoolConfig(100, 60, address(0x3333))
        });
        PositionId positionId = createPositionId(bytes24(uint192(0x4444)), -100, 100);
        uint128 amount0 = 1000;
        uint128 amount1 = 2000;

        // Test when extension should be called
        IExtension(address(extension)).maybeCallAfterCollectFees(locker, poolKey, positionId, amount0, amount1);

        assertEq(extension.afterCollectFeesCalls(), 1);
        assertEq(Locker.unwrap(extension.lastLocker()), Locker.unwrap(locker));
        assertEq(extension.lastPoolKey().token0, poolKey.token0);
        assertEq(extension.lastPoolKey().token1, poolKey.token1);
        assertEq(PoolConfig.unwrap(extension.lastPoolKey().config), PoolConfig.unwrap(poolKey.config));
        assertEq(PositionId.unwrap(extension.lastPositionId()), PositionId.unwrap(positionId));
        assertEq(extension.lastAmount0(), amount0);
        assertEq(extension.lastAmount1(), amount1);

        // Test when extension should not be called (locker == extension)
        extension.reset();
        IExtension(address(extension))
            .maybeCallAfterCollectFees(
                Locker.wrap(bytes32(uint256(uint160(address(extension))))), poolKey, positionId, amount0, amount1
            );
        assertEq(extension.afterCollectFeesCalls(), 0);
    }

    function test_maybeCallRevertsBubbleUp() public {
        // Deploy MockExtension at address with all relevant bits set (16 + 8 + 4 + 2 = 30)
        address extensionAddr = address(uint160(30) << 152); // Set bits for all four methods
        MockExtension extension = new MockExtension();
        vm.etch(extensionAddr, address(extension).code);
        extension = MockExtension(extensionAddr);

        extension.setShouldRevert(true);
        Locker locker = Locker.wrap(bytes32(uint256(uint160(address(0x1234)))));
        PoolKey memory poolKey = PoolKey({
            token0: address(0x1111),
            token1: address(0x2222),
            config: createConcentratedPoolConfig(100, 60, address(0x3333))
        });
        PositionId positionId = createPositionId(bytes24(uint192(0x4444)), -100, 100);
        PoolState stateAfter = createPoolState(SqrtRatio.wrap(100), 1, 1);

        // Test that reverts bubble up for all maybeCall methods
        vm.expectRevert("MockExtension: revert");
        IExtension(address(extension)).maybeCallBeforeUpdatePosition(locker, poolKey, positionId, 1000);

        vm.expectRevert("MockExtension: revert");
        PoolBalanceUpdate revertBalanceUpdate = createPoolBalanceUpdate(500, -300);
        IExtension(address(extension))
            .maybeCallAfterUpdatePosition(locker, poolKey, positionId, 1000, revertBalanceUpdate, stateAfter);

        vm.expectRevert("MockExtension: revert");
        IExtension(address(extension)).maybeCallBeforeCollectFees(locker, poolKey, positionId);

        vm.expectRevert("MockExtension: revert");
        IExtension(address(extension)).maybeCallAfterCollectFees(locker, poolKey, positionId, 1000, 2000);
    }
}

contract MockExtension is IExtension {
    uint256 public beforeUpdatePositionCalls;
    uint256 public afterUpdatePositionCalls;
    uint256 public beforeCollectFeesCalls;
    uint256 public afterCollectFeesCalls;

    Locker public lastLocker;
    PoolKey private _lastPoolKey;
    PositionId public lastPositionId;
    int128 public lastLiquidityDelta;
    int128 public lastDelta0;
    int128 public lastDelta1;
    uint128 public lastAmount0;
    uint128 public lastAmount1;
    PoolState public lastStateAfter;

    bool public shouldRevert;

    function lastPoolKey() external view returns (PoolKey memory) {
        return _lastPoolKey;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function reset() external {
        beforeUpdatePositionCalls = 0;
        afterUpdatePositionCalls = 0;
        beforeCollectFeesCalls = 0;
        afterCollectFeesCalls = 0;
        lastLocker = Locker.wrap(bytes32(0));
        delete _lastPoolKey;
        lastPositionId = PositionId.wrap(0);
        lastLiquidityDelta = 0;
        lastDelta0 = 0;
        lastDelta1 = 0;
        lastAmount0 = 0;
        lastAmount1 = 0;
    }

    function beforeInitializePool(address, PoolKey calldata, int32) external pure {
        revert("Not implemented");
    }

    function afterInitializePool(address, PoolKey calldata, int32, SqrtRatio) external pure {
        revert("Not implemented");
    }

    function beforeUpdatePosition(Locker locker, PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        external
    {
        if (shouldRevert) revert("MockExtension: revert");
        beforeUpdatePositionCalls++;
        lastLocker = locker;
        _lastPoolKey = poolKey;
        lastPositionId = positionId;
        lastLiquidityDelta = liquidityDelta;
    }

    function afterUpdatePosition(
        Locker locker,
        PoolKey memory poolKey,
        PositionId positionId,
        int128 liquidityDelta,
        PoolBalanceUpdate balanceUpdate,
        PoolState stateAfter
    ) external {
        if (shouldRevert) revert("MockExtension: revert");
        afterUpdatePositionCalls++;
        lastLocker = locker;
        _lastPoolKey = poolKey;
        lastPositionId = positionId;
        lastLiquidityDelta = liquidityDelta;
        (lastDelta0, lastDelta1) = (balanceUpdate.delta0(), balanceUpdate.delta1());
        lastStateAfter = stateAfter;
    }

    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure {
        revert("Not implemented");
    }

    function afterSwap(Locker, PoolKey memory, SwapParameters, PoolBalanceUpdate, PoolState) external pure {
        revert("Not implemented");
    }

    function beforeCollectFees(Locker locker, PoolKey memory poolKey, PositionId positionId) external {
        if (shouldRevert) revert("MockExtension: revert");
        beforeCollectFeesCalls++;
        lastLocker = locker;
        _lastPoolKey = poolKey;
        lastPositionId = positionId;
    }

    function afterCollectFees(
        Locker locker,
        PoolKey memory poolKey,
        PositionId positionId,
        uint128 amount0,
        uint128 amount1
    ) external {
        if (shouldRevert) revert("MockExtension: revert");
        afterCollectFeesCalls++;
        lastLocker = locker;
        _lastPoolKey = poolKey;
        lastPositionId = positionId;
        lastAmount0 = amount0;
        lastAmount1 = amount1;
    }
}
