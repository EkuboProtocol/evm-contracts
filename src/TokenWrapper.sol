// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {LibClone} from "solady/utils/LibClone.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseForwardee} from "./base/BaseForwardee.sol";
import {ICore} from "./interfaces/ICore.sol";
import {toDate, toQuarter} from "./libraries/TimeDescriptor.sol";
import {CoreLib} from "./libraries/CoreLib.sol";

/// @title TokenWrapper - Time-locked token wrapper
/// @notice Wraps tokens that can only be unwrapped after a specific unlock time
contract TokenWrapper is IERC20, BaseLocker, BaseForwardee {
    using CoreLib for *;

    /// @notice Thrown when trying to unwrap before the token has unlocked
    error TooEarly();

    /// @notice Thrown when trying to use an amount greater than type(uint128).max
    error AmountTooLarge();

    /// @notice Thrown when calling transferFrom with an insufficient allowance
    error InsufficientAllowance();

    /// @notice Returns the amount of tokens in existence.
    uint256 public override totalSupply;

    mapping(address owner => mapping(address spender => uint256)) public override allowance;

    constructor(ICore core) BaseLocker(core) BaseForwardee(core) {}

    /// @dev Returns the immutable arguments in the clone
    function args() private view returns (IERC20 token, uint64 unlock) {
        assembly ("memory-safe") {
            extcodecopy(address(), 0, 0x2d, 0x1c)
            token := shr(96, mload(0x00))
            unlock := shr(192, mload(0x14))
        }
    }

    /// @notice The underlying token being wrapped
    function underlyingToken() external view returns (IERC20) {
        (IERC20 token,) = args();
        return token;
    }

    /// @notice Timestamp when tokens can be unwrapped
    function unlockTime() external view returns (uint64) {
        (, uint64 unlock) = args();
        return unlock;
    }

    function name() external view override returns (string memory) {
        (IERC20 underlying, uint64 unlock) = args();

        return string.concat(underlying.name(), " ", toDate(unlock));
    }

    function symbol() external view override returns (string memory) {
        (IERC20 underlying, uint64 unlock) = args();
        return string.concat("g", underlying.symbol(), "-", toQuarter(unlock));
    }

    function decimals() external view override returns (uint8) {
        (IERC20 underlying,) = args();
        return underlying.decimals();
    }

    /// @notice Returns the amount of tokens owned by `account`.
    function balanceOf(address account) external view override returns (uint256) {
        (IERC20 token,) = args();
        return
            uint256(ICore(payable(accountant)).savedBalances(address(this), address(token), bytes32(bytes20(account))));
    }

    /// @notice Moves `amount` tokens from the caller's account to `to`.
    function transfer(address to, uint256 amount) external returns (bool) {
        if (amount > type(uint128).max) {
            revert AmountTooLarge();
        }
        lock(abi.encode(uint256(0), msg.sender, to, amount));
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 allowanceCurrent = allowance[owner][spender];
        if (allowanceCurrent != type(uint256).max) {
            if (allowanceCurrent < amount) revert InsufficientAllowance();
            unchecked {
                allowance[owner][spender] = allowanceCurrent - amount;
            }
        }
    }

    /// @notice Moves `amount` tokens from `from` to `to` using the allowance mechanism.
    /// `amount` is then deducted from the caller's allowance.
    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        _spendAllowance(from, to, amount);
        if (amount > type(uint128).max) revert AmountTooLarge();
        lock(abi.encode(uint256(0), from, to, amount));
    }

    error UnrecognizedCallType();

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        uint256 callType;

        assembly ("memory-safe") {
            callType := mload(add(data, 0x20))
        }

        if (callType == 0) {
            // transfer
            (IERC20 token,) = args();
            // decoding amount as a uint128 because the bounds are checked in transfer
            (, address sender, address recipient, uint128 amount) =
                abi.decode(data, (uint256, address, address, uint128));
            ICore(payable(accountant)).load(address(token), bytes32(bytes20(sender)), amount);
            ICore(payable(accountant)).save(address(this), address(token), bytes32(bytes20(recipient)), amount);
        } else if (callType == 1) {
            // wrap
            (IERC20 token,) = args();

            // decoding amount as a uint128 because the bounds are checked in transfer
            (, address payer, address recipient, uint128 amount) =
                abi.decode(data, (uint256, address, address, uint128));

            ICore(payable(accountant)).save(address(this), address(token), bytes32(bytes20(recipient)), amount);

            pay(payer, address(token), amount);
        } else if (callType == 2) {
            // unwrap
            (IERC20 token, uint64 unlock) = args();

            if (block.timestamp < unlock) revert TooEarly();

            // decoding amount as a uint128 because the bounds are checked in transfer
            (, address owner, address recipient, uint128 amount) =
                abi.decode(data, (uint256, address, address, uint128));

            ICore(payable(accountant)).load(address(token), bytes32(bytes20(owner)), amount);
            ICore(payable(accountant)).withdraw(address(token), recipient, amount);
        } else {
            revert UnrecognizedCallType();
        }
    }

    function handleForwardData(uint256 id, address originalLocker, bytes memory data)
        internal
        override
        returns (bytes memory result)
    {}

    function wrap(uint128 amount) external {
        wrapTo(amount, msg.sender);
    }

    /// @notice Wrap underlying tokens to receive wrapper tokens
    function wrapTo(uint128 amount, address recipient) public {
        lock(abi.encode(uint256(1), msg.sender, recipient, amount));
    }

    function unwrap(uint128 amount) external {
        unwrapFrom(msg.sender, msg.sender, amount);
    }

    function unwrapTo(address recipient, uint128 amount) external {
        unwrapFrom(msg.sender, recipient, amount);
    }

    /// @notice Unwrap tokens to receive underlying tokens (only after unlock time)
    function unwrapFrom(address owner, address recipient, uint128 amount) public {
        if (owner != msg.sender) {
            _spendAllowance(owner, msg.sender, amount);
        }

        lock(abi.encode(uint256(2), owner, recipient, amount));
    }
}

/// @title TokenWrapperFactory - Factory for creating time-locked token wrappers
/// @notice Creates TokenWrapper contracts with formatted names and symbols based on unlock dates
contract TokenWrapperFactory {
    event TokenWrapperDeployed(IERC20 underlyingToken, uint256 unlockTime, TokenWrapper tokenWrapper);

    TokenWrapper public immutable implementation;

    constructor(ICore core) {
        implementation = new TokenWrapper(core);
    }

    /// @notice Deploy a new TokenWrapper with auto-generated name and symbol
    /// @param underlyingToken The token to be wrapped
    /// @param unlockTime Timestamp when tokens can be unwrapped
    /// @return tokenWrapper The deployed TokenWrapper contract
    function deployWrapper(IERC20 underlyingToken, uint64 unlockTime) external returns (TokenWrapper tokenWrapper) {
        bytes32 salt = keccak256(abi.encode(underlyingToken, unlockTime));

        tokenWrapper = TokenWrapper(
            LibClone.cloneDeterministic(address(implementation), abi.encodePacked(underlyingToken, unlockTime), salt)
        );

        emit TokenWrapperDeployed(underlyingToken, unlockTime, tokenWrapper);
    }
}
