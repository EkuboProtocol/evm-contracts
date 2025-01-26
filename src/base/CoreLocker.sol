// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ILocker} from "../interfaces/IFlashAccountant.sol";
import {ICore, NATIVE_TOKEN_ADDRESS} from "../interfaces/ICore.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {UsesCore} from "./UsesCore.sol";

abstract contract CoreLocker is UsesCore, ILocker {
    constructor(ICore core) UsesCore(core) {}

    function lock(bytes memory data) internal returns (bytes memory result) {
        address c = address(core);

        assembly ("memory-safe") {
            result := mload(0x40)
            // selector of lock()
            mstore(result, shl(224, 0xf83d08ba))
            // then copy the data after the selector
            let len := mload(data)

            // we only copy the data, since the calldatasize implicitly encodes the length
            mcopy(add(result, 4), add(data, 32), len)

            // if it failed, pass through revert
            if iszero(call(gas(), c, 0, result, add(len, 36), 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }

            mstore(result, returndatasize())
            returndatacopy(add(result, 32), 0, returndatasize())

            // we need 32 bytes for length plus the entire return data
            mstore(0x40, add(result, add(32, returndatasize())))

            // aligns the free memory pointer to the next greatest 32 bytes
            mstore(0x40, add(mload(0x40), 31))
        }
    }

    function locked(uint256) external onlyCore {
        bytes memory data = msg.data[36:];

        bytes memory result = handleLockData(data);

        assembly ("memory-safe") {
            // raw return whatever the handler sent
            return(add(result, 32), mload(result))
        }
    }

    function payCallback(uint256, address token, bytes memory data) external onlyCore returns (bytes memory) {
        (address from, uint256 amount) = abi.decode(data, (address, uint256));
        SafeTransferLib.safeTransferFrom2(token, from, address(core), amount);
    }

    function payCore(address from, address token, uint256 amount) internal {
        if (amount > 0) {
            if (token == NATIVE_TOKEN_ADDRESS) {
                SafeTransferLib.safeTransferETH(address(core), amount);
            } else {
                core.pay(token, abi.encode(from, amount));
            }
        }
    }

    // Since payments of ETH to Core happen from this contract, we need to allow users to refund the ETH they sent
    function refundNativeToken() external payable {
        if (address(this).balance > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, address(this).balance);
        }
    }

    function withdrawFromCore(address token, uint128 amount, address recipient) internal {
        if (amount > 0) {
            core.withdraw(token, recipient, amount);
        }
    }

    function handleLockData(bytes memory data) internal virtual returns (bytes memory result);
}
