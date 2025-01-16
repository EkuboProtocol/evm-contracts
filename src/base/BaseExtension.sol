// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Core, IExtension, UpdatePositionParameters, SwapParameters} from "../Core.sol";
import {CallPoints} from "../types/callPoints.sol";
import {PoolKey, PositionKey, Bounds} from "../types/keys.sol";

abstract contract BaseExtension is IExtension {
    Core internal immutable core;

    constructor(Core _core) {
        core = _core;
        core.registerExtension(getCallPoints());
    }

    function getCallPoints() internal virtual returns (CallPoints memory);

    error CoreOnly();

    modifier onlyCore() {
        if (msg.sender != address(core)) revert CoreOnly();
        _;
    }

    error CallPointNotImplemented();

    function beforeInitializePool(address caller, PoolKey calldata key, int32 tick) external virtual {
        revert CallPointNotImplemented();
    }

    function afterInitializePool(address caller, PoolKey calldata key, int32 tick, uint256 sqrtRatio)
        external
        virtual
    {
        revert CallPointNotImplemented();
    }

    function beforeUpdatePosition(address locker, PoolKey memory poolKey, UpdatePositionParameters memory params)
        external
        virtual
    {
        revert CallPointNotImplemented();
    }

    function afterUpdatePosition(
        address locker,
        PoolKey memory poolKey,
        UpdatePositionParameters memory params,
        int128 delta0,
        int128 delta1
    ) external virtual {
        revert CallPointNotImplemented();
    }

    function beforeSwap(address locker, PoolKey memory poolKey, SwapParameters memory params) external virtual {
        revert CallPointNotImplemented();
    }

    function afterSwap(
        address locker,
        PoolKey memory poolKey,
        SwapParameters memory params,
        int128 delta0,
        int128 delta1
    ) external virtual {
        revert CallPointNotImplemented();
    }

    function beforeCollectFees(address locker, PoolKey memory poolKey, bytes32 salt, Bounds memory bounds) external {
        revert CallPointNotImplemented();
    }

    function afterCollectFees(
        address locker,
        PoolKey memory poolKey,
        bytes32 salt,
        Bounds memory bounds,
        uint128 amount0,
        uint128 amount1
    ) external virtual {
        revert CallPointNotImplemented();
    }
}
