// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ILocker, IForwardee, IFlashAccountant} from "../interfaces/IFlashAccountant.sol";

abstract contract FlashAccountant is IFlashAccountant {
    // These are randomly selected offsets so that they do not accidentally overlap with any other base contract's use of transient storage

    // cast keccak "FlashAccountant#LOCKER_COUNT"
    uint256 private constant _LOCKER_COUNT_SLOT = 0xdfe868523f8ede687139be83247bb2178878f1f7e5f4163159d5efcacd490ee8;
    // cast keccak "FlashAccountant#LOCKER_ADDRESS_OFFSET"
    uint256 private constant _LOCKER_ADDRESSES_OFFSET =
        0x62f1193cf979f3b3e5310bfcb479bd02c801c390b7d4b953d62823a220c07066;
    // cast keccak "FlashAccountant#NONZERO_DEBT_COUNT_OFFSET"
    uint256 private constant _NONZERO_DEBT_COUNT_OFFSET =
        0x7772acfd7e0f66ebb20a058830296c3dc1301b111d23348e1c961d324223190d;
    // cast keccak "FlashAccountant#DEBT_HASH_OFFSET"
    uint256 private constant _DEBT_HASH_OFFSET = 0x3fee1dc3ade45aa30d633b5b8645760533723e46597841ef1126c6577a091742;

    function _getLocker() internal view returns (uint256 id, address locker) {
        assembly ("memory-safe") {
            id := sub(tload(_LOCKER_COUNT_SLOT), 1)
            locker := tload(add(_LOCKER_ADDRESSES_OFFSET, id))
        }
        if (id == type(uint256).max) revert NotLocked();
    }

    function _requireLocker() internal view returns (uint256 id, address locker) {
        (id, locker) = _getLocker();
        if (locker != msg.sender) revert LockerOnly();
    }

    // Negative means erasing debt, positive means adding debt
    function _accountDebt(uint256 id, address token, int256 debtChange) internal {
        assembly ("memory-safe") {
            if iszero(iszero(debtChange)) {
                mstore(0, add(add(shl(160, id), token), _DEBT_HASH_OFFSET))
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
        (uint256 id, address locker) = _requireLocker();

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
