// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseNonfungibleToken} from "./base/BaseNonfungibleToken.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ISingleTokenRewards} from "./interfaces/extensions/ISingleTokenRewards.sol";
import {IVeGauge} from "./interfaces/IVeGauge.sol";
import {SingleTokenRewardsLib} from "./libraries/SingleTokenRewardsLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {nextValidTime} from "./math/time.sol";
import {PoolId} from "./types/poolId.sol";
import {PoolKey} from "./types/poolKey.sol";

/// @notice Vote-escrow gauge that receives fees from VePositions and directs emissions to voted pools.
contract VeGauge is IVeGauge, UsesCore, PayableMulticallable, BaseLocker, BaseNonfungibleToken {
    using SingleTokenRewardsLib for ICore;
    using FlashAccountantLib for *;

    uint256 public constant MAX_LOCK_DURATION = 4 * 365 days;
    uint256 public constant EMISSION_DURATION = 7 days;
    uint256 private constant CALL_TYPE_TRIGGER_POOL_EMISSIONS = 0;

    ICore public immutable core;
    address public immutable positions;
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
    }

    struct VePoolPosition {
        uint256 weight;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
        uint256 accrued0;
        uint256 accrued1;
    }

    mapping(uint256 => Lock) public locks;
    mapping(uint256 => PoolId[]) public votedPools;
    mapping(uint256 => mapping(PoolId => VePoolPosition)) public vePoolPositions;
    mapping(PoolId => PoolVoteState) public poolVoteStates;

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

    error InvalidLock();
    error InvalidVote();
    error EmissionAmountTooSmall();
    error RewardTokenMismatch();
    error PositionsOnly();

    constructor(ICore _core, address owner, address _positions, address _stakeToken)
        BaseNonfungibleToken(owner)
        BaseLocker(_core)
        UsesCore(_core)
    {
        core = _core;
        positions = _positions;
        stakeToken = _stakeToken;
        emissionsLastAccrued = uint64(block.timestamp);
        totalVoteSecondsLastAccrued = uint64(block.timestamp);
    }

    receive() external payable {}

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

    function vote(uint256 veId, PoolId[] calldata poolIds, uint256[] calldata weights) external authorizedForNft(veId) {
        if (poolIds.length != weights.length) revert InvalidVote();

        uint256 power = votingPower(veId);
        if (power == 0) revert InvalidVote();

        uint256 totalWeight;
        for (uint256 i = 0; i < weights.length; i++) {
            totalWeight += weights[i];
            for (uint256 j = 0; j < i; j++) {
                if (PoolId.unwrap(poolIds[i]) == PoolId.unwrap(poolIds[j])) revert InvalidVote();
            }
        }
        if (totalWeight == 0) revert InvalidVote();

        _clearVotes(veId);
        _accrueTotalVoteSeconds();

        for (uint256 i = 0; i < poolIds.length; i++) {
            uint256 weight = (power * weights[i]) / totalWeight;
            if (weight == 0) continue;

            PoolId poolId = poolIds[i];
            _accruePoolVoteSeconds(poolId);

            PoolVoteState storage poolState = poolVoteStates[poolId];
            VePoolPosition storage vePool = vePoolPositions[veId][poolId];

            poolState.weight += weight;
            totalVoteWeight += weight;

            vePool.weight = weight;
            vePool.feeGrowth0X128 = poolState.feeGrowth0X128;
            vePool.feeGrowth1X128 = poolState.feeGrowth1X128;
            votedPools[veId].push(poolId);
        }

        emit Voted(veId);
    }

    function notifyPoolFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) external {
        if (msg.sender != positions) revert PositionsOnly();
        _accountPoolFees(poolKey, amount0, amount1);
    }

    function claimPoolFees(uint256 veId, PoolKey memory poolKey)
        external
        authorizedForNft(veId)
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
            _transferToken(poolKey.token0, recipient, amount0);
            _transferToken(poolKey.token1, recipient, amount1);
        }

        emit PoolFeesClaimed(veId, poolId, ownerOf(veId), amount0, amount1);
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
        amount = abi.decode(lock(abi.encode(CALL_TYPE_TRIGGER_POOL_EMISSIONS, poolKey)), (uint224));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_TRIGGER_POOL_EMISSIONS) {
            (, PoolKey memory poolKey) = abi.decode(data, (uint256, PoolKey));
            result = abi.encode(_triggerPoolEmissions(poolKey));
        } else {
            revert();
        }
    }

    function _accountPoolFees(PoolKey memory poolKey, uint128 amount0, uint128 amount1) private {
        if (amount0 == 0 && amount1 == 0) return;

        PoolId poolId = poolKey.toPoolId();
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

    function _triggerPoolEmissions(PoolKey memory poolKey) private returns (uint224 amount) {
        if (ISingleTokenRewards(poolKey.config.extension()).rewardToken() != stakeToken) revert RewardTokenMismatch();

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

        amount = CORE.addRewards(poolKey, 0, uint64(endTime), rewardRate);
        emissionReserve -= amount;
        if (amount != 0) ACCOUNTANT.pay(stakeToken, amount);

        emit PoolEmissionsTriggered(poolId, amount, uint64(endTime));
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
                poolVoteStates[poolId].weight -= weight;
                totalVoteWeight -= weight;
                vePool.weight = 0;
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

    function _transferToken(address token, address recipient, uint128 amount) private {
        if (amount == 0) return;
        if (token == NATIVE_TOKEN_ADDRESS) {
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(token, recipient, amount);
        }
    }
}
