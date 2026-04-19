// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {IExtension} from "../ICore.sol";
import {IExposedStorage} from "../IExposedStorage.sol";

interface ICircuitBreaker is IExposedStorage, IExtension {
    function AMPERAGE() external view returns (uint32);

    function HALT_DURATION() external view returns (uint32);

    error ConcentratedLiquidityPoolsOnly();
    error InvalidPool();
    error SwappingPaused(uint32 resetTime);
    error TickMovementExceedsHardLimit(uint256 maxDelta, int32 blockStartTick, int32 tickAfterSwap);
}
