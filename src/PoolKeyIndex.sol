// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {UsesCore} from "./base/UsesCore.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {ICore} from "./interfaces/ICore.sol";
import {PoolId} from "./types/poolId.sol";
import {PoolKey} from "./types/poolKey.sol";

/// @title Pool Key Index
/// @notice Optional registry for discovering initialized pool keys by pool id, token, or extension
contract PoolKeyIndex is UsesCore {
    using CoreLib for *;

    /// @notice Registered pool key for a pool id
    mapping(PoolId poolId => PoolKey poolKey) public poolKeyById;

    /// @notice All registered pool ids
    PoolId[] public poolIds;

    /// @notice Registered pool ids that include a token
    mapping(address token => PoolId[] poolIds) public tokenPoolIds;

    /// @notice Registered pool ids that use an extension
    mapping(address extension => PoolId[] poolIds) public extensionPoolIds;

    constructor(ICore core) UsesCore(core) {}

    /// @notice Registers an initialized pool key for discovery
    /// @param poolKey The initialized pool key to register
    /// @return inserted True if the pool key was newly inserted, false if it was already registered
    function register(PoolKey memory poolKey) external returns (bool inserted) {
        PoolId poolId = poolKey.toPoolId();
        if (!CORE.poolState(poolId).isInitialized()) revert ICore.PoolNotInitialized();

        inserted = !isRegistered(poolId);
        if (inserted) {
            poolKeyById[poolId] = poolKey;
            poolIds.push(poolId);
            tokenPoolIds[poolKey.token0].push(poolId);
            tokenPoolIds[poolKey.token1].push(poolId);
            extensionPoolIds[poolKey.config.extension()].push(poolId);
        }
    }

    /// @notice Returns whether a pool id has been registered in this index
    function isRegistered(PoolId poolId) public view returns (bool) {
        return poolKeyById[poolId].token1 != address(0);
    }

    /// @notice Returns the number of registered pool ids
    function poolIdCount() external view returns (uint256) {
        return poolIds.length;
    }

    /// @notice Returns all registered pool ids
    function getPoolIds() external view returns (PoolId[] memory) {
        return poolIds;
    }

    /// @notice Returns all registered pool keys
    function getPoolKeys() external view returns (PoolKey[] memory poolKeys) {
        poolKeys = _poolKeys(poolIds);
    }

    /// @notice Returns the number of registered pool ids that include a token
    function tokenPoolIdCount(address token) external view returns (uint256) {
        return tokenPoolIds[token].length;
    }

    /// @notice Returns registered pool ids that include a token
    function getPoolIdsByToken(address token) external view returns (PoolId[] memory) {
        return tokenPoolIds[token];
    }

    /// @notice Returns registered pool keys that include a token
    function getPoolKeysByToken(address token) external view returns (PoolKey[] memory poolKeys) {
        poolKeys = _poolKeys(tokenPoolIds[token]);
    }

    /// @notice Returns the number of registered pool ids that use an extension
    function extensionPoolIdCount(address extension) external view returns (uint256) {
        return extensionPoolIds[extension].length;
    }

    /// @notice Returns registered pool ids that use an extension
    function getPoolIdsByExtension(address extension) external view returns (PoolId[] memory) {
        return extensionPoolIds[extension];
    }

    /// @notice Returns registered pool keys that use an extension
    function getPoolKeysByExtension(address extension) external view returns (PoolKey[] memory poolKeys) {
        poolKeys = _poolKeys(extensionPoolIds[extension]);
    }

    function _poolKeys(PoolId[] storage ids) internal view returns (PoolKey[] memory poolKeys) {
        poolKeys = new PoolKey[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            poolKeys[i] = poolKeyById[ids[i]];
        }
    }
}
