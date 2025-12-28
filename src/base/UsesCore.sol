// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "../interfaces/ICore.sol";

/// @title Uses Core
/// @notice Abstract base contract for contracts that need to interact with the Ekubo Protocol core
/// @dev Provides core contract reference and access control functionality
abstract contract UsesCore {
    /// @notice Thrown when a function restricted to the core contract is called by another address
    error CoreOnly();

    /// @notice The core contract instance that this contract interacts with
    ICore internal immutable CORE;

    /// @notice Constructs the UsesCore contract with a core contract reference
    /// @param _core The core contract instance to use
    constructor(ICore _core) {
        CORE = _core;
    }

    /// @notice Restricts function access to only the core contract
    /// @dev Reverts with CoreOnly if called by any address other than the core contract
    modifier onlyCore() {
        if (msg.sender != address(CORE)) revert CoreOnly();
        _;
    }
}
