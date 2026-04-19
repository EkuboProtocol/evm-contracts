// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ICore} from "../interfaces/ICore.sol";
import {ICircuitBreaker} from "../interfaces/extensions/ICircuitBreaker.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {CircuitBreakerPoolState} from "../types/circuitBreakerPoolState.sol";
import {CoreLib} from "./CoreLib.sol";
import {ExposedStorageLib} from "./ExposedStorageLib.sol";

library CircuitBreakerLib {
    using CoreLib for *;
    using ExposedStorageLib for *;

    function poolState(ICircuitBreaker circuitBreaker, PoolId poolId)
        internal
        view
        returns (CircuitBreakerPoolState state)
    {
        state = CircuitBreakerPoolState.wrap(circuitBreaker.sload(PoolId.unwrap(poolId)));
    }

    function resetTime(ICircuitBreaker circuitBreaker, PoolId poolId) internal view returns (uint64) {
        return poolState(circuitBreaker, poolId).lastSwapTimestamp() + uint64(circuitBreaker.HALT_DURATION());
    }

    function elapsedSinceLastSwap(ICircuitBreaker circuitBreaker, PoolId poolId)
        internal
        view
        returns (uint256 elapsed)
    {
        elapsed =
            uint64(block.timestamp) - poolState(circuitBreaker, poolId).lastSwapTimestamp();
    }

    function isFuseTripped(ICore core, ICircuitBreaker circuitBreaker, PoolKey memory poolKey)
        internal
        view
        returns (bool tripped)
    {
        PoolId poolId = poolKey.toPoolId();
        CircuitBreakerPoolState state = poolState(circuitBreaker, poolId);

        if (state.lastSwapTimestamp() == uint64(block.timestamp)) {
            return false;
        }

        uint64 elapsed = uint64(block.timestamp) - state.lastSwapTimestamp();
        if (elapsed >= circuitBreaker.HALT_DURATION()) {
            return false;
        }

        int32 currentTick = core.poolState(poolId).tick();
        uint256 threshold = uint256(circuitBreaker.AMPERAGE()) * poolKey.config.concentratedTickSpacing();

        tripped = uint256(FixedPointMathLib.abs(int256(currentTick) - int256(state.blockStartTick()))) > threshold;
    }
}
