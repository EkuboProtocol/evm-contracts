// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {BaseForwardee} from "./base/BaseForwardee.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {toDate, toQuarter} from "./libraries/TimeDescriptor.sol";
import {CoreLib} from "./libraries/CoreLib.sol";

/// @title Time-locked token wrapper
/// @notice Wraps tokens that can only be unwrapped after a specific unlock time. Wrapping and unwrapping happens via Ekubo Core#forward.
contract TokenWrapper is UsesCore, IERC20, BaseForwardee {
    using CoreLib for *;

    /// @notice Thrown when trying to unwrap the token before the token has unlocked
    error TooEarly();

    /// @notice Thrown when attempting to transfer an amount greater than the balance
    error InsufficientBalance();

    /// @notice Thrown when calling transferFrom with an insufficient allowance
    error InsufficientAllowance();

    /// @notice The token that is wrapped
    IERC20 public immutable underlyingToken;

    /// @notice The time after which the token may be unwrapped
    uint256 public immutable unlockTime;

    constructor(ICore core, IERC20 _underlyingToken, uint256 _unlockTime) UsesCore(core) BaseForwardee(core) {
        underlyingToken = _underlyingToken;
        unlockTime = _unlockTime;
    }

    /// @inheritdoc IERC20
    mapping(address owner => mapping(address spender => uint256)) public override allowance;

    /// @dev Not public because we use coreBalance for Core
    mapping(address account => uint256) private _balanceOf;

    /// @dev Transient storage slot 0
    /// @dev Core never actually holds a real balance of this token, we just use this transient balance to enable low cost payments to core
    uint256 private transient coreBalance;

    /// @inheritdoc IERC20
    function balanceOf(address account) external view returns (uint256) {
        if (account == address(core)) return coreBalance;
        return _balanceOf[account];
    }

    /// @inheritdoc IERC20
    function totalSupply() external view override returns (uint256) {
        (uint128 supply,) = core.savedBalances({
            owner: address(this),
            token0: address(underlyingToken),
            token1: address(type(uint160).max),
            salt: bytes32(0)
        });

        return supply;
    }

    /// @inheritdoc IERC20
    function name() external view returns (string memory) {
        return string.concat(underlyingToken.name(), " ", toDate(unlockTime));
    }

    /// @inheritdoc IERC20
    function symbol() external view returns (string memory) {
        return string.concat("g", underlyingToken.symbol(), "-", toQuarter(unlockTime));
    }

    /// @inheritdoc IERC20
    function decimals() external view returns (uint8) {
        return underlyingToken.decimals();
    }

    /// @inheritdoc IERC20
    function transfer(address to, uint256 amount) external returns (bool) {
        if (msg.sender != address(core)) {
            uint256 balance = _balanceOf[msg.sender];
            if (balance < amount) {
                revert InsufficientBalance();
            }
            // since we already checked balance >= amount
            unchecked {
                _balanceOf[msg.sender] = balance - amount;
            }
        }
        if (to == address(core)) {
            coreBalance += amount;
        } else if (to != address(0)) {
            // we save storage writes on burn by checking to != address(0)
            _balanceOf[to] += amount;
        }
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// @inheritdoc IERC20
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    /// @inheritdoc IERC20
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowanceCurrent = allowance[from][msg.sender];
        if (allowanceCurrent != type(uint256).max) {
            if (allowanceCurrent < amount) revert InsufficientAllowance();
            // since we already checked allowanceCurrent >= amount
            unchecked {
                allowance[from][msg.sender] = allowanceCurrent - amount;
            }
        }

        // we know `from` at this point will never be address(core) for amount > 0, since Core will never give an allowance to any address

        uint256 balance = _balanceOf[from];
        if (balance < amount) {
            revert InsufficientBalance();
        }
        // since we already checked balance >= amount
        unchecked {
            _balanceOf[from] = balance - amount;
        }

        if (to == address(core)) {
            coreBalance += amount;
        } else {
            _balanceOf[to] += amount;
        }
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// @dev Encode (int256 delta) in the forwarded data, where a positive amount means wrapping and a negative amount means unwrapping.
    /// @dev For wrap, the specified amount of this wrapper token will be credited to the locker and the same amount of underlying will be debited.
    /// @dev For unwrap, the specified amount of the underlying will be credited to the locker and the same amount of this wrapper token will be debited, iff block.timestamp > unlockTime and at least that much token has been wrapped.
    function handleForwardData(uint256, address, bytes memory data) internal override returns (bytes memory) {
        (int256 amount) = abi.decode(data, (int256));

        // unwrap
        if (amount < 0) {
            if (block.timestamp < unlockTime) revert TooEarly();
        }

        core.updateSavedBalances({
            token0: address(underlyingToken),
            token1: address(type(uint160).max),
            salt: bytes32(0),
            delta0: amount,
            delta1: 0
        });

        core.updateDebt(-amount);
    }
}
