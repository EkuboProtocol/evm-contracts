// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {BaseLocker} from "../base/BaseLocker.sol";
import {BaseNonfungibleToken} from "../base/BaseNonfungibleToken.sol";
import {PayableMulticallable} from "../base/PayableMulticallable.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {ICore} from "../interfaces/ICore.sol";
import {addLiquidityDelta} from "../math/liquidity.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {MAX_NUM_VALID_TIMES, isTimeValid, nextValidTime} from "../math/time.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {capFee, defaultFeeForTickSpacing as defaultVeFeeForTickSpacing} from "../math/tickSpacingFee.sol";
import {bitmapWordAndIndexToTime, timeToBitmapWordAndIndex} from "../math/timeBitmap.sol";
import {Bitmap} from "../types/bitmap.sol";
import {CallPoints} from "../types/callPoints.sol";
import {Locker} from "../types/locker.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolState} from "../types/poolState.sol";
import {PositionId} from "../types/positionId.sol";
import {SingleTokenRewardsPoolState, createSingleTokenRewardsPoolState} from "../types/singleTokenRewardsPoolState.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";

uint256 constant VE33_SWAP = 0;
uint256 constant VE33_CLAIM_REWARDS = 1;
uint256 constant VE33_DONATE_REWARDS = 2;
uint256 constant VE33_ADD_REWARDS = 3;

uint256 constant VE33_LOCK_CLAIM_POOL_FEES = 0;
uint256 constant VE33_LOCK_TRIGGER_POOL_EMISSIONS = 1;

