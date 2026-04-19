// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {IExtension} from "../ICore.sol";
import {IExposedStorage} from "../IExposedStorage.sol";

interface ICircuitBreaker is IExposedStorage, IExtension {
    function AMPERAGE() external view returns (uint256);

    function HALT_DURATION() external view returns (uint256);

    error ConcentratedLiquidityPoolsOnly();
    error BreakerTripped(uint256 untilTime);
    error TickMovementExceedsHardLimit(uint256 maxDelta, int32 blockStartTick, int32 tickAfterSwap);
}
