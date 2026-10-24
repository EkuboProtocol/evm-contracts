// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.33;

import {BaseLocker} from "../src/base/BaseLocker.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {PoolState} from "../src/types/poolState.sol";
import {createSwapParameters} from "../src/types/swapParameters.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @dev Test-only single-hop locker. Standard ABI, no deployed-router bytecode or route format dependency.
contract LaunchTestRouter is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function swap(
        PoolKey memory key,
        address specified,
        address calculated,
        int128 amount,
        int128 minOut,
        bool allowPartial,
        uint32 deadline
    ) external payable returns (address, address, int256 paid, int256 received) {
        require(block.timestamp <= deadline, "deadline");
        require(
            (specified == key.token0 && calculated == key.token1)
                || (specified == key.token1 && calculated == key.token0),
            "pair"
        );
        (paid, received) = abi.decode(lock(abi.encode(key, specified, amount, msg.sender)), (int256, int256));
        require(allowPartial || paid == amount, "partial fill");
        require(received >= minOut, "minimum output");
        if (address(this).balance != 0) SafeTransferLib.safeTransferETH(msg.sender, address(this).balance);
        return (specified, calculated, paid, received);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory key, address specified, int128 amount, address payer) =
            abi.decode(data, (PoolKey, address, int128, address));
        (PoolBalanceUpdate update,) = abi.decode(
            ACCOUNTANT.forward(
                key.config.extension(),
                abi.encode(key, createSwapParameters(SqrtRatio.wrap(0), amount, specified == key.token1, 0))
            ),
            (PoolBalanceUpdate, PoolState)
        );
        _settle(key.token0, update.delta0(), payer);
        _settle(key.token1, update.delta1(), payer);
        return specified == key.token0
            ? abi.encode(int256(update.delta0()), -int256(update.delta1()))
            : abi.encode(int256(update.delta1()), -int256(update.delta0()));
    }

    function _settle(address token, int128 delta, address payer) private {
        if (delta > 0) {
            if (token == address(0)) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint128(delta));
            else ACCOUNTANT.payFrom(payer, token, uint128(delta));
        } else if (delta < 0) {
            ACCOUNTANT.withdraw(token, payer, uint128(-delta));
        }
    }

    receive() external payable {}
}
