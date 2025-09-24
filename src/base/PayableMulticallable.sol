// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {Multicallable} from "solady/utils/Multicallable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title Payable Multicallable
/// @notice Abstract contract that extends Multicallable to support payable multicalls and ETH refunds
/// @dev Provides functionality for batching multiple calls with native token support
///      Derived contracts can use this to enable efficient batch operations with ETH payments
abstract contract PayableMulticallable is Multicallable {
    /// @notice Executes multiple calls in a single transaction with native token support
    /// @dev Overrides the base multicall function to make it payable, allowing ETH to be sent
    ///      Uses direct return to avoid unnecessary memory copying for gas efficiency
    /// @param data Array of encoded function call data to execute
    /// @return results Array of return data from each function call
    function multicall(bytes[] calldata data) public payable override returns (bytes[] memory) {
        _multicallDirectReturn(_multicall(data));
    }

    /// @notice Refunds any remaining native token balance to the caller
    /// @dev Allows callers to recover ETH that was sent for transient payments but not fully consumed
    ///      This is useful when exact payment amounts are difficult to calculate in advance
    ///      Only refunds if there is a non-zero balance to avoid unnecessary gas costs
    function refundNativeToken() external payable {
        if (address(this).balance != 0) {
            SafeTransferLib.safeTransferETH(msg.sender, address(this).balance);
        }
    }
}
