// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseLocker} from "./base/BaseLocker.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {SlippageChecker} from "./base/SlippageChecker.sol";
import {ICore, SwapParameters} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/keys.sol";
import {isPriceIncreasing} from "./math/swap.sol";

contract SimpleSwapper is BaseLocker, SlippageChecker, PayableMulticallable {
    constructor(ICore core) BaseLocker(core) {}

    function swap(PoolKey memory poolKey, bool isToken1, int128 amount, uint256 sqrtRatioLimit, uint256 skipAhead)
        external
        payable
        returns (int128 delta0, int128 delta1)
    {
        (delta0, delta1) = abi.decode(
            lock(abi.encode(false, msg.sender, poolKey, isToken1, amount, sqrtRatioLimit, skipAhead)), (int128, int128)
        );
    }

    function quote(PoolKey memory poolKey, bool isToken1, int128 amount, uint256 sqrtRatioLimit, uint256 skipAhead)
        external
        returns (int128 delta0, int128 delta1)
    {
        // todo: this doesn't work, we need to catch the revert internally
        (delta0, delta1) = abi.decode(
            lock(abi.encode(true, msg.sender, poolKey, isToken1, amount, sqrtRatioLimit, skipAhead)), (int128, int128)
        );
    }

    error QuoteReturnValue(int128 delta0, int128 delta1);

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        (
            bool revertWithResult,
            address swapper,
            PoolKey memory poolKey,
            bool isToken1,
            int128 amount,
            uint256 sqrtRatioLimit,
            uint256 skipAhead
        ) = abi.decode(data, (bool, address, PoolKey, bool, int128, uint256, uint256));

        (int128 delta0, int128 delta1) =
            ICore(payable(accountant)).swap(poolKey, SwapParameters(amount, isToken1, sqrtRatioLimit, skipAhead));

        if (revertWithResult) {
            revert QuoteReturnValue(delta0, delta1);
        }

        if (isPriceIncreasing(amount, isToken1)) {
            withdraw(poolKey.token0, uint128(-delta0), swapper);
            pay(swapper, poolKey.token1, uint128(delta1));
        } else {
            withdraw(poolKey.token1, uint128(-delta1), swapper);
            pay(swapper, poolKey.token0, uint128(delta0));
        }

        result = abi.encode(delta0, delta1);
    }
}
