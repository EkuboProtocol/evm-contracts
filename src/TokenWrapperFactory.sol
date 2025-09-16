// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

import {ICore} from "./interfaces/ICore.sol";
import {TokenWrapper} from "./TokenWrapper.sol";

/// @title Token Wrapper Factory
/// @author Ekubo Protocol
/// @notice Factory contract for creating time-locked token wrappers
/// @dev Creates TokenWrapper contracts using CREATE2 for deterministic addresses and emits events for indexing
contract TokenWrapperFactory {
    /// @notice Emitted whenever a token wrapper is deployed via the factory
    /// @param underlyingToken The token that is being wrapped
    /// @param unlockTime The timestamp after which tokens can be unwrapped
    /// @param tokenWrapper The address of the deployed TokenWrapper contract
    event TokenWrapperDeployed(IERC20 underlyingToken, uint256 unlockTime, TokenWrapper tokenWrapper);

    /// @notice The core contract associated with all the token wrappers that are deployed
    ICore public immutable core;

    /// @notice Constructs the TokenWrapperFactory
    /// @param _core The Ekubo Core contract
    constructor(ICore _core) {
        core = _core;
    }

    /// @notice Deploys a new TokenWrapper contract
    /// @dev Uses CREATE2 with a deterministic salt for predictable addresses
    /// @param underlyingToken The token to be wrapped
    /// @param unlockTime Timestamp after which wrapped tokens can be unwrapped
    /// @return tokenWrapper The deployed TokenWrapper contract
    function deployWrapper(IERC20 underlyingToken, uint256 unlockTime) external returns (TokenWrapper tokenWrapper) {
        bytes32 salt = EfficientHashLib.hash(uint256(uint160(address(underlyingToken))), unlockTime);

        tokenWrapper = new TokenWrapper{salt: salt}(core, underlyingToken, unlockTime);

        emit TokenWrapperDeployed(underlyingToken, unlockTime, tokenWrapper);
    }
}
