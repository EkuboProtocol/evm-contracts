// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Treasury Vault
/// @notice Unified ERC20 custody for the RUNR launchpad with per-token, per-category sub-ledgers.
/// @dev Deposits are pulled with transferFrom from approved depositors (or the owner) so the ledger can only
/// grow by tokens that actually arrived. Only the owner can withdraw or reclassify. Native ETH is unsupported.
contract TreasuryVault is Ownable {
    /// @notice Accounting buckets. Tokens are fungible across buckets; the ledger is a governance commitment.
    enum Category {
        UNRESTRICTED,
        RUNR_BUYBACK,
        ECO_BUYBACK,
        BOND
    }

    /// @notice Addresses allowed to deposit besides the owner (revenue allocator, bond depository, buybacks).
    mapping(address depositor => bool allowed) public depositors;

    /// @notice Amount attributed to each token and category.
    mapping(address token => mapping(Category category => uint256 amount)) public ledger;

    error DepositorOnly();
    error InsufficientLedger();
    error InvalidRecipient();

    event DepositorUpdated(address indexed depositor, bool allowed);
    event Deposited(address indexed token, Category indexed category, address indexed from, uint256 amount);
    event Withdrawn(address indexed token, Category indexed category, address indexed to, uint256 amount);
    event Reclassified(address indexed token, Category indexed from, Category indexed to, uint256 amount);

    constructor(address owner) {
        _initializeOwner(owner);
    }

    /// @notice Grants or revokes deposit rights.
    function setDepositor(address depositor, bool allowed) external onlyOwner {
        depositors[depositor] = allowed;
        emit DepositorUpdated(depositor, allowed);
    }

    /// @notice Pulls `amount` of `token` from the caller and books it under `category`.
    function deposit(address token, Category category, uint256 amount) external {
        if (!depositors[msg.sender] && msg.sender != owner()) revert DepositorOnly();
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        ledger[token][category] += amount;
        emit Deposited(token, category, msg.sender, amount);
    }

    /// @notice Sends `amount` of `token` booked under `category` to `to`.
    function withdraw(address token, Category category, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        _debit(token, category, amount);
        SafeTransferLib.safeTransfer(token, to, amount);
        emit Withdrawn(token, category, to, amount);
    }

    /// @notice Moves `amount` of `token` between categories without moving tokens.
    function reclassify(address token, Category from, Category to, uint256 amount) external onlyOwner {
        _debit(token, from, amount);
        ledger[token][to] += amount;
        emit Reclassified(token, from, to, amount);
    }

    function _debit(address token, Category category, uint256 amount) private {
        uint256 booked = ledger[token][category];
        if (booked < amount) revert InsufficientLedger();
        ledger[token][category] = booked - amount;
    }
}
