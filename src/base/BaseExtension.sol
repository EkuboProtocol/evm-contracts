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

    function getCallPoints() internal pure virtual returns (CallPoints memory);

    error CoreOnly();

    modifier onlyCore() {
        if (msg.sender != address(core)) revert CoreOnly();
        _;
    }

    error CallPointNotImplemented();

    function beforeInitializePool(address, PoolKey calldata, int32) external virtual {
        revert CallPointNotImplemented();
    }

    function afterInitializePool(address, PoolKey calldata, int32, uint256) external virtual {
        revert CallPointNotImplemented();
    }

    function beforeUpdatePosition(address, PoolKey memory, UpdatePositionParameters memory) external virtual {
        revert CallPointNotImplemented();
    }

    function afterUpdatePosition(address, PoolKey memory, UpdatePositionParameters memory, int128, int128)
        external
        virtual
    {
        revert CallPointNotImplemented();
    }

    function beforeSwap(address, PoolKey memory, SwapParameters memory) external virtual {
        revert CallPointNotImplemented();
    }

    function afterSwap(address, PoolKey memory, SwapParameters memory, int128, int128) external virtual {
        revert CallPointNotImplemented();
    }

    function beforeCollectFees(address, PoolKey memory, bytes32, Bounds memory) external virtual {
        revert CallPointNotImplemented();
    }

    function afterCollectFees(address, PoolKey memory, bytes32, Bounds memory, uint128, uint128) external virtual {
        revert CallPointNotImplemented();
    }
}
