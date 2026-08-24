// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {RevenueBuybacks} from "../base/RevenueBuybacks.sol";
import {IOrders} from "../interfaces/IOrders.sol";

/// @title Exchequer Vault
/// @notice One of the two vaults where the Exchequer fee engine lands (whitepaper §11)
/// @dev Deployed twice against the same machinery, differing only in what they buy:
///
///      - the **expansion vault** buys the hard reserve asset (tokenized gold and comparable
///        assets), which the central bank then holds;
///      - the **contraction vault** buys $ISSUE, which the central bank then burns.
///
///      §11 rate-limits contraction buybacks with an hourly `min(0.10 * V, 0.002 * R)` tick so that
///      "defense cannot be baited into one blockable shot". A TWAMM order already is that rate
///      limiter, executed continuously rather than hourly and with no keeper to bait, so the spend
///      rate here is set by the configured order duration instead. A balance sold over ten days
///      spends about a tenth of it per day, matching the launch intent.
///
///      The vault is owned by the central bank. `RevenueBuybacks.collect` is permissionless and
///      delivers to the owner, so everything a vault buys can only ever land at the bank, and the
///      owner's arbitrary `call` is reachable by nobody, because the bank exposes no way to make it.
///      The bank's own owner can configure the order duration and fee through
///      `Exchequer.configureVault`, and nothing else.
contract ExchequerVault is RevenueBuybacks {
    /// @param bank The central bank, which owns the vault and receives everything it buys
    /// @param orders The TWAMM orders contract used to execute buybacks
    /// @param buyToken The asset this vault accumulates
    constructor(address bank, IOrders orders, address buyToken) RevenueBuybacks(bank, orders, buyToken) {}
}
