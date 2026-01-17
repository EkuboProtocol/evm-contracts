// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {BaseForwardee} from "../base/BaseForwardee.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {CallPoints} from "../types/callPoints.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionId} from "../types/positionId.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {Locker} from "../types/locker.sol";
import {PoolId} from "../types/poolId.sol";
import {ICore, IExtension} from "../interfaces/ICore.sol";
import {IBoostedFees} from "../interfaces/extensions/IBoostedFees.sol";

import {BaseExtension} from "../base/BaseExtension.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {TwammPoolState, createTwammPoolState} from "../types/twammPoolState.sol";
import {addSaleRateDelta} from "../math/twamm.sol";
import {MAX_ABS_VALUE_SALE_RATE_DELTA, isTimeValid} from "../math/time.sol";
import {searchForNextInitializedTime, flipTime} from "../math/timeBitmap.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {TWAMMStorageLayout} from "../libraries/TWAMMStorageLayout.sol";
import {StorageSlot} from "../types/storageSlot.sol";

function boostedFeesCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: false,
        afterInitializePool: true,
        beforeSwap: true,
        afterSwap: false,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeCollectFees: true,
        afterCollectFees: false
    });
}

contract BoostedFees is IBoostedFees, BaseExtension, BaseForwardee, ExposedStorage {
    using CoreLib for *;

    constructor(ICore core) BaseExtension(core) BaseForwardee(core) {}

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return boostedFeesCallPoints();
    }

    /// @dev Writes the TwammPoolState to storage.
    function _setPoolState(PoolId poolId, TwammPoolState state) private {
        TWAMMStorageLayout.twammPoolStateSlot(poolId).store(TwammPoolState.unwrap(state));
    }

    /// @dev Reads the state for the pool
    function _getPoolState(PoolId poolId) private view returns (TwammPoolState state) {
        state = TwammPoolState.wrap(TWAMMStorageLayout.twammPoolStateSlot(poolId).load());
    }

    /// @dev Emits a zero-topic event matching TWAMM's execution format.
    function _emitFeesDonated(PoolId poolId, uint256 rate0, uint256 rate1) private {
        assembly ("memory-safe") {
            // by writing it backwards, we overwrite only the empty bits with each subsequent write
            // 28-60, only 46-60 can be non-zero
            mstore(28, rate1)
            // 14-46, only 32-46 can be non-zero
            mstore(14, rate0)
            mstore(0, poolId)

            log0(0, 60)
        }
    }

    /// @inheritdoc IExtension
    function afterInitializePool(address, PoolKey memory poolKey, int32, SqrtRatio)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        PoolId poolId = poolKey.toPoolId();
        _setPoolState(poolId, createTwammPoolState(uint32(block.timestamp), 0, 0));
        _emitFeesDonated(poolId, 0, 0);
    }

    /// @inheritdoc IExtension
    function beforeSwap(Locker, PoolKey memory poolKey, SwapParameters) external override(BaseExtension, IExtension) {
        maybeAccumulateFees(poolKey);
    }

    /// @inheritdoc IExtension
    function beforeUpdatePosition(Locker, PoolKey memory poolKey, PositionId, int128)
        external
        override(BaseExtension, IExtension)
    {
        maybeAccumulateFees(poolKey);
    }

    /// @inheritdoc IExtension
    function beforeCollectFees(Locker, PoolKey memory poolKey, PositionId)
        external
        override(BaseExtension, IExtension)
    {
        maybeAccumulateFees(poolKey);
    }

    /// @dev Locks Core to accumulate the given amount of fees to the specified pool.
    function _accumulateFeesFromSavedBalance(PoolKey memory poolKey, uint128 amount0, uint128 amount1) private {
        address target = address(CORE);
        assembly ("memory-safe") {
            let o := mload(0x40)
            mstore(o, shl(224, 0xf83d08ba))
            mcopy(add(o, 4), poolKey, 96)
            let amounts := or(shl(128, amount0), shr(128, shl(128, amount1)))
            mstore(add(o, 100), amounts)

            if iszero(call(gas(), target, 0, o, 132, 0, 0)) {
                returndatacopy(o, 0, returndatasize())
                revert(o, returndatasize())
            }
        }
    }

    /// @dev This is only called if there is an amount that needs to be donated for a pool.
    function locked_6416899205(uint256) external override onlyCore {
        PoolKey memory poolKey;
        uint128 amount0;
        uint128 amount1;

        assembly ("memory-safe") {
            calldatacopy(poolKey, 36, 96)
            let amounts := calldataload(132)

            amount0 := shr(128, amounts)
            amount1 := shr(128, shl(128, amounts))
        }

        CORE.accumulateAsFees(poolKey, amount0, amount1);
        CORE.updateSavedBalances(
            poolKey.token0, poolKey.token1, bytes32(0), -int256(uint256(amount0)), -int256(uint256(amount1))
        );
    }

    /// @dev Note this checks that the pool is initialized via the local state of the contract
    function maybeAccumulateFees(PoolKey memory poolKey) public {
        unchecked {
            PoolId poolId = poolKey.toPoolId();

            TwammPoolState state = _getPoolState(poolId);

            if (TwammPoolState.unwrap(state) == bytes32(0)) {
                if (poolKey.config.extension() != address(this) || !CORE.poolState(poolId).isInitialized()) {
                    revert PoolNotInitialized();
                }
            }

            (uint32 lastAccumulated, uint256 rate0, uint256 rate1) = state.parse();

            if (uint32(block.timestamp) != lastAccumulated) {
                StorageSlot initializedTimesBitmapSlot = TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId);

                // `TwammPoolState` stores timestamps modulo 2**32.
                // `realLastVirtualOrderExecutionTime()` reconstructs an absolute timestamp in the same 2**32 window as
                // `block.timestamp`, so `block.timestamp - time` is guaranteed to fit in 32 bits.
                uint256 realLastDonationTime = state.realLastVirtualOrderExecutionTime();
                uint256 time = realLastDonationTime;

                uint256 amount0;
                uint256 amount1;

                while (time != block.timestamp) {
                    (uint256 eventTime, bool hasEvent) = searchForNextInitializedTime({
                        slot: initializedTimesBitmapSlot,
                        lastVirtualOrderExecutionTime: realLastDonationTime,
                        fromTime: time,
                        untilTime: block.timestamp
                    });

                    // Overflow notes:
                    // - `rate{0,1}` are stored as `uint112` (see `TwammPoolState`), so they are < 2**112.
                    // - `(eventTime - time)` fits in 32 bits (see comment above).
                    // - The product therefore fits in 112 + 32 = 144 bits and the subsequent `>> 32` fits in 112 bits.
                    // - `amount{0,1}` are cumulative over at most `MAX_NUM_VALID_TIMES` segments, so they stay < 2**128.
                    amount0 += (rate0 * (eventTime - time)) >> 32;
                    amount1 += (rate1 * (eventTime - time)) >> 32;

                    if (hasEvent) {
                        StorageSlot timeInfoSlot = TWAMMStorageLayout.poolTimeInfosSlot(poolId, eventTime);
                        PoolBalanceUpdate deltas = PoolBalanceUpdate.wrap(timeInfoSlot.load());

                        rate0 = addSaleRateDelta(rate0, deltas.delta0());
                        rate1 = addSaleRateDelta(rate1, deltas.delta1());

                        // saves on storage by clearing the slots
                        timeInfoSlot.store(bytes32(0));
                        flipTime(initializedTimesBitmapSlot, eventTime);
                    }

                    time = eventTime;
                }

                _setPoolState(
                    poolId,
                    createTwammPoolState({
                        _lastVirtualOrderExecutionTime: uint32(block.timestamp),
                        // `rate{0,1}` are tracked as `uint256` locally for convenience, but are always maintained within the
                        // `uint112` range: they originate from `TwammPoolState.parse()` (which returns `uint112`) and are
                        // only updated via `addSaleRateDelta(...)`, which reverts if the result exceeds 112 bits.
                        _saleRateToken0: uint112(rate0),
                        _saleRateToken1: uint112(rate1)
                    })
                );

                if (amount0 != 0 || amount1 != 0) {
                    // `amount{0,1}` are bounded as described above and fit within 128 bits, so these casts cannot truncate.
                    _accumulateFeesFromSavedBalance(poolKey, uint128(amount0), uint128(amount1));
                }

                _emitFeesDonated(poolId, rate0, rate1);
            }
        }
    }

    function handleForwardData(Locker, bytes memory data) internal override returns (bytes memory result) {
        unchecked {
            (PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint112 rate0, uint112 rate1) =
                abi.decode(data, (PoolKey, uint64, uint64, uint112, uint112));

            if (
                !isTimeValid({currentTime: block.timestamp, time: startTime})
                    || !isTimeValid({currentTime: block.timestamp, time: endTime}) || endTime <= startTime
                    || endTime <= block.timestamp
            ) {
                revert InvalidTimestamps();
            }

            // First thing we must always do is always update the pool to the current state
            maybeAccumulateFees(poolKey);

            // Compute the amounts that the user must pay.
            //
            // Safety notes:
            // - The timestamp checks above guarantee `endTime > max(block.timestamp, startTime)`, so this cannot underflow.
            // - `isTimeValid` constrains `endTime` (and `startTime` when in the future) to be within a 2**32 second window
            //   of `block.timestamp`, so `realDuration` fits in 32 bits.
            uint256 realDuration = uint256(endTime) - FixedPointMathLib.max(block.timestamp, startTime);
            // `rate{0,1}` are fixed point values with 32 fractional bits. Since `realDuration` is <= 2**32 - 1 and
            // `rate{0,1} < 2**112`, the product fits in 144 bits and the `>> 32` result fits in 112 bits.
            // Adding `type(uint32).max` implements a round-up when shifting.
            uint256 amount0 = ((realDuration * rate0) + type(uint32).max) >> 32;
            uint256 amount1 = ((realDuration * rate1) + type(uint32).max) >> 32;

            // `amount{0,1}` fit within 112 bits, so converting to `int256` is safe (always positive, never wraps).
            CORE.updateSavedBalances(poolKey.token0, poolKey.token1, bytes32(0), int256(amount0), int256(amount1));

            PoolId poolId = poolKey.toPoolId();
            StorageSlot initializedTimesBitmapSlot = TWAMMStorageLayout.poolInitializedTimesBitmapSlot(poolId);

            if (startTime > block.timestamp) {
                _updateTime(
                    initializedTimesBitmapSlot, poolId, startTime, int256(uint256(rate0)), int256(uint256(rate1))
                );
            } else {
                TwammPoolState state = _getPoolState(poolId);
                _setPoolState(
                    poolId,
                    createTwammPoolState(
                        uint32(block.timestamp),
                        uint112(addSaleRateDelta(state.saleRateToken0(), int256(uint256(rate0)))),
                        uint112(addSaleRateDelta(state.saleRateToken1(), int256(uint256(rate1))))
                    )
                );
            }

            _updateTime(initializedTimesBitmapSlot, poolId, endTime, -int256(uint256(rate0)), -int256(uint256(rate1)));

            emit PoolBoosted(poolId, startTime, endTime, rate0, rate1);

            result = abi.encode(amount0, amount1);
        }
    }

    /// @dev Adds a signed change to an existing rate delta with bounds checking.
    function _addConstrainRateDelta(int128 rateDelta, int256 change) private pure returns (int128 next) {
        int256 result = int256(rateDelta) + change;

        if (FixedPointMathLib.abs(result) > MAX_ABS_VALUE_SALE_RATE_DELTA) {
            revert MaxRateDeltaPerTime();
        }

        next = int128(result);
    }

    function _updateTime(
        StorageSlot initializedTimesBitmapSlot,
        PoolId poolId,
        uint64 time,
        int256 delta0,
        int256 delta1
    ) private {
        StorageSlot timeInfoSlot = TWAMMStorageLayout.poolTimeInfosSlot(poolId, time);
        PoolBalanceUpdate info = PoolBalanceUpdate.wrap(timeInfoSlot.load());

        PoolBalanceUpdate infoNext = createPoolBalanceUpdate(
            _addConstrainRateDelta(info.delta0(), delta0), _addConstrainRateDelta(info.delta1(), delta1)
        );

        timeInfoSlot.store(PoolBalanceUpdate.unwrap(infoNext));

        if ((PoolBalanceUpdate.unwrap(info) == bytes32(0)) != (PoolBalanceUpdate.unwrap(infoNext) == bytes32(0))) {
            flipTime(initializedTimesBitmapSlot, time);
        }
    }
}
