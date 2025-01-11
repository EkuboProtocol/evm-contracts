// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {LibClone} from "solady/utils/LibClone.sol";
import {Core} from "./Core.sol";

contract CoreProxyDeployer {
    Core public core;

    constructor(address implementation, address owner) {
        core = Core(LibClone.deployDeterministicERC1967(implementation, bytes32(0x0)));
        core.initialize(owner);
    }
}
