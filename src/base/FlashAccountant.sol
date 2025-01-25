// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ILocker, IForwardee, IFlashAccountant} from "../interfaces/IFlashAccountant.sol";

abstract contract FlashAccountant is IFlashAccountant {
    uint256 private constant _LOCKER_COUNT_SLOT = 0;
    uint256 private constant _LOCKER_ADDRESSES_OFFSET = 0x100000000;
    uint256 private constant _NONZERO_DEBT_COUNT_OFFSET = 0x200000000;

    function getLocker() internal view returns (uint256 id, address locker) {
        assembly ("memory-safe") {
            id := sub(tload(_LOCKER_COUNT_SLOT), 1)
            locker := tload(add(_LOCKER_ADDRESSES_OFFSET, id))
        }
        if (id == type(uint256).max) revert NotLocked();
    }

    function requireLocker() internal view returns (uint256 id, address locker) {
        (id, locker) = getLocker();
        if (locker != msg.sender) revert LockerOnly();
    }

    // Negative means erasing debt, positive means adding debt
    function accountDebt(uint256 id, address token, int256 debtChange) internal {
        assembly ("memory-safe") {
            if iszero(iszero(debtChange)) {
                mstore(0, add(shl(160, id), token))
                let deltaSlot := keccak256(0, 32)
                let current := tload(deltaSlot)

                // we know this never overflows because debtChange is only ever derived from 128 bit values in this contract
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
    function lock(bytes calldata data) external returns (bytes memory result) {
        uint256 id;

        assembly ("memory-safe") {
            id := tload(_LOCKER_COUNT_SLOT)
            // store the count
            tstore(_LOCKER_COUNT_SLOT, add(id, 1))
            // store the address of the locker
            tstore(add(_LOCKER_ADDRESSES_OFFSET, id), caller())
        }

        // We make the assumption that this code can never be called recursively this many times, causing storage slots to overlap
        // This is just the codified assumption
        assert(id < type(uint32).max);

        result = ILocker(msg.sender).locked(id, data);

        uint256 nonzeroDebtCount;
        assembly ("memory-safe") {
            // reset the locker id
            tstore(_LOCKER_COUNT_SLOT, id)
            // remove the address
            tstore(add(_LOCKER_ADDRESSES_OFFSET, id), 0)
            // load the delta count which should already be reset to zero
            nonzeroDebtCount := tload(add(_NONZERO_DEBT_COUNT_OFFSET, id))
        }

        if (nonzeroDebtCount != 0) revert DebtsNotZeroed();
    }

    // Allows forwarding the lock context to another actor, allowing them to act on the original locker's debt
    function forward(address to, bytes calldata data) external returns (bytes memory result) {
        (uint256 id, address locker) = requireLocker();

        // update this lock's locker to the forwarded address for the duration of the forwarded
        // call, meaning only the forwarded address can update state
        assembly ("memory-safe") {
            tstore(add(_LOCKER_ADDRESSES_OFFSET, id), to)
        }

        result = IForwardee(to).forwarded(locker, id, data);

        assembly ("memory-safe") {
            tstore(add(_LOCKER_ADDRESSES_OFFSET, id), locker)
        }
    }
}
