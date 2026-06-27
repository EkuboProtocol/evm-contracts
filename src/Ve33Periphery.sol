// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {Ve33} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {Ve33Lib} from "./libraries/Ve33Lib.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Token-settling periphery for Ve33 forwarded actions.
/// @dev Ve33 accounts saved balances during `forward`; this contract pays or withdraws the corresponding tokens.
contract Ve33Periphery is PayableMulticallable, BaseLocker {
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_SCHEDULE_EMISSIONS = 0;

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

    /// @notice Schedules global Ve33 emissions.
    /// @param startTime Real emission schedule start time, or zero for immediate start.
    /// @param endTime Valid real timestamp when the emission stream ends.
    /// @param rewardRate Q32 global emission rate in stake tokens per second.
    /// @return amount Amount of stake token required by the schedule.
    function scheduleEmissions(uint64 startTime, uint64 endTime, uint160 rewardRate)
        external
        payable
        returns (uint128 amount)
    {
        amount = abi.decode(
            lock(abi.encode(CALL_TYPE_SCHEDULE_EMISSIONS, msg.sender, startTime, endTime, rewardRate)), (uint128)
        );
    }

    /// @inheritdoc BaseLocker
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_SCHEDULE_EMISSIONS) {
            (, address payer, uint64 startTime, uint64 endTime, uint160 rewardRate) =
                abi.decode(data, (uint256, address, uint64, uint64, uint160));
            uint128 amount = Ve33Lib.scheduleEmissions(CORE_REF, ve33, startTime, endTime, rewardRate);
            result = abi.encode(amount);
            if (amount != 0) {
                if (stakeToken == NATIVE_TOKEN_ADDRESS) {
                    SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount);
                } else {
                    ACCOUNTANT.payFrom(payer, stakeToken, amount);
                }
            }
        } else {
            revert();
        }
    }
}
