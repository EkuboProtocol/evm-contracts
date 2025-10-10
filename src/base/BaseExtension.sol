// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {ICore, IExtension} from "../interfaces/ICore.sol";
import {CallPoints} from "../types/callPoints.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionId} from "../types/positionId.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {PoolState} from "../types/poolState.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {UsesCore} from "./UsesCore.sol";
import {Locker} from "../types/locker.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";

/// @title Base Extension
/// @notice Abstract base contract for creating extensions to the Ekubo Protocol
/// @dev Extensions can hook into various pool operations to add custom functionality
///      Derived contracts must implement getCallPoints() and the specific hook functions they want to use
abstract contract BaseExtension is IExtension, UsesCore {
    /// @notice Thrown when a call point is not implemented by the extension
    error CallPointNotImplemented();

    /// @notice Constructs the BaseExtension and optionally registers it with the core
    /// @param core The core contract instance
    constructor(ICore core) UsesCore(core) {
        if (_registerInConstructor()) core.registerExtension(getCallPoints());
    }

    /// @notice Determines whether the extension should register itself in the constructor
    /// @dev Can be overridden by derived contracts to control registration timing
    /// @return True if the extension should register in the constructor
    function _registerInConstructor() internal pure virtual returns (bool) {
        return true;
    }

    /// @notice Returns the call points configuration for this extension
    /// @dev Must be implemented by derived contracts to specify which hooks they use
    /// @return The call points configuration
    function getCallPoints() internal virtual returns (CallPoints memory);

    /// @inheritdoc IExtension
    function beforeInitializePool(address, PoolKey calldata, int32) external virtual {
        revert CallPointNotImplemented();
    }

    /// @inheritdoc IExtension
    function afterInitializePool(address, PoolKey calldata, int32, SqrtRatio) external virtual {
        revert CallPointNotImplemented();
    }

    /// @inheritdoc IExtension
    function beforeUpdatePosition(Locker, PoolKey memory, PositionId, int128) external virtual {
        revert CallPointNotImplemented();
    }

    /// @inheritdoc IExtension
    function afterUpdatePosition(Locker, PoolKey memory, PositionId, int128, PoolBalanceUpdate, PoolState)
        external
        virtual
    {
        revert CallPointNotImplemented();
    }

    /// @inheritdoc IExtension
    function beforeSwap(Locker, PoolKey memory, SwapParameters) external virtual {
        revert CallPointNotImplemented();
    }

    /// @inheritdoc IExtension
    function afterSwap(Locker, PoolKey memory, SwapParameters, PoolBalanceUpdate, PoolState) external virtual {
        revert CallPointNotImplemented();
    }

    /// @inheritdoc IExtension
    function beforeCollectFees(Locker, PoolKey memory, PositionId) external virtual {
        revert CallPointNotImplemented();
    }

    /// @inheritdoc IExtension
    function afterCollectFees(Locker, PoolKey memory, PositionId, uint128, uint128) external virtual {
        revert CallPointNotImplemented();
    }
}
