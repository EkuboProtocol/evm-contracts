// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {LibClone} from "solady/utils/LibClone.sol";
import {Core} from "./Core.sol";

contract CoreProxyDeployer {
    Core public core;

    constructor(address implementation, address owner) {
        core = Core(LibClone.deployERC1967(implementation));
        core.initialize(owner);
    }
}
