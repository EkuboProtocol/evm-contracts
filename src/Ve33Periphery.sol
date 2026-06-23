// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {Ve33} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {Ve33Lib} from "./libraries/Ve33Lib.sol";
import {PoolKey} from "./types/poolKey.sol";

/// @notice Token-settling periphery for Ve33 forwarded actions.
/// @dev Ve33 accounts saved balances during `forward`; this contract pays or withdraws the corresponding tokens.
contract Ve33Periphery is BaseLocker {
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_DONATE_REWARDS = 0;
    uint256 private constant CALL_TYPE_SCHEDULE_REWARDS = 1;
    uint256 private constant CALL_TYPE_SCHEDULE_EMISSIONS = 2;

    ICore private immutable CORE_REF;

    Ve33 public immutable ve33;
    address public immutable stakeToken;

    /// @notice Creates the Ve33 token-settling periphery.
    /// @param core Ekubo Core contract used for locks and settlement.
    /// @param _ve33 Ve33 extension this periphery settles for.
    constructor(ICore core, Ve33 _ve33) BaseLocker(core) {
        CORE_REF = core;
        ve33 = _ve33;
        stakeToken = _ve33.stakeToken();
    }

    receive() external payable {}

    /// @notice Donates stake tokens immediately to current eligible LP liquidity.
    /// @param poolKey Pool receiving the donation.
    /// @param amount Amount of stake token to donate.
    /// @return donated Amount accepted by Ve33.
    function donateRewards(PoolKey memory poolKey, uint128 amount) external returns (uint128 donated) {
        donated = abi.decode(lock(abi.encode(CALL_TYPE_DONATE_REWARDS, msg.sender, poolKey, amount)), (uint128));
    }

    /// @notice Schedules stake-token LP rewards for a pool.
    /// @param poolKey Pool receiving rewards.
    /// @param startTime Reward schedule start time, or zero for immediate start.
    /// @param endTime Reward schedule end time.
    /// @param rewardRate Q32 reward rate in stake tokens per second.
    /// @return amount Amount of stake token required by the schedule.
    function scheduleRewards(PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate)
        external
        returns (uint224 amount)
    {
        amount = abi.decode(
            lock(abi.encode(CALL_TYPE_SCHEDULE_REWARDS, msg.sender, poolKey, startTime, endTime, rewardRate)), (uint224)
        );
    }

    /// @notice Schedules global Ve33 emissions.
    /// @param startTime Emission schedule start time, or zero for immediate start.
    /// @param endTime Valid timestamp when the emission stream ends.
    /// @param rewardRate Q32 global emission rate in stake tokens per second.
    /// @return amount Amount of stake token required by the schedule.
    function scheduleEmissions(uint64 startTime, uint64 endTime, uint224 rewardRate) external returns (uint224 amount) {
        amount = abi.decode(
            lock(abi.encode(CALL_TYPE_SCHEDULE_EMISSIONS, msg.sender, startTime, endTime, rewardRate)), (uint224)
        );
    }

    /// @inheritdoc BaseLocker
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_DONATE_REWARDS) {
            (, address payer, PoolKey memory poolKey, uint128 amount) =
                abi.decode(data, (uint256, address, PoolKey, uint128));
            uint128 donated = Ve33Lib.donateRewards(CORE_REF, ve33, poolKey, amount);
            result = abi.encode(donated);
            if (donated != 0) ACCOUNTANT.payFrom(payer, stakeToken, donated);
        } else if (callType == CALL_TYPE_SCHEDULE_REWARDS) {
            (, address payer, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate) =
                abi.decode(data, (uint256, address, PoolKey, uint64, uint64, uint224));
            uint224 amount = Ve33Lib.scheduleRewards(CORE_REF, ve33, poolKey, startTime, endTime, rewardRate);
            result = abi.encode(amount);
            if (amount != 0) ACCOUNTANT.payFrom(payer, stakeToken, amount);
        } else if (callType == CALL_TYPE_SCHEDULE_EMISSIONS) {
            (, address payer, uint64 startTime, uint64 endTime, uint224 rewardRate) =
                abi.decode(data, (uint256, address, uint64, uint64, uint224));
            uint224 amount = Ve33Lib.scheduleEmissions(CORE_REF, ve33, startTime, endTime, rewardRate);
            result = abi.encode(amount);
            if (amount != 0) ACCOUNTANT.payFrom(payer, stakeToken, amount);
        } else {
            revert();
        }
    }
}
