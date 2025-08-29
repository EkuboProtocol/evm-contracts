// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {LibClone} from "solady/utils/LibClone.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {BaseForwardee} from "./base/BaseForwardee.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {IFlashAccountant, IPayer} from "./interfaces/IFlashAccountant.sol";
import {toDate, toQuarter} from "./libraries/TimeDescriptor.sol";
import {CoreLib} from "./libraries/CoreLib.sol";

library TokenWrapperLib {
    /// @dev Returns the immutable arguments from a clone
    function parameters(TokenWrapper tokenWrapper) internal view returns (IERC20 token, uint64 unlock) {
        assembly ("memory-safe") {
            extcodecopy(tokenWrapper, 0, 0x2d, 0x1c)
            token := shr(96, mload(0x00))
            unlock := shr(192, mload(0x14))
        }
    }

    /// @notice The underlying token being wrapped
    function underlyingToken(TokenWrapper tokenWrapper) internal view returns (IERC20) {
        (IERC20 token,) = parameters(tokenWrapper);
        return token;
    }

    /// @notice Timestamp when tokens can be unwrapped
    function unlockTime(TokenWrapper tokenWrapper) internal view returns (uint64) {
        (, uint64 unlock) = parameters(tokenWrapper);
        return unlock;
    }
}

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

    constructor(ICore core) UsesCore(core) BaseForwardee(core) {}

    /// @dev Returns the immutable arguments in the clone
    function parameters() public view returns (IERC20 token, uint64 unlock) {
        (token, unlock) = TokenWrapperLib.parameters(this);
    }

    mapping(address owner => mapping(address spender => uint256)) public override allowance;
    mapping(address account => uint256) private _balanceOf;

    uint256 private transient coreBalance;

    function balanceOf(address account) external view returns (uint256) {
        if (account == address(core)) return coreBalance;
        return _balanceOf[account];
    }

    function totalSupply() external view override returns (uint256) {
        (IERC20 token,) = parameters();
        return uint256(core.savedBalances(address(this), address(token), bytes32(0)));
    }

    function name() external view override returns (string memory) {
        (IERC20 underlying, uint64 unlock) = parameters();

        return string.concat(underlying.name(), " ", toDate(unlock));
    }

    function symbol() external view override returns (string memory) {
        (IERC20 underlying, uint64 unlock) = parameters();
        return string.concat("g", underlying.symbol(), "-", toQuarter(unlock));
    }

    function decimals() external view override returns (uint8) {
        (IERC20 underlying,) = parameters();
        return underlying.decimals();
    }

    /// @notice Moves `amount` tokens from the caller's account to `to`.
    function transfer(address to, uint256 amount) external returns (bool) {
        if (msg.sender != address(core)) {
            uint256 balance = _balanceOf[msg.sender];
            if (balance < amount) {
                revert InsufficientBalance();
            }
            _balanceOf[msg.sender] = balance - amount;
        }
        if (to != address(0)) {
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
        uint256 amount;
        assembly ("memory-safe") {
            amount := calldataload(68)
        }
        coreBalance = amount;
    }

    function handleForwardData(uint256, address, bytes memory data) internal override returns (bytes memory) {
        uint256 callType;

        assembly ("memory-safe") {
            callType := mload(add(data, 0x20))
        }

        if (callType == 0) {
            // wrap
            (IERC20 token,) = parameters();

            (, uint128 amount) = abi.decode(data, (uint256, uint128));

            // saves the underlying so that the user has to deposit it
            core.save(address(this), address(token), bytes32(bytes20(0)), amount);
            // reset core balance to 0
            coreBalance = 0;
            // pays the amount of this token to make it available to withdraw
            (bool success,) =
                address(core).call(abi.encodeWithSelector(IFlashAccountant.pay.selector, address(this), amount));
            assert(success);
        } else {
            // unwrap
            (IERC20 token, uint64 unlock) = parameters();

            if (block.timestamp < unlock) revert TooEarly();

            (, uint128 amount) = abi.decode(data, (uint256, uint128));

            // loads the underlying so that user can withdraw it
            core.load(address(token), bytes32(0), amount);
            // burn the same amount of this token by withdrawing to address 0
            // this causes core to call transfer but we have a special case for it
            core.withdraw(address(this), address(0), amount);
        }
    }
}

contract WrappedTokenMinter is BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    function wrap(TokenWrapper wrapper, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, msg.sender, amount));
    }

    function wrap(TokenWrapper wrapper, address recipient, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, recipient, amount));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (TokenWrapper wrapper, address payer, address recipient, uint128 amount) =
            abi.decode(data, (TokenWrapper, address, address, uint128));

        // this creates the deltas
        forward(address(wrapper), abi.encode(uint256(0), amount));
        // now withdraw to the recipient
        accountant.withdraw(address(wrapper), recipient, amount);
        // and pay the wrapped token from the payer
        pay(payer, address(TokenWrapperLib.underlyingToken(wrapper)), amount);
    }
}

contract WrappedTokenBurner is BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    function unwrap(TokenWrapper wrapper, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, msg.sender, amount));
    }

    function unwrap(TokenWrapper wrapper, address recipient, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, recipient, amount));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (TokenWrapper wrapper, address payer, address recipient, uint128 amount) =
            abi.decode(data, (TokenWrapper, address, address, uint128));

        // this creates the deltas
        forward(address(wrapper), abi.encode(uint256(1), amount));
        // now withdraw to the recipient
        accountant.withdraw(address(TokenWrapperLib.underlyingToken(wrapper)), recipient, amount);
        // and pay the wrapped token from the payer
        pay(payer, address(wrapper), amount);
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
