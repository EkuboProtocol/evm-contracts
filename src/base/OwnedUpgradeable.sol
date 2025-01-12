// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {UUPSUpgradeable} from "solady/utils/UUPSUpgradeable.sol";

abstract contract OwnedUpgradeable is Ownable, UUPSUpgradeable {
    // Only called once at deploy time
    function initialize(address owner) external {
        _initializeOwner(owner);
    }

    // Prevents initialize from being called more than once
    function _guardInitializeOwner() internal pure override returns (bool guard) {
        guard = true;
    }

    // This proxy can only be upgraded by the owner
    function _authorizeUpgrade(address) internal override onlyOwner {}

    // Returns the current implementation address
    function getImplementation() external view onlyProxy returns (address implementation) {
        assembly {
            implementation := sload(_ERC1967_IMPLEMENTATION_SLOT)
        }
    }
}
