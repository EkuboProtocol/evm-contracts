// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ICore, IExtension} from "../interfaces/ICore.sol";
import {ISingleTokenRewards} from "../interfaces/extensions/ISingleTokenRewards.sol";
import {
    SINGLE_TOKEN_REWARDS_ADD_REWARDS,
    SINGLE_TOKEN_REWARDS_CLAIM_TO_RECIPIENT,
    SINGLE_TOKEN_REWARDS_DONATE_REWARDS
} from "../libraries/SingleTokenRewardsLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {addLiquidityDelta} from "../math/liquidity.sol";
import {MAX_NUM_VALID_TIMES, isTimeValid, nextValidTime} from "../math/time.sol";
import {Bitmap} from "../types/bitmap.sol";
import {CallPoints} from "../types/callPoints.sol";
import {Locker} from "../types/locker.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PositionId} from "../types/positionId.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {SingleTokenRewardsPoolState, createSingleTokenRewardsPoolState} from "../types/singleTokenRewardsPoolState.sol";
import {PoolState} from "../types/poolState.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {bitmapWordAndIndexToTime, timeToBitmapWordAndIndex} from "../math/timeBitmap.sol";

uint256 constant MAX_ABS_VALUE_REWARD_RATE_DELTA = type(uint224).max / MAX_NUM_VALID_TIMES;

function singleTokenRewardsCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: false,
        afterInitializePool: false,
        beforeSwap: true,
        afterSwap: true,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

