// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.31;

import {IForwardee, IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {Locker} from "../types/locker.sol";

/// @title Base Forwardee
/// @notice Abstract base contract for contracts that need to receive forwarded calls from the flash accountant
/// @dev Provides the forwarding mechanism and delegates actual data handling to implementing contracts
abstract contract BaseForwardee is IForwardee {
    /// @notice Thrown when a function is called by an address other than the accountant
    error BaseForwardeeAccountantOnly();

    /// @notice The flash accountant contract that can forward calls to this contract
    IFlashAccountant private immutable ACCOUNTANT;

    /// @notice Constructs the BaseForwardee with a flash accountant
    /// @param _accountant The flash accountant contract that will forward calls
    constructor(IFlashAccountant _accountant) {
        ACCOUNTANT = _accountant;
    }

    /// CALLBACK HANDLERS

    /// @inheritdoc IForwardee
    /// @dev Extracts the forwarded data from calldata and delegates to handleForwardData
    /// The first 68 bytes of calldata contain the function selector (4 bytes), id (32 bytes), and originalLocker (32 bytes)
    /// All remaining calldata is treated as the forwarded data
    /// Return data from handleForwardData is returned exactly as is, with no additional encoding or decoding
    /// Reverts are also bubbled up
    function forwarded_2374103877(Locker original) external {
        if (msg.sender != address(ACCOUNTANT)) revert BaseForwardeeAccountantOnly();

        bytes memory data = msg.data[36:];

        bytes memory result = handleForwardData(original, data);

        assembly ("memory-safe") {
            // raw return whatever the handler sent
            return(add(result, 32), mload(result))
        }
    }

    /// INTERNAL FUNCTIONS

    /// @notice Handles the execution of forwarded data
    /// @dev Must be implemented by derived contracts to define forwarding behavior
    /// @param original The original locker that called forward
    /// @param data The forwarded data to process
    /// @return result The result of processing the forwarded data
    function handleForwardData(Locker original, bytes memory data) internal virtual returns (bytes memory result);
}
