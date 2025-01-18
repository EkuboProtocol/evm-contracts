// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ICore} from "../interfaces/ICore.sol";

// Common storage getters we need for external contracts are defined here instead of in the core contract
library CoreLib {
    function poolPrice(ICore core, bytes32 poolId) internal view returns (uint192 sqrtRatio, int32 tick) {
        bytes32 result = core.sload(keccak256(abi.encodePacked(poolId, uint256(2))));
        assembly {
            sqrtRatio := and(result, 0xffffffffffffffffffffffffffffffffffffffffffffffff)
            tick := shr(192, result)
        }
    }

    function poolLiquidity(ICore core, bytes32 poolId) internal view returns (uint128 liquidity) {
        bytes32 result = core.sload(keccak256(abi.encodePacked(poolId, uint256(3))));
        assembly {
            liquidity := and(result, 0xffffffffffffffffffffffffffffffff)
        }
    }
}