contract SingleTokenRewards is ISingleTokenRewards, BaseExtension, BaseForwardee {
    using CoreLib for *;
    using FlashAccountantLib for *;

    /// @inheritdoc ISingleTokenRewards
    address public immutable rewardToken;

    mapping(PoolId => SingleTokenRewardsPoolState) public poolRewardState;
    mapping(PoolId => uint256) public rewardsGlobalPerLiquidity;
    mapping(PoolId => mapping(int32 => uint256)) public tickRewardsOutsidePerLiquidity;
    mapping(PoolId => mapping(address => mapping(PositionId => uint256))) public positionRewardsSnapshotPerLiquidity;

    mapping(PoolId => mapping(uint256 => uint256)) private initializedTimeBitmap;
    mapping(PoolId => mapping(uint256 => int256)) public rewardRateDeltaAtTime;

    constructor(ICore core, address _rewardToken) BaseExtension(core) BaseForwardee(core) {
        rewardToken = _rewardToken;
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return singleTokenRewardsCallPoints();
    }

    /// @inheritdoc IExtension
    function beforeSwap(Locker, PoolKey memory poolKey, SwapParameters)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        PoolId poolId = poolKey.toPoolId();
        maybeAccumulateRewards(poolKey);
        _storeTickBeforeSwap(poolId, CORE.poolState(poolId).tick());
    }

    /// @inheritdoc IExtension
    function afterSwap(Locker, PoolKey memory poolKey, SwapParameters params, PoolBalanceUpdate, PoolState stateAfter)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        if (poolKey.config.isStableswap()) return;

        PoolId poolId = poolKey.toPoolId();
        int32 tickBefore = _loadTickBeforeSwap(poolId);
        int32 tickAfter = stateAfter.tick();
        if (tickBefore == tickAfter) return;

        uint256 rewardsGlobalPerLiquidity_ = rewardsGlobalPerLiquidity[poolId];
        uint32 tickSpacing = poolKey.config.concentratedTickSpacing();
        uint256 skipAhead = params.skipAhead();

        if (tickAfter > tickBefore) {
            int32 tick = tickBefore;
            while (true) {
                bool initialized;
                (tick, initialized) = CORE.nextInitializedTick(poolId, tick, tickSpacing, skipAhead);
                if (!initialized || tick > tickAfter) break;
                unchecked {
                    tickRewardsOutsidePerLiquidity[poolId][tick] =
                        rewardsGlobalPerLiquidity_ - tickRewardsOutsidePerLiquidity[poolId][tick];
                }
            }
        } else {
            int32 tick = tickBefore;
            while (true) {
                bool initialized;
                (tick, initialized) = CORE.prevInitializedTick(poolId, tick, tickSpacing, skipAhead);
                if (!initialized || tick <= tickAfter) break;
                unchecked {
                    tickRewardsOutsidePerLiquidity[poolId][tick] =
                        rewardsGlobalPerLiquidity_ - tickRewardsOutsidePerLiquidity[poolId][tick];
                    tick--;
                }
            }
        }
    }

    /// @inheritdoc IExtension
    function beforeUpdatePosition(Locker locker, PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        maybeAccumulateRewards(poolKey);

        PoolId poolId = poolKey.toPoolId();
        address owner = locker.addr();
        uint128 liquidity = CORE.poolPositions(poolId, owner, positionId).liquidity;

        if (liquidityDelta != 0) {
            uint128 liquidityNext = addLiquidityDelta(liquidity, liquidityDelta);
            uint256 rewardsInsidePerLiquidity =
                _getRewardsInsidePerLiquidity(poolId, poolKey, positionId.tickLower(), positionId.tickUpper());
            uint256 positionRewardsSnapshotPerLiquidity_ =
                positionRewardsSnapshotPerLiquidity[poolId][owner][positionId];
            uint256 amount =
                _positionRewards(positionRewardsSnapshotPerLiquidity_, rewardsInsidePerLiquidity, liquidity);

            if (liquidityNext == 0) {
                _updateTickRewardsPerLiquidityOutside(poolId, poolKey, positionId.tickLower(), liquidityDelta);
                _updateTickRewardsPerLiquidityOutside(poolId, poolKey, positionId.tickUpper(), liquidityDelta);

                positionRewardsSnapshotPerLiquidity[poolId][owner][positionId] = 0;
            } else {
                _updateTickRewardsPerLiquidityOutside(poolId, poolKey, positionId.tickLower(), liquidityDelta);
                _updateTickRewardsPerLiquidityOutside(poolId, poolKey, positionId.tickUpper(), liquidityDelta);

                uint256 rewardsInsideNextPerLiquidity =
                    _getRewardsInsidePerLiquidity(poolId, poolKey, positionId.tickLower(), positionId.tickUpper());
                unchecked {
                    positionRewardsSnapshotPerLiquidity[poolId][owner][positionId] =
                        rewardsInsideNextPerLiquidity - ((amount << 128) / liquidityNext);
                }
            }
        }
    }

    function _addRewards(PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate)
        private
        returns (uint224 amount)
    {
        if (
            !isTimeValid({currentTime: block.timestamp, time: startTime})
                || !isTimeValid({currentTime: block.timestamp, time: endTime}) || endTime <= startTime
                || endTime <= block.timestamp
        ) {
            revert InvalidTimestamps();
        }

        maybeAccumulateRewards(poolKey);

        unchecked {
            uint256 realDuration = uint256(endTime) - FixedPointMathLib.max(block.timestamp, startTime);
            amount = uint224(((realDuration * rewardRate) + type(uint32).max) >> 32);
        }

        if (amount > type(uint128).max) revert RewardAmountOverflow();

        if (amount != 0) _updateRewardSavedBalance(int256(uint256(amount)));

        PoolId poolId = poolKey.toPoolId();

        int256 rewardRateDelta = int256(uint256(rewardRate));
        if (startTime > block.timestamp) {
            _updateTime(poolId, startTime, rewardRateDelta);
        } else {
            SingleTokenRewardsPoolState state = poolRewardState[poolId];
            poolRewardState[poolId] = createSingleTokenRewardsPoolState(
                state.lastAccumulated(), uint224(_addSaleRate(state.rewardRate(), rewardRateDelta))
            );
        }

        unchecked {
            _updateTime(poolId, endTime, -rewardRateDelta);
        }

        emit PoolRewarded(poolId, startTime, endTime, rewardRate, amount);
    }

    function _donateRewards(PoolKey memory poolKey, uint128 amount) private returns (uint128) {
        maybeAccumulateRewards(poolKey);

        PoolId poolId = poolKey.toPoolId();
        if (amount != 0) {
            uint128 liquidity = CORE.poolState(poolId).liquidity();
            _updateRewardSavedBalance(int256(uint256(amount)));
            if (liquidity != 0) {
                unchecked {
                    rewardsGlobalPerLiquidity[poolId] += (uint256(amount) << 128) / liquidity;
                }
            }
        }

        emit RewardsDonated(poolId, amount);
        return amount;
    }

    /// @inheritdoc ISingleTokenRewards
    function maybeAccumulateRewards(PoolKey memory poolKey) public {
        unchecked {
            PoolId poolId = poolKey.toPoolId();
            SingleTokenRewardsPoolState state = poolRewardState[poolId];

            if (state.lastAccumulated() == 0) {
                if (poolKey.config.extension() != address(this) || !CORE.poolState(poolId).isInitialized()) {
                    revert PoolNotInitialized();
                }
                state = createSingleTokenRewardsPoolState(uint32(block.timestamp), 0);
                poolRewardState[poolId] = state;
            }

            if (uint32(block.timestamp) == state.lastAccumulated()) return;

            uint256 lastAccumulated = state.realLastAccumulated();
            uint256 time = lastAccumulated;
            uint256 rewardRate = state.rewardRate();
            uint256 rewardsAccrued;

            while (time != block.timestamp) {
                (uint256 eventTime, bool hasEvent) =
                    _searchForNextInitializedTime(poolId, lastAccumulated, time, block.timestamp);

                rewardsAccrued += (rewardRate * (eventTime - time)) >> 32;

                if (hasEvent) {
                    int256 rateDelta = rewardRateDeltaAtTime[poolId][eventTime];
                    rewardRate = _addSaleRate(rewardRate, rateDelta);

                    delete rewardRateDeltaAtTime[poolId][eventTime];
                    _flipTime(poolId, eventTime);
                }

                time = eventTime;
            }

            uint128 liquidity = CORE.poolState(poolId).liquidity();
            if (rewardsAccrued != 0 && liquidity != 0) {
                rewardsGlobalPerLiquidity[poolId] += (rewardsAccrued << 128) / liquidity;
            }

            poolRewardState[poolId] = createSingleTokenRewardsPoolState(uint32(block.timestamp), uint224(rewardRate));
        }
    }

    function _claimRewards(PoolKey memory poolKey, address owner, PositionId positionId, address recipient)
        private
        returns (uint256 amount)
    {
        maybeAccumulateRewards(poolKey);

        PoolId poolId = poolKey.toPoolId();
        uint128 liquidity = CORE.poolPositions(poolId, owner, positionId).liquidity;
        uint256 positionRewardsSnapshotPerLiquidity_ = positionRewardsSnapshotPerLiquidity[poolId][owner][positionId];

        uint256 rewardsInsidePerLiquidity =
            _getRewardsInsidePerLiquidity(poolId, poolKey, positionId.tickLower(), positionId.tickUpper());
        amount = _positionRewards(positionRewardsSnapshotPerLiquidity_, rewardsInsidePerLiquidity, liquidity);

        positionRewardsSnapshotPerLiquidity[poolId][owner][positionId] = liquidity == 0 ? 0 : rewardsInsidePerLiquidity;

        if (amount > type(uint128).max) revert RewardAmountOverflow();

        if (amount != 0) {
            uint128 amountUint128 = uint128(amount);
            unchecked {
                _updateRewardSavedBalance(-int256(uint256(amountUint128)));
            }
            CORE.withdraw(rewardToken, recipient, amountUint128);
        }

        emit RewardsClaimed(poolId, owner, positionId, recipient, amount);
    }

    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == SINGLE_TOKEN_REWARDS_ADD_REWARDS) {
            (, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate) =
                abi.decode(data, (uint256, PoolKey, uint64, uint64, uint224));

            result = abi.encode(_addRewards(poolKey, startTime, endTime, rewardRate));
        } else if (callType == SINGLE_TOKEN_REWARDS_CLAIM_TO_RECIPIENT) {
            (, PoolKey memory poolKey, PositionId positionId, address recipient) =
                abi.decode(data, (uint256, PoolKey, PositionId, address));

            address owner = original.addr();
            result = abi.encode(_claimRewards(poolKey, owner, positionId, recipient));
        } else if (callType == SINGLE_TOKEN_REWARDS_DONATE_REWARDS) {
            (, PoolKey memory poolKey, uint128 amount) = abi.decode(data, (uint256, PoolKey, uint128));

            result = abi.encode(_donateRewards(poolKey, amount));
        } else {
            revert();
        }
    }

    function _updateRewardSavedBalance(int256 delta) private {
        CORE.updateSavedBalances(address(0), rewardToken, bytes32(0), 0, delta);
    }

    function _getRewardsInsidePerLiquidity(PoolId poolId, PoolKey memory poolKey, int32 tickLower, int32 tickUpper)
        private
        view
        returns (uint256 rewardsInsidePerLiquidity)
    {
        if (poolKey.config.isStableswap()) {
            return rewardsGlobalPerLiquidity[poolId];
        }

        int32 tick = CORE.poolState(poolId).tick();
        uint256 lower = tickRewardsOutsidePerLiquidity[poolId][tickLower];
        uint256 upper = tickRewardsOutsidePerLiquidity[poolId][tickUpper];

        unchecked {
            if (tick < tickLower) {
                rewardsInsidePerLiquidity = lower - upper;
            } else if (tick < tickUpper) {
                rewardsInsidePerLiquidity = rewardsGlobalPerLiquidity[poolId] - upper - lower;
            } else {
                rewardsInsidePerLiquidity = upper - lower;
            }
        }
    }

    function _updateTickRewardsPerLiquidityOutside(
        PoolId poolId,
        PoolKey memory poolKey,
        int32 tick,
        int128 liquidityDelta
    ) private {
        if (poolKey.config.isStableswap()) return;

        (, uint128 liquidityNet) = CORE.poolTicks(poolId, tick);
        uint128 liquidityNetNext = addLiquidityDelta(liquidityNet, liquidityDelta);
        if ((liquidityNet == 0) != (liquidityNetNext == 0)) {
            if (liquidityNetNext == 0) {
                delete tickRewardsOutsidePerLiquidity[poolId][tick];
            } else if (tick <= CORE.poolState(poolId).tick()) {
                tickRewardsOutsidePerLiquidity[poolId][tick] = rewardsGlobalPerLiquidity[poolId];
            }
        }
    }

    function _storeTickBeforeSwap(PoolId poolId, int32 tick) private {
        assembly ("memory-safe") {
            tstore(poolId, tick)
        }
    }

    function _loadTickBeforeSwap(PoolId poolId) private view returns (int32 tick) {
        assembly ("memory-safe") {
            tick := signextend(3, tload(poolId))
        }
    }

    function _positionRewards(
        uint256 positionRewardsSnapshotPerLiquidity_,
        uint256 rewardsInsidePerLiquidity_,
        uint128 liquidity
    ) private pure returns (uint256 amount) {
        if (liquidity != 0) {
            unchecked {
                amount = FixedPointMathLib.fullMulDivN(
                    rewardsInsidePerLiquidity_ - positionRewardsSnapshotPerLiquidity_, liquidity, 128
                );
            }
        }
    }

    function _addSaleRate(uint256 saleRate, int256 delta) private pure returns (uint256 next) {
        unchecked {
            next = uint256(int256(saleRate) + delta);
        }
        if (next > type(uint224).max) revert MaxRateDeltaPerTime();
    }

    function _addConstrainRateDelta(int256 rateDelta, int256 change) private pure returns (int256 next) {
        unchecked {
            next = rateDelta + change;
        }

        if (FixedPointMathLib.abs(next) > MAX_ABS_VALUE_REWARD_RATE_DELTA) {
            revert MaxRateDeltaPerTime();
        }
    }

    function _updateTime(PoolId poolId, uint64 time, int256 delta) private {
        int256 rateDelta = rewardRateDeltaAtTime[poolId][time];
        int256 rateDeltaNext = _addConstrainRateDelta(rateDelta, delta);

        rewardRateDeltaAtTime[poolId][time] = rateDeltaNext;

        if ((rateDelta == 0) != (rateDeltaNext == 0)) {
            _flipTime(poolId, time);
        }
    }

    function _flipTime(PoolId poolId, uint256 time) private {
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        unchecked {
            initializedTimeBitmap[poolId][word] ^= uint256(1) << index;
        }
    }

    function _findNextInitializedTime(PoolId poolId, uint256 fromTime)
        private
        view
        returns (uint256 nextTime, bool isInitialized)
    {
        unchecked {
            (uint256 word, uint256 index) = timeToBitmapWordAndIndex(fromTime);
            Bitmap bitmap = Bitmap.wrap(initializedTimeBitmap[poolId][word]);
            uint256 nextIndex = bitmap.geSetBit(uint8(index));

            isInitialized = nextIndex != 0;

            assembly ("memory-safe") {
                nextIndex := mod(sub(nextIndex, 1), 256)
            }

            nextTime = bitmapWordAndIndexToTime(word, nextIndex);
        }
    }

    function _searchForNextInitializedTime(PoolId poolId, uint256 lastAccumulated, uint256 fromTime, uint256 untilTime)
        private
        view
        returns (uint256 nextTime, bool isInitialized)
    {
        unchecked {
            nextTime = fromTime;
            while (!isInitialized && nextTime != untilTime) {
                uint256 nextValid = nextValidTime(lastAccumulated, nextTime);
                if (nextValid == 0) {
                    nextTime = untilTime;
                    isInitialized = false;
                    break;
                }
                (nextTime, isInitialized) = _findNextInitializedTime(poolId, nextValid);
                if (nextTime > untilTime) {
                    nextTime = untilTime;
                    isInitialized = false;
                }
            }
        }
    }
}
