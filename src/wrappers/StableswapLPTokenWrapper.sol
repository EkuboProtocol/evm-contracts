// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ERC6909} from "solady/tokens/ERC6909.sol";
import {IStableswapLPPositions} from "../interfaces/IStableswapLPPositions.sol";

/// @title StableswapLPTokenWrapper
/// @notice ERC20 wrapper for ERC6909 LP tokens (for lending market compatibility)
/// @dev Provides 1:1 backing: 1 ERC20 = 1 ERC6909 token
/// @author Bogdan Sivochkin
contract StableswapLPTokenWrapper is ERC20 {
    /// @notice The StableswapLPPositions contract (ERC6909 source)
    IStableswapLPPositions public immutable positions;

    /// @notice The pool ID (ERC6909 token ID)
    uint256 public immutable poolId;

    /// @notice Emitted when user wraps ERC6909 → ERC20
    event Wrapped(address indexed user, uint256 amount);

    /// @notice Emitted when user unwraps ERC20 → ERC6909
    event Unwrapped(address indexed user, uint256 amount);

    /// @notice Constructs the wrapper for a specific pool
    /// @param _positions The StableswapLPPositions contract
    /// @param _poolId The pool ID (ERC6909 token ID)
    constructor(IStableswapLPPositions _positions, uint256 _poolId) {
        positions = _positions;
        poolId = _poolId;
    }

    /// @notice Returns the name of the wrapped token
    function name() public view override returns (string memory) {
        return string.concat("Wrapped ", positions.name(poolId));
    }

    /// @notice Returns the symbol of the wrapped token
    function symbol() public view override returns (string memory) {
        return string.concat("w", positions.symbol(poolId));
    }

    /// @notice Returns 18 decimals (matches ERC6909)
    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @notice Wrap ERC6909 tokens into ERC20
    /// @dev User must have approved this contract via ERC6909.approve
    /// @param amount Amount of ERC6909 tokens to wrap
    function wrap(uint256 amount) external {
        // Transfer ERC6909 tokens from user to this contract
        // Cast to ERC6909 to access transferFrom
        ERC6909(address(positions)).transferFrom(msg.sender, address(this), poolId, amount);

        // Mint equivalent ERC20 tokens to user
        _mint(msg.sender, amount);

        emit Wrapped(msg.sender, amount);
    }

    /// @notice Unwrap ERC20 tokens back to ERC6909
    /// @param amount Amount of ERC20 tokens to unwrap
    function unwrap(uint256 amount) external {
        // Burn ERC20 tokens from user
        _burn(msg.sender, amount);

        // Transfer ERC6909 tokens to user
        // Cast to ERC6909 to access transfer
        ERC6909(address(positions)).transfer(msg.sender, poolId, amount);

        emit Unwrapped(msg.sender, amount);
    }

    /// @notice Get the total wrapped supply
    /// @dev This equals the ERC6909 balance held by this contract
    function totalSupply() public view override returns (uint256) {
        // Cast to ERC6909 to access balanceOf
        return ERC6909(address(positions)).balanceOf(address(this), poolId);
    }
}
