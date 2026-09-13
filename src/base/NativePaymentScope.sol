// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Multicallable} from "solady/utils/Multicallable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Isolates an active caller's native funding from reentrant third parties.
abstract contract NativePaymentScope is Multicallable {
    error InsufficientNativePayment();

    address private transient _nativeCaller;
    uint256 private transient _nativeReserve;

    /// @dev Delegatecalls from a multicall share its budget. A different caller reserves the entire
    ///      pre-call balance, so nested calls can spend only their own value and withdrawal proceeds.
    modifier nativePaymentScope() {
        address previousCaller = _nativeCaller;
        uint256 previousReserve = _nativeReserve;
        bool newFrame = msg.sender != previousCaller;
        if (newFrame) {
            _nativeCaller = msg.sender;
            // Unassigned balance is permissionlessly spendable between calls, as in PayableMulticallable.
            _nativeReserve = previousCaller == address(0) ? 0 : address(this).balance - msg.value;
        }
        _;
        if (newFrame) {
            _nativeCaller = previousCaller;
            _nativeReserve = previousReserve;
        }
    }

    function multicall(bytes[] calldata data) public payable override nativePaymentScope returns (bytes[] memory) {
        // A direct assembly return would bypass the modifier's frame restoration.
        return _multicallResultsToBytesArray(_multicall(data));
    }

    function refundNativeToken() external payable nativePaymentScope {
        uint256 amount = address(this).balance - _nativeReserve;
        if (amount != 0) SafeTransferLib.safeTransferETH(msg.sender, amount);
    }

    function _payNative(address recipient, uint256 amount) internal {
        if (amount > address(this).balance - _nativeReserve) revert InsufficientNativePayment();
        if (amount != 0) SafeTransferLib.safeTransferETH(recipient, amount);
    }
}
