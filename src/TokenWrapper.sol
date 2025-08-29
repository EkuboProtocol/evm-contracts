// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseForwardee} from "./base/BaseForwardee.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IFlashAccountant, IPayer} from "./interfaces/IFlashAccountant.sol";
import {toDate, toQuarter} from "./libraries/TimeDescriptor.sol";
import {CoreLib} from "./libraries/CoreLib.sol";

/// @title TokenWrapper - Time-locked token wrapper
/// @notice Wraps tokens that can only be unwrapped after a specific unlock time
contract TokenWrapper is UsesCore, IERC20, IPayer, BaseForwardee {
    using CoreLib for *;

    /// @notice Thrown when trying to unwrap the token before the token has unlocked
    error TooEarly();

    /// @notice Thrown when attempting to transfer an amount greater than the balance
    error InsufficientBalance();

    /// @notice Thrown when calling transferFrom with an insufficient allowance
    error InsufficientAllowance();

    IERC20 public immutable underlyingToken;
    uint256 public immutable unlockTime;

    constructor(ICore core, IERC20 _underlyingToken, uint256 _unlockTime) UsesCore(core) BaseForwardee(core) {
        underlyingToken = _underlyingToken;
        unlockTime = _unlockTime;
    }

    mapping(address owner => mapping(address spender => uint256)) public override allowance;
    mapping(address account => uint256) private _balanceOf;

    // transient storage slot 0
    // core never actually holds a real balance of this token
    uint256 private transient coreBalance;

    function balanceOf(address account) external view returns (uint256) {
        if (account == address(core)) return coreBalance;
        return _balanceOf[account];
    }

    function totalSupply() external view override returns (uint256) {
        return uint256(core.savedBalances(address(this), address(underlyingToken), bytes32(0)));
    }

    function name() external view override returns (string memory) {
        return string.concat(underlyingToken.name(), " ", toDate(unlockTime));
    }

    function symbol() external view override returns (string memory) {
        return string.concat("g", underlyingToken.symbol(), "-", toQuarter(unlockTime));
    }

    function decimals() external view override returns (uint8) {
        return underlyingToken.decimals();
    }

    /// @notice Moves `amount` tokens from the caller's account to `to`.
    function transfer(address to, uint256 amount) external returns (bool) {
        if (msg.sender != address(core)) {
            uint256 balance = _balanceOf[msg.sender];
            if (balance < amount) {
                revert InsufficientBalance();
            }
            unchecked {
                _balanceOf[msg.sender] = balance - amount;
            }
        }
        if (to == address(core)) {
            coreBalance += amount;
        } else if (to != address(0)) {
            _balanceOf[to] += amount;
        }
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
        _spendAllowance(from, msg.sender, amount);

        uint256 balance = _balanceOf[from];
        if (balance < amount) {
            revert InsufficientBalance();
        }
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

    function payCallback(uint256, address) external override onlyCore {
        assembly ("memory-safe") {
            tstore(0, calldataload(68))
        }
    }

    function handleForwardData(uint256, address, bytes memory data) internal override returns (bytes memory) {
        (uint256 callType, uint128 amount) = abi.decode(data, (uint256, uint128));

        // wrap
        if (callType == 0) {
            // saves the underlying so that the user has to deposit it
            core.save(address(this), address(underlyingToken), bytes32(0), amount);
            // reset core balance to 0
            coreBalance = 0;
            // pays the amount of this token to make it available to withdraw
            (bool success,) =
                address(core).call(abi.encodeWithSelector(IFlashAccountant.pay.selector, address(this), amount));
            assert(success);
        } else {
            // unwrap
            if (block.timestamp < unlockTime) revert TooEarly();

            // loads the underlying so that user can withdraw it
            core.load(address(underlyingToken), bytes32(0), amount);
            // burn the same amount of this token by withdrawing to address 0
            // this causes core to call transfer but we have a special case for it
            core.withdraw(address(this), address(0), amount);
        }
    }
}

/// @title TokenWrapperFactory - Factory for creating time-locked token wrappers
/// @notice Creates TokenWrapper contracts with formatted names and symbols based on unlock dates
contract TokenWrapperFactory {
    event TokenWrapperDeployed(IERC20 underlyingToken, uint256 unlockTime, TokenWrapper tokenWrapper);

    ICore public immutable core;
    TokenWrapper public immutable implementation;

    constructor(ICore _core) {
        core = _core;
    }

    /// @notice Deploy a new TokenWrapper with auto-generated name and symbol
    /// @param underlyingToken The token to be wrapped
    /// @param unlockTime Timestamp when tokens can be unwrapped
    /// @return tokenWrapper The deployed TokenWrapper contract
    function deployWrapper(IERC20 underlyingToken, uint256 unlockTime) external returns (TokenWrapper tokenWrapper) {
        bytes32 salt = keccak256(abi.encode(underlyingToken, unlockTime));

        tokenWrapper = new TokenWrapper{salt: salt}(core, underlyingToken, unlockTime);

        emit TokenWrapperDeployed(underlyingToken, unlockTime, tokenWrapper);
    }
}
