// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {DETERMINISTIC_DEPLOYER} from "../script/DeployAll.s.sol";
import {DeployFreeLPBootstrap} from "../script/DeployFreeLPBootstrap.s.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {PoolKeyIndex} from "../src/PoolKeyIndex.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolConfig, createConcentratedPoolConfig} from "../src/types/poolConfig.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {TestToken} from "./TestToken.sol";

contract FreeLPBootstrapTest is Test {
    // Runtime of the standard CREATE2 deployer used by the protocol deployment scripts.
    bytes constant DEPLOYER_RUNTIME =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    // One API page shaped like prod-api.ekubo.org/poolKeys: a native pool with unpadded hex, a pool without
    // state, a pool with zero liquidity, and a full-width config.
    string constant PAGE = "{\"pools\":["
        "{\"pool_id\":\"0x01\",\"pool_key\":{\"token0\":\"0x0\",\"token1\":\"0xb20000000000000000000010c822aa94cb700e2a\","
        "\"config\":\"0x413f1995eea74340bf300156e63d84b5546e1a56000000000000000080004e20\"},"
        "\"state\":{\"sqrt_ratio\":\"1\",\"tick\":1,\"liquidity\":\"47252971363426472046925\"}},"
        "{\"pool_id\":\"0x02\",\"pool_key\":{\"token0\":\"0x0\",\"token1\":\"0x833589fcd6edb6e08f4c7c32d4f71b54bda02913\","
        "\"config\":\"0x00000000000000000000000000000000000000000020c49ba5e353f7800003e8\"},\"state\":null},"
        "{\"pool_id\":\"0x03\",\"pool_key\":{\"token0\":\"0x0\",\"token1\":\"0x4200000000000000000000000000000000000006\","
        "\"config\":\"0x00000000000000000000000000000000000000000020c49ba5e353f880000064\"},"
        "\"state\":{\"sqrt_ratio\":\"1\",\"tick\":-1,\"liquidity\":\"0\"}},"
        "{\"pool_id\":\"0x04\",\"pool_key\":{\"token0\":\"0x833589fcd6edb6e08f4c7c32d4f71b54bda02913\","
        "\"token1\":\"0xb20000000000000000000010c822aa94cb700e2a\","
        "\"config\":\"0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"},"
        "\"state\":{\"sqrt_ratio\":\"1\",\"tick\":0,\"liquidity\":\"5\"}}"
        "],\"next_cursor\":\"0x04\",\"has_more\":false}";

    DeployFreeLPBootstrap script;
    PoolKeyIndex index;
    ICore core;
    address token0;
    address token1;

    function setUp() public {
        vm.etch(DETERMINISTIC_DEPLOYER, DEPLOYER_RUNTIME);
        script = new DeployFreeLPBootstrap();
        (core, index) = script.deployContracts();
        TestToken tokenA = new TestToken(address(this));
        TestToken tokenB = new TestToken(address(this));
        (token0, token1) =
            address(tokenA) < address(tokenB) ? (address(tokenA), address(tokenB)) : (address(tokenB), address(tokenA));
    }

    function test_deployContracts_usesCanonicalAddresses() public view {
        assertEq(address(core), script.CORE());
        assertEq(address(index), script.POOL_KEY_INDEX());
        assertGt(script.CORE().code.length, 0);
        assertGt(script.POOL_KEY_INDEX().code.length, 0);
        assertGt(script.METADATA_RENDERER().code.length, 0);
        assertGt(script.FREE_LP().code.length, 0);
        assertGt(script.DATA_FETCHER().code.length, 0);
    }

    function test_deployContracts_isIdempotent() public {
        (ICore coreAgain, PoolKeyIndex indexAgain) = script.deployContracts();
        assertEq(address(coreAgain), address(core));
        assertEq(address(indexAgain), address(index));
    }

    function test_parsePoolKeys_keepsPoolsWithLiquidity() public view {
        PoolKey[] memory keys = script.parsePoolKeys(PAGE);
        assertEq(keys.length, 2);
        assertEq(keys[0].token0, NATIVE_TOKEN_ADDRESS);
        assertEq(keys[0].token1, 0xb20000000000000000000010C822aA94CB700E2A);
        assertEq(PoolConfig.unwrap(keys[0].config), 0x413f1995eea74340bf300156e63d84b5546e1a56000000000000000080004e20);
        assertEq(keys[1].token0, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(keys[1].token1, 0xb20000000000000000000010C822aA94CB700E2A);
        assertEq(PoolConfig.unwrap(keys[1].config), bytes32(type(uint256).max));
    }

    function test_parsePoolKeys_emptyPage() public view {
        assertEq(script.parsePoolKeys("{\"pools\":[],\"next_cursor\":null,\"has_more\":false}").length, 0);
    }

    function test_bootstrap_registersInitializedKeysAndSkipsTheRest() public {
        PoolKey[] memory keys = fixtureKeys();
        core.initializePool(keys[0], 0);
        core.initializePool(keys[1], 100);

        DeployFreeLPBootstrap.Counts memory counts = script.bootstrap(core, index, keys);
        assertEq(counts.registered, 2);
        assertEq(counts.alreadyRegistered, 0);
        assertEq(counts.skippedUninitialized, 1);
        assertTrue(index.isRegistered(keys[0].toPoolId()));
        assertTrue(index.isRegistered(keys[1].toPoolId()));
        assertFalse(index.isRegistered(keys[2].toPoolId()));
        assertEq(index.poolIdCount(), 2);

        counts = script.bootstrap(core, index, keys);
        assertEq(counts.registered, 0);
        assertEq(counts.alreadyRegistered, 2);
        assertEq(counts.skippedUninitialized, 1);
        assertEq(index.poolIdCount(), 2);
    }

    function fixtureKeys() internal view returns (PoolKey[] memory keys) {
        keys = new PoolKey[](3);
        keys[0] = PoolKey({token0: token0, token1: token1, config: createConcentratedPoolConfig(0, 100, address(0))});
        keys[1] = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: token1,
            config: createConcentratedPoolConfig(1 << 32, 1000, address(0))
        });
        keys[2] = PoolKey({token0: token0, token1: token1, config: createConcentratedPoolConfig(0, 200, address(0))});
    }
}
