// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {TokenWrapper} from "./TokenWrapper.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {LibClone} from "solady/utils/LibClone.sol";

/// @title TokenWrapperFactory - Factory for creating time-locked token wrappers
/// @notice Creates TokenWrapper contracts with formatted names and symbols based on unlock dates
contract TokenWrapperFactory {
    event TokenWrapperDeployed(ERC20 underlyingToken, uint256 unlockTime, TokenWrapper tokenWrapper);

    TokenWrapper public immutable implementation;

    constructor() {
        implementation = new TokenWrapper();
    }

    /// @notice Deploy a new TokenWrapper with auto-generated name and symbol
    /// @param underlyingToken The token to be wrapped
    /// @param unlockTime Timestamp when tokens can be unwrapped
    /// @return tokenWrapper The deployed TokenWrapper contract
    function deployWrapper(ERC20 underlyingToken, uint256 unlockTime) external returns (TokenWrapper tokenWrapper) {
        bytes32 salt = keccak256(abi.encode(underlyingToken, unlockTime));

        tokenWrapper = TokenWrapper(
            LibClone.cloneDeterministic(address(implementation), abi.encode(underlyingToken, unlockTime), salt)
        );

        emit TokenWrapperDeployed(underlyingToken, unlockTime, tokenWrapper);
    }
}
