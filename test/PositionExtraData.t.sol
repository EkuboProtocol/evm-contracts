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

    TestToken public token0;
    TestToken public token1;

    constructor(ICore core, TestToken _token0, TestToken _token1) BaseLocker(core) UsesCore(core) {
        token0 = _token0;
        token1 = _token1;
    }

    function doLock(bytes memory data) external returns (bytes memory) {
        return lock(data);
    }

    function approveTokens() external {
        token0.approve(address(ACCOUNTANT), type(uint256).max);
        token1.approve(address(ACCOUNTANT), type(uint256).max);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        bytes1 callType = data[0];

        if (callType == 0x01) {
            // Create position
            (, PoolKey memory _poolKey, PositionId _positionId, int128 liquidityDelta) =
                abi.decode(data, (bytes1, PoolKey, PositionId, int128));

            (int128 delta0, int128 delta1) = CORE.updatePosition(_poolKey, _positionId, liquidityDelta);

            // Pay for the position - transfer tokens to ACCOUNTANT and use pay functions
            token0.transfer(address(ACCOUNTANT), uint128(delta0));
            token1.transfer(address(ACCOUNTANT), uint128(delta1));

            // Complete the payments
            ACCOUNTANT.pay(_poolKey.token0, uint128(delta0));
            ACCOUNTANT.pay(_poolKey.token1, uint128(delta1));
        } else if (callType == 0x02) {
            // Set extraData
            (, PoolId _poolId, PositionId _positionId, bytes16 _extraData) =
                abi.decode(data, (bytes1, PoolId, PositionId, bytes16));

            CORE.setPositionExtraData(_poolId, _positionId, _extraData);
        } else if (callType == 0x03) {
            // Update position with extraData
            (, PoolKey memory _poolKey, PositionId _positionId, int128 liquidityDelta, bytes16 _extraData) =
                abi.decode(data, (bytes1, PoolKey, PositionId, int128, bytes16));

            (int128 delta0, int128 delta1) = CORE.updatePosition(_poolKey, _positionId, liquidityDelta, _extraData);

            // Handle debt settlement
            if (liquidityDelta > 0) {
                // Adding liquidity - pay tokens
                token0.transfer(address(ACCOUNTANT), uint128(delta0));
                token1.transfer(address(ACCOUNTANT), uint128(delta1));

                ACCOUNTANT.pay(_poolKey.token0, uint128(delta0));
                ACCOUNTANT.pay(_poolKey.token1, uint128(delta1));
            } else if (liquidityDelta < 0) {
                // Removing liquidity - withdraw tokens
                FlashAccountantLib.withdraw(ACCOUNTANT, _poolKey.token0, address(this), uint128(-delta0));
                FlashAccountantLib.withdraw(ACCOUNTANT, _poolKey.token1, address(this), uint128(-delta1));
            }
        }

        return "";
    }
}

contract PositionExtraDataTest is Test {
    using CoreLib for *;

    Core public core;
    TestLocker public locker;
    TestToken public token0;
    TestToken public token1;
    PoolKey public poolKey;
    PoolId public poolId;

    function setUp() public {
        core = new Core();

        token0 = new TestToken(address(this));
        token1 = new TestToken(address(this));

        // Ensure token0 < token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }

        locker = new TestLocker(core, token0, token1);

        // Transfer tokens to locker
        token0.transfer(address(locker), 10000e18);
        token1.transfer(address(locker), 10000e18);

        // Have locker approve tokens
        locker.approveTokens();

        // Create pool key
        poolKey =
            PoolKey({token0: address(token0), token1: address(token1), config: createPoolConfig(3000, 60, address(0))});

        poolId = poolKey.toPoolId();

        // Initialize pool
        core.initializePool(poolKey, 0);
    }

    function test_setExtraData_roundtrip() public {
        PositionId positionId = createPositionId({_salt: bytes24(0), _tickLower: -60, _tickUpper: 60});

        // Create a position by calling core directly
        locker.doLock(abi.encode(bytes1(0x01), poolKey, positionId, int128(1000e18)));

        // Set extraData - use a full 16-byte value for clarity
        bytes16 extraData = 0x123456789abcdef0123456789abcdef0;
        locker.doLock(abi.encode(bytes1(0x02), poolId, positionId, extraData));

        // Read position via CoreLib
        Position memory position = core.poolPositions(poolId, address(locker), positionId);

        // Verify extraData was set correctly
        assertEq(position.extraData, extraData, "extraData should match");
        assertGt(position.liquidity, 0, "liquidity should be nonzero");
    }

    function test_setExtraData_reverts_if_liquidity_zero() public {
        PositionId positionId = createPositionId({_salt: bytes24(0), _tickLower: -60, _tickUpper: 60});

        // Try to set extraData on a position that doesn't exist (liquidity = 0)
        bytes16 extraData = bytes16(uint128(0x123));

        vm.expectRevert(ICore.ExtraDataMustBeZeroForZeroLiquidity.selector);
        locker.doLock(abi.encode(bytes1(0x02), poolId, positionId, extraData));
    }

    function test_updatePosition_with_extraData() public {
        PositionId positionId = createPositionId({_salt: bytes24(0), _tickLower: -60, _tickUpper: 60});
        bytes16 extraData = 0xabcdef0123456789abcdef0123456789;

        // Create a position with extraData in one call
        locker.doLock(abi.encode(bytes1(0x03), poolKey, positionId, int128(1000e18), extraData));

        // Read position via CoreLib
        Position memory position = core.poolPositions(poolId, address(locker), positionId);

        // Verify extraData was set correctly
        assertEq(position.extraData, extraData, "extraData should match");
        assertGt(position.liquidity, 0, "liquidity should be nonzero");
    }

    function test_updatePosition_extraData_must_be_zero_when_withdrawing_all() public {
        PositionId positionId = createPositionId({_salt: bytes24(0), _tickLower: -60, _tickUpper: 60});

        // Create a position
        locker.doLock(abi.encode(bytes1(0x01), poolKey, positionId, int128(1000e18)));

        // Try to withdraw all liquidity with non-zero extraData - should revert
        bytes16 extraData = 0xabcdef0123456789abcdef0123456789;
        vm.expectRevert(ICore.ExtraDataMustBeZeroForZeroLiquidity.selector);
        locker.doLock(abi.encode(bytes1(0x03), poolKey, positionId, int128(-1000e18), extraData));
    }

    function test_updatePosition_can_set_extraData_to_zero_when_withdrawing_all() public {
        PositionId positionId = createPositionId({_salt: bytes24(0), _tickLower: -60, _tickUpper: 60});

        // Create a position with extraData
        bytes16 extraData = 0xabcdef0123456789abcdef0123456789;
        locker.doLock(abi.encode(bytes1(0x03), poolKey, positionId, int128(1000e18), extraData));

        // Withdraw all liquidity with zero extraData - should succeed
        locker.doLock(abi.encode(bytes1(0x03), poolKey, positionId, int128(-1000e18), bytes16(0)));

        // Verify position has zero liquidity and zero extraData
        Position memory position = core.poolPositions(poolId, address(locker), positionId);
        assertEq(position.liquidity, 0, "liquidity should be zero");
        assertEq(position.extraData, bytes16(0), "extraData should be zero");
    }
}
