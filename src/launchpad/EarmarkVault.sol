// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Earmark Vault
/// @notice Holds one revenue leg until a future executor is wired in. Deposits come only from the allocator.
/// @dev The owner can withdraw to hand funds to an executor (for example a buybacks contract). Nothing else
/// can move tokens. Per-token cumulative deposits and withdrawals are tracked for analytics.
contract EarmarkVault is Ownable {
    /// @notice The only address permitted to deposit.
    address public immutable ALLOCATOR;

    /// @notice Short label describing the leg this vault holds, e.g. "RUNR buyback".
    bytes32 public immutable PURPOSE;

    /// @notice Cumulative amount deposited per token.
    mapping(address token => uint256 amount) public received;

    /// @notice Cumulative amount withdrawn per token.
    mapping(address token => uint256 amount) public withdrawn;

    error AllocatorOnly();
    error InvalidRecipient();

    event Earmarked(address indexed token, uint256 amount, uint256 cumulative);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    constructor(address owner, address allocator, bytes32 purpose) {
        _initializeOwner(owner);
        ALLOCATOR = allocator;
        PURPOSE = purpose;
    }

    /// @notice Pulls `amount` of `token` from the allocator and records it.
    function deposit(address token, uint256 amount) external {
        if (msg.sender != ALLOCATOR) revert AllocatorOnly();
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        uint256 cumulative = received[token] + amount;
        received[token] = cumulative;
        emit Earmarked(token, amount, cumulative);
    }

    /// @notice Releases `amount` of `token` to `to`, typically a future executor contract.
    function withdraw(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        withdrawn[token] += amount;
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Withdrawn(token, to, amount);
    }
}
