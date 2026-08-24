// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {RevenueBuybacks} from "../base/RevenueBuybacks.sol";
import {IOrders} from "../interfaces/IOrders.sol";

/// @title Standard Vault
/// @notice One of the two vaults where the Standard fee engine lands (whitepaper §11)
/// @dev Deployed twice against the same machinery, differing only in what they buy:
///
///      - the **expansion vault** buys the hard reserve asset (tokenized gold and comparable
///        assets), which the central bank then holds;
///      - the **contraction vault** buys $STANDARD, which the central bank then burns.
///
///      §11 rate-limits contraction buybacks with an hourly `min(0.10 * V, 0.002 * R)` tick so that
///      "defense cannot be baited into one blockable shot". A TWAMM order already is that rate
///      limiter, executed continuously rather than hourly and with no keeper to bait, so the spend
///      rate here is set by the configured order duration instead. A balance sold over ten days
///      spends about a tenth of it per day, matching the launch intent.
///
///      Neither vault can sell what it bought: proceeds only ever move to `RECIPIENT`.
contract StandardVault is RevenueBuybacks {
    /// @notice Fixed destination of everything this vault buys, the central bank
    address public immutable RECIPIENT;

    /// @param owner Administrator able to configure the order duration and fee
    /// @param orders The TWAMM orders contract used to execute buybacks
    /// @param buyToken The asset this vault accumulates
    /// @param recipient The central bank, which holds reserves and burns repurchased currency
    constructor(address owner, IOrders orders, address buyToken, address recipient)
        RevenueBuybacks(owner, orders, buyToken)
    {
        RECIPIENT = recipient;
    }

    /// @notice Collects finished buyback proceeds to the central bank. Permissionless.
    /// @param token The token that was sold, normally the native token
    /// @param fee The fee of the order being collected
    /// @param endTime The end time of the order being collected
    /// @return proceeds Quantity of `BUY_TOKEN` delivered to `RECIPIENT`
    function collectToRecipient(address token, uint64 fee, uint64 endTime) external returns (uint128 proceeds) {
        proceeds = ORDERS.collectProceeds(NFT_ID, _createOrderKey(token, fee, 0, endTime), RECIPIENT);
    }
}
