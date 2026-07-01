// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseVault} from "../base/BaseVault.sol";
import {ICore} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolAllocation} from "../types/vaultTypes.sol";

/// @title SimpleVault
/// @notice A simple single-pool vault implementation for testing
/// @dev Demonstrates how to extend BaseVault with a concrete strategy
contract SimpleVault is BaseVault {
    /// @notice The target pool for this vault
    PoolKey private _targetPool;

    /// @notice Whether a target pool has been set
    bool private _hasTargetPool;

    /// @notice Thrown when trying to process epoch without a target pool
    error NoTargetPoolSet();

    /// @notice Constructs the SimpleVault
    /// @param core The core contract instance
    /// @param owner_ The owner of the vault
    /// @param depositToken The token users deposit
    /// @param minEpochDuration Minimum time between epoch processing
    constructor(
        ICore core,
        address owner_,
        address depositToken,
        uint256 minEpochDuration
    )
        BaseVault(core, owner_, depositToken, minEpochDuration)
    {}

    /// @notice Returns the name of the vault token
    function name() public pure override returns (string memory) {
        return "Simple Ekubo Vault";
    }

    /// @notice Returns the symbol of the vault token
    function symbol() public pure override returns (string memory) {
        return "sEKV";
    }

    /// @notice Sets the target pool for the vault
    /// @param poolKey The pool key for the target pool
    function setTargetPool(PoolKey memory poolKey) external onlyOwner {
        require(
            poolKey.token0 == DEPOSIT_TOKEN || poolKey.token1 == DEPOSIT_TOKEN,
            "Pool must contain deposit token"
        );
        _targetPool = poolKey;
        _hasTargetPool = true;
    }

    /// @inheritdoc BaseVault
    function getTargetAllocations() public view override returns (PoolAllocation[] memory allocations) {
        if (!_hasTargetPool) {
            // Return empty allocations if no pool set
            return new PoolAllocation[](0);
        }

        allocations = new PoolAllocation[](1);
        allocations[0] = PoolAllocation({
            poolKey: _targetPool,
            targetBps: 10000 // 100% allocation to single pool
        });
    }

    /// @notice Returns the target pool
    function getTargetPool() external view returns (PoolKey memory) {
        return _targetPool;
    }

    /// @notice Returns whether a target pool has been set
    function hasTargetPool() external view returns (bool) {
        return _hasTargetPool;
    }
}
