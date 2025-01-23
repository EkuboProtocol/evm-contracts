// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CoreLib} from "../libraries/CoreLib.sol";
import {UsesCore} from "../base/UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/keys.sol";

contract CoreDataFetcher is UsesCore {
    using CoreLib for *;

    constructor(ICore core) UsesCore(core) {}

    function poolPrice(PoolKey memory poolKey) external view returns (uint256 sqrtRatio, int32 tick) {
        (sqrtRatio, tick) = core.poolPrice(poolKey.toPoolId());
    }

    function poolLiquidity(PoolKey memory poolKey) external view returns (uint128 liquidity) {
        liquidity = core.poolLiquidity(poolKey.toPoolId());
    }
}
