// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CoreLib} from "../libraries/CoreLib.sol";
import {TWAMMLib} from "../libraries/TWAMMLib.sol";
import {TWAMM} from "../extensions/TWAMM.sol";
import {UsesCore} from "../base/UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionKey} from "../types/positionKey.sol";
import {Position} from "../types/position.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {BaseLocker} from "../base/BaseLocker.sol";

contract TWAMMDataFetcher is UsesCore, BaseLocker {
    using CoreLib for *;
    using TWAMMLib for *;

    TWAMM public immutable twamm;

    constructor(ICore core, TWAMM _twamm) UsesCore(core) BaseLocker(core) {
        twamm = _twamm;
    }

    function poolState(PoolKey memory poolKey)
        public
        view
        returns (uint32 lastVirtualOrderExecutionTime, uint112 saleRateToken0, uint112 saleRateToken1)
    {
        (lastVirtualOrderExecutionTime, saleRateToken0, saleRateToken1) = twamm.poolState(poolKey.toPoolId());
    }

    function handleLockData(uint256, bytes memory) internal override returns (bytes memory result) {}
}
