// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {ICore} from "../interfaces/ICore.sol";

abstract contract UsesCore {
    error CoreOnly();

    ICore internal immutable core;

    constructor(ICore _core) {
        core = _core;
    }

    modifier onlyCore() {
        if (msg.sender != address(core)) revert CoreOnly();
        _;
    }
}
