// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Multicallable} from "solady/utils/Multicallable.sol";
import {CoreLocker} from "./base/CoreLocker.sol";
import {ICore, SwapParameters} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/keys.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "./math/ticks.sol";
import {isPriceIncreasing} from "./math/swap.sol";
import {Permittable} from "./base/Permittable.sol";

struct RouteNode {
    PoolKey poolKey;
    uint256 sqrtRatioLimit;
    uint256 skipAhead;
}

struct TokenAmount {
    address token;
    int128 amount;
}

struct Swap {
    RouteNode[] route;
    TokenAmount tokenAmount;
    // If the swap has a positive tokenAmount.amount, this is the minimum amount that the final swap should receive.
    // If the swap has a negative tokenAmount.amount, this is the maximum amount that the last swap should pay (noting exact out swaps are performed backwards).
    uint256 calculatedAmountThreshold;
}

struct Delta {
    int128 amount0;
    int128 amount1;
}

contract Router is Multicallable, Permittable, CoreLocker {
    error MinimumOutputNotReceived(uint256 swapIndex, uint256 amountReceived, uint256 minimumAmountOut);
    error MaximumInputExceeded(uint256 swapIndex, uint256 amountRequired, uint256 maximumAmountIn);

    constructor(ICore core) CoreLocker(core) {}

    function handleLockData(bytes calldata data) internal override returns (bytes memory result) {
        (address swapper, Swap[] memory swaps) = abi.decode(data, (address, Swap[]));
        Delta[][] memory results = new Delta[][](swaps.length);
        unchecked {
            for (uint256 i = 0; i < swaps.length; i++) {
                Swap memory s = swaps[i];
                results[i] = new Delta[](s.route.length);

                bool isExactOut = s.tokenAmount.amount < 0;

                TokenAmount memory firstSwapAmount;
                TokenAmount memory tokenAmount = s.tokenAmount;

                for (uint256 j = 0; j < s.route.length; j++) {
                    RouteNode memory node = s.route[j];

                    bool isToken1 = tokenAmount.token == node.poolKey.token1;

                    uint256 sqrtRatioLimit = node.sqrtRatioLimit;
                    if (sqrtRatioLimit == 0) {
                        sqrtRatioLimit =
                            isPriceIncreasing(tokenAmount.amount, isToken1) ? MAX_SQRT_RATIO : MIN_SQRT_RATIO;
                    }

                    (int128 delta0, int128 delta1) = core.swap(
                        node.poolKey,
                        SwapParameters({
                            amount: tokenAmount.amount,
                            isToken1: isToken1,
                            sqrtRatioLimit: sqrtRatioLimit,
                            skipAhead: node.skipAhead
                        })
                    );

                    results[i][j] = Delta(delta0, delta1);

                    if (firstSwapAmount.token == address(0)) {
                        firstSwapAmount = isToken1
                            ? TokenAmount({amount: delta1, token: node.poolKey.token1})
                            : TokenAmount({amount: delta0, token: node.poolKey.token0});
                    }

                    if (isToken1) {
                        tokenAmount = TokenAmount({token: node.poolKey.token0, amount: -delta0});
                    } else {
                        tokenAmount = TokenAmount({token: node.poolKey.token1, amount: -delta1});
                    }
                }

                if (!isExactOut && uint256(int256(tokenAmount.amount)) < s.calculatedAmountThreshold) {
                    revert MinimumOutputNotReceived(i, uint256(int256(tokenAmount.amount)), s.calculatedAmountThreshold);
                }
                if (
                    isExactOut && s.calculatedAmountThreshold != 0
                        && uint256(-int256(tokenAmount.amount)) > s.calculatedAmountThreshold
                ) {
                    revert MaximumInputExceeded(i, uint256(-int256(tokenAmount.amount)), s.calculatedAmountThreshold);
                }

                if (firstSwapAmount.amount < 0) {
                    withdrawFromCore(firstSwapAmount.token, uint128(-firstSwapAmount.amount), swapper);
                } else {
                    payCore(swapper, firstSwapAmount.token, uint128(firstSwapAmount.amount));
                }

                if (tokenAmount.amount > 0) {
                    withdrawFromCore(tokenAmount.token, uint128(tokenAmount.amount), swapper);
                } else {
                    payCore(swapper, tokenAmount.token, uint128(-tokenAmount.amount));
                }
            }
        }
        return abi.encode(results);
    }

    function swap(RouteNode calldata node, TokenAmount calldata tokenAmount, uint128 calculatedAmountThreshold)
        external
        payable
        returns (Delta memory result)
    {
        Swap memory s;
        s.route = new RouteNode[](1);
        s.route[0] = node;
        s.tokenAmount = tokenAmount;
        s.calculatedAmountThreshold = calculatedAmountThreshold;
        return multihopSwap(s)[0];
    }

    function multihopSwap(Swap memory s) public payable returns (Delta[] memory result) {
        Swap[] memory swaps = new Swap[](1);
        swaps[0] = s;
        result = multiMultihopSwap(swaps)[0];
    }

    function multiMultihopSwap(Swap[] memory swaps) public payable returns (Delta[][] memory results) {
        results = abi.decode(lock(abi.encode(msg.sender, swaps)), (Delta[][]));
    }
}
