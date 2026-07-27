// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {VeToken} from "./VeToken.sol";
import {PoolConfig} from "./types/poolConfig.sol";
import {PoolId} from "./types/poolId.sol";
import {PoolKey} from "./types/poolKey.sol";

/// @title VeToken Bribe
/// @notice Custodies VeToken NFTs, directs their votes to one pool, and pays an ERC20 incentive by applied vote weight.
/// @dev A deposited NFT keeps the vote weight applied when it enters the bribe. Call `refreshVote` to checkpoint
///      incentives, collect its voter fees, and apply its current voting power and `votingFee()` again.
contract VeTokenBribe {
    uint256 private constant REWARD_GROWTH_SCALE = 1e18;

    /// @notice VeToken collection accepted by this bribe.
    VeToken public immutable VE_TOKEN;

    /// @notice ERC20 paid as the additional voting incentive.
    address public immutable REWARD_TOKEN;

    /// @notice Account allowed to fund or extend the incentive stream.
    address public immutable REWARD_DISTRIBUTOR;

    /// @notice Pool incentivized by this bribe and receiving every deposited NFT vote.
    PoolId public immutable POOL_ID;

    address public immutable POOL_TOKEN0;
    address public immutable POOL_TOKEN1;
    PoolConfig public immutable POOL_CONFIG;

    uint64 private immutable _DEFAULT_VOTING_FEE;

    /// @notice Sum of the applied vote weights earning incentives.
    uint256 public totalWeight;

    /// @notice Total incentive tokens in the current stream, including rolled-over unvested rewards.
    uint256 public periodReward;

    /// @notice Start of the current incentive stream.
    uint64 public periodStart;

    /// @notice End of the current incentive stream.
    uint64 public periodFinish;

    /// @notice Last timestamp included in `rewardGrowthStored`.
    uint64 public lastUpdateTime;

    /// @notice Accumulated incentive per unit of applied vote weight, scaled by 1e18.
    uint256 public rewardGrowthStored;

    struct Deposit {
        address owner;
        uint128 weight;
        uint256 rewardGrowthSnapshot;
        uint256 accruedReward;
    }

    /// @notice Bribe deposit state keyed by VeToken id.
    mapping(uint256 veId => Deposit) public deposits;

    error InvalidAddress();
    error InvalidPool();
    error InvalidDuration();
    error InvalidRewardAmount();
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
    event RewardAdded(
        address indexed funder, uint256 addedAmount, uint256 rewardRate, uint256 rewardRemainder, uint64 periodFinish
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
        lastUpdateTime = uint64(block.timestamp);
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

    /// @notice Floor of the current incentive tokens streamed per second.
    function rewardRate() public view returns (uint256) {
        uint64 duration = periodFinish - periodStart;
        return duration == 0 ? 0 : periodReward / duration;
    }

    /// @notice Remainder from dividing `periodReward` by the duration, spread across the stream.
    function rewardRemainder() public view returns (uint256) {
        uint64 duration = periodFinish - periodStart;
        return duration == 0 ? 0 : periodReward % duration;
    }

    /// @notice Returns the latest timestamp that can accrue rewards.
    function lastTimeRewardApplicable() public view returns (uint64) {
        uint64 finish = periodFinish;
        return uint64(block.timestamp) < finish ? uint64(block.timestamp) : finish;
    }

    /// @notice Returns current accumulated incentive per unit of applied vote weight.
    function rewardGrowth() public view returns (uint256 growth) {
        growth = rewardGrowthStored;
        uint256 weight = totalWeight;
        if (weight != 0) {
            uint64 applicableTime = lastTimeRewardApplicable();
            uint64 updatedAt = lastUpdateTime;
            if (applicableTime > updatedAt) {
                uint256 accrued = _vestedReward(applicableTime) - _vestedReward(updatedAt);
                growth += FixedPointMathLib.fullMulDiv(accrued, REWARD_GROWTH_SCALE, weight);
            }
        }
    }

    /// @notice Returns the incentive currently claimable for a deposited VeToken.
    function earned(uint256 veId) public view returns (uint256 amount) {
        Deposit storage deposit = deposits[veId];
        amount = deposit.accruedReward
            + FixedPointMathLib.fullMulDiv(
                deposit.weight, rewardGrowth() - deposit.rewardGrowthSnapshot, REWARD_GROWTH_SCALE
            );
    }

    /// @notice Takes custody of a VeToken and directs its full applied vote to the incentivized pool.
    /// @dev An existing vote is accepted only for the incentivized pool. Its voter fees are paid before the vote is
    ///      reapplied, ensuring current voting power is read without discarding previously earned fees.
    function stake(uint256 veId) external {
        if (deposits[veId].owner != address(0)) revert AlreadyDeposited();

        (PoolId votedPool,,,,) = VE_TOKEN.voteState(veId);
        bool hasVote = PoolId.unwrap(votedPool) != bytes32(0);
        if (hasVote && PoolId.unwrap(votedPool) != PoolId.unwrap(POOL_ID)) revert IncompatibleExistingVote();

        _updateRewardGrowth();
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
            owner: msg.sender, weight: appliedWeight, rewardGrowthSnapshot: rewardGrowthStored, accruedReward: 0
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
        _updateRewardGrowth();

        address owner = deposit.owner;
        uint128 weight = deposit.weight;
        totalWeight -= weight;
        delete deposits[veId];
        emit Unstaked(owner, veId, weight);

        VE_TOKEN.clearVote(veId);
        VE_TOKEN.transferFrom(address(this), owner, veId);
    }

    /// @notice Replaces the incentive stream with the added amount plus any unvested rewards.
    /// @dev Accrued rewards are checkpointed first. The replacement is vested cumulatively across `duration`, and its
    ///      clock pauses while the bribe has no applied vote weight.
    /// @param amount Amount requested from the reward distributor.
    /// @param duration Duration of the replacement stream.
    /// @return received Reward-token amount received. Reverts unless it exactly matches `amount`.
    function notifyRewardAmount(uint256 amount, uint64 duration) external returns (uint256 received) {
        if (msg.sender != REWARD_DISTRIBUTOR) revert RewardDistributorOnly();
        if (duration == 0) revert InvalidDuration();
        if (amount == 0) revert InvalidRewardAmount();

        uint256 balanceBefore = SafeTransferLib.balanceOf(REWARD_TOKEN, address(this));
        _updateRewardGrowth();

        uint256 funding = amount;
        uint64 currentTime = uint64(block.timestamp);
        uint64 finish = periodFinish;
        if (currentTime < finish) funding += periodReward - _vestedReward(currentTime);

        uint256 nextRewardRate = funding / duration;
        uint256 nextRewardRemainder = funding % duration;

        periodReward = funding;
        periodStart = currentTime;
        periodFinish = currentTime + duration;
        lastUpdateTime = currentTime;

        SafeTransferLib.safeTransferFrom(REWARD_TOKEN, msg.sender, address(this), amount);
        received = SafeTransferLib.balanceOf(REWARD_TOKEN, address(this)) - balanceBefore;
        if (received != amount) revert UnexpectedRewardAmount(amount, received);

        emit RewardAdded(msg.sender, amount, nextRewardRate, nextRewardRemainder, periodFinish);
    }

    function _authorizedDeposit(uint256 veId) private view returns (Deposit storage deposit) {
        deposit = deposits[veId];
        if (deposit.owner == address(0)) revert NotDeposited();
        if (deposit.owner != msg.sender) revert DepositOwnerOnly();
    }

    function _updateRewardGrowth() private {
        if (totalWeight == 0) {
            uint64 currentTime = uint64(block.timestamp);
            uint64 updatedAt = lastUpdateTime;
            if (currentTime > updatedAt) {
                uint64 finish = periodFinish;
                if (finish > updatedAt) {
                    uint64 idleTime = currentTime - updatedAt;
                    periodStart += idleTime;
                    periodFinish = finish + idleTime;
                }
                lastUpdateTime = currentTime;
            }
            return;
        }

        uint64 applicableTime = lastTimeRewardApplicable();
        rewardGrowthStored = rewardGrowth();
        lastUpdateTime = applicableTime;
    }

    function _vestedReward(uint64 time) private view returns (uint256) {
        uint64 start = periodStart;
        if (time <= start) return 0;

        uint64 finish = periodFinish;
        uint256 reward = periodReward;
        if (time >= finish) return reward;

        return FixedPointMathLib.fullMulDiv(reward, time - start, finish - start);
    }

    function _checkpoint(Deposit storage deposit) private {
        _updateRewardGrowth();
        deposit.accruedReward += FixedPointMathLib.fullMulDiv(
            deposit.weight, rewardGrowthStored - deposit.rewardGrowthSnapshot, REWARD_GROWTH_SCALE
        );
        deposit.rewardGrowthSnapshot = rewardGrowthStored;
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
