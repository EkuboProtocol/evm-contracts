// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CoreLib} from "../libraries/CoreLib.sol";
import {UsesCore} from "../base/UsesCore.sol";
import {ICore} from "../interfaces/ICore.sol";
import {PoolKey, PositionKey} from "../types/keys.sol";
import {Position} from "../types/position.sol";

contract CoreDataFetcher is UsesCore {
    using CoreLib for *;

    constructor(ICore core) UsesCore(core) {}

    function protocolFeesCollected(address token) external view returns (uint256 amount) {
        amount = core.protocolFeesCollected(token);
    }

    function poolPrice(PoolKey memory poolKey) external view returns (uint256 sqrtRatio, int32 tick) {
        (sqrtRatio, tick) = core.poolPrice(poolKey.toPoolId());
    }

    function poolLiquidity(PoolKey memory poolKey) external view returns (uint128 liquidity) {
        liquidity = core.poolLiquidity(poolKey.toPoolId());
    }

    function poolPosition(PoolKey memory poolKey, PositionKey memory positionKey)
        external
        view
        returns (Position memory position)
    {
        position = core.poolPositions(poolKey.toPoolId(), positionKey.toPositionId());
    }

    function savedBalances(ICore core, address owner, address token, bytes32 salt)
        external
        view
        returns (uint256 savedBalance)
    {
        savedBalance = core.savedBalances(owner, token, salt);
    }
}
