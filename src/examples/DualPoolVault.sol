// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseVault} from "../base/BaseVault.sol";
import {ICore} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolAllocation} from "../types/vaultTypes.sol";

/// @title DualPoolVault
/// @notice Example vault demonstrating multi-pool allocation strategy
/// @dev Splits liquidity between two pools with configurable weights
contract DualPoolVault is BaseVault {
    /// @notice Maximum number of pools this vault supports
    uint256 private constant MAX_POOLS = 2;

    /// @notice Pool configuration struct
    struct PoolConfig {
        PoolKey poolKey;
        uint16 targetBps;
        bool isSet;
    }

    /// @notice First pool configuration
    PoolConfig private _pool0;

    /// @notice Second pool configuration
    PoolConfig private _pool1;

    /// @notice Thrown when pool does not contain deposit token
    error PoolMustContainDepositToken();

    /// @notice Thrown when allocations don't sum to 10000 bps
    error AllocationsMustSum100Percent();

    /// @notice Thrown when trying to set allocation for unset pool
    error PoolNotSet();

    /// @notice Emitted when a pool is configured
    event PoolConfigured(uint256 indexed poolIndex, address token0, address token1, uint16 targetBps);

    /// @notice Emitted when allocations are updated
    event AllocationsUpdated(uint16 pool0Bps, uint16 pool1Bps);

    /// @notice Constructs the DualPoolVault
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
        return "Dual Pool Ekubo Vault";
    }

    /// @notice Returns the symbol of the vault token
    function symbol() public pure override returns (string memory) {
        return "dpEKV";
    }

    /// @notice Sets the first pool with its target allocation
    /// @param poolKey The pool key for the first pool
    /// @param targetBps Target allocation in basis points (0-10000)
    function setPool0(PoolKey memory poolKey, uint16 targetBps) external onlyOwner {
        if (poolKey.token0 != DEPOSIT_TOKEN && poolKey.token1 != DEPOSIT_TOKEN) {
            revert PoolMustContainDepositToken();
        }

        _pool0 = PoolConfig({
            poolKey: poolKey,
            targetBps: targetBps,
            isSet: true
        });

        emit PoolConfigured(0, poolKey.token0, poolKey.token1, targetBps);
        _validateAllocations();
    }

    /// @notice Sets the second pool with its target allocation
    /// @param poolKey The pool key for the second pool
    /// @param targetBps Target allocation in basis points (0-10000)
    function setPool1(PoolKey memory poolKey, uint16 targetBps) external onlyOwner {
        if (poolKey.token0 != DEPOSIT_TOKEN && poolKey.token1 != DEPOSIT_TOKEN) {
            revert PoolMustContainDepositToken();
        }

        _pool1 = PoolConfig({
            poolKey: poolKey,
            targetBps: targetBps,
            isSet: true
        });

        emit PoolConfigured(1, poolKey.token0, poolKey.token1, targetBps);
        _validateAllocations();
    }

    /// @notice Updates allocation weights for both pools
    /// @param pool0Bps Target allocation for pool 0 in basis points
    /// @param pool1Bps Target allocation for pool 1 in basis points
    function setAllocations(uint16 pool0Bps, uint16 pool1Bps) external onlyOwner {
        if (!_pool0.isSet && pool0Bps > 0) revert PoolNotSet();
        if (!_pool1.isSet && pool1Bps > 0) revert PoolNotSet();
        if (uint256(pool0Bps) + uint256(pool1Bps) != 10000) revert AllocationsMustSum100Percent();

        _pool0.targetBps = pool0Bps;
        _pool1.targetBps = pool1Bps;

        emit AllocationsUpdated(pool0Bps, pool1Bps);
    }

    /// @inheritdoc BaseVault
    function getTargetAllocations() public view override returns (PoolAllocation[] memory allocations) {
        uint256 count = 0;
        if (_pool0.isSet && _pool0.targetBps > 0) count++;
        if (_pool1.isSet && _pool1.targetBps > 0) count++;

        if (count == 0) {
            return new PoolAllocation[](0);
        }

        allocations = new PoolAllocation[](count);
        uint256 idx = 0;

        if (_pool0.isSet && _pool0.targetBps > 0) {
            allocations[idx] = PoolAllocation({
                poolKey: _pool0.poolKey,
                targetBps: _pool0.targetBps
            });
            idx++;
        }

        if (_pool1.isSet && _pool1.targetBps > 0) {
            allocations[idx] = PoolAllocation({
                poolKey: _pool1.poolKey,
                targetBps: _pool1.targetBps
            });
        }
    }

    /// @notice Returns the first pool configuration
    function getPool0() external view returns (PoolKey memory poolKey, uint16 targetBps, bool isSet) {
        return (_pool0.poolKey, _pool0.targetBps, _pool0.isSet);
    }

    /// @notice Returns the second pool configuration
    function getPool1() external view returns (PoolKey memory poolKey, uint16 targetBps, bool isSet) {
        return (_pool1.poolKey, _pool1.targetBps, _pool1.isSet);
    }

    /// @notice Returns whether both pools are configured
    function isFullyConfigured() external view returns (bool) {
        return _pool0.isSet && _pool1.isSet;
    }

    /// @notice Validates that allocations sum to 100% when both pools are set
    function _validateAllocations() internal view {
        if (_pool0.isSet && _pool1.isSet) {
            if (uint256(_pool0.targetBps) + uint256(_pool1.targetBps) != 10000) {
                revert AllocationsMustSum100Percent();
            }
        }
    }
}
