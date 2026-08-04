// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {VeToken} from "./VeToken.sol";
import {MAX_NUM_VALID_TIMES, isTimeValid, nextValidTime} from "./math/time.sol";
import {bitmapWordAndIndexToTime, timeToBitmapWordAndIndex} from "./math/timeBitmap.sol";
import {Bitmap} from "./types/bitmap.sol";
import {PoolId} from "./types/poolId.sol";
import {PoolKey} from "./types/poolKey.sol";
import {Ve33GlobalEmissionState, createVe33GlobalEmissionState} from "./types/ve33GlobalEmissionState.sol";

uint256 constant BRIBE_MAX_ABS_VALUE_REWARD_RATE_DELTA = type(uint160).max / MAX_NUM_VALID_TIMES;

/// @notice Identifies a canonical bribe: one incentivized pool, one reward token, and one directed swap fee.
struct BribeKey {
    /// @notice Pool incentivized by the bribe and receiving every deposited NFT vote.
    PoolKey poolKey;
    /// @notice ERC20 paid as the additional voting incentive.
    address rewardToken;
    /// @notice Swap fee selected whenever the bribe directs a deposited NFT's vote.
    uint64 votingFee;
}

using {toBribeId} for BribeKey global;

/// @notice Converts a bribe key to its unique bribe id.
function toBribeId(BribeKey memory key) pure returns (bytes32 bribeId) {
    bribeId = keccak256(abi.encode(key.poolKey.toPoolId(), key.rewardToken, key.votingFee));
}

