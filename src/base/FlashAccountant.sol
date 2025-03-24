// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {IPayer, IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

abstract contract FlashAccountant is IFlashAccountant {
    // These offsets are selected so that they do not accidentally overlap with any other base contract's use of transient storage

    // cast keccak "FlashAccountant#CURRENT_LOCKER_SLOT"
    uint256 private constant _CURRENT_LOCKER_SLOT = 0x07cc7f5195d862f505d6b095c82f92e00cfc1766f5bca4383c28dc5fca1555fd;
    // cast keccak "FlashAccountant#NONZERO_DEBT_COUNT_OFFSET"
    uint256 private constant _NONZERO_DEBT_COUNT_OFFSET =
        0x7772acfd7e0f66ebb20a058830296c3dc1301b111d23348e1c961d324223190d;
    // cast keccak "FlashAccountant#DEBT_HASH_OFFSET"
    uint256 private constant _DEBT_HASH_OFFSET = 0x3fee1dc3ade45aa30d633b5b8645760533723e46597841ef1126c6577a091742;
    // cast keccak "FlashAccountant#PAY_REENTRANCY_LOCK"
    uint256 private constant _PAY_REENTRANCY_LOCK = 0xe1be600102d456bf2d4dee36e1641404df82292916888bf32557e00dfe166412;

    function _getLocker() internal view returns (uint256 id, address locker) {
        assembly ("memory-safe") {
            let current := tload(_CURRENT_LOCKER_SLOT)

            if iszero(current) {
                // cast sig "NotLocked()"
                mstore(0, shl(224, 0x1834e265))
                revert(0, 4)
            }

            id := sub(shr(160, current), 1)
            locker := shr(96, shl(96, current))
        }
    }

    function _requireLocker() internal view returns (uint256 id, address locker) {
        (id, locker) = _getLocker();
        if (locker != msg.sender) revert LockerOnly();
    }

    // We assume debtChange cannot exceed a 128 bits value, even though it uses a int256 container
    // This must be enforced at the places it is called for this contract's safety
    // Negative means erasing debt, positive means adding debt
    function _accountDebt(uint256 id, address token, int256 debtChange) internal {
        assembly ("memory-safe") {
            if iszero(iszero(debtChange)) {
                mstore(0, add(add(shl(160, id), token), _DEBT_HASH_OFFSET))
                let deltaSlot := keccak256(0, 32)
                let current := tload(deltaSlot)

                // we know this never overflows because debtChange is only ever derived from 128 bit values in inheriting contracts
                let next := add(current, debtChange)

                let nextZero := iszero(next)
                if xor(iszero(current), nextZero) {
                    let nzdCountSlot := add(id, _NONZERO_DEBT_COUNT_OFFSET)

                    tstore(nzdCountSlot, add(sub(tload(nzdCountSlot), nextZero), iszero(nextZero)))
                }

                tstore(deltaSlot, next)
            }
        }
    }

    // The entrypoint for all operations on the core contract
    function lock() external {
        assembly ("memory-safe") {
            let current := tload(_CURRENT_LOCKER_SLOT)

            let id := shr(160, current)

            // store the count
            tstore(_CURRENT_LOCKER_SLOT, or(shl(160, add(id, 1)), caller()))

            let free := mload(0x40)
            // Prepare call to locked(uint256) -> selector 0xb45a3c0e
            mstore(free, shl(224, 0xb45a3c0e))
            mstore(add(free, 4), id) // ID argument

            calldatacopy(add(free, 36), 4, sub(calldatasize(), 4))

            // Call the original caller with the packed data
            let success := call(gas(), caller(), 0, free, add(calldatasize(), 32), 0, 0)

            // Pass through the error on failure
            if iszero(success) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }

            // Undo the "locker" state changes
            tstore(_CURRENT_LOCKER_SLOT, current)

            // Check if something is nonzero
            let nonzeroDebtCount := tload(add(_NONZERO_DEBT_COUNT_OFFSET, id))
            if nonzeroDebtCount {
                // cast sig "DebtsNotZeroed(uint256)"
                mstore(0x00, 0x9731ba37)
                mstore(0x20, id)
                revert(0x1c, 0x24)
            }

            // Directly return whatever the subcall returned
            returndatacopy(free, 0, returndatasize())
            return(free, returndatasize())
        }
    }

    // Allows forwarding the lock context to another actor, allowing them to act on the original locker's debt
    function forward(address to) external {
        (uint256 id, address locker) = _requireLocker();

        // update this lock's locker to the forwarded address for the duration of the forwarded
        // call, meaning only the forwarded address can update state
        assembly ("memory-safe") {
            tstore(_CURRENT_LOCKER_SLOT, or(shl(160, add(id, 1)), to))

            let free := mload(0x40)

            // Prepare call to forwarded(uint256,address) -> selector 0x64919dea
            mstore(free, shl(224, 0x64919dea))
            mstore(add(free, 4), id)
            mstore(add(free, 36), locker)

            calldatacopy(add(free, 68), 36, sub(calldatasize(), 36))

            // Call the forwardee with the packed data
            let success := call(gas(), to, 0, free, add(32, calldatasize()), 0, 0)

            // Pass through the error on failure
            if iszero(success) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }

            tstore(_CURRENT_LOCKER_SLOT, or(shl(160, add(id, 1)), locker))

            // Directly return whatever the subcall returned
            returndatacopy(free, 0, returndatasize())
            return(free, returndatasize())
        }
    }

    function pay(address token) external returns (uint128 payment) {
        assembly ("memory-safe") {
            if tload(_PAY_REENTRANCY_LOCK) {
                // cast sig "PayReentrance()"
                mstore(0, 0xced108be)
                revert(0x1c, 0x04)
            }
            tstore(_PAY_REENTRANCY_LOCK, 1)
        }

        (uint256 id,) = _getLocker();

        assembly ("memory-safe") {
            let free := mload(0x40)

            mstore(20, address()) // Store the `account` argument.
            mstore(0, 0x70a08231000000000000000000000000) // `balanceOf(address)`.
            let successBefore := staticcall(gas(), token, 0x10, 0x24, free, 0x20)
            let tokenBalanceBefore := mload(free)

            // Prepare call to "payCallback(uint256,address)"
            mstore(free, shl(224, 0x599d0714))
            mstore(add(free, 4), id)
            mstore(add(free, 36), token)

            // copy the token, plus anything else that they wanted to forward
            calldatacopy(add(free, 68), 36, sub(calldatasize(), 36))

            // Call the forwardee with the packed data
            // Pass through the error on failure
            if iszero(call(gas(), caller(), 0, free, add(32, calldatasize()), 0, 0)) {
                returndatacopy(free, 0, returndatasize())
                revert(free, returndatasize())
            }

            let successAfter := staticcall(gas(), token, 0x10, 0x24, 0x20, 0x20)
            let tokenBalanceAfter := mload(0x20)

            payment :=
                mul(
                    sub(tokenBalanceAfter, tokenBalanceBefore),
                    // payment only counts if both calls are successful and the balance after is greater than the balance before
                    and(gt(tokenBalanceAfter, tokenBalanceBefore), and(successAfter, successBefore))
                )

            // We never expect tokens to have this much total supply
            if gt(payment, 0xffffffffffffffffffffffffffffffff) {
                // cast sig "PaymentOverflow()"
                mstore(0x00, 0x9cac58ca)
                revert(0x1c, 4)
            }
        }

        // The unary negative operator never fails because payment is less than max uint128
        unchecked {
            _accountDebt(id, token, -int256(uint256(payment)));
        }

        assembly ("memory-safe") {
            tstore(_PAY_REENTRANCY_LOCK, 0)
        }
    }

    function withdraw(address token, address recipient, uint128 amount) external {
        (uint256 id,) = _requireLocker();

        _accountDebt(id, token, int256(uint256(amount)));

        if (token == NATIVE_TOKEN_ADDRESS) {
            SafeTransferLib.safeTransferETH(recipient, amount);
        } else {
            SafeTransferLib.safeTransfer(token, recipient, amount);
        }
    }

    receive() external payable {
        (uint256 id,) = _getLocker();

        // Note because we use msg.value here, this contract can never be multicallable, i.e. it should never expose the ability
        //      to delegatecall itself more than once in a single call
        unchecked {
            // We never expect the native token to exceed this supply
            if (msg.value > type(uint128).max) revert PaymentOverflow();

            _accountDebt(id, NATIVE_TOKEN_ADDRESS, -int256(msg.value));
        }
    }
}
