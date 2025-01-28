// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ICore} from "../interfaces/ICore.sol";
import {BaseLocker} from "../base/BaseLocker.sol";
import {PoolKey} from "../types/keys.sol";

abstract contract Quoter is BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    // todo: implement this
    function quote(PoolKey memory poolKey, int128 amount, bool isToken1, uint256 sqrtRatioLimit, uint256 skipAhead)
        external
        virtual
        returns (int128 delta0, int128 delta1);
}
