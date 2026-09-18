// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {EarmarkVault} from "./EarmarkVault.sol";

/// @title Holder Vault
/// @notice Receives the holder share of launchpad revenue. V1 only earmarks: per-token accounting and events.
/// @dev No claim logic exists in V1. A V2 distributor will receive the balance through the owner-only
/// withdraw inherited from EarmarkVault; until then nothing else can move tokens.
contract HolderVault is EarmarkVault {
    constructor(address owner, address allocator) EarmarkVault(owner, allocator, "RUNR holders") {}
}
