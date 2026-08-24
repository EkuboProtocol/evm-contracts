// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @notice The subset of the central bank that the share token needs
interface IBankShareHook {
    /// @notice Advances global issuance and settles the accrued ledger balance of both parties
    /// @dev Must be invoked before any balance changes, so each party's accrual is computed against
    ///      the balance they actually held while it was accruing
    function settleShares(address a, address b) external;
}

/// @title Bank
/// @notice The branch share of the Standard economy. One whole token is one branch.
/// @dev The whitepaper wraps branches in a soulbound charter NFT; this implementation collapses both
///      into a single fungible share, so a balance is a bank and every whole unit of it is a branch.
///      Selling shares is therefore §12's "seat sale": an exit with zero sell pressure on $ISSUE,
///      because the buyer replaces the seller one for one, ledger balance included.
///
///      Every balance change settles the accrued issuance of both parties first, so a transfer moves
///      the future yield of the share without moving anything already earned by the seller.
contract BankToken is ERC20 {
    /// @notice The central bank, the only address permitted to mint or burn
    address public immutable BANK;

    /// @notice Thrown when an address other than the central bank attempts to mint or burn
    error CentralBankOnly();

    /// @dev The deployer is the central bank
    constructor() {
        BANK = msg.sender;
    }

    modifier onlyBank() {
        if (msg.sender != BANK) revert CentralBankOnly();
        _;
    }

    /// @inheritdoc ERC20
    function name() public pure override returns (string memory) {
        return "Bank";
    }

    /// @inheritdoc ERC20
    function symbol() public pure override returns (string memory) {
        return "BANK";
    }

    /// @notice Opens `amount` of new branches for `to`
    function mint(address to, uint256 amount) external onlyBank {
        _mint(to, amount);
    }

    /// @notice Retires `amount` of branches held by `from`
    function burn(address from, uint256 amount) external onlyBank {
        _burn(from, amount);
    }

    /// @inheritdoc ERC20
    /// @dev Fires for transfers, mints (`from == address(0)`) and burns (`to == address(0)`) alike.
    ///      The bank ignores the zero address.
    function _beforeTokenTransfer(address from, address to, uint256) internal override {
        IBankShareHook(BANK).settleShares(from, to);
    }
}
