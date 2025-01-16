// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {CallPoints} from "../types/callPoints.sol";
import {PoolKey, PositionKey, Bounds} from "../types/keys.sol";
import {Core, UpdatePositionParameters, SwapParameters} from "../Core.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {BaseExtension} from "../base/BaseExtension.sol";

contract Oracle is ExposedStorage, BaseExtension {
    address public immutable oracleToken;

    constructor(address _oracleToken, Core core) BaseExtension(core) {
        oracleToken = _oracleToken;
    }

    function getCallPoints() internal override returns (CallPoints memory) {
        return CallPoints({
            beforeInitializePool: true,
            afterInitializePool: false,
            beforeUpdatePosition: true,
            afterUpdatePosition: false,
            beforeSwap: true,
            afterSwap: false,
            beforeCollectFees: false,
            afterCollectFees: false
        });
    }

    function beforeInitializePool(address caller, PoolKey calldata key, int32 tick) external override onlyCore {
        // todo
    }
    function beforeUpdatePosition(address locker, PoolKey memory poolKey, UpdatePositionParameters memory params)
        external
        override
        onlyCore
    {
        // todo
    }

    function beforeSwap(address locker, PoolKey memory poolKey, SwapParameters memory params)
        external
        override
        onlyCore
    {
        // todo
    }
}
