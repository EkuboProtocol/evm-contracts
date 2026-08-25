// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {RevenueBuybacks} from "../base/RevenueBuybacks.sol";
import {IOrders} from "../interfaces/IOrders.sol";

/// @title Exchequer Vault
/// @notice The expansion vault, where the fee engine lands in expansion epochs (whitepaper §11)
/// @dev Receives ETH from `Exchequer.flush` and sells it through a TWAMM order for the hard
///      reserve asset (tokenized gold and comparable assets), which the bank then holds. There is
///      no canonical market for the reserve asset, so this is the one place the economy trades
///      through a TWAMM pool; its order duration is the spend rate. Contraction epochs never come
///      here: buybacks are standing bids placed by the bank itself, see `Exchequer.defend`.
///
///      The vault is owned by the bank. `RevenueBuybacks.collect` is permissionless and delivers to
///      the owner, so everything the vault buys can only ever land at the bank, and the owner's
///      arbitrary `call` is reachable by nobody, because the bank exposes no way to make it. The
///      bank's own owner can configure the order duration and fee through
///      `Exchequer.configureExpansionVault`, and nothing else.
contract ExchequerVault is RevenueBuybacks {
    /// @param bank The central bank, which owns the vault and receives everything it buys
    /// @param orders The TWAMM orders contract used to execute buybacks
    /// @param buyToken The asset this vault accumulates
    constructor(address bank, IOrders orders, address buyToken) RevenueBuybacks(bank, orders, buyToken) {}
}
