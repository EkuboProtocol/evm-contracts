// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest, MockExtension} from "./FullTest.sol";
import {PoolKeyIndex} from "../src/PoolKeyIndex.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolConfig, createConcentratedPoolConfig} from "../src/types/poolConfig.sol";

contract PoolKeyIndexTest is FullTest {
    PoolKeyIndex index;

    function setUp() public override {
        super.setUp();
        index = new PoolKeyIndex(core);
    }

    function test_register_storesPoolKeyByPoolId() public {
        PoolKey memory poolKey = createPool(0, 0, 100);
        PoolId poolId = poolKey.toPoolId();

        assertTrue(index.register(poolKey));

        assertTrue(index.isRegistered(poolId));
        assertEq(index.poolIdCount(), 1);
        assertEq(PoolId.unwrap(index.poolIds(0)), PoolId.unwrap(poolId));

        (address token0_, address token1_, PoolConfig config_) = index.poolKeyById(poolId);
        assertEq(token0_, poolKey.token0);
        assertEq(token1_, poolKey.token1);
        assertEq(PoolConfig.unwrap(config_), PoolConfig.unwrap(poolKey.config));

        PoolKey[] memory poolKeys = index.getPoolKeys();
        assertEq(poolKeys.length, 1);
        assertPoolKeyEq(poolKeys[0], poolKey);
    }

    function test_register_revertsIfPoolIsNotInitialized() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token0), token1: address(token1), config: createConcentratedPoolConfig(0, 100, address(0))
        });

        vm.expectRevert(ICore.PoolNotInitialized.selector);
        index.register(poolKey);
    }

    function test_register_doesNotValidatePoolKeyBeforeInitializedCheck() public {
        PoolKey memory poolKey = PoolKey({
            token0: address(token1), token1: address(token0), config: createConcentratedPoolConfig(0, 0, address(0))
        });

        vm.expectRevert(ICore.PoolNotInitialized.selector);
        index.register(poolKey);
    }

    function test_register_isIdempotent() public {
        PoolKey memory poolKey = createPool(0, 0, 100);

        assertFalse(index.isRegistered(poolKey.toPoolId()));
        assertTrue(index.register(poolKey));
        assertTrue(index.isRegistered(poolKey.toPoolId()));
        assertFalse(index.register(poolKey));

        assertEq(index.poolIdCount(), 1);
        assertEq(index.tokenPoolIdCount(poolKey.token0), 1);
        assertEq(index.tokenPoolIdCount(poolKey.token1), 1);
        assertEq(index.extensionPoolIdCount(address(0)), 1);
    }

    function test_getPoolKeysByToken() public {
        PoolKey memory poolKey0 = createPool(0, 0, 100);
        PoolKey memory poolKey1 = createPool(1, 1, 100);

        assertTrue(index.register(poolKey0));
        assertTrue(index.register(poolKey1));

        PoolId[] memory token0PoolIds = index.getPoolIdsByToken(address(token0));
        assertEq(token0PoolIds.length, 2);
        assertEq(PoolId.unwrap(token0PoolIds[0]), PoolId.unwrap(poolKey0.toPoolId()));
        assertEq(PoolId.unwrap(token0PoolIds[1]), PoolId.unwrap(poolKey1.toPoolId()));

        PoolKey[] memory token1PoolKeys = index.getPoolKeysByToken(address(token1));
        assertEq(token1PoolKeys.length, 2);
        assertPoolKeyEq(token1PoolKeys[0], poolKey0);
        assertPoolKeyEq(token1PoolKeys[1], poolKey1);

        PoolKey[] memory unrelatedPoolKeys = index.getPoolKeysByToken(makeAddr("unrelated token"));
        assertEq(unrelatedPoolKeys.length, 0);
    }

    function test_getPoolKeysByExtension() public {
        MockExtension extension = createAndRegisterExtension();
        PoolKey memory poolKey = createPool(0, 0, 100, address(extension));
        PoolKey memory otherPoolKey = createPool(1, 1, 100);

        assertTrue(index.register(poolKey));
        assertTrue(index.register(otherPoolKey));

        PoolId[] memory extensionPoolIds = index.getPoolIdsByExtension(address(extension));
        assertEq(extensionPoolIds.length, 1);
        assertEq(PoolId.unwrap(extensionPoolIds[0]), PoolId.unwrap(poolKey.toPoolId()));

        PoolKey[] memory extensionPoolKeys = index.getPoolKeysByExtension(address(extension));
        assertEq(extensionPoolKeys.length, 1);
        assertPoolKeyEq(extensionPoolKeys[0], poolKey);

        PoolKey[] memory noExtensionPoolKeys = index.getPoolKeysByExtension(address(0));
        assertEq(noExtensionPoolKeys.length, 1);
        assertPoolKeyEq(noExtensionPoolKeys[0], otherPoolKey);
    }

    function test_register_nativeTokenPoolDoesNotUseDefaultPoolKeyAsSentinel() public {
        PoolKey memory poolKey = createETHPool(0, 0, 100);
        PoolId poolId = poolKey.toPoolId();

        assertEq(poolKey.token0, NATIVE_TOKEN_ADDRESS);
        assertTrue(index.register(poolKey));

        assertTrue(index.isRegistered(poolId));
        assertEq(index.tokenPoolIdCount(NATIVE_TOKEN_ADDRESS), 1);

        PoolKey[] memory nativeTokenPoolKeys = index.getPoolKeysByToken(NATIVE_TOKEN_ADDRESS);
        assertEq(nativeTokenPoolKeys.length, 1);
        assertPoolKeyEq(nativeTokenPoolKeys[0], poolKey);
    }

    function assertPoolKeyEq(PoolKey memory actual, PoolKey memory expected) internal pure {
        assertEq(actual.token0, expected.token0);
        assertEq(actual.token1, expected.token1);
        assertEq(PoolConfig.unwrap(actual.config), PoolConfig.unwrap(expected.config));
    }
}
