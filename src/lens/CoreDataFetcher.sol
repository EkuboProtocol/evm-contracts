// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CoreLib} from "../libraries/CoreLib.sol";
import {UsesCore} from "../base/UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionKey} from "../types/positionKey.sol";
import {Position} from "../types/position.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";

contract CoreDataFetcher is UsesCore {
    using CoreLib for *;

    constructor(ICore core) UsesCore(core) {}

    function isExtensionRegistered(address extension) external view returns (bool registered) {
        registered = core.isExtensionRegistered(extension);
    }

    function protocolFeesCollected(address token) external view returns (uint256 amountCollected) {
        amountCollected = core.protocolFeesCollected(token);
    }

    function poolPrice(PoolKey memory poolKey) external view returns (uint256 sqrtRatioFixed, int32 tick) {
        SqrtRatio sqrtRatio;
        (sqrtRatio, tick,) = poolState(poolKey);
        sqrtRatioFixed = sqrtRatio.toFixed();
    }

    function poolState(PoolKey memory poolKey)
        public
        view
        returns (SqrtRatio sqrtRatio, int32 tick, uint128 liquidity)
    {
        (sqrtRatio, tick, liquidity) = core.poolState(poolKey.toPoolId());
    }

    function poolPosition(PoolKey memory poolKey, PositionKey memory positionKey)
        external
        view
        returns (Position memory position)
    {
        position = core.poolPositions(poolKey.toPoolId(), positionKey.toPositionId());
    }

    function savedBalances(address owner, address token0, address token1, bytes32 salt)
        external
        view
        returns (uint128 savedBalance0, uint128 savedBalance1)
    {
        (savedBalance0, savedBalance1) = core.savedBalances(owner, token0, token1, salt);
    }

    function poolTicks(bytes32 poolId, int32 tick)
        external
        view
        returns (int128 liquidityDelta, uint128 liquidityNet)
    {
        (liquidityDelta, liquidityNet) = core.poolTicks(poolId, tick);
    }
}
