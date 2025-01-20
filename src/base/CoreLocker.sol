// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ICore, ILocker, NATIVE_TOKEN_ADDRESS} from "../interfaces/ICore.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {UsesCore} from "./UsesCore.sol";

abstract contract CoreLocker is UsesCore, ILocker {
    constructor(ICore core) UsesCore(core) {}

    function locked(uint256, bytes calldata data) external onlyCore returns (bytes memory) {
        return handleLockData(data);
    }

    function payCallback(uint256, address token, bytes memory data) external onlyCore returns (bytes memory) {
        (address from, uint256 amount) = abi.decode(data, (address, uint256));
        SafeTransferLib.safeTransferFrom2(token, from, address(core), amount);
    }

    function lock(bytes memory data) internal returns (bytes memory result) {
        result = core.lock(data);
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
    function refundNativeToken() external {
        if (address(this).balance > 0) {
            SafeTransferLib.safeTransferETH(msg.sender, address(this).balance);
        }
    }

    function withdrawFromCore(address token, uint128 amount, address recipient) internal {
        if (amount > 0) {
            core.withdraw(token, recipient, amount);
        }
    }

    function handleLockData(bytes calldata data) internal virtual returns (bytes memory result);
}
