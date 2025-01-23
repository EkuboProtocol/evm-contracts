// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Multicallable} from "solady/utils/Multicallable.sol";

abstract contract PayableMulticallable is Multicallable {
    function multicall(bytes[] calldata data) public payable override returns (bytes[] memory) {
        _multicallDirectReturn(_multicall(data));
    }
}