/// @title VeToken Bribes
/// @notice Singleton that custodies VeToken NFTs, directs their votes to bribed pools, and pays ERC20 incentives by
///         applied vote weight. Each bribe is identified by its `BribeKey` and created lazily on first use.
/// @dev A deposited NFT keeps the vote weight applied when it enters a bribe. Call `refreshVote` to checkpoint
///      incentives, collect its voter fees, and apply its current voting power and the bribe's voting fee again.
contract VeTokenBribes {
    /// @notice VeToken collection accepted by every bribe.
    VeToken public immutable VE_TOKEN;

    struct Bribe {
        /// @dev Sum of the applied vote weights earning this bribe's incentives.
        uint256 totalWeight;
        /// @dev Accumulated Q128 reward growth per unit of applied vote weight.
        uint256 rewardGrowthGlobalX128;
        /// @dev Packed Q32 reward rate and uint32 last-accrued timestamp, shared with Ve33's scheduler
        ///      representation. Nonzero for every created bribe.
        Ve33GlobalEmissionState globalRewardState;
        mapping(uint256 time => int256 delta) rewardRateDeltaAtTime;
        mapping(uint256 word => Bitmap bitmap) rewardInitializedTimeBitmap;
    }

    struct Deposit {
        address owner;
        uint128 weight;
        bytes32 bribeId;
        uint256 rewardGrowthGlobalX128Snapshot;
        uint256 accruedReward;
    }

    mapping(bytes32 bribeId => Bribe) private _bribes;

    /// @notice Bribe deposit state keyed by VeToken id.
    mapping(uint256 veId => Deposit) public deposits;

    error InvalidAddress();
    error InvalidPool();
    error InvalidTimestamps();
    error RewardFundingOverflow();
    error MaxRewardRateDeltaPerTime();
    error UnexpectedRewardAmount(uint256 expected, uint256 received);
    error AlreadyDeposited();
    error NotDeposited();
    error DepositOwnerOnly();
    error NoVotingPower();
    error IncompatibleExistingVote();
    error BribeKeyMismatch();

    event BribeCreated(
        bytes32 indexed bribeId, PoolId indexed poolId, address indexed rewardToken, PoolKey poolKey, uint64 votingFee
    );
    event Staked(bytes32 indexed bribeId, address indexed owner, uint256 indexed veId, uint128 weight);
    event Unstaked(bytes32 indexed bribeId, address indexed owner, uint256 indexed veId, uint128 weight);
    event VoteRefreshed(
        bytes32 indexed bribeId, address indexed owner, uint256 indexed veId, uint128 previousWeight, uint128 weight
    );
    event RewardPaid(bytes32 indexed bribeId, address indexed owner, uint256 indexed veId, uint256 amount);
    event RewardsScheduled(
        bytes32 indexed bribeId,
        address indexed funder,
        uint64 startTime,
        uint64 endTime,
        uint160 rewardRate,
        uint128 amount
    );
    event VotingFeesClaimed(
        bytes32 indexed bribeId,
        address indexed owner,
        uint256 indexed veId,
        address recipient,
        uint128 amount0,
        uint128 amount1
    );

    constructor(VeToken veToken) {
        if (address(veToken) == address(0)) revert InvalidAddress();
        VE_TOKEN = veToken;
    }

    /// @notice Returns whether a bribe has been created.
    function isCreated(bytes32 bribeId) public view returns (bool) {
        return Ve33GlobalEmissionState.unwrap(_bribes[bribeId].globalRewardState) != bytes32(0);
    }

    /// @notice Returns the sum of the applied vote weights earning a bribe's incentives.
    function totalWeight(bytes32 bribeId) public view returns (uint256) {
        return _bribes[bribeId].totalWeight;
    }

    /// @notice Returns a bribe's current Q32 reward-token rate per second, including elapsed scheduled changes.
    function rewardRate(bytes32 bribeId) public view returns (uint160 rate) {
        (, rate) = _previewRewardState(_bribes[bribeId]);
    }

    /// @notice Returns the packed timestamp of a bribe's last state-changing reward accrual.
    function rewardsLastAccrued(bytes32 bribeId) public view returns (uint32) {
        return _bribes[bribeId].globalRewardState.lastAccrued();
    }

    /// @notice Returns a bribe's scheduled Q32 reward-rate delta.
    function rewardRateDeltaAtTime(bytes32 bribeId, uint256 time) public view returns (int256) {
        return _bribes[bribeId].rewardRateDeltaAtTime[time];
    }

    /// @notice Returns one initialized-time bitmap word for a bribe's scheduled reward-rate changes.
    function rewardInitializedTimeBitmap(bytes32 bribeId, uint256 word) public view returns (uint256) {
        return Bitmap.unwrap(_bribes[bribeId].rewardInitializedTimeBitmap[word]);
    }

    /// @notice Returns a bribe's current Q128 reward growth per unit of applied vote weight.
    function rewardGrowthGlobalX128(bytes32 bribeId) public view returns (uint256 growth) {
        (growth,) = _previewRewardState(_bribes[bribeId]);
    }

    /// @notice Returns the incentive currently claimable for a deposited VeToken.
    function earned(uint256 veId) public view returns (uint256 amount) {
        Deposit storage deposit = deposits[veId];
        uint256 growthDelta;
        unchecked {
            growthDelta = rewardGrowthGlobalX128(deposit.bribeId) - deposit.rewardGrowthGlobalX128Snapshot;
        }
        amount = deposit.accruedReward + FixedPointMathLib.fullMulDivN(growthDelta, deposit.weight, 128);
    }

    /// @notice Takes custody of a VeToken and directs its full applied vote to a bribe's pool.
    /// @dev Creates the bribe if it does not exist. An existing vote is accepted only for the bribed pool. Its voter
    ///      fees are paid before the vote is reapplied, ensuring current voting power is read without discarding
    ///      previously earned fees.
    function stake(BribeKey calldata key, uint256 veId) external {
        if (deposits[veId].owner != address(0)) revert AlreadyDeposited();
        bytes32 bribeId = key.toBribeId();
        Bribe storage bribe = _getOrCreateBribe(key, bribeId);

        (PoolId votedPool,,,,) = VE_TOKEN.voteState(veId);
        bool hasVote = PoolId.unwrap(votedPool) != bytes32(0);
        if (hasVote && PoolId.unwrap(votedPool) != PoolId.unwrap(key.poolKey.toPoolId())) {
            revert IncompatibleExistingVote();
        }

        _accrueRewards(bribe);
        VE_TOKEN.transferFrom(msg.sender, address(this), veId);

        if (hasVote) {
            (uint128 amount0, uint128 amount1) = VE_TOKEN.claimPoolFees(veId, key.poolKey, msg.sender);
            emit VotingFeesClaimed(bribeId, msg.sender, veId, msg.sender, amount0, amount1);
        }

        VE_TOKEN.vote(veId, key.poolKey, key.votingFee);
        (, uint128 appliedWeight,,,) = VE_TOKEN.voteState(veId);
        if (appliedWeight == 0) revert NoVotingPower();

        deposits[veId] = Deposit({
            owner: msg.sender,
            weight: appliedWeight,
            bribeId: bribeId,
            rewardGrowthGlobalX128Snapshot: bribe.rewardGrowthGlobalX128,
            accruedReward: 0
        });
        bribe.totalWeight += appliedWeight;

        emit Staked(bribeId, msg.sender, veId, appliedWeight);
    }

    /// @notice Collects voter fees, reapplies current voting power and fee, and updates incentive weight.
    function refreshVote(BribeKey calldata key, uint256 veId) external {
        (bytes32 bribeId, Bribe storage bribe, Deposit storage deposit) = _authorizedDepositForKey(key, veId);
        _checkpoint(bribe, deposit);

        uint128 previousWeight = deposit.weight;
        uint128 nextWeight = SafeCastLib.toUint128(VE_TOKEN.votingPower(veId));
        bribe.totalWeight = bribe.totalWeight - previousWeight + nextWeight;
        deposit.weight = nextWeight;

        (uint128 amount0, uint128 amount1) = _claimVotingFeesIfVoted(key.poolKey, veId, deposit.owner);
        emit VotingFeesClaimed(bribeId, deposit.owner, veId, deposit.owner, amount0, amount1);

        VE_TOKEN.vote(veId, key.poolKey, key.votingFee);

        emit VoteRefreshed(bribeId, deposit.owner, veId, previousWeight, nextWeight);
    }

    /// @notice Claims the additional incentive for a deposited VeToken.
    function claimReward(BribeKey calldata key, uint256 veId) external returns (uint256 amount) {
        (bytes32 bribeId, Bribe storage bribe, Deposit storage deposit) = _authorizedDepositForKey(key, veId);
        _checkpoint(bribe, deposit);
        amount = _payReward(bribeId, key.rewardToken, deposit, veId);
    }

    /// @notice Claims the VeToken's underlying voter fees without removing it from the bribe.
    function claimVotingFees(BribeKey calldata key, uint256 veId, address recipient)
        external
        returns (uint128 amount0, uint128 amount1)
    {
        (bytes32 bribeId,, Deposit storage deposit) = _authorizedDepositForKey(key, veId);
        if (recipient == address(0)) revert InvalidAddress();
        address owner = deposit.owner;

        (amount0, amount1) = _claimVotingFeesIfVoted(key.poolKey, veId, recipient);
        emit VotingFeesClaimed(bribeId, owner, veId, recipient, amount0, amount1);
    }

    /// @notice Claims all incentives and voter fees, clears the deposited NFT's vote, and returns the VeToken.
    function unstake(BribeKey calldata key, uint256 veId)
        external
        returns (uint256 reward, uint128 votingFees0, uint128 votingFees1)
    {
        (bytes32 bribeId, Bribe storage bribe, Deposit storage deposit) = _authorizedDepositForKey(key, veId);
        _checkpoint(bribe, deposit);

        address owner = deposit.owner;
        uint128 weight = deposit.weight;
        reward = deposit.accruedReward;

        bribe.totalWeight -= weight;
        delete deposits[veId];
        emit Unstaked(bribeId, owner, veId, weight);

        (votingFees0, votingFees1) = _claimVotingFeesIfVoted(key.poolKey, veId, owner);
        emit VotingFeesClaimed(bribeId, owner, veId, owner, votingFees0, votingFees1);
        VE_TOKEN.clearVote(veId);
        VE_TOKEN.transferFrom(address(this), owner, veId);

        if (reward != 0) {
            emit RewardPaid(bribeId, owner, veId, reward);
            SafeTransferLib.safeTransfer(key.rewardToken, owner, reward);
        }
    }

    /// @notice Clears the deposited NFT's vote and returns it without interacting with reward or pool tokens.
    /// @dev This custody escape forfeits all unclaimed bribe rewards and Ve33 voter fees for `veId`. It remains
    ///      available if an external token blocks the normal claim-and-unstake path.
    function unstakeWithoutClaiming(uint256 veId) external {
        Deposit storage deposit = _authorizedDeposit(veId);
        bytes32 bribeId = deposit.bribeId;
        Bribe storage bribe = _bribes[bribeId];
        _accrueRewards(bribe);

        address owner = deposit.owner;
        uint128 weight = deposit.weight;
        bribe.totalWeight -= weight;
        delete deposits[veId];
        emit Unstaked(bribeId, owner, veId, weight);

        VE_TOKEN.clearVote(veId);
        VE_TOKEN.transferFrom(address(this), owner, veId);
    }

    /// @notice Adds a Q32 reward-token rate to a bribe over a chosen valid time range.
    /// @dev Creates the bribe if it does not exist. Anyone may schedule rewards; the caller funds the full amount.
    ///      Overlapping schedules add their rates. Rewards emitted while a bribe's `totalWeight` is zero are not
    ///      retroactive.
    /// @param key The bribe to fund.
    /// @param startTime Real schedule start time, or zero for immediate start.
    /// @param endTime Schedule end time.
    /// @param rate Q32 reward-token rate per second.
    /// @return amount Reward-token amount required to back the schedule, rounded up.
    function scheduleRewards(BribeKey calldata key, uint64 startTime, uint64 endTime, uint160 rate)
        external
        returns (uint128 amount)
    {
        if (rate == 0) return 0;
        bytes32 bribeId = key.toBribeId();
        Bribe storage bribe = _getOrCreateBribe(key, bribeId);

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

        uint256 balanceBefore = SafeTransferLib.balanceOf(key.rewardToken, address(this));
        _accrueRewards(bribe);

        int256 rateDelta = int256(uint256(rate));
        if (startTime > block.timestamp) {
            _updateRewardTime(bribe, startTime, rateDelta);
        } else {
            (uint160 currentRate, uint32 lastAccruedTime) = bribe.globalRewardState.parse();
            unchecked {
                currentRate += rate;
            }
            bribe.globalRewardState = createVe33GlobalEmissionState(currentRate, lastAccruedTime);
        }
        _updateRewardTime(bribe, endTime, -rateDelta);

        SafeTransferLib.safeTransferFrom(key.rewardToken, msg.sender, address(this), amount);
        uint256 received = SafeTransferLib.balanceOf(key.rewardToken, address(this)) - balanceBefore;
        if (received != amount) revert UnexpectedRewardAmount(amount, received);

        emit RewardsScheduled(bribeId, msg.sender, startTime, endTime, rate, amount);
    }

    /// @notice Accrues a bribe's scheduled rewards into Q128 reward growth through the current timestamp.
    /// @dev Creates the bribe if it does not exist.
    function accrueRewards(BribeKey calldata key) external {
        _accrueRewards(_getOrCreateBribe(key, key.toBribeId()));
    }

    /// @notice Finds a bribe's next initialized reward-rate change strictly after `fromTime`.
    function nextRewardRateChangeTime(bytes32 bribeId, uint256 fromTime)
        external
        view
        returns (uint64 time, int256 delta)
    {
        Bribe storage bribe = _bribes[bribeId];
        uint256 lastAccruedTime = bribe.globalRewardState.realEmissionTimeAtOrBeforeNow();
        uint256 untilTime;
        unchecked {
            untilTime = block.timestamp + type(uint32).max;
        }
        (uint256 nextTime, bool initialized) = _searchForNextRewardTime(bribe, lastAccruedTime, fromTime, untilTime);
        if (initialized) {
            time = uint64(nextTime);
            delta = bribe.rewardRateDeltaAtTime[nextTime];
        }
    }

    function _getOrCreateBribe(BribeKey calldata key, bytes32 bribeId) private returns (Bribe storage bribe) {
        bribe = _bribes[bribeId];
        if (Ve33GlobalEmissionState.unwrap(bribe.globalRewardState) == bytes32(0)) {
            if (key.rewardToken == address(0)) revert InvalidAddress();
            PoolKey memory poolKey = key.poolKey;
            poolKey.validate();
            if (poolKey.config.extension() != address(VE_TOKEN.ve33()) || poolKey.config.fee() != 0) {
                revert InvalidPool();
            }

            bribe.globalRewardState = createVe33GlobalEmissionState({rate: 0, lastAccruedTime: uint32(block.timestamp)});
            emit BribeCreated(bribeId, key.poolKey.toPoolId(), key.rewardToken, key.poolKey, key.votingFee);
        }
    }

    function _authorizedDeposit(uint256 veId) private view returns (Deposit storage deposit) {
        deposit = deposits[veId];
        if (deposit.owner == address(0)) revert NotDeposited();
        if (deposit.owner != msg.sender) revert DepositOwnerOnly();
    }

    function _authorizedDepositForKey(BribeKey calldata key, uint256 veId)
        private
        view
        returns (bytes32 bribeId, Bribe storage bribe, Deposit storage deposit)
    {
        deposit = _authorizedDeposit(veId);
        bribeId = key.toBribeId();
        if (deposit.bribeId != bribeId) revert BribeKeyMismatch();
        bribe = _bribes[bribeId];
    }

    function _previewRewardState(Bribe storage bribe) private view returns (uint256 growth, uint160 rate) {
        Ve33GlobalEmissionState globalRewardState = bribe.globalRewardState;
        rate = globalRewardState.emissionRate();
        uint256 lastAccruedTime = globalRewardState.realEmissionTimeAtOrBeforeNow();
        uint256 time = lastAccruedTime;
        growth = bribe.rewardGrowthGlobalX128;
        uint256 weight = bribe.totalWeight;

        while (time != block.timestamp) {
            (uint256 eventTime, bool initialized) =
                _searchForNextRewardTime(bribe, lastAccruedTime, time, block.timestamp);
            growth = _accumulateRewardGrowth(growth, rate, eventTime - time, weight);

            if (initialized) {
                unchecked {
                    rate = uint160(uint256(int256(uint256(rate)) + bribe.rewardRateDeltaAtTime[eventTime]));
                }
            }
            time = eventTime;
        }
    }

    function _accrueRewards(Bribe storage bribe) private {
        Ve33GlobalEmissionState globalRewardState = bribe.globalRewardState;
        uint160 rate = globalRewardState.emissionRate();
        uint256 lastAccruedTime = globalRewardState.realEmissionTimeAtOrBeforeNow();
        if (lastAccruedTime == block.timestamp) return;

        uint256 time = lastAccruedTime;
        uint256 growth = bribe.rewardGrowthGlobalX128;
        uint256 weight = bribe.totalWeight;

        while (time != block.timestamp) {
            (uint256 eventTime, bool initialized) =
                _searchForNextRewardTime(bribe, lastAccruedTime, time, block.timestamp);
            growth = _accumulateRewardGrowth(growth, rate, eventTime - time, weight);

            if (initialized) {
                unchecked {
                    rate = uint160(uint256(int256(uint256(rate)) + bribe.rewardRateDeltaAtTime[eventTime]));
                }
                bribe.rewardRateDeltaAtTime[eventTime] = 0;
                _flipRewardTime(bribe, eventTime);
            }
            time = eventTime;
        }

        bribe.rewardGrowthGlobalX128 = growth;
        bribe.globalRewardState = createVe33GlobalEmissionState(rate, uint32(block.timestamp));
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

    function _updateRewardTime(Bribe storage bribe, uint64 time, int256 delta) private {
        int256 currentDelta = bribe.rewardRateDeltaAtTime[time];
        int256 nextDelta = _addConstrainedRateDelta(currentDelta, delta);
        bribe.rewardRateDeltaAtTime[time] = nextDelta;

        if ((currentDelta == 0) != (nextDelta == 0)) _flipRewardTime(bribe, time);
    }

    function _flipRewardTime(Bribe storage bribe, uint256 time) private {
        (uint256 word, uint256 index) = timeToBitmapWordAndIndex(time);
        bribe.rewardInitializedTimeBitmap[word] = bribe.rewardInitializedTimeBitmap[word].toggle(uint8(index));
    }

    function _findNextRewardTime(Bribe storage bribe, uint256 fromTime)
        private
        view
        returns (uint256 nextTime, bool initialized)
    {
        unchecked {
            (uint256 word, uint256 index) = timeToBitmapWordAndIndex(fromTime);
            uint256 nextIndex = bribe.rewardInitializedTimeBitmap[word].geSetBit(uint8(index));
            initialized = nextIndex != 0;
            nextIndex = (nextIndex - 1) % 256;
            nextTime = bitmapWordAndIndexToTime(word, nextIndex);
        }
    }

    function _searchForNextRewardTime(Bribe storage bribe, uint256 lastAccrued, uint256 fromTime, uint256 untilTime)
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
                (nextTime, initialized) = _findNextRewardTime(bribe, nextValid);
                if (nextTime > untilTime) {
                    nextTime = untilTime;
                    initialized = false;
                }
            }
        }
    }

    function _checkpoint(Bribe storage bribe, Deposit storage deposit) private {
        _accrueRewards(bribe);
        uint256 growthDelta;
        unchecked {
            growthDelta = bribe.rewardGrowthGlobalX128 - deposit.rewardGrowthGlobalX128Snapshot;
        }
        deposit.accruedReward += FixedPointMathLib.fullMulDivN(growthDelta, deposit.weight, 128);
        deposit.rewardGrowthGlobalX128Snapshot = bribe.rewardGrowthGlobalX128;
    }

    function _claimVotingFeesIfVoted(PoolKey calldata poolKey, uint256 veId, address recipient)
        private
        returns (uint128 amount0, uint128 amount1)
    {
        (PoolId votedPool,,,,) = VE_TOKEN.voteState(veId);
        if (PoolId.unwrap(votedPool) == PoolId.unwrap(poolKey.toPoolId())) {
            (amount0, amount1) = VE_TOKEN.claimPoolFees(veId, poolKey, recipient);
        }
    }

    function _payReward(bytes32 bribeId, address rewardToken, Deposit storage deposit, uint256 veId)
        private
        returns (uint256 amount)
    {
        amount = deposit.accruedReward;
        if (amount != 0) {
            address owner = deposit.owner;
            deposit.accruedReward = 0;
            emit RewardPaid(bribeId, owner, veId, amount);
            SafeTransferLib.safeTransfer(rewardToken, owner, amount);
        }
    }
}
