// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ILocker, IPayer, IForwardee, IFlashAccountant, NATIVE_TOKEN_ADDRESS} from "../interfaces/IFlashAccountant.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {UsesCore} from "./UsesCore.sol";

abstract contract BaseForwardee is IForwardee {
    error BaseForwardeeAccountantOnly();

    IFlashAccountant private immutable accountant;

    constructor(IFlashAccountant _accountant) {
        accountant = _accountant;
    }

    function forwarded(uint256 id, address originalLocker) external {
        if (msg.sender != address(accountant)) revert BaseForwardeeAccountantOnly();

        bytes memory data = msg.data[68:];

        bytes memory result = handleForwardData(id, originalLocker, data);

        assembly ("memory-safe") {
            // raw return whatever the handler sent
            return(add(result, 32), mload(result))
        }
    }

    function handleForwardData(uint256 id, address originalLocker, bytes memory data)
        internal
        virtual
        returns (bytes memory result);
}
