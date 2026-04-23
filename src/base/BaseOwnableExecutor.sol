// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";

/// @title Base Ownable Executor
/// @author Moody Salem <moody@ekubo.org>
/// @notice Base contract that lets the owner execute arbitrary calls from this contract
/// @dev `delegateCall` executes in this contract's storage context and is therefore intended for governance-controlled proxies
abstract contract BaseOwnableExecutor is Ownable, Multicallable {
    error NotSelf();

    /// @param owner The address that will own this contract and have administrative privileges
    constructor(address owner) {
        _initializeOwner(owner);
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) revert NotSelf();
        _;
    }

    /// @notice Executes an arbitrary external call from this contract
    /// @dev Reverts with the original revert data if the call fails
    /// @param target The contract to call
    /// @param value The ETH value to send with the call
    /// @param data The calldata to forward to the target
    /// @return result The raw return data from the target call
    function call(address target, uint256 value, bytes calldata data)
        external
        payable
        onlyOwner
        returns (bytes memory result)
    {
        (bool success, bytes memory returnData) = target.call{value: value}(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        return returnData;
    }

    /// @notice Executes an arbitrary delegatecall from this contract
    /// @dev Reverts with the original revert data if the call fails
    /// @param target The contract to delegatecall
    /// @param data The calldata to forward to the target
    /// @return result The raw return data from the target call
    function delegateCall(address target, bytes calldata data)
        external
        payable
        onlyOwner
        returns (bytes memory result)
    {
        (bool success, bytes memory returnData) = target.delegatecall(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 32), mload(returnData))
            }
        }
        return returnData;
    }

    /// @notice Allows the contract to receive ETH so the owner can forward value in future calls
    receive() external payable {}
}
