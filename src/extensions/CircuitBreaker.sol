// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

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

    uint256 public immutable AMPERAGE;
    uint256 public immutable HALT_DURATION;

    constructor(ICore core, uint256 amperage, uint256 haltDuration) BaseExtension(core) {
        if (haltDuration == 0 || haltDuration > type(uint32).max) {
            revert InvalidHaltDuration();
        }
        if (amperage == 0 || amperage > 255) {
            revert InvalidAmperage();
        }

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

        setPoolState(poolKey.toPoolId(), createCircuitBreakerPoolState(uint64(block.timestamp), tick));
    }

    function beforeSwap(Locker, PoolKey memory poolKey, SwapParameters)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        PoolId poolId = poolKey.toPoolId();
        CircuitBreakerPoolState state = getPoolState(poolId);
        int32 currentTick = CORE.poolState(poolId).tick();
        uint256 tickDelta = FixedPointMathLib.dist(currentTick, state.blockStartTick());

        uint64 lastSwapTimestamp = state.lastSwapTimestamp();

        // Breaker is tripped if the tick has moved by more than the expected amount in the last block
        if (tickDelta > AMPERAGE * poolKey.config.concentratedTickSpacing()) {
            uint64 timeElapsed;
            unchecked {
                timeElapsed = uint64(block.timestamp) - lastSwapTimestamp;
            }

            // Breaker untrips after the halt duration. At this point, anyone who has left their liquidity in the pool is vulnerable.
            if (timeElapsed < HALT_DURATION) {
                unchecked {
                    revert BreakerTripped(block.timestamp - timeElapsed + HALT_DURATION);
                }
            }
        }

        // We need to update the pool state at the beginning of each block so we know breaker was not tripped
        if (lastSwapTimestamp != uint64(block.timestamp)) {
            setPoolState(poolId, createCircuitBreakerPoolState(uint64(block.timestamp), currentTick));
        }
    }

    function afterSwap(Locker, PoolKey memory poolKey, SwapParameters, PoolBalanceUpdate, PoolState stateAfter)
        external
        view
        override(BaseExtension, IExtension)
        onlyCore
    {
        CircuitBreakerPoolState state = getPoolState(poolKey.toPoolId());
        int32 blockStartTick = state.blockStartTick();
        uint256 hardLimit = AMPERAGE * poolKey.config.concentratedTickSpacing() * 2;
        int32 tickAfter = stateAfter.tick();
        uint256 tickDelta = FixedPointMathLib.dist(tickAfter, blockStartTick);

        if (tickDelta > hardLimit) {
            revert TickMovementExceedsHardLimit(hardLimit, blockStartTick, tickAfter);
        }
    }

    function getPoolState(PoolId poolId) internal view returns (CircuitBreakerPoolState state) {
        assembly ("memory-safe") {
            state := sload(poolId)
        }
    }

    function setPoolState(PoolId poolId, CircuitBreakerPoolState state) internal {
        assembly ("memory-safe") {
            sstore(poolId, state)
        }
    }
}
