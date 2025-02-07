// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseLocker} from "./base/BaseLocker.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {SlippageChecker} from "./base/SlippageChecker.sol";
import {ICore, SwapParameters} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/poolKey.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {isPriceIncreasing} from "./math/isPriceIncreasing.sol";

contract SimpleSwapper is BaseLocker, SlippageChecker, PayableMulticallable {
    constructor(ICore core) BaseLocker(core) {}

    function swap(PoolKey memory poolKey, bool isToken1, int128 amount, uint256 sqrtRatioLimit, uint256 skipAhead)
        external
        payable
        returns (int128 delta0, int128 delta1)
    {
        (delta0, delta1) = abi.decode(
            lock(abi.encode(msg.sender, poolKey, isToken1, amount, sqrtRatioLimit, skipAhead)), (int128, int128)
        );
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        (
            address swapper,
            PoolKey memory poolKey,
            bool isToken1,
            int128 amount,
            uint256 sqrtRatioLimit,
            uint256 skipAhead
        ) = abi.decode(data, (address, PoolKey, bool, int128, uint256, uint256));

        bool increasing = isPriceIncreasing(amount, isToken1);

        uint128 value = poolKey.token0 == NATIVE_TOKEN_ADDRESS && !increasing && amount > 0 ? uint128(amount) : 0;

        (int128 delta0, int128 delta1) = ICore(payable(accountant)).swap{value: value}(
            poolKey, SwapParameters(amount, isToken1, sqrtRatioLimit, skipAhead)
        );

        if (increasing) {
            withdraw(poolKey.token0, uint128(-delta0), swapper);
            pay(swapper, poolKey.token1, uint128(delta1));
        } else {
            withdraw(poolKey.token1, uint128(-delta1), swapper);
            // we already paid in the swap call, so refund it
            if (value != 0) {
                withdraw(poolKey.token0, uint128(value) - uint128(delta0), swapper);
            } else {
                pay(swapper, poolKey.token0, uint128(delta0) - uint128(value));
            }
        }

        result = abi.encode(delta0, delta1);
    }
}
