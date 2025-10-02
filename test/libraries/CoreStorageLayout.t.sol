// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {CoreStorageLayout} from "../../src/libraries/CoreStorageLayout.sol";
import {PoolKey, PoolConfig} from "../../src/types/poolKey.sol";

contract CoreStorageLayoutTest is Test {
    function check_noStorageLayoutCollisions_isExtensionRegisteredSlot_isExtensionRegisteredSlot(
        address extension0,
        address extension1
    ) public pure {
        bytes32 extensionSlot0 = CoreStorageLayout.isExtensionRegisteredSlot(extension0);
        bytes32 extensionSlot1 = CoreStorageLayout.isExtensionRegisteredSlot(extension1);
        assertEq((extensionSlot0 == extensionSlot1), (extension0 == extension1));
    }

    function check_noStorageLayoutCollisions_isExtensionRegisteredSlot_poolStateSlot(
        address extension,
        PoolKey memory poolKey
    ) public pure {
        bytes32 extensionSlot = CoreStorageLayout.isExtensionRegisteredSlot(extension);
        bytes32 poolStateSlot = CoreStorageLayout.poolStateSlot(poolKey.toPoolId());
        assertNotEq(extensionSlot, poolStateSlot);
    }

    function check_noStorageLayoutCollisions_poolStateSlot_poolStateSlot(
        PoolKey memory poolKey0,
        PoolKey memory poolKey1
    ) public pure {
        bytes32 poolStateSlot0 = CoreStorageLayout.poolStateSlot(poolKey0.toPoolId());
        bytes32 poolStateSlot1 = CoreStorageLayout.poolStateSlot(poolKey1.toPoolId());
        assertEq(
            (
                poolKey0.token0 == poolKey1.token0 && poolKey0.token1 == poolKey1.token1
                    && PoolConfig.unwrap(poolKey0.config) == PoolConfig.unwrap(poolKey1.config)
            ),
            (poolStateSlot0 == poolStateSlot1)
        );
    }
}
