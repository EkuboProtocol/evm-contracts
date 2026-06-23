// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

uint64 constant MAX_VE_FEE = uint64(1 << 63);

function capFee(uint64 fee) pure returns (uint64) {
    return uint64(FixedPointMathLib.min(fee, MAX_VE_FEE));
}
