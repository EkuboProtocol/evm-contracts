// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {VeToken} from "./VeToken.sol";
import {MAX_NUM_VALID_TIMES, isTimeValid, nextValidTime} from "./math/time.sol";
import {bitmapWordAndIndexToTime, timeToBitmapWordAndIndex} from "./math/timeBitmap.sol";
import {Bitmap} from "./types/bitmap.sol";
import {PoolConfig} from "./types/poolConfig.sol";
import {PoolId} from "./types/poolId.sol";
import {PoolKey} from "./types/poolKey.sol";
import {Ve33GlobalEmissionState, createVe33GlobalEmissionState} from "./types/ve33GlobalEmissionState.sol";

uint256 constant BRIBE_MAX_ABS_VALUE_REWARD_RATE_DELTA = type(uint160).max / MAX_NUM_VALID_TIMES;

/// @title VeToken Bribe
/// @notice Custodies VeToken NFTs, directs their votes to one pool, and pays an ERC20 incentive by applied vote weight.
/// @dev A deposited NFT keeps the vote weight applied when it enters the bribe. Call `refreshVote` to checkpoint
///      incentives, collect its voter fees, and apply its current voting power and `votingFee()` again.
contract VeTokenBribe {
    /// @notice VeToken collection accepted by this bribe.
    VeToken public immutable VE_TOKEN;

    /// @notice ERC20 paid as the additional voting incentive.
    address public immutable REWARD_TOKEN;

    /// @notice Account allowed to schedule incentive rewards.
    address public immutable REWARD_DISTRIBUTOR;

    /// @notice Pool incentivized by this bribe and receiving every deposited NFT vote.
    PoolId public immutable POOL_ID;

    address public immutable POOL_TOKEN0;
    address public immutable POOL_TOKEN1;
    PoolConfig public immutable POOL_CONFIG;

    uint64 private immutable _DEFAULT_VOTING_FEE;

    /// @notice Sum of the applied vote weights earning incentives.
    uint256 public totalWeight;

    /// @notice Accumulated Q128 reward growth per unit of applied vote weight.
    uint256 private _rewardGrowthGlobalX128;

    /// @dev Packed Q32 reward rate and uint32 last-accrued timestamp, shared with Ve33's scheduler representation.
    Ve33GlobalEmissionState private _globalRewardState;

    mapping(uint256 time => int256 delta) private _rewardRateDeltaAtTime;
    mapping(uint256 word => Bitmap bitmap) private _rewardInitializedTimeBitmap;

    struct Deposit {
        address owner;
        uint128 weight;
        uint256 rewardGrowthGlobalX128Snapshot;
        uint256 accruedReward;
    }

    /// @notice Bribe deposit state keyed by VeToken id.
    mapping(uint256 veId => Deposit) public deposits;

    error InvalidAddress();
    error InvalidPool();
    error InvalidTimestamps();
    error RewardFundingOverflow();
    error MaxRewardRateDeltaPerTime();
    error UnexpectedRewardAmount(uint256 expected, uint256 received);
    error RewardDistributorOnly();
    error AlreadyDeposited();
    error NotDeposited();
    error DepositOwnerOnly();
    error NoVotingPower();
    error IncompatibleExistingVote();

    event Staked(address indexed owner, uint256 indexed veId, uint128 weight);
    event Unstaked(address indexed owner, uint256 indexed veId, uint128 weight);
    event VoteRefreshed(address indexed owner, uint256 indexed veId, uint128 previousWeight, uint128 weight);
    event RewardPaid(address indexed owner, uint256 indexed veId, uint256 amount);
    event RewardsScheduled(
        address indexed funder, uint64 startTime, uint64 endTime, uint160 rewardRate, uint128 amount
    );
    event VotingFeesClaimed(
        address indexed owner, uint256 indexed veId, address indexed recipient, uint128 amount0, uint128 amount1
    );

    constructor(
        VeToken veToken,
        PoolKey memory _poolKey,
        uint64 defaultVotingFee,
        address rewardToken,
        address rewardDistributor
    ) {
        if (address(veToken) == address(0) || rewardToken == address(0) || rewardDistributor == address(0)) {
            revert InvalidAddress();
        }
        _poolKey.validate();
        if (_poolKey.config.extension() != address(veToken.ve33()) || _poolKey.config.fee() != 0) {
            revert InvalidPool();
        }

        VE_TOKEN = veToken;
        REWARD_TOKEN = rewardToken;
        REWARD_DISTRIBUTOR = rewardDistributor;
        POOL_ID = _poolKey.toPoolId();
        POOL_TOKEN0 = _poolKey.token0;
        POOL_TOKEN1 = _poolKey.token1;
        POOL_CONFIG = _poolKey.config;
        _DEFAULT_VOTING_FEE = defaultVotingFee;
        _globalRewardState = createVe33GlobalEmissionState({rate: 0, lastAccruedTime: uint32(block.timestamp)});
    }

    /// @notice Returns the pool incentivized by this bribe.
    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({token0: POOL_TOKEN0, token1: POOL_TOKEN1, config: POOL_CONFIG});
    }

    /// @notice Returns the swap fee selected whenever this bribe directs a deposited NFT's vote.
    /// @dev Override this function to implement a different fee policy.
    function votingFee() public view virtual returns (uint64) {
        return _DEFAULT_VOTING_FEE;
    }

    /// @notice Returns the current Q32 reward-token rate per second, including elapsed scheduled changes.
    function rewardRate() public view returns (uint160 rate) {
        (, rate) = _previewRewardState();
    }

    /// @notice Returns the packed timestamp of the last state-changing reward accrual.
    function rewardsLastAccrued() public view returns (uint32) {
        return _globalRewardState.lastAccrued();
    }

    /// @notice Returns a scheduled Q32 reward-rate delta.
    function rewardRateDeltaAtTime(uint256 time) public view returns (int256) {
        return _rewardRateDeltaAtTime[time];
    }

    /// @notice Returns one initialized-time bitmap word for scheduled reward-rate changes.
    function rewardInitializedTimeBitmap(uint256 word) public view returns (uint256) {
        return Bitmap.unwrap(_rewardInitializedTimeBitmap[word]);
    }

    /// @notice Returns current Q128 reward growth per unit of applied vote weight.
    function rewardGrowthGlobalX128() public view returns (uint256 growth) {
        (growth,) = _previewRewardState();
    }

    /// @notice Returns the incentive currently claimable for a deposited VeToken.
    function earned(uint256 veId) public view returns (uint256 amount) {
        Deposit storage deposit = deposits[veId];
        uint256 growthDelta;
        unchecked {
            growthDelta = rewardGrowthGlobalX128() - deposit.rewardGrowthGlobalX128Snapshot;
        }
        amount = deposit.accruedReward + FixedPointMathLib.fullMulDivN(growthDelta, deposit.weight, 128);
    }

    /// @notice Takes custody of a VeToken and directs its full applied vote to the incentivized pool.
    /// @dev An existing vote is accepted only for the incentivized pool. Its voter fees are paid before the vote is
    ///      reapplied, ensuring current voting power is read without discarding previously earned fees.
    function stake(uint256 veId) external {
        if (deposits[veId].owner != address(0)) revert AlreadyDeposited();

        (PoolId votedPool,,,,) = VE_TOKEN.voteState(veId);
        bool hasVote = PoolId.unwrap(votedPool) != bytes32(0);
        if (hasVote && PoolId.unwrap(votedPool) != PoolId.unwrap(POOL_ID)) revert IncompatibleExistingVote();

        accrueRewards();
        VE_TOKEN.transferFrom(msg.sender, address(this), veId);

        if (hasVote) {
            (uint128 amount0, uint128 amount1) = VE_TOKEN.claimPoolFees(veId, poolKey(), msg.sender);
            emit VotingFeesClaimed(msg.sender, veId, msg.sender, amount0, amount1);
        }

        uint64 fee = votingFee();
        VE_TOKEN.vote(veId, poolKey(), fee);
        (, uint128 appliedWeight,,,) = VE_TOKEN.voteState(veId);
        if (appliedWeight == 0) revert NoVotingPower();

        deposits[veId] = Deposit({
            owner: msg.sender,
            weight: appliedWeight,
            rewardGrowthGlobalX128Snapshot: _rewardGrowthGlobalX128,
            accruedReward: 0
        });
        totalWeight += appliedWeight;

        emit Staked(msg.sender, veId, appliedWeight);
    }

    /// @notice Collects voter fees, reapplies current voting power and fee, and updates incentive weight.
    function refreshVote(uint256 veId) external {
        Deposit storage deposit = _authorizedDeposit(veId);
        _checkpoint(deposit);

        uint128 previousWeight = deposit.weight;
        uint128 nextWeight = SafeCastLib.toUint128(VE_TOKEN.votingPower(veId));
        totalWeight = totalWeight - previousWeight + nextWeight;
        deposit.weight = nextWeight;

        (uint128 amount0, uint128 amount1) = _claimVotingFeesIfVoted(veId, deposit.owner);
        emit VotingFeesClaimed(deposit.owner, veId, deposit.owner, amount0, amount1);

        uint64 fee = votingFee();
        VE_TOKEN.vote(veId, poolKey(), fee);

        emit VoteRefreshed(deposit.owner, veId, previousWeight, nextWeight);
    }

    /// @notice Claims the additional incentive for a deposited VeToken.
    function claimReward(uint256 veId) external returns (uint256 amount) {
        Deposit storage deposit = _authorizedDeposit(veId);
        _checkpoint(deposit);
        amount = _payReward(deposit, veId);
    }

    /// @notice Claims the VeToken's underlying voter fees without removing it from the bribe.
    function claimVotingFees(uint256 veId, address recipient) external returns (uint128 amount0, uint128 amount1) {
        Deposit storage deposit = _authorizedDeposit(veId);
        if (recipient == address(0)) revert InvalidAddress();
        address owner = deposit.owner;

        (amount0, amount1) = _claimVotingFeesIfVoted(veId, recipient);
        emit VotingFeesClaimed(owner, veId, recipient, amount0, amount1);
    }

    /// @notice Claims all incentives and voter fees, clears the deposited NFT's vote, and returns the VeToken.
    function unstake(uint256 veId) external returns (uint256 reward, uint128 votingFees0, uint128 votingFees1) {
        Deposit storage deposit = _authorizedDeposit(veId);
        _checkpoint(deposit);

        address owner = deposit.owner;
        uint128 weight = deposit.weight;
        reward = deposit.accruedReward;

        totalWeight -= weight;
        delete deposits[veId];
        emit Unstaked(owner, veId, weight);

        (votingFees0, votingFees1) = _claimVotingFeesIfVoted(veId, owner);
        emit VotingFeesClaimed(owner, veId, owner, votingFees0, votingFees1);
        VE_TOKEN.clearVote(veId);
        VE_TOKEN.transferFrom(address(this), owner, veId);

        if (reward != 0) {
            emit RewardPaid(owner, veId, reward);
            SafeTransferLib.safeTransfer(REWARD_TOKEN, owner, reward);
        }
    }

    /// @notice Clears the deposited NFT's vote and returns it without interacting with reward or pool tokens.
    /// @dev This custody escape forfeits all unclaimed bribe rewards and Ve33 voter fees for `veId`. It remains
    ///      available if an external token blocks the normal claim-and-unstake path.
    function unstakeWithoutClaiming(uint256 veId) external {
        Deposit storage deposit = _authorizedDeposit(veId);
        accrueRewards();

        address owner = deposit.owner;
        uint128 weight = deposit.weight;
        totalWeight -= weight;
        delete deposits[veId];
        emit Unstaked(owner, veId, weight);

        VE_TOKEN.clearVote(veId);
        VE_TOKEN.transferFrom(address(this), owner, veId);
    }

    /// @notice Adds a Q32 reward-token rate over a chosen valid time range.
    /// @dev Overlapping schedules add their rates. Rewards emitted while `totalWeight` is zero are not retroactive.
    /// @param startTime Real schedule start time, or zero for immediate start.
    /// @param endTime Schedule end time.
    /// @param rate Q32 reward-token rate per second.
    /// @return amount Reward-token amount required to back the schedule, rounded up.
    function scheduleRewards(uint64 startTime, uint64 endTime, uint160 rate) external returns (uint128 amount) {
        if (msg.sender != REWARD_DISTRIBUTOR) revert RewardDistributorOnly();
        if (rate == 0) return 0;

        uint256 realStartTime = FixedPointMathLib.max(block.timestamp, startTime);
        if (
            !isTimeValid({currentTime: block.timestamp, time: startTime})
                || !isTimeValid({currentTime: block.timestamp, time: endTime}) || endTime <= realStartTime
        ) {
            revert InvalidTimestamps();
        }

        unchecked {
            uint256 realDuration = endTime - realStartTime;
            uint256 requiredAmount = ((realDuration * rate) + type(uint32).max) >> 32;
            if (requiredAmount > type(uint128).max) revert RewardFundingOverflow();
            amount = uint128(requiredAmount);
        }

        uint256 balanceBefore = SafeTransferLib.balanceOf(REWARD_TOKEN, address(this));
        accrueRewards();

        int256 rateDelta = int256(uint256(rate));
        if (startTime > block.timestamp) {
            _updateRewardTime(startTime, rateDelta);
        } else {
            (uint160 currentRate, uint32 lastAccrued) = _globalRewardState.parse();
            unchecked {
                currentRate += rate;
            }
            _globalRewardState = createVe33GlobalEmissionState(currentRate, lastAccrued);
        }
        _updateRewardTime(endTime, -rateDelta);

        SafeTransferLib.safeTransferFrom(REWARD_TOKEN, msg.sender, address(this), amount);
        uint256 received = SafeTransferLib.balanceOf(REWARD_TOKEN, address(this)) - balanceBefore;
        if (received != amount) revert UnexpectedRewardAmount(amount, received);

        emit RewardsScheduled(msg.sender, startTime, endTime, rate, amount);
    }

    /// @notice Accrues scheduled rewards into Q128 reward growth through the current timestamp.
    function accrueRewards() public {
        Ve33GlobalEmissionState globalRewardState = _globalRewardState;
        uint160 rate = globalRewardState.emissionRate();
        uint256 lastAccruedTime = globalRewardState.realEmissionTimeAtOrBeforeNow();
        if (lastAccruedTime == block.timestamp) return;

        uint256 time = lastAccruedTime;
        uint256 growth = _rewardGrowthGlobalX128;
        uint256 weight = totalWeight;

        while (time != block.timestamp) {
            (uint256 eventTime, bool initialized) = _searchForNextRewardTime(lastAccruedTime, time, block.timestamp);
            growth = _accumulateRewardGrowth(growth, rate, eventTime - time, weight);

            if (initialized) {
                unchecked {
                    rate = uint160(uint256(int256(uint256(rate)) + _rewardRateDeltaAtTime[eventTime]));
                }
                _rewardRateDeltaAtTime[eventTime] = 0;
                _flipRewardTime(eventTime);
            }
            time = eventTime;
        }

        _rewardGrowthGlobalX128 = growth;
        _globalRewardState = createVe33GlobalEmissionState(rate, uint32(block.timestamp));
    }

    /// @notice Finds the next initialized reward-rate change strictly after `fromTime`.
    function nextRewardRateChangeTime(uint256 fromTime) external view returns (uint64 time, int256 delta) {
        uint256 lastAccruedTime = _globalRewardState.realEmissionTimeAtOrBeforeNow();
        uint256 untilTime;
        unchecked {
            untilTime = block.timestamp + type(uint32).max;
        }
        (uint256 nextTime, bool initialized) = _searchForNextRewardTime(lastAccruedTime, fromTime, untilTime);
        if (initialized) {
            time = uint64(nextTime);
            delta = _rewardRateDeltaAtTime[nextTime];
        }
    }

    function _authorizedDeposit(uint256 veId) private view returns (Deposit storage deposit) {
        deposit = deposits[veId];
        if (deposit.owner == address(0)) revert NotDeposited();
        if (deposit.owner != msg.sender) revert DepositOwnerOnly();
    }

    function _previewRewardState() private view returns (uint256 growth, uint160 rate) {
        Ve33GlobalEmissionState globalRewardState = _globalRewardState;
        rate = globalRewardState.emissionRate();
        uint256 lastAccruedTime = globalRewardState.realEmissionTimeAtOrBeforeNow();
        uint256 time = lastAccruedTime;
        growth = _rewardGrowthGlobalX128;
        uint256 weight = totalWeight;

        while (time != block.timestamp) {
            (uint256 eventTime, bool initialized) = _searchForNextRewardTime(lastAccruedTime, time, block.timestamp);
            growth = _accumulateRewardGrowth(growth, rate, eventTime - time, weight);

            if (initialized) {
                unchecked {
                    rate = uint160(uint256(int256(uint256(rate)) + _rewardRateDeltaAtTime[eventTime]));
                }
            }
            time = eventTime;
        }
    }

    function _accumulateRewardGrowth(uint256 growth, uint160 rate, uint256 elapsed, uint256 weight)
        private
        pure
        returns (uint256)
    {
        uint256 amount = (uint256(rate) * elapsed) >> 32;
        assembly ("memory-safe") {
            growth := add(growth, div(shl(128, amount), weight))
        }
        return growth;
    }

    function _addConstrainedRateDelta(int256 rateDelta, int256 change) private pure returns (int256 next) {
        unchecked {
            next = rateDelta + change;
        }
        if (FixedPointMathLib.abs(next) > BRIBE_MAX_ABS_VALUE_REWARD_RATE_DELTA) {
            revert MaxRewardRateDeltaPerTime();
        }
    }

    function _updateRewardTime(uint64 time, int256 delta) private {
        int256 currentDelta = _rewardRateDeltaAtTime[time];
        int256 nextDelta = _addConstrainedRateDelta(currentDelta, delta);
        _rewardRateDeltaAtTime[time] = nextDelta;

        if ((currentDelta == 0) != (nextDelta == 0)) _flipRewardTime(time);
    }

    function _flipRewardTime(uint256 time) private {
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        _rewardInitializedTimeBitmap[word] = _rewardInitializedTimeBitmap[word].toggle(uint8(index));
    }

    function _findNextRewardTime(uint256 fromTime) private view returns (uint256 nextTime, bool initialized) {
        unchecked {
            (uint256 word, uint256 index) = timeToBitmapWordAndIndex(fromTime);
            uint256 nextIndex = _rewardInitializedTimeBitmap[word].geSetBit(uint8(index));
            initialized = nextIndex != 0;
            nextIndex = (nextIndex - 1) % 256;
            nextTime = bitmapWordAndIndexToTime(word, nextIndex);
        }
    }

    function _searchForNextRewardTime(uint256 lastAccrued, uint256 fromTime, uint256 untilTime)
        private
        view
        returns (uint256 nextTime, bool initialized)
    {
        unchecked {
            nextTime = fromTime;
            while (!initialized && nextTime != untilTime) {
                uint256 nextValid = nextValidTime(lastAccrued, nextTime);
                if (nextValid == 0) {
                    nextTime = untilTime;
                    break;
                }
                (nextTime, initialized) = _findNextRewardTime(nextValid);
                if (nextTime > untilTime) {
                    nextTime = untilTime;
                    initialized = false;
                }
            }
        }
    }

    function _checkpoint(Deposit storage deposit) private {
        accrueRewards();
        uint256 growthDelta;
        unchecked {
            growthDelta = _rewardGrowthGlobalX128 - deposit.rewardGrowthGlobalX128Snapshot;
        }
        deposit.accruedReward += FixedPointMathLib.fullMulDivN(growthDelta, deposit.weight, 128);
        deposit.rewardGrowthGlobalX128Snapshot = _rewardGrowthGlobalX128;
    }

    function _claimVotingFeesIfVoted(uint256 veId, address recipient)
        private
        returns (uint128 amount0, uint128 amount1)
    {
        (PoolId votedPool,,,,) = VE_TOKEN.voteState(veId);
        if (PoolId.unwrap(votedPool) == PoolId.unwrap(POOL_ID)) {
            (amount0, amount1) = VE_TOKEN.claimPoolFees(veId, poolKey(), recipient);
        }
    }

    function _payReward(Deposit storage deposit, uint256 veId) private returns (uint256 amount) {
        amount = deposit.accruedReward;
        if (amount != 0) {
            address owner = deposit.owner;
            deposit.accruedReward = 0;
            emit RewardPaid(owner, veId, amount);
            SafeTransferLib.safeTransfer(REWARD_TOKEN, owner, amount);
        }
    }
}
