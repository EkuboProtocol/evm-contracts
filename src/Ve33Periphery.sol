// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {
    Ve33,
    VE33_ADD_REWARDS,
    VE33_DONATE_REWARDS,
    VE33_FUND_EMISSIONS,
    VE33_SWAP,
    VE33_TRIGGER_POOL_EMISSIONS
} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolState} from "./types/poolState.sol";
import {SwapParameters} from "./types/swapParameters.sol";

/// @notice Token-settling periphery for Ve33 forwarded actions.
/// @dev Ve33 accounts saved balances during `forward`; this contract pays or withdraws the corresponding tokens.
contract Ve33Periphery is BaseLocker {
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_SWAP = 0;
    uint256 private constant CALL_TYPE_DONATE_REWARDS = 1;
    uint256 private constant CALL_TYPE_ADD_REWARDS = 2;
    uint256 private constant CALL_TYPE_FUND_EMISSIONS = 3;
    uint256 private constant CALL_TYPE_TRIGGER_POOL_EMISSIONS = 4;

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

    /// @notice Swaps through a Ve33 pool and settles token deltas with the caller and recipient.
    /// @dev The caller or router must set the intended sqrt-ratio limit before calling.
    /// @param poolKey Pool to swap against.
    /// @param params Swap parameters forwarded to Ve33.
    /// @param recipient Account receiving output tokens.
    /// @return balanceUpdate Final token deltas including Ve33 voter fees.
    /// @return stateAfter Core pool state after the swap.
    function swap(PoolKey memory poolKey, SwapParameters params, address recipient)
        external
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) = abi.decode(
            lock(abi.encode(CALL_TYPE_SWAP, msg.sender, poolKey, params, recipient)), (PoolBalanceUpdate, PoolState)
        );
    }

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
    function addRewards(PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate)
        external
        returns (uint224 amount)
    {
        amount = abi.decode(
            lock(abi.encode(CALL_TYPE_ADD_REWARDS, msg.sender, poolKey, startTime, endTime, rewardRate)), (uint224)
        );
    }

    /// @notice Funds global Ve33 emissions for one emission duration.
    /// @param amount Amount of stake token to fund.
    /// @return rate Added Q32 global emission rate.
    /// @return end Timestamp when the funded emission stream ends.
    function fundEmissions(uint128 amount) external returns (uint224 rate, uint64 end) {
        (rate, end) = abi.decode(lock(abi.encode(CALL_TYPE_FUND_EMISSIONS, msg.sender, amount)), (uint224, uint64));
    }

    /// @notice Assigns a voted pool's share of funded emissions to LP rewards.
    /// @param poolKey Pool receiving its accrued emission share.
    /// @return amount Amount scheduled as pool LP rewards.
    function triggerPoolEmissions(PoolKey memory poolKey) external returns (uint224 amount) {
        amount = abi.decode(lock(abi.encode(CALL_TYPE_TRIGGER_POOL_EMISSIONS, poolKey)), (uint224));
    }

    /// @inheritdoc BaseLocker
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_SWAP) {
            (, address payer, PoolKey memory poolKey, SwapParameters params, address recipient) =
                abi.decode(data, (uint256, address, PoolKey, SwapParameters, address));
            (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) = abi.decode(
                CORE_REF.forward(poolKey.config.extension(), abi.encode(VE33_SWAP, poolKey, params)),
                (PoolBalanceUpdate, PoolState)
            );
            _settle(poolKey, payer, recipient, balanceUpdate);
            result = abi.encode(balanceUpdate, stateAfter);
        } else if (callType == CALL_TYPE_DONATE_REWARDS) {
            (, address payer, PoolKey memory poolKey, uint128 amount) =
                abi.decode(data, (uint256, address, PoolKey, uint128));
            result = CORE_REF.forward(poolKey.config.extension(), abi.encode(VE33_DONATE_REWARDS, poolKey, amount));
            uint128 donated = abi.decode(result, (uint128));
            if (donated != 0) ACCOUNTANT.payFrom(payer, stakeToken, donated);
        } else if (callType == CALL_TYPE_ADD_REWARDS) {
            (, address payer, PoolKey memory poolKey, uint64 startTime, uint64 endTime, uint224 rewardRate) =
                abi.decode(data, (uint256, address, PoolKey, uint64, uint64, uint224));
            result = CORE_REF.forward(
                poolKey.config.extension(), abi.encode(VE33_ADD_REWARDS, poolKey, startTime, endTime, rewardRate)
            );
            uint224 amount = abi.decode(result, (uint224));
            if (amount != 0) ACCOUNTANT.payFrom(payer, stakeToken, amount);
        } else if (callType == CALL_TYPE_FUND_EMISSIONS) {
            (, address payer, uint128 amount) = abi.decode(data, (uint256, address, uint128));
            result = CORE_REF.forward(address(ve33), abi.encode(VE33_FUND_EMISSIONS, amount));
            if (amount != 0) ACCOUNTANT.payFrom(payer, stakeToken, amount);
        } else if (callType == CALL_TYPE_TRIGGER_POOL_EMISSIONS) {
            (, PoolKey memory poolKey) = abi.decode(data, (uint256, PoolKey));
            result = CORE_REF.forward(address(ve33), abi.encode(VE33_TRIGGER_POOL_EMISSIONS, poolKey));
        } else {
            revert();
        }
    }

    function _settle(PoolKey memory poolKey, address payer, address recipient, PoolBalanceUpdate balanceUpdate)
        private
    {
        int128 delta0_ = balanceUpdate.delta0();
        int128 delta1_ = balanceUpdate.delta1();

        unchecked {
            if (delta0_ > 0) {
                ACCOUNTANT.payFrom(payer, poolKey.token0, uint128(delta0_));
            } else if (delta0_ < 0) {
                ACCOUNTANT.withdraw(poolKey.token0, recipient, uint128(-delta0_));
            }

            if (delta1_ > 0) {
                ACCOUNTANT.payFrom(payer, poolKey.token1, uint128(delta1_));
            } else if (delta1_ < 0) {
                ACCOUNTANT.withdraw(poolKey.token1, recipient, uint128(-delta1_));
            }
        }
    }
}
