// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {RevenueBuybacks} from "../base/RevenueBuybacks.sol";
import {IOrders} from "../interfaces/IOrders.sol";
import {TreasuryVault} from "./TreasuryVault.sol";

/// @title RUNR Revenue Buybacks
/// @notice TWAMM buybacks of RUNR whose proceeds are settled into the treasury's RUNR_BUYBACK ledger.
/// @dev Revenue reaches this contract when the RUNR earmark vault's owner withdraws to it. `roll` and
/// `configure` are inherited. Prerequisite: a canonical TWAMM full-range pool for (token, RUNR) at the
/// configured fee must exist with liquidity, otherwise orders cannot execute. The treasury must register
/// this contract as a depositor. The inherited `collect` still pays the owner; use `settle` instead.
contract RunrRevenueBuybacks is RevenueBuybacks {
    TreasuryVault public immutable TREASURY;

    event Settled(address indexed token, uint64 fee, uint64 endTime, uint128 proceeds);

    constructor(address owner, IOrders orders, address runr, TreasuryVault treasury)
        RevenueBuybacks(owner, orders, runr)
    {
        TREASURY = treasury;
    }

    /// @notice Collects RUNR bought by the order for `token` and deposits it into the treasury.
    function settle(address token, uint64 fee, uint64 endTime) external returns (uint128 proceeds) {
        proceeds = ORDERS.collectProceeds(NFT_ID, _createOrderKey(token, fee, 0, endTime), address(this));
        if (proceeds != 0) {
            SafeTransferLib.safeApproveWithRetry(BUY_TOKEN, address(TREASURY), proceeds);
            TREASURY.deposit(BUY_TOKEN, TreasuryVault.Category.RUNR_BUYBACK, proceeds);
        }
        emit Settled(token, fee, endTime, proceeds);
    }
}