uint256 constant VE33_MAX_ABS_VALUE_REWARD_RATE_DELTA = type(uint224).max / MAX_NUM_VALID_TIMES;

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
contract Ve33Rewards is BaseExtension, BaseForwardee, BaseLocker, BaseNonfungibleToken, PayableMulticallable {
    using CoreLib for *;
    using FlashAccountantLib for *;
    uint256 public constant MAX_LOCK_DURATION = 4 * 365 days;
    uint256 public constant EMISSION_DURATION = 7 days;

    address public immutable stakeToken;

    struct Lock {
        uint128 amount;
        uint64 end;
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

    mapping(uint256 => Lock) public locks;
    mapping(uint256 => PoolId[]) public votedPools;
    mapping(uint256 => mapping(PoolId => VePoolPosition)) public vePoolPositions;
    mapping(PoolId => PoolVoteState) public poolVoteStates;

    mapping(PoolId => SingleTokenRewardsPoolState) public poolRewardState;
    mapping(PoolId => uint256) public rewardsGlobalPerLiquidity;
    mapping(PoolId => mapping(int32 => uint256)) public tickRewardsOutsidePerLiquidity;
    mapping(PoolId => mapping(address => mapping(PositionId => uint256))) public positionRewardsSnapshotPerLiquidity;
    mapping(PoolId => mapping(uint256 => uint256)) private initializedTimeBitmap;
    mapping(PoolId => mapping(uint256 => int256)) public rewardRateDeltaAtTime;

    uint256 public nextVeId = 1;
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

    event LockCreated(uint256 indexed veId, address indexed owner, uint128 amount, uint64 end);
    event LockAmountIncreased(uint256 indexed veId, uint128 amount);
    event LockExtended(uint256 indexed veId, uint64 end);
    event LockWithdrawn(uint256 indexed veId, address indexed owner, uint128 amount);
    event Voted(uint256 indexed veId);
    event PoolFeesAccounted(PoolId indexed poolId, uint128 amount0, uint128 amount1);
    event PoolFeesClaimed(
        uint256 indexed veId, PoolId indexed poolId, address indexed recipient, uint128 amount0, uint128 amount1
    );
    event EmissionsFunded(address indexed funder, uint128 amount, uint224 rate, uint64 end);
    event PoolEmissionsTriggered(PoolId indexed poolId, uint224 amount, uint64 end);
    event PoolRewarded(PoolId indexed poolId, uint64 startTime, uint64 endTime, uint224 rewardRate, uint224 amount);
    event RewardsClaimed(
        PoolId indexed poolId, address indexed owner, PositionId indexed positionId, address recipient, uint256 amount
    );
    event RewardsDonated(PoolId indexed poolId, uint128 amount);
    event PoolSwapFeeUpdated(PoolId indexed poolId, uint64 swapFee);

    error ConcentratedLiquidityPoolsOnly();
    error ZeroConfigFeeOnly();
    error SwapMustHappenThroughForward();
    error InvalidLock();
    error InvalidVote();
    error EmissionAmountTooSmall();
    error InvalidTimestamps();
    error RewardAmountOverflow();
    error MaxRateDeltaPerTime();
    error PoolNotInitialized();

    constructor(ICore core, address owner, address _stakeToken)
        BaseExtension(core)
        BaseForwardee(core)
        BaseLocker(core)
        BaseNonfungibleToken(owner)
    {
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

    function beforeInitializePool(address, PoolKey memory poolKey, int32) external override(BaseExtension) onlyCore {
        if (poolKey.config.isStableswap()) revert ConcentratedLiquidityPoolsOnly();
        if (poolKey.config.fee() != 0) revert ZeroConfigFeeOnly();

        PoolId poolId = poolKey.toPoolId();
        uint64 defaultSwapFee = defaultVeFeeForTickSpacing(poolKey.config.concentratedTickSpacing());
        poolVoteStates[poolId].swapFee = defaultSwapFee;
        poolVoteStates[poolId].defaultSwapFee = defaultSwapFee;
        poolRewardState[poolId] = createSingleTokenRewardsPoolState(uint32(block.timestamp), 0);
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

    function createLock(uint128 amount, uint64 end) external returns (uint256 veId) {
        if (amount == 0 || end <= block.timestamp || end > block.timestamp + MAX_LOCK_DURATION) revert InvalidLock();

        veId = nextVeId++;
        locks[veId] = Lock({amount: amount, end: end});
        _mint(msg.sender, veId);

        SafeTransferLib.safeTransferFrom(stakeToken, msg.sender, address(this), amount);

        emit LockCreated(veId, msg.sender, amount, end);
    }

    function increaseLockAmount(uint256 veId, uint128 amount) external authorizedForNft(veId) {
        if (amount == 0 || locks[veId].end <= block.timestamp) revert InvalidLock();

        _clearVotes(veId);
        locks[veId].amount += amount;
        SafeTransferLib.safeTransferFrom(stakeToken, msg.sender, address(this), amount);

        emit LockAmountIncreased(veId, amount);
    }

    function extendLock(uint256 veId, uint64 end) external authorizedForNft(veId) {
        Lock storage userLock = locks[veId];
        if (userLock.amount == 0 || end <= userLock.end || end > block.timestamp + MAX_LOCK_DURATION) {
            revert InvalidLock();
        }

        _clearVotes(veId);
        userLock.end = end;

        emit LockExtended(veId, end);
    }

    function withdrawLock(uint256 veId) external authorizedForNft(veId) {
        Lock memory userLock = locks[veId];
        if (userLock.amount == 0 || block.timestamp < userLock.end) revert InvalidLock();

        _clearVotes(veId);
        delete locks[veId];
        _burn(veId);
        SafeTransferLib.safeTransfer(stakeToken, msg.sender, userLock.amount);

        emit LockWithdrawn(veId, msg.sender, userLock.amount);
    }

    function votingPower(uint256 veId) public view returns (uint256) {
        Lock memory userLock = locks[veId];
        if (block.timestamp >= userLock.end) return 0;

        unchecked {
            return (uint256(userLock.amount) * (userLock.end - block.timestamp)) / MAX_LOCK_DURATION;
        }
    }

    function vote(uint256 veId, PoolKey[] calldata poolKeys, uint256[] calldata weights, uint64[] calldata swapFees)
        external
        authorizedForNft(veId)
    {
        _vote(veId, poolKeys, weights, swapFees);
    }

    function voteWithTickSpacing(
        uint256 veId,
        PoolKey[] calldata poolKeys,
        uint256[] calldata weights,
        uint32[] calldata tickSpacings
    ) external authorizedForNft(veId) {
        if (poolKeys.length != tickSpacings.length) revert InvalidVote();

        uint64[] memory swapFees = new uint64[](tickSpacings.length);
        for (uint256 i = 0; i < tickSpacings.length; i++) {
            swapFees[i] = defaultVeFeeForTickSpacing(tickSpacings[i]);
        }
        _vote(veId, poolKeys, weights, swapFees);
    }

    function claimPoolFees(uint256 veId, PoolKey memory poolKey)
        external
        authorizedForNft(veId)
        returns (uint128 amount0, uint128 amount1)
    {
        return abi.decode(lock(abi.encode(VE33_LOCK_CLAIM_POOL_FEES, veId, poolKey)), (uint128, uint128));
    }

    function fundEmissions(uint128 amount) external {
        if (amount == 0) revert EmissionAmountTooSmall();

        _accrueEmissions();

        uint224 rate = uint224((uint256(amount) << 32) / EMISSION_DURATION);
        if (rate == 0) revert EmissionAmountTooSmall();

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
                    rewardRate = _addRewardRate(rewardRate, rateDelta);

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
        } else {
            revert();
        }
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == VE33_LOCK_CLAIM_POOL_FEES) {
            (, uint256 veId, PoolKey memory poolKey) = abi.decode(data, (uint256, uint256, PoolKey));
            (uint128 amount0, uint128 amount1) = _claimPoolFeesUnlocked(veId, poolKey);
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
            params = params.withDefaultSqrtRatioLimit();

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

            if (swapFee != 0) {
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

            _updateTickRewardsPerLiquidityOutside(poolId, positionId.tickLower(), liquidityDelta);
            _updateTickRewardsPerLiquidityOutside(poolId, positionId.tickUpper(), liquidityDelta);

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

    function _vote(uint256 veId, PoolKey[] calldata poolKeys, uint256[] calldata weights, uint64[] memory swapFees)
        private
    {
        if (poolKeys.length != weights.length || poolKeys.length != swapFees.length) revert InvalidVote();

        uint256 power = votingPower(veId);
        if (power == 0) revert InvalidVote();

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

        _clearVotes(veId);
        _accrueTotalVoteSeconds();

        for (uint256 i = 0; i < poolKeys.length; i++) {
            uint256 weight = (power * weights[i]) / totalWeight;
            if (weight == 0) continue;

            PoolId poolId = poolKeys[i].toPoolId();
            uint64 swapFee = capFee(swapFees[i]);
            _accruePoolVoteSeconds(poolId);

            PoolVoteState storage poolState = poolVoteStates[poolId];
            VePoolPosition storage vePool = vePoolPositions[veId][poolId];

            poolState.weight += weight;
            poolState.feeWeightSum += weight * swapFee;
            totalVoteWeight += weight;

            vePool.weight = weight;
            vePool.swapFee = swapFee;
            vePool.feeGrowth0X128 = poolState.feeGrowth0X128;
            vePool.feeGrowth1X128 = poolState.feeGrowth1X128;
            votedPools[veId].push(poolId);

            _updatePoolSwapFee(poolId);
        }

        emit Voted(veId);
    }

    function _accountPoolFees(PoolId poolId, uint128 amount0, uint128 amount1) private {
        if (amount0 == 0 && amount1 == 0) return;

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

    function _claimPoolFeesUnlocked(uint256 veId, PoolKey memory poolKey)
        private
        returns (uint128 amount0, uint128 amount1)
    {
        PoolId poolId = poolKey.toPoolId();
        _accrueVePoolFees(veId, poolId);

        VePoolPosition storage vePool = vePoolPositions[veId][poolId];
        amount0 = uint128(vePool.accrued0);
        amount1 = uint128(vePool.accrued1);

        if (amount0 != 0 || amount1 != 0) {
            vePool.accrued0 = 0;
            vePool.accrued1 = 0;
            address recipient = ownerOf(veId);
            CORE.updateSavedBalances(
                poolKey.token0,
                poolKey.token1,
                PoolId.unwrap(poolId),
                -int256(uint256(amount0)),
                -int256(uint256(amount1))
            );
            ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, recipient, amount0, amount1);
        }

        emit PoolFeesClaimed(veId, poolId, ownerOf(veId), amount0, amount1);
    }

    function _triggerPoolEmissions(PoolKey memory poolKey) private returns (uint224 amount) {
        if (poolKey.config.extension() != address(this)) revert PoolNotInitialized();

        PoolId poolId = poolKey.toPoolId();
        _accrueEmissions();
        _accrueTotalVoteSeconds();
        _accruePoolVoteSeconds(poolId);

        PoolVoteState storage poolState = poolVoteStates[poolId];
        uint256 poolSeconds = poolState.voteSeconds;
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
        if (endTime == 0) revert EmissionAmountTooSmall();
        uint256 duration = endTime - block.timestamp;
        uint224 rewardRate = uint224((amount256 << 32) / duration);
        if (rewardRate == 0) revert EmissionAmountTooSmall();

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
            SingleTokenRewardsPoolState state = poolRewardState[poolId];
            poolRewardState[poolId] = createSingleTokenRewardsPoolState(
                state.lastAccumulated(), uint224(_addRewardRate(state.rewardRate(), rewardRateDelta))
            );
        }

        _updateTime(poolId, endTime, -rewardRateDelta);

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

    function _clearVotes(uint256 veId) private {
        PoolId[] storage pools = votedPools[veId];
        if (pools.length == 0) return;

        _accrueTotalVoteSeconds();

        for (uint256 i = 0; i < pools.length; i++) {
            PoolId poolId = pools[i];
            _accruePoolVoteSeconds(poolId);
            _accrueVePoolFees(veId, poolId);

            VePoolPosition storage vePool = vePoolPositions[veId][poolId];
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

        delete votedPools[veId];
    }

    function _accrueVePoolFees(uint256 veId, PoolId poolId) private {
        PoolVoteState storage poolState = poolVoteStates[poolId];
        VePoolPosition storage vePool = vePoolPositions[veId][poolId];

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

    function _accrueTotalVoteSeconds() private {
        uint64 lastAccrued = totalVoteSecondsLastAccrued;
        if (lastAccrued != block.timestamp) {
            unchecked {
                totalVoteSeconds += totalVoteWeight * (block.timestamp - lastAccrued);
            }
            totalVoteSecondsLastAccrued = uint64(block.timestamp);
        }
    }

    function _accrueEmissions() private {
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
        uint32 tickSpacing = poolKey.config.concentratedTickSpacing();

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
            if (liquidityNetNext == 0) {
                delete tickRewardsOutsidePerLiquidity[poolId][tick];
            } else {
                tickRewardsOutsidePerLiquidity[poolId][tick] =
                    CORE.poolState(poolId).tick() >= tick ? rewardsGlobalPerLiquidity[poolId] : 0;
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
