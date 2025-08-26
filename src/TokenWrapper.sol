// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ERC20} from "solady/tokens/ERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {toDate, toQuarter} from "./libraries/TimeDescriptor.sol";

/// @title TokenWrapper - Time-locked token wrapper
/// @notice Wraps tokens that can only be unwrapped after a specific unlock time
contract TokenWrapper is ERC20 {
    using SafeTransferLib for address;

    /// @dev Returns the immutable arguments
    function args() private view returns (ERC20 token, uint256 unlock) {
        assembly ("memory-safe") {
            extcodecopy(address(), 0, 0x2d, 0x40)
            token := mload(0x00)
            unlock := mload(0x20)
        }
    }

    /// @notice The underlying token being wrapped
    function underlyingToken() external view returns (ERC20) {
        (ERC20 token,) = args();
        return token;
    }

    /// @notice Timestamp when tokens can be unwrapped
    function unlockTime() external view returns (uint256) {
        (, uint256 unlock) = args();
        return unlock;
    }

    function name() public view override returns (string memory) {
        (ERC20 underlying, uint256 unlock) = args();

        return string.concat(underlying.name(), " ", toDate(unlock));
    }

    function symbol() public view override returns (string memory) {
        (ERC20 underlying, uint256 unlock) = args();
        return string.concat("g", underlying.symbol(), "-", toQuarter(unlock));
    }

    function decimals() public view override returns (uint8) {
        (ERC20 underlying,) = args();
        return underlying.decimals();
    }

    /// @notice Thrown when trying to unwrap before unlock time
    error TooEarly();

    /// @notice Wrap underlying tokens to receive wrapper tokens
    function wrap(uint256 amount) external {
        (ERC20 underlying,) = args();
        address(underlying).safeTransferFrom(msg.sender, address(this), amount);
        _mint(msg.sender, amount);
    }

    function unwrap(uint256 amount) external {
        unwrapFrom(msg.sender, msg.sender, amount);
    }

    function unwrapTo(address recipient, uint256 amount) external {
        unwrapFrom(msg.sender, recipient, amount);
    }

    /// @notice Unwrap tokens to receive underlying tokens (only after unlock time)
    function unwrapFrom(address owner, address recipient, uint256 amount) public {
        (ERC20 underlying, uint256 unlock) = args();
        if (block.timestamp < unlock) revert TooEarly();

        if (owner != msg.sender) {
            _spendAllowance(owner, msg.sender, amount);
        }

        _burn(owner, amount);
        address(underlying).safeTransfer(recipient, amount);
    }
}
