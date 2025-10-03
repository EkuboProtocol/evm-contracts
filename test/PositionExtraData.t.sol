// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {Core} from "../src/Core.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {TestToken} from "./TestToken.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolConfig, createPoolConfig} from "../src/types/poolConfig.sol";
import {PoolId} from "../src/types/poolId.sol";
import {Position} from "../src/types/position.sol";
import {PositionId, createPositionId} from "../src/types/positionId.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {UsesCore} from "../src/base/UsesCore.sol";

contract TestLocker is BaseLocker, UsesCore {
    using CoreLib for *;
    using FlashAccountantLib for *;

    TestToken public immutable token0;
    TestToken public immutable token1;

    constructor(ICore core, TestToken _token0, TestToken _token1) BaseLocker(core) UsesCore(core) {
        token0 = _token0;
        token1 = _token1;
    }

    function doLock(bytes memory data) external returns (bytes memory) {
        return lock(data);
    }

    function setExtraData(PoolId poolId, PositionId positionId, bytes16 extraData) external {
        CORE.setExtraData(poolId, positionId, extraData);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta) =
            abi.decode(data, (PoolKey, PositionId, int128));

        (int128 delta0, int128 delta1) = CORE.updatePosition(poolKey, positionId, liquidityDelta);

        if (liquidityDelta > 0) {
            ACCOUNTANT.pay(poolKey.token0, uint128(delta0));
            ACCOUNTANT.pay(poolKey.token1, uint128(delta1));
        } else if (liquidityDelta < 0) {
            ACCOUNTANT.withdraw(poolKey.token0, address(this), uint128(-delta0));
            ACCOUNTANT.withdraw(poolKey.token1, address(this), uint128(-delta1));
        }
    }
}

contract PositionExtraDataTest is Test {
    using CoreLib for *;

    Core public core;
    TestLocker public locker;
    TestToken public token0;
    TestToken public token1;
    PoolKey public poolKey;

    function setUp() public {
        core = new Core();

        token0 = new TestToken(address(this));
        token1 = new TestToken(address(this));

        locker = new TestLocker(core, token0, token1);

        token0.transfer(address(locker), type(uint128).max);
        token1.transfer(address(locker), type(uint128).max);

        poolKey =
            PoolKey({token0: address(token0), token1: address(token1), config: createPoolConfig(3000, 60, address(0))});

        core.initializePool(poolKey, 0);
    }

    function test_updatePosition_with_extraData_fails_if_liquidity_is_zero(
        PoolId poolId,
        PositionId positionId,
        bytes16 extraData
    ) public {
        vm.expectRevert(ICore.PositionDoesNotExist.selector);
        locker.setExtraData(poolId, positionId, extraData);
    }

    function test_updatePosition_with_extraData(uint128 liquidity, bytes16 extraData) public {
        liquidity = uint128(bound(liquidity, 1, type(uint64).max));
        PositionId positionId = createPositionId({_salt: bytes24(0), _tickLower: -60, _tickUpper: 60});

        locker.doLock(abi.encode(poolKey, positionId, int128(liquidity)));

        Position memory position = core.poolPositions(poolKey.toPoolId(), address(locker), positionId);

        assertEq(position.extraData, bytes16(0), "extraData should be zero at create");
        assertEq(position.liquidity, liquidity, "liquidity should equal what we set");

        locker.setExtraData(poolKey.toPoolId(), positionId, extraData);
        position = core.poolPositions(poolKey.toPoolId(), address(locker), positionId);
        assertEq(position.extraData, extraData, "extraData should change after setExtraData");
        assertEq(position.liquidity, liquidity, "liquidity should still equal what we set");
    }

    function test_updatePosition_extraData_must_be_zero_when_withdrawing_all(
        uint128 liquidity,
        bytes16 extraDataNonZero
    ) public {
        vm.assume(extraDataNonZero != bytes16(0));
        liquidity = uint128(bound(liquidity, 1, type(uint64).max));

        PositionId positionId = createPositionId({_salt: bytes24(0), _tickLower: -60, _tickUpper: 60});

        locker.doLock(abi.encode(poolKey, positionId, int128(liquidity)));

        locker.setExtraData(poolKey.toPoolId(), positionId, extraDataNonZero);

        vm.expectRevert(ICore.ExtraDataMustBeEmpty.selector);
        locker.doLock(abi.encode(poolKey, positionId, -int128(liquidity)));
    }

    /// forge-config: default.isolate = true
    function test_setExtraData_gas() public {
        PositionId positionId = createPositionId({_salt: bytes24(0), _tickLower: -60, _tickUpper: 60});
        locker.doLock(abi.encode(poolKey, positionId, 1));

        locker.setExtraData(poolKey.toPoolId(), positionId, bytes16(uint128(0x1234)));
        vm.snapshotGasLastCall("#setExtraData");
    }
}
