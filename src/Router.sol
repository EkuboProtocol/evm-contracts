// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore, SwapParameters} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/poolKey.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "./math/constants.sol";
import {isPriceIncreasing} from "./math/swap.sol";
import {Permittable} from "./base/Permittable.sol";
import {SlippageChecker} from "./base/SlippageChecker.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

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
}

struct Delta {
    int128 amount0;
    int128 amount1;
}

contract Router is UsesCore, PayableMulticallable, SlippageChecker, Permittable, BaseLocker {
    error PartialSwapsDisallowed();
    error SlippageCheckFailed(int256 expectedAmount, int256 calculatedAmount);

    constructor(ICore core) BaseLocker(core) UsesCore(core) {}

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        (address swapper, int256 calculatedAmountThreshold, Swap[] memory swaps) =
            abi.decode(data, (address, int256, Swap[]));
        Delta[][] memory results = new Delta[][](swaps.length);
        unchecked {
            int256 totalCalculated;
            int256 totalSpecified;
            address specifiedToken;
            address calculatedToken;
            for (uint256 i = 0; i < swaps.length; i++) {
                Swap memory s = swaps[i];
                results[i] = new Delta[](s.route.length);

                TokenAmount memory firstSwapAmount;
                TokenAmount memory tokenAmount = s.tokenAmount;

                for (uint256 j = 0; j < s.route.length; j++) {
                    RouteNode memory node = s.route[j];

                    bool isToken1 = tokenAmount.token == node.poolKey.token1;

                    uint256 sqrtRatioLimit = node.sqrtRatioLimit;
                    if (sqrtRatioLimit == 0) {
                        sqrtRatioLimit = FixedPointMathLib.ternary(
                            isPriceIncreasing(tokenAmount.amount, isToken1), MAX_SQRT_RATIO, MIN_SQRT_RATIO
                        );
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

                    if (j == 0) {
                        firstSwapAmount = isToken1
                            ? TokenAmount({amount: delta1, token: node.poolKey.token1})
                            : TokenAmount({amount: delta0, token: node.poolKey.token0});
                    }

                    if (isToken1) {
                        if (delta1 != tokenAmount.amount) revert PartialSwapsDisallowed();
                        tokenAmount = TokenAmount({token: node.poolKey.token0, amount: -delta0});
                    } else {
                        if (delta0 != tokenAmount.amount) revert PartialSwapsDisallowed();
                        tokenAmount = TokenAmount({token: node.poolKey.token1, amount: -delta1});
                    }
                }

                // all the swaps must have the same input/output token
                assert(i == 0 || (calculatedToken == firstSwapAmount.token && specifiedToken == tokenAmount.token));
                specifiedToken = firstSwapAmount.token;
                totalSpecified += firstSwapAmount.amount;
                calculatedToken = tokenAmount.token;
                totalCalculated += tokenAmount.amount;
            }

            if (totalCalculated < calculatedAmountThreshold) {
                revert SlippageCheckFailed(calculatedAmountThreshold, totalCalculated);
            }

            if (totalSpecified < 0) {
                withdraw(specifiedToken, uint128(uint256(-totalSpecified)), swapper);
            } else {
                pay(swapper, specifiedToken, uint128(uint256(totalSpecified)));
            }

            if (totalCalculated > 0) {
                withdraw(calculatedToken, uint128(uint256(totalCalculated)), swapper);
            } else {
                pay(swapper, calculatedToken, uint128(uint256(-totalCalculated)));
            }
        }
        result = abi.encode(results);
    }

    function swap(RouteNode calldata node, TokenAmount calldata tokenAmount, int256 calculatedAmountThreshold)
        external
        payable
        returns (Delta memory result)
    {
        Swap[] memory swaps = new Swap[](1);
        RouteNode[] memory nodes = new RouteNode[](1);
        nodes[0] = node;
        swaps[0] = Swap(nodes, tokenAmount);
        result = abi.decode(lock(abi.encode(msg.sender, calculatedAmountThreshold, swaps)), (Delta[][]))[0][0];
    }

    function multihopSwap(Swap memory s, int256 calculatedAmountThreshold)
        external
        payable
        returns (Delta[] memory result)
    {
        Swap[] memory swaps = new Swap[](1);
        swaps[0] = s;
        result = abi.decode(lock(abi.encode(msg.sender, calculatedAmountThreshold, swaps)), (Delta[][]))[0];
    }

    function multiMultihopSwap(Swap[] memory swaps, int256 calculatedAmountThreshold)
        external
        payable
        returns (Delta[][] memory results)
    {
        results = abi.decode(lock(abi.encode(msg.sender, calculatedAmountThreshold, swaps)), (Delta[][]));
    }
}
