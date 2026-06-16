// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {BaseLocker} from "../base/BaseLocker.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {ICore} from "../interfaces/ICore.sol";
import {addLiquidityDelta} from "../math/liquidity.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {MAX_NUM_VALID_TIMES, isTimeValid, nextValidTime} from "../math/time.sol";
import {
    capFee,
    defaultFeeForStableswapAmplification as defaultVeFeeForStableswapAmplification,
    defaultFeeForTickSpacing as defaultVeFeeForTickSpacing
} from "../math/tickSpacingFee.sol";
import {bitmapWordAndIndexToTime, timeToBitmapWordAndIndex} from "../math/timeBitmap.sol";
import {Bitmap} from "../types/bitmap.sol";
import {CallPoints} from "../types/callPoints.sol";
import {Locker} from "../types/locker.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolConfig} from "../types/poolConfig.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolState} from "../types/poolState.sol";
import {PositionId} from "../types/positionId.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";

uint256 constant VE33_SWAP = 0;
uint256 constant VE33_CLAIM_REWARDS = 1;
uint256 constant VE33_DONATE_REWARDS = 2;
uint256 constant VE33_ADD_REWARDS = 3;
uint256 constant VE33_DEPOSIT_LOCK = 4;
uint256 constant VE33_WITHDRAW_LOCK = 5;
uint256 constant VE33_MOVE_LOCK = 6;

uint256 constant VE33_LOCK_CLAIM_POOL_FEES = 0;
uint256 constant VE33_LOCK_TRIGGER_POOL_EMISSIONS = 1;

uint256 constant VE33_MAX_ABS_VALUE_REWARD_RATE_DELTA = type(uint224).max / MAX_NUM_VALID_TIMES;
uint256 constant VE33_MAX_LOCK_DURATION = 4 * 365 days;

type Ve33RewardPoolState is bytes32;

using {
    ve33LastAccumulated,
    ve33RealLastAccumulated,
    ve33RewardRate,
    ve33ParseRewardPoolState
} for Ve33RewardPoolState global;

function ve33LastAccumulated(Ve33RewardPoolState state) pure returns (uint32 time) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
    }
}

function ve33RealLastAccumulated(Ve33RewardPoolState state) view returns (uint256 time) {
    assembly ("memory-safe") {
        time := sub(timestamp(), and(sub(and(timestamp(), 0xffffffff), and(state, 0xffffffff)), 0xffffffff))
    }
}

function ve33RewardRate(Ve33RewardPoolState state) pure returns (uint224 rate) {
    assembly ("memory-safe") {
        rate := shr(32, state)
    }
}

function ve33ParseRewardPoolState(Ve33RewardPoolState state) pure returns (uint32 time, uint224 rate) {
    assembly ("memory-safe") {
        time := and(state, 0xffffffff)
        rate := shr(32, state)
    }
}

function createVe33RewardPoolState(uint32 _lastAccumulated, uint224 _rewardRate) pure returns (Ve33RewardPoolState s) {
    assembly ("memory-safe") {
        s := or(and(_lastAccumulated, 0xffffffff), shl(32, _rewardRate))
    }
}

function ve33RewardsCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: false,
        beforeSwap: true,
        afterSwap: false,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

