// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {BaseLocker} from "./base/BaseLocker.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {SlippageChecker} from "./base/SlippageChecker.sol";
import {ICore, SwapParameters} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/keys.sol";
import {isPriceIncreasing} from "./math/swap.sol";

contract SimpleQuoter is BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    function quote(PoolKey memory poolKey, bool isToken1, int128 amount, uint256 sqrtRatioLimit, uint256 skipAhead)
        external
        returns (int128 delta0, int128 delta1)
    {
        bytes memory revertData = lockAndExpectRevert(abi.encode(poolKey, isToken1, amount, sqrtRatioLimit, skipAhead));

        // check that the sig matches the error data

        bytes4 sig;
        assembly ("memory-safe") {
            sig := mload(add(revertData, 32))
        }
        if (sig == QuoteReturnValue.selector && revertData.length == 68) {
            (delta0, delta1) = abi.decode(revertData, (int128, int128));
        }
    }

    error QuoteReturnValue(int128 delta0, int128 delta1);

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory poolKey, bool isToken1, int128 amount, uint256 sqrtRatioLimit, uint256 skipAhead) =
            abi.decode(data, (PoolKey, bool, int128, uint256, uint256));

        (int128 delta0, int128 delta1) =
            ICore(payable(accountant)).swap(poolKey, SwapParameters(amount, isToken1, sqrtRatioLimit, skipAhead));

        revert QuoteReturnValue(delta0, delta1);
    }
}

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

        (int128 delta0, int128 delta1) =
            ICore(payable(accountant)).swap(poolKey, SwapParameters(amount, isToken1, sqrtRatioLimit, skipAhead));

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
