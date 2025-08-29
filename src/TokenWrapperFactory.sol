// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {ICore} from "./interfaces/ICore.sol";
import {TokenWrapper} from "./TokenWrapper.sol";

/// @title Factory for creating time-locked token wrappers
/// @notice Creates TokenWrapper contracts and emits events for indexing
contract TokenWrapperFactory {
    /// @notice Emitted whenever a token wrapper is deployed via the factory
    event TokenWrapperDeployed(IERC20 underlyingToken, uint256 unlockTime, TokenWrapper tokenWrapper);

    ICore public immutable core;

    constructor(ICore _core) {
        core = _core;
    }

    /// @notice Deploy a new TokenWrapper
    /// @param underlyingToken The token to be wrapped
    /// @param unlockTime Timestamp after which wrapped tokens can be unwrapped
    /// @return tokenWrapper The deployed TokenWrapper contract
    function deployWrapper(IERC20 underlyingToken, uint256 unlockTime) external returns (TokenWrapper tokenWrapper) {
        bytes32 salt = keccak256(abi.encode(underlyingToken, unlockTime));

        tokenWrapper = new TokenWrapper{salt: salt}(core, underlyingToken, unlockTime);

        emit TokenWrapperDeployed(underlyingToken, unlockTime, tokenWrapper);
    }
}
