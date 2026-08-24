// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title Issue
/// @notice The single currency of the Exchequer closed monetary economy
/// @dev Minted only by the central bank, and only at a withdrawal or at genesis. Burned by expansion
///      licenses, open market buybacks, and half of every resolution fee.
///
///      Supply obeys whitepaper eq 3.1 at every block:
///        totalSupply() == GENESIS_LIQUIDITY + withdrawalMints - cumulativeBurns
///      and because burns are permanent, eq 3.2 gives a strictly non-increasing ceiling:
///        maxSupply() == HARD_CAP - cumulativeBurns
contract IssueToken is ERC20 {
    /// @notice The maximum quantity that may ever be minted, cumulatively, across all time
    uint256 public constant HARD_CAP = 1_000_000_000e18;

    /// @notice The central bank, the only address permitted to mint
    address public immutable MINTER;

    /// @notice Cumulative quantity ever minted. Never decreases, so burns do not free headroom.
    uint256 public totalMinted;

    /// @notice Cumulative quantity ever burned
    uint256 public totalBurned;

    /// @notice Thrown when an address other than the central bank attempts to mint
    error MinterOnly();

    /// @notice Thrown when a mint would push cumulative issuance past the hard cap
    error HardCapExceeded();

    /// @notice Emitted whenever supply is permanently destroyed
    event Burned(address indexed from, uint256 amount);

    /// @dev The deployer is the central bank
    constructor() {
        MINTER = msg.sender;
    }

    /// @inheritdoc ERC20
    function name() public pure override returns (string memory) {
        return "Issue";
    }

    /// @inheritdoc ERC20
    function symbol() public pure override returns (string memory) {
        return "ISSUE";
    }

    /// @notice Mints `amount` to `to`, subject to the cumulative hard cap
    /// @param to Recipient of the newly minted currency
    /// @param amount Quantity to mint
    function mint(address to, uint256 amount) external {
        if (msg.sender != MINTER) revert MinterOnly();

        uint256 minted = totalMinted + amount;
        if (minted > HARD_CAP) revert HardCapExceeded();
        totalMinted = minted;

        _mint(to, amount);
    }

    /// @notice Permanently destroys `amount` from the caller's balance
    /// @param amount Quantity to burn
    function burn(uint256 amount) external {
        unchecked {
            totalBurned += amount;
        }
        _burn(msg.sender, amount);

        emit Burned(msg.sender, amount);
    }

    /// @notice The largest supply that can ever exist from here forward (whitepaper eq 3.2)
    /// @return The hard cap less everything ever burned
    function maxSupply() external view returns (uint256) {
        unchecked {
            return HARD_CAP - totalBurned;
        }
    }
}
