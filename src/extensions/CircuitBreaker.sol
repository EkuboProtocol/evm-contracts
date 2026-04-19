// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore, IExtension, PoolKey, CallPoints} from "../interfaces/ICore.sol";
import {ICircuitBreaker} from "../interfaces/extensions/ICircuitBreaker.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolState} from "../types/poolState.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {CircuitBreakerPoolState, createCircuitBreakerPoolState} from "../types/circuitBreakerPoolState.sol";
import {Locker} from "../types/locker.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";

function circuitBreakerCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: false,
        beforeSwap: true,
        afterSwap: true,
        beforeUpdatePosition: false,
        afterUpdatePosition: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

contract CircuitBreaker is ICircuitBreaker, BaseExtension, ExposedStorage {
    using CoreLib for *;

    uint32 public immutable AMPERAGE;
    uint32 public immutable HALT_DURATION;

    constructor(ICore core, uint32 amperage, uint32 haltDuration) BaseExtension(core) {
        AMPERAGE = amperage;
        HALT_DURATION = haltDuration;
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return circuitBreakerCallPoints();
    }

    function beforeInitializePool(address, PoolKey calldata poolKey, int32 tick)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        if (poolKey.config.isStableswap()) {
            revert ConcentratedLiquidityPoolsOnly();
        }

        _setPoolState(poolKey.toPoolId(), createCircuitBreakerPoolState(0, tick));
    }

    function beforeSwap(Locker, PoolKey memory poolKey, SwapParameters)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        CircuitBreakerPoolState state = _syncCircuitBreaker(poolKey);
        uint32 resetTime = _resetTime(state.lastSwapTimestamp());
        if (
            state.lastSwapTimestamp() != uint32(block.timestamp) && _isTripped(poolKey, state.blockStartTick())
                && !_haltHasElapsed(state.lastSwapTimestamp())
        ) {
            revert SwappingPaused(resetTime);
        }
    }

    function afterSwap(Locker, PoolKey memory poolKey, SwapParameters, PoolBalanceUpdate, PoolState stateAfter)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        CircuitBreakerPoolState state = _getPoolState(poolKey.toPoolId());
        int32 blockStartTick_ = state.blockStartTick();
        uint256 hardLimit = _tripThreshold(poolKey) * 2;
        int32 tickAfter = stateAfter.tick();

        if (_tickDelta(blockStartTick_, tickAfter) > hardLimit) {
            revert TickMovementExceedsHardLimit(hardLimit, blockStartTick_, tickAfter);
        }

        _setPoolState(poolKey.toPoolId(), createCircuitBreakerPoolState(uint32(block.timestamp), blockStartTick_));
    }

    function _syncCircuitBreaker(PoolKey memory poolKey) internal returns (CircuitBreakerPoolState nextState) {
        PoolId poolId = poolKey.toPoolId();
        if (poolKey.config.extension() != address(this) || !CORE.poolState(poolId).isInitialized()) {
            revert InvalidPool();
        }

        CircuitBreakerPoolState state = _getPoolState(poolId);
        if (state.lastSwapTimestamp() == uint32(block.timestamp)) {
            return state;
        }

        int32 currentTick = CORE.poolState(poolId).tick();
        uint32 lastSwapTimestamp_ = state.lastSwapTimestamp();

        if (
            _tickDelta(state.blockStartTick(), currentTick) > _tripThreshold(poolKey)
                && !_haltHasElapsed(lastSwapTimestamp_)
        ) {
            return state;
        }

        nextState = createCircuitBreakerPoolState(lastSwapTimestamp_, currentTick);
        _setPoolState(poolId, nextState);
    }

    function _tripThreshold(PoolKey memory poolKey) internal view returns (uint256) {
        return uint256(AMPERAGE) * poolKey.config.concentratedTickSpacing();
    }

    function _tickDelta(int32 tick0, int32 tick1) internal pure returns (uint256) {
        unchecked {
            return uint256(uint32(tick1 > tick0 ? tick1 - tick0 : tick0 - tick1));
        }
    }

    function _isTripped(PoolKey memory poolKey, int32 blockStartTick_) internal view returns (bool) {
        return _tickDelta(blockStartTick_, CORE.poolState(poolKey.toPoolId()).tick()) > _tripThreshold(poolKey);
    }

    function _resetTime(uint32 lastSwapTimestamp_) internal view returns (uint32 resetTime) {
        unchecked {
            resetTime = lastSwapTimestamp_ + HALT_DURATION;
        }
    }

    function _haltHasElapsed(uint32 lastSwapTimestamp_) internal view returns (bool) {
        uint256 elapsed = block.timestamp - lastSwapTimestamp_;
        return elapsed >= HALT_DURATION && elapsed < type(uint32).max;
    }

    function _getPoolState(PoolId poolId) internal view returns (CircuitBreakerPoolState state) {
        assembly ("memory-safe") {
            state := sload(poolId)
        }
    }

    function _setPoolState(PoolId poolId, CircuitBreakerPoolState state) internal {
        assembly ("memory-safe") {
            sstore(poolId, state)
        }
    }
}