/// @notice Forward-only ve(3,3) pool extension with dynamic voter fees and single-token LP rewards.
contract Ve33Rewards is BaseExtension, BaseForwardee, BaseLocker {
    using CoreLib for *;
    using FlashAccountantLib for *;
    uint256 public constant EMISSION_DURATION = 7 days;
    uint256 public constant MAX_LOCK_DURATION = VE33_MAX_LOCK_DURATION;

    address public immutable stakeToken;

    struct LockKey {
        address owner;
        bytes32 salt;
        uint64 endTime;
    }

    struct PoolVoteState {
        uint256 weight;
        uint256 voteSeconds;
        uint64 lastAccrued;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
        uint256 feeWeightSum;
        uint64 swapFee;
        uint64 defaultSwapFee;
    }

    struct VePoolPosition {
        uint256 weight;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
        uint256 accrued0;
        uint256 accrued1;
        uint64 swapFee;
    }

    mapping(address => mapping(bytes32 => mapping(uint64 => uint128))) public lockAmounts;
    mapping(bytes32 => PoolId[]) public votedPools;
    mapping(bytes32 => mapping(PoolId => VePoolPosition)) public vePoolPositions;
    mapping(PoolId => PoolVoteState) public poolVoteStates;

    mapping(PoolId => Ve33RewardPoolState) public poolRewardState;
    mapping(PoolId => uint256) public rewardsGlobalPerLiquidity;
    mapping(PoolId => mapping(int32 => uint256)) public tickRewardsOutsidePerLiquidity;
    mapping(PoolId => mapping(address => mapping(PositionId => uint256))) public positionRewardsSnapshotPerLiquidity;
    mapping(PoolId => mapping(uint256 => uint256)) private initializedTimeBitmap;
    mapping(PoolId => mapping(uint256 => int256)) public rewardRateDeltaAtTime;

    uint256 public totalVoteWeight;
    uint256 public totalVoteSeconds;
    uint64 public totalVoteSecondsLastAccrued;

    uint256 public emissionReserve;
    uint256 public unallocatedEmissions;
    uint224 public emissionRate;
    uint64 public emissionsLastAccrued;
    uint256 public nextEmissionEventIndex;
    uint64[] public emissionEventTimes;
    mapping(uint64 => uint224) public emissionRateDecreaseAt;

    event LockDeposited(address indexed owner, bytes32 indexed salt, uint64 indexed endTime, uint128 amount);
    event LockWithdrawn(address indexed owner, bytes32 indexed salt, uint64 indexed endTime, uint128 amount);
    event LockMoved(
        address indexed owner, bytes32 indexed fromSalt, uint64 indexed fromEndTime, bytes32 toSalt, uint64 toEndTime
    );
    event Voted(bytes32 indexed lockId);
    event PoolFeesAccounted(PoolId indexed poolId, uint128 amount0, uint128 amount1);
    event PoolFeesClaimed(
        bytes32 indexed lockId, PoolId indexed poolId, address indexed recipient, uint128 amount0, uint128 amount1
    );
    event EmissionsFunded(address indexed funder, uint128 amount, uint224 rate, uint64 end);
    event PoolEmissionsTriggered(PoolId indexed poolId, uint224 amount, uint64 end);
    event PoolRewarded(PoolId indexed poolId, uint64 startTime, uint64 endTime, uint224 rewardRate, uint224 amount);
    event RewardsClaimed(
        PoolId indexed poolId, address indexed owner, PositionId indexed positionId, address recipient, uint256 amount
    );
    event RewardsDonated(PoolId indexed poolId, uint128 amount);
    event PoolSwapFeeUpdated(PoolId indexed poolId, uint64 swapFee);

    error ZeroConfigFeeOnly();
    error SwapMustHappenThroughForward();
    error InvalidVote();
    error EmissionAmountTooSmall();
    error InvalidTimestamps();
    error RewardAmountOverflow();
    error MaxRateDeltaPerTime();
    error PoolNotInitialized();
    error NotLockOwner();
    error InvalidLock();

    constructor(ICore core, address _stakeToken) BaseExtension(core) BaseForwardee(core) BaseLocker(core) {
        stakeToken = _stakeToken;
        emissionsLastAccrued = uint64(block.timestamp);
        totalVoteSecondsLastAccrued = uint64(block.timestamp);
    }

    receive() external payable {}

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return ve33RewardsCallPoints();
    }

    function defaultFeeForTickSpacing(uint32 tickSpacing) public pure returns (uint64) {
        return defaultVeFeeForTickSpacing(tickSpacing);
    }

    function defaultFeeForStableswapAmplification(uint8 amplification) public pure returns (uint64) {
        return defaultVeFeeForStableswapAmplification(amplification);
    }

    function defaultFeeForPoolConfig(PoolConfig config) public pure returns (uint64) {
        return config.isStableswap()
            ? defaultVeFeeForStableswapAmplification(config.stableswapAmplification())
            : defaultVeFeeForTickSpacing(config.concentratedTickSpacing());
    }

    function beforeInitializePool(address, PoolKey memory poolKey, int32) external override(BaseExtension) onlyCore {
        if (poolKey.config.fee() != 0) revert ZeroConfigFeeOnly();

        PoolId poolId = poolKey.toPoolId();
        uint64 defaultSwapFee = defaultFeeForPoolConfig(poolKey.config);
        poolVoteStates[poolId].swapFee = defaultSwapFee;
        poolVoteStates[poolId].defaultSwapFee = defaultSwapFee;
        poolRewardState[poolId] = createVe33RewardPoolState(uint32(block.timestamp), 0);
    }

    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override(BaseExtension) {
        revert SwapMustHappenThroughForward();
    }

    function beforeUpdatePosition(Locker locker, PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        external
        override(BaseExtension)
        onlyCore
    {
        _beforeUpdatePosition(locker.addr(), poolKey, positionId, liquidityDelta);
    }

    function votingPower(LockKey memory lockKey) public view returns (uint256) {
        if (block.timestamp >= lockKey.endTime) return 0;

        unchecked {
            return (uint256(lockAmounts[lockKey.owner][lockKey.salt][lockKey.endTime])
                    * (lockKey.endTime - block.timestamp)) / MAX_LOCK_DURATION;
        }
    }

    function vote(
        LockKey calldata lockKey,
        PoolKey[] calldata poolKeys,
        uint256[] calldata weights,
        uint64[] calldata swapFees
    ) external {
        if (lockKey.owner != msg.sender) revert NotLockOwner();
        _vote(lockKey, poolKeys, weights, swapFees);
    }

    function voteWithTickSpacing(
        LockKey calldata lockKey,
        PoolKey[] calldata poolKeys,
        uint256[] calldata weights,
        uint32[] calldata tickSpacings
    ) external {
        if (lockKey.owner != msg.sender) revert NotLockOwner();
        if (poolKeys.length != tickSpacings.length) revert InvalidVote();

        uint64[] memory swapFees = new uint64[](tickSpacings.length);
        for (uint256 i = 0; i < tickSpacings.length; i++) {
            swapFees[i] = defaultVeFeeForTickSpacing(tickSpacings[i]);
        }
        _vote(lockKey, poolKeys, weights, swapFees);
    }

    function claimPoolFees(LockKey memory lockKey, PoolKey memory poolKey)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        if (lockKey.owner != msg.sender) revert NotLockOwner();
        return abi.decode(lock(abi.encode(VE33_LOCK_CLAIM_POOL_FEES, lockKey, poolKey)), (uint128, uint128));
    }

    function fundEmissions(uint128 amount) external {
        if (amount == 0) revert EmissionAmountTooSmall();

        uint224 rate = uint224(((uint256(amount) + _accrueEmissions()) << 32) / EMISSION_DURATION);

        uint64 end = uint64(block.timestamp + EMISSION_DURATION);
        emissionReserve += amount;
        emissionRate += rate;
        emissionRateDecreaseAt[end] += rate;
        emissionEventTimes.push(end);

        SafeTransferLib.safeTransferFrom(stakeToken, msg.sender, address(this), amount);

        emit EmissionsFunded(msg.sender, amount, rate, end);
    }

    function triggerPoolEmissions(PoolKey memory poolKey) external payable returns (uint224 amount) {
        amount = abi.decode(lock(abi.encode(VE33_LOCK_TRIGGER_POOL_EMISSIONS, poolKey)), (uint224));
    }

    function maybeAccumulateRewards(PoolKey memory poolKey) public {
        unchecked {
            PoolId poolId = poolKey.toPoolId();
            Ve33RewardPoolState state = poolRewardState[poolId];

            if (state.ve33LastAccumulated() == 0) {
                if (poolKey.config.extension() != address(this) || !CORE.poolState(poolId).isInitialized()) {
                    revert PoolNotInitialized();
                }
                state = createVe33RewardPoolState(uint32(block.timestamp), 0);
                poolRewardState[poolId] = state;
            }

            if (uint32(block.timestamp) == state.ve33LastAccumulated()) return;

            uint256 lastAccumulated = state.ve33RealLastAccumulated();
            uint256 time = lastAccumulated;
            uint256 rewardRate = state.ve33RewardRate();
            uint256 rewardsAccrued;

            for (uint256 eventTime; time != block.timestamp; time = eventTime) {
                bool hasEvent;
                (eventTime, hasEvent) = _searchForNextInitializedTime(poolId, lastAccumulated, time, block.timestamp);

                rewardsAccrued += (rewardRate * (eventTime - time)) >> 32;

                if (hasEvent) {
                    int256 rateDelta = rewardRateDeltaAtTime[poolId][eventTime];
                    rewardRate = _addRewardRate(rewardRate, rateDelta);

                    delete rewardRateDeltaAtTime[poolId][eventTime];
                    _flipTime(poolId, eventTime);
                }
            }

            PoolState coreState = CORE.poolState(poolId);
            uint128 liquidity = coreState.liquidity();
            if (liquidity != 0 && poolKey.config.isStableswap()) {
                (int32 lower, int32 upper) = poolKey.config.stableswapActiveLiquidityTickRange();
                int32 tick = coreState.tick();
                if (tick < lower || tick >= upper) liquidity = 0;
            }
            if (rewardsAccrued != 0 && liquidity != 0) {
                rewardsGlobalPerLiquidity[poolId] += (rewardsAccrued << 128) / liquidity;
            }

            poolRewardState[poolId] = createVe33RewardPoolState(uint32(block.timestamp), uint224(rewardRate));
        }
    }

    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == VE33_SWAP) {
            (, PoolKey memory poolKey, SwapParameters params) = abi.decode(data, (uint256, PoolKey, SwapParameters));
            (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) = _swap(poolKey, params);
            result = abi.encode(balanceUpdate, stateAfter);
        } else if (callType == VE33_CLAIM_REWARDS) {
            (, PoolKey memory poolKey, PositionId positionId, address recipient) =
                abi.decode(data, (uint256, PoolKey, PositionId, address));
            result = abi.encode(_claimRewards(poolKey, original.addr(), positionId, recipient));
        } else if (callType == VE33_DONATE_REWARDS) {
            (, PoolKey memory poolKey, uint128 amount) = abi.decode(data, (uint256, PoolKey, uint128));
            result = abi.encode(_donateRewards(poolKey, amount));
        } else if (callType == VE33_ADD_REWARDS) {
            (, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate) =
                abi.decode(data, (uint256, PoolKey, uint64, uint64, uint224));
            result = abi.encode(_addRewards(poolKey, startTime, endTime, rewardRate));
        } else if (callType == VE33_DEPOSIT_LOCK) {
            (, bytes32 salt, uint64 endTime, uint128 amount) = abi.decode(data, (uint256, bytes32, uint64, uint128));
            result = abi.encode(_depositLock(original.addr(), salt, endTime, amount));
        } else if (callType == VE33_WITHDRAW_LOCK) {
            (, bytes32 salt, uint64 endTime, uint128 amount) = abi.decode(data, (uint256, bytes32, uint64, uint128));
            result = abi.encode(_withdrawLock(original.addr(), salt, endTime, amount));
        } else if (callType == VE33_MOVE_LOCK) {
            (, bytes32 fromSalt, uint64 fromEndTime, bytes32 toSalt, uint64 toEndTime, uint128 amount) =
                abi.decode(data, (uint256, bytes32, uint64, bytes32, uint64, uint128));
            result = abi.encode(_moveLock(original.addr(), fromSalt, fromEndTime, toSalt, toEndTime, amount));
        } else {
            revert();
        }
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == VE33_LOCK_CLAIM_POOL_FEES) {
            (, LockKey memory lockKey, PoolKey memory poolKey) = abi.decode(data, (uint256, LockKey, PoolKey));
            (uint128 amount0, uint128 amount1) = _claimPoolFeesUnlocked(lockKey, poolKey);
            result = abi.encode(amount0, amount1);
        } else if (callType == VE33_LOCK_TRIGGER_POOL_EMISSIONS) {
            (, PoolKey memory poolKey) = abi.decode(data, (uint256, PoolKey));
            result = abi.encode(_triggerPoolEmissions(poolKey));
        } else {
            revert();
        }
    }

    function _swap(PoolKey memory poolKey, SwapParameters params)
        private
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        unchecked {
            PoolId poolId = poolKey.toPoolId();
            maybeAccumulateRewards(poolKey);
            int32 tickBefore = CORE.poolState(poolId).tick();

            uint64 swapFee = poolVoteStates[poolId].swapFee;
            int128 fee0;
            int128 fee1;
            SwapParameters coreParams = params;

            if (swapFee != 0 && !params.isExactOut()) {
                uint128 amount = uint128(uint256(int256(params.amount())));
                uint128 fee = computeFee(amount, swapFee);
                coreParams = createSwapParameters(
                    params.sqrtRatioLimit(),
                    SafeCastLib.toInt128(uint256(amount - fee)),
                    params.isToken1(),
                    params.skipAhead()
                );
            }

            (balanceUpdate, stateAfter) = CORE.swap(0, poolKey, coreParams);

            if (balanceUpdate.delta0() > 0) {
                uint128 inputAmount = uint128(uint256(int256(balanceUpdate.delta0())));
                int128 fee = params.isExactOut()
                    ? SafeCastLib.toInt128(amountBeforeFee(inputAmount, swapFee) - inputAmount)
                    : SafeCastLib.toInt128(computeFee(uint128(uint256(int256(params.amount()))), swapFee));
                fee0 = fee;
                balanceUpdate = createPoolBalanceUpdate(balanceUpdate.delta0() + fee, balanceUpdate.delta1());
            } else if (balanceUpdate.delta1() > 0) {
                uint128 inputAmount = uint128(uint256(int256(balanceUpdate.delta1())));
                int128 fee = params.isExactOut()
                    ? SafeCastLib.toInt128(amountBeforeFee(inputAmount, swapFee) - inputAmount)
                    : SafeCastLib.toInt128(computeFee(uint128(uint256(int256(params.amount()))), swapFee));
                fee1 = fee;
                balanceUpdate = createPoolBalanceUpdate(balanceUpdate.delta0(), balanceUpdate.delta1() + fee);
            }

            if (fee0 != 0 || fee1 != 0) {
                CORE.updateSavedBalances(poolKey.token0, poolKey.token1, PoolId.unwrap(poolId), fee0, fee1);
                _accountPoolFees(poolId, uint128(uint256(int256(fee0))), uint128(uint256(int256(fee1))));
            }

            _updateCrossedTicks(poolKey, poolId, tickBefore, stateAfter.tick(), params.skipAhead());
        }
    }

    function _beforeUpdatePosition(address owner, PoolKey memory poolKey, PositionId positionId, int128 liquidityDelta)
        private
    {
        maybeAccumulateRewards(poolKey);

        PoolId poolId = poolKey.toPoolId();
        uint128 liquidity = CORE.poolPositions(poolId, owner, positionId).liquidity;

        if (liquidityDelta != 0) {
            uint128 liquidityNext = addLiquidityDelta(liquidity, liquidityDelta);
            uint256 rewardsInsidePerLiquidity =
                _getRewardsInsidePerLiquidity(poolId, positionId.tickLower(), positionId.tickUpper());
            uint256 snapshot = positionRewardsSnapshotPerLiquidity[poolId][owner][positionId];
            uint256 amount = _positionRewards(snapshot, rewardsInsidePerLiquidity, liquidity);

            if (poolKey.config.isStableswap()) {
                _updateStableswapTickRewardsPerLiquidityOutside(poolKey, poolId, liquidityDelta);
            } else {
                _updateTickRewardsPerLiquidityOutside(poolId, positionId.tickLower(), liquidityDelta);
                _updateTickRewardsPerLiquidityOutside(poolId, positionId.tickUpper(), liquidityDelta);
            }

            if (liquidityNext == 0) {
                positionRewardsSnapshotPerLiquidity[poolId][owner][positionId] = 0;
            } else {
                uint256 rewardsInsideNextPerLiquidity =
                    _getRewardsInsidePerLiquidity(poolId, positionId.tickLower(), positionId.tickUpper());
                unchecked {
                    positionRewardsSnapshotPerLiquidity[poolId][owner][positionId] =
                        rewardsInsideNextPerLiquidity - ((amount << 128) / liquidityNext);
                }
            }
        }
    }

    function _lockId(address owner, bytes32 salt, uint64 endTime) private pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt, endTime));
    }

    function _validateNewLock(uint64 endTime, uint128 amount) private view {
        if (amount == 0 || endTime <= block.timestamp || endTime > block.timestamp + MAX_LOCK_DURATION) {
            revert InvalidLock();
        }
    }

    function _depositLock(address owner, bytes32 salt, uint64 endTime, uint128 amount)
        private
        returns (uint128 deposited)
    {
        _validateNewLock(endTime, amount);

        deposited = amount;
        bytes32 lockId = _lockId(owner, salt, endTime);
        _clearVotes(lockId);
        lockAmounts[owner][salt][endTime] += amount;

        emit LockDeposited(owner, salt, endTime, amount);
    }

    function _withdrawLock(address owner, bytes32 salt, uint64 endTime, uint128 amount)
        private
        returns (uint128 withdrawn)
    {
        if (amount == 0 || block.timestamp < endTime) revert InvalidLock();

        uint128 currentAmount = lockAmounts[owner][salt][endTime];
        if (amount > currentAmount) revert InvalidLock();

        withdrawn = amount;
        bytes32 lockId = _lockId(owner, salt, endTime);
        _clearVotes(lockId);
        lockAmounts[owner][salt][endTime] = currentAmount - amount;

        emit LockWithdrawn(owner, salt, endTime, amount);
    }

    function _moveLock(
        address owner,
        bytes32 fromSalt,
        uint64 fromEndTime,
        bytes32 toSalt,
        uint64 toEndTime,
        uint128 amount
    ) private returns (uint128 moved) {
        _validateNewLock(toEndTime, amount);

        uint128 currentAmount = lockAmounts[owner][fromSalt][fromEndTime];
        if (amount > currentAmount) revert InvalidLock();

        moved = amount;
        bytes32 fromLockId = _lockId(owner, fromSalt, fromEndTime);
        bytes32 toLockId = _lockId(owner, toSalt, toEndTime);
        _clearVotes(fromLockId);
        _clearVotes(toLockId);
        lockAmounts[owner][fromSalt][fromEndTime] = currentAmount - amount;
        lockAmounts[owner][toSalt][toEndTime] += amount;

        emit LockMoved(owner, fromSalt, fromEndTime, toSalt, toEndTime);
    }

    function _vote(
        LockKey calldata lockKey,
        PoolKey[] calldata poolKeys,
        uint256[] calldata weights,
        uint64[] memory swapFees
    ) private {
        if (poolKeys.length != weights.length || poolKeys.length != swapFees.length) {
            revert InvalidVote();
        }

        uint256 power = votingPower(lockKey);
        if (power == 0) revert InvalidVote();
        bytes32 lockId = _lockId(lockKey.owner, lockKey.salt, lockKey.endTime);

        uint256 totalWeight;
        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
            PoolId poolId = poolKeys[i].toPoolId();
            if (poolKeys[i].config.extension() != address(this) || poolKeys[i].config.fee() != 0) revert InvalidVote();
            for (uint256 j = 0; j < i; j++) {
                if (PoolId.unwrap(poolId) == PoolId.unwrap(poolKeys[j].toPoolId())) revert InvalidVote();
            }
        }
        if (totalWeight == 0) revert InvalidVote();

        _clearVotes(lockId);
        for (uint256 i = _accrueTotalVoteSeconds(); i < poolKeys.length; i++) {
            uint256 weight = (power * weights[i]) / totalWeight;
            if (weight == 0) continue;

            PoolId poolId = poolKeys[i].toPoolId();
            uint64 swapFee = capFee(swapFees[i]);
            _accruePoolVoteSeconds(poolId);

            PoolVoteState storage poolState = poolVoteStates[poolId];
            VePoolPosition storage vePool = vePoolPositions[lockId][poolId];

            poolState.weight += weight;
            poolState.feeWeightSum += weight * swapFee;
            totalVoteWeight += weight;

            vePool.weight = weight;
            vePool.swapFee = swapFee;
            vePool.feeGrowth0X128 = poolState.feeGrowth0X128;
            vePool.feeGrowth1X128 = poolState.feeGrowth1X128;
            votedPools[lockId].push(poolId);

            _updatePoolSwapFee(poolId);
        }

        emit Voted(lockId);
    }

    function _accountPoolFees(PoolId poolId, uint128 amount0, uint128 amount1) private {
        PoolVoteState storage poolState = poolVoteStates[poolId];
        uint256 weight = poolState.weight;
        if (weight != 0) {
            unchecked {
                poolState.feeGrowth0X128 += (uint256(amount0) << 128) / weight;
                poolState.feeGrowth1X128 += (uint256(amount1) << 128) / weight;
            }
        }

        emit PoolFeesAccounted(poolId, amount0, amount1);
    }

    function _claimPoolFeesUnlocked(LockKey memory lockKey, PoolKey memory poolKey)
        private
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId poolId = poolKey.toPoolId();
        bytes32 lockId = _lockId(lockKey.owner, lockKey.salt, lockKey.endTime);
        _accrueVePoolFees(lockId, poolId);

        VePoolPosition storage vePool = vePoolPositions[lockId][poolId];
        amount0 = uint128(vePool.accrued0);
        amount1 = uint128(vePool.accrued1);

        if (amount0 != 0 || amount1 != 0) {
            vePool.accrued0 = 0;
            vePool.accrued1 = 0;
            CORE.updateSavedBalances(
                poolKey.token0,
                poolKey.token1,
                PoolId.unwrap(poolId),
                -int256(uint256(amount0)),
                -int256(uint256(amount1))
            );
            ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, lockKey.owner, amount0, amount1);
        }

        emit PoolFeesClaimed(lockId, poolId, lockKey.owner, amount0, amount1);
    }

    function _triggerPoolEmissions(PoolKey memory poolKey) private returns (uint224 amount) {
        if (poolKey.config.extension() != address(this)) revert PoolNotInitialized();

        PoolId poolId = poolKey.toPoolId();
        _accrueEmissions();
        _accruePoolVoteSeconds(poolId);

        PoolVoteState storage poolState = poolVoteStates[poolId];
        uint256 poolSeconds = poolState.voteSeconds + _accrueTotalVoteSeconds();
        if (poolSeconds == 0 || totalVoteSeconds == 0 || unallocatedEmissions == 0 || emissionReserve == 0) {
            emit PoolEmissionsTriggered(poolId, 0, uint64(block.timestamp));
            return 0;
        }

        uint256 amount256 = (unallocatedEmissions * poolSeconds) / totalVoteSeconds;
        if (amount256 > emissionReserve) amount256 = emissionReserve;
        if (amount256 == 0) {
            emit PoolEmissionsTriggered(poolId, 0, uint64(block.timestamp));
            return 0;
        }

        unchecked {
            unallocatedEmissions -= amount256;
            totalVoteSeconds -= poolSeconds;
        }
        poolState.voteSeconds = 0;

        uint256 endTime = nextValidTime(block.timestamp, block.timestamp + EMISSION_DURATION - 1);
        uint256 duration = endTime - block.timestamp;
        uint224 rewardRate = uint224((amount256 << 32) / duration);

        amount = _addRewards(poolKey, 0, uint64(endTime), rewardRate);
        emissionReserve -= amount;
        if (amount != 0) ACCOUNTANT.pay(stakeToken, amount);

        emit PoolEmissionsTriggered(poolId, amount, uint64(endTime));
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
            Ve33RewardPoolState state = poolRewardState[poolId];
            poolRewardState[poolId] = createVe33RewardPoolState(
                state.ve33LastAccumulated(), uint224(_addRewardRate(state.ve33RewardRate(), rewardRateDelta))
            );
        }

        _updateTime(poolId, endTime, -rewardRateDelta);

        emit PoolRewarded(poolId, startTime, endTime, rewardRate, amount);
    }

    function _donateRewards(PoolKey memory poolKey, uint128 amount) private returns (uint128 donated) {
        donated = amount;
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
    }

    function _claimRewards(PoolKey memory poolKey, address owner, PositionId positionId, address recipient)
        private
        returns (uint256 amount)
    {
        maybeAccumulateRewards(poolKey);

        PoolId poolId = poolKey.toPoolId();
        uint128 liquidity = CORE.poolPositions(poolId, owner, positionId).liquidity;
        uint256 snapshot = positionRewardsSnapshotPerLiquidity[poolId][owner][positionId];

        uint256 rewardsInsidePerLiquidity =
            _getRewardsInsidePerLiquidity(poolId, positionId.tickLower(), positionId.tickUpper());
        amount = _positionRewards(snapshot, rewardsInsidePerLiquidity, liquidity);

        positionRewardsSnapshotPerLiquidity[poolId][owner][positionId] = liquidity == 0 ? 0 : rewardsInsidePerLiquidity;

        if (amount > type(uint128).max) revert RewardAmountOverflow();

        if (amount != 0) {
            uint128 amountUint128 = uint128(amount);
            _updateRewardSavedBalance(-int256(uint256(amountUint128)));
            ACCOUNTANT.withdraw(stakeToken, recipient, amountUint128);
        }

        emit RewardsClaimed(poolId, owner, positionId, recipient, amount);
    }

    function _clearVotes(bytes32 lockId) private {
        PoolId[] storage pools = votedPools[lockId];
        if (pools.length == 0) return;

        for (uint256 i = _accrueTotalVoteSeconds(); i < pools.length; i++) {
            PoolId poolId = pools[i];
            _accruePoolVoteSeconds(poolId);
            _accrueVePoolFees(lockId, poolId);

            VePoolPosition storage vePool = vePoolPositions[lockId][poolId];
            uint256 weight = vePool.weight;
            if (weight != 0) {
                PoolVoteState storage poolState = poolVoteStates[poolId];
                poolState.weight -= weight;
                poolState.feeWeightSum -= weight * vePool.swapFee;
                totalVoteWeight -= weight;
                vePool.weight = 0;
                _updatePoolSwapFee(poolId);
            }
        }

        delete votedPools[lockId];
    }

    function _accrueVePoolFees(bytes32 lockId, PoolId poolId) private {
        PoolVoteState storage poolState = poolVoteStates[poolId];
        VePoolPosition storage vePool = vePoolPositions[lockId][poolId];

        uint256 weight = vePool.weight;
        if (weight != 0) {
            unchecked {
                vePool.accrued0 += ((poolState.feeGrowth0X128 - vePool.feeGrowth0X128) * weight) >> 128;
                vePool.accrued1 += ((poolState.feeGrowth1X128 - vePool.feeGrowth1X128) * weight) >> 128;
            }
        }

        vePool.feeGrowth0X128 = poolState.feeGrowth0X128;
        vePool.feeGrowth1X128 = poolState.feeGrowth1X128;
    }

    function _accruePoolVoteSeconds(PoolId poolId) private {
        PoolVoteState storage poolState = poolVoteStates[poolId];
        uint64 lastAccrued = poolState.lastAccrued;
        if (lastAccrued == 0) {
            poolState.lastAccrued = uint64(block.timestamp);
        } else if (lastAccrued != block.timestamp) {
            unchecked {
                poolState.voteSeconds += poolState.weight * (block.timestamp - lastAccrued);
            }
            poolState.lastAccrued = uint64(block.timestamp);
        }
    }

    function _accrueTotalVoteSeconds() private returns (uint256 zero) {
        uint64 lastAccrued = totalVoteSecondsLastAccrued;
        if (lastAccrued != block.timestamp) {
            unchecked {
                totalVoteSeconds += totalVoteWeight * (block.timestamp - lastAccrued);
            }
            totalVoteSecondsLastAccrued = uint64(block.timestamp);
        }
    }

    function _accrueEmissions() private returns (uint256 zero) {
        uint256 time = emissionsLastAccrued;
        uint224 rate = emissionRate;

        while (nextEmissionEventIndex < emissionEventTimes.length) {
            uint64 eventTime = emissionEventTimes[nextEmissionEventIndex];
            if (eventTime > block.timestamp) break;

            unchecked {
                unallocatedEmissions += (uint256(rate) * (eventTime - time)) >> 32;
            }
            rate -= emissionRateDecreaseAt[eventTime];
            delete emissionRateDecreaseAt[eventTime];
            time = eventTime;
            do {
                nextEmissionEventIndex++;
            } while (
                nextEmissionEventIndex < emissionEventTimes.length
                    && emissionEventTimes[nextEmissionEventIndex] == eventTime
            );
        }

        if (time != block.timestamp) {
            unchecked {
                unallocatedEmissions += (uint256(rate) * (block.timestamp - time)) >> 32;
            }
        }

        emissionRate = rate;
        emissionsLastAccrued = uint64(block.timestamp);
    }

    function _updatePoolSwapFee(PoolId poolId) private {
        PoolVoteState storage poolState = poolVoteStates[poolId];
        uint64 swapFee =
            poolState.weight == 0 ? poolState.defaultSwapFee : uint64(poolState.feeWeightSum / poolState.weight);
        poolState.swapFee = swapFee;
        emit PoolSwapFeeUpdated(poolId, swapFee);
    }

    function _updateCrossedTicks(
        PoolKey memory poolKey,
        PoolId poolId,
        int32 tickBefore,
        int32 tickAfter,
        uint256 skipAhead
    ) private {
        if (tickBefore == tickAfter) return;

        uint256 rewardsGlobalPerLiquidity_ = rewardsGlobalPerLiquidity[poolId];

        if (poolKey.config.isStableswap()) {
            (int32 lower, int32 upper) = poolKey.config.stableswapActiveLiquidityTickRange();
            if (tickAfter > tickBefore) {
                if (tickBefore < lower && tickAfter >= lower) {
                    unchecked {
                        tickRewardsOutsidePerLiquidity[poolId][lower] =
                            rewardsGlobalPerLiquidity_ - tickRewardsOutsidePerLiquidity[poolId][lower];
                    }
                }
                if (tickBefore < upper && tickAfter >= upper) {
                    unchecked {
                        tickRewardsOutsidePerLiquidity[poolId][upper] =
                            rewardsGlobalPerLiquidity_ - tickRewardsOutsidePerLiquidity[poolId][upper];
                    }
                }
            } else {
                if (tickBefore >= upper && tickAfter < upper) {
                    unchecked {
                        tickRewardsOutsidePerLiquidity[poolId][upper] =
                            rewardsGlobalPerLiquidity_ - tickRewardsOutsidePerLiquidity[poolId][upper];
                    }
                }
                if (tickBefore >= lower && tickAfter < lower) {
                    unchecked {
                        tickRewardsOutsidePerLiquidity[poolId][lower] =
                            rewardsGlobalPerLiquidity_ - tickRewardsOutsidePerLiquidity[poolId][lower];
                    }
                }
            }
            return;
        }

        uint32 tickSpacing = poolKey.config.concentratedTickSpacing();

        bool priceIncreasing = tickAfter > tickBefore;
        if (!priceIncreasing) {
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
        if (priceIncreasing) {
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
        }
    }

    function _updateRewardSavedBalance(int256 delta) private {
        CORE.updateSavedBalances(stakeToken, address(type(uint160).max), bytes32(0), delta, 0);
    }

    function _getRewardsInsidePerLiquidity(PoolId poolId, int32 tickLower, int32 tickUpper)
        private
        view
        returns (uint256 rewardsInsidePerLiquidity)
    {
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

    function _updateTickRewardsPerLiquidityOutside(PoolId poolId, int32 tick, int128 liquidityDelta) private {
        (, uint128 liquidityNet) = CORE.poolTicks(poolId, tick);
        uint128 liquidityNetNext = addLiquidityDelta(liquidityNet, liquidityDelta);
        if ((liquidityNet == 0) != (liquidityNetNext == 0)) {
            delete tickRewardsOutsidePerLiquidity[poolId][tick];
            if (liquidityNetNext != 0) {
                tickRewardsOutsidePerLiquidity[poolId][tick] =
                    CORE.poolState(poolId).tick() >= tick ? rewardsGlobalPerLiquidity[poolId] : 0;
            }
        }
    }

    function _updateStableswapTickRewardsPerLiquidityOutside(
        PoolKey memory poolKey,
        PoolId poolId,
        int128 liquidityDelta
    ) private {
        uint128 liquidity = CORE.poolState(poolId).liquidity();
        uint128 liquidityNext = addLiquidityDelta(liquidity, liquidityDelta);
        if ((liquidity == 0) != (liquidityNext == 0)) {
            (int32 lower, int32 upper) = poolKey.config.stableswapActiveLiquidityTickRange();
            delete tickRewardsOutsidePerLiquidity[poolId][lower];
            delete tickRewardsOutsidePerLiquidity[poolId][upper];
            if (liquidityNext != 0) {
                int32 tick = CORE.poolState(poolId).tick();
                uint256 rewardsGlobalPerLiquidity_ = rewardsGlobalPerLiquidity[poolId];
                tickRewardsOutsidePerLiquidity[poolId][lower] = tick >= lower ? rewardsGlobalPerLiquidity_ : 0;
                tickRewardsOutsidePerLiquidity[poolId][upper] = tick >= upper ? rewardsGlobalPerLiquidity_ : 0;
            }
        }
    }

    function _positionRewards(uint256 snapshot, uint256 rewardsInsidePerLiquidity_, uint128 liquidity)
        private
        pure
        returns (uint256 amount)
    {
        if (liquidity != 0) {
            unchecked {
                amount = FixedPointMathLib.fullMulDivN(rewardsInsidePerLiquidity_ - snapshot, liquidity, 128);
            }
        }
    }

    function _addRewardRate(uint256 rewardRate, int256 delta) private pure returns (uint256 next) {
        unchecked {
            next = uint256(int256(rewardRate) + delta);
        }
        if (next > type(uint224).max) revert MaxRateDeltaPerTime();
    }

    function _addConstrainRateDelta(int256 rateDelta, int256 change) private pure returns (int256 next) {
        unchecked {
            next = rateDelta + change;
        }

        if (FixedPointMathLib.abs(next) > VE33_MAX_ABS_VALUE_REWARD_RATE_DELTA) {
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

            nextIndex = (nextIndex - 1) % 256;

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
                (nextTime, isInitialized) = _findNextInitializedTime(poolId, nextValid);
                if (nextTime > untilTime) {
                    nextTime = untilTime;
                    isInitialized = false;
                }
            }
        }
    }
}
