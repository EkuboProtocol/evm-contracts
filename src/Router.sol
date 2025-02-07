// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore, SwapParameters} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/poolKey.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO, NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
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
    bool isToken1;
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
        bytes1 callType = data[0];

        if (callType == bytes1(0x00)) {
            // swap
            (, address swapper, RouteNode memory node, TokenAmount memory tokenAmount, int256 calculatedAmountThreshold)
            = abi.decode(data, (bytes1, address, RouteNode, TokenAmount, int256));

            unchecked {
                uint128 value = uint128(
                    FixedPointMathLib.ternary(
                        node.poolKey.token0 == NATIVE_TOKEN_ADDRESS && !tokenAmount.isToken1 && tokenAmount.amount > 0,
                        uint128(tokenAmount.amount),
                        0
                    )
                );

                bool increasing = isPriceIncreasing(tokenAmount.amount, tokenAmount.isToken1);
                uint256 sqrtRatioLimit = FixedPointMathLib.ternary(
                    node.sqrtRatioLimit == 0,
                    FixedPointMathLib.ternary(increasing, MAX_SQRT_RATIO, MIN_SQRT_RATIO),
                    node.sqrtRatioLimit
                );

                (int128 delta0, int128 delta1) = core.swap{value: value}(
                    node.poolKey,
                    SwapParameters({
                        amount: tokenAmount.amount,
                        isToken1: tokenAmount.isToken1,
                        sqrtRatioLimit: sqrtRatioLimit,
                        skipAhead: node.skipAhead
                    })
                );

                int128 amountCalculated = tokenAmount.isToken1 ? -delta0 : -delta1;
                if (amountCalculated < calculatedAmountThreshold) {
                    revert SlippageCheckFailed(calculatedAmountThreshold, amountCalculated);
                }

                if (increasing) {
                    withdraw(node.poolKey.token0, uint128(-delta0), swapper);
                    pay(swapper, node.poolKey.token1, uint128(delta1));
                } else {
                    withdraw(node.poolKey.token1, uint128(-delta1), swapper);
                    if (uint128(delta0) <= value) {
                        withdraw(node.poolKey.token0, value - uint128(delta0), swapper);
                    } else {
                        pay(swapper, node.poolKey.token0, uint128(delta0));
                    }
                }

                result = abi.encode(Delta(delta0, delta1));
            }
        } else if (callType == bytes1(0x01)) {
            // multihopSwap
            (, address swapper, Swap memory s, int256 calculatedAmountThreshold) =
                abi.decode(data, (bytes1, address, Swap, int256));
            Delta[] memory results = new Delta[](s.route.length);
            TokenAmount memory tokenAmount = s.tokenAmount;
            TokenAmount memory firstSwapAmount;
            address specifiedToken;
            address calculatedToken;

            unchecked {
                for (uint256 j = 0; j < s.route.length; j++) {
                    RouteNode memory node = s.route[j];
                    uint256 sqrtRatioLimit = FixedPointMathLib.ternary(
                        node.sqrtRatioLimit == 0,
                        FixedPointMathLib.ternary(
                            isPriceIncreasing(tokenAmount.amount, tokenAmount.isToken1), MAX_SQRT_RATIO, MIN_SQRT_RATIO
                        ),
                        node.sqrtRatioLimit
                    );
                    uint128 value = uint128(
                        FixedPointMathLib.ternary(
                            j == 0 && !tokenAmount.isToken1 && node.poolKey.token0 == NATIVE_TOKEN_ADDRESS
                                && tokenAmount.amount > 0,
                            uint128(tokenAmount.amount),
                            0
                        )
                    );
                    (int128 delta0, int128 delta1) = core.swap{value: value}(
                        node.poolKey,
                        SwapParameters({
                            amount: tokenAmount.amount,
                            isToken1: tokenAmount.isToken1,
                            sqrtRatioLimit: sqrtRatioLimit,
                            skipAhead: node.skipAhead
                        })
                    );
                    results[j] = Delta(delta0, delta1);

                    if (j == 0) {
                        firstSwapAmount = tokenAmount.isToken1
                            ? TokenAmount({amount: delta1, isToken1: true})
                            : TokenAmount({amount: delta0 - int128(value), isToken1: false});
                        // Set specified token from first swap.
                        specifiedToken = tokenAmount.isToken1 ? node.poolKey.token1 : node.poolKey.token0;
                    }

                    if (tokenAmount.isToken1) {
                        if (delta1 != tokenAmount.amount) revert PartialSwapsDisallowed();
                        tokenAmount = TokenAmount({isToken1: false, amount: -delta0});
                    } else {
                        if (delta0 != tokenAmount.amount) revert PartialSwapsDisallowed();
                        tokenAmount = TokenAmount({isToken1: true, amount: -delta1});
                    }
                }

                if (tokenAmount.amount < calculatedAmountThreshold) {
                    revert SlippageCheckFailed(calculatedAmountThreshold, tokenAmount.amount);
                }

                // Determine calculated token based on initial direction.
                if (s.tokenAmount.isToken1) {
                    // Input was token1; output is token0.
                    specifiedToken = s.route[0].poolKey.token1;
                    calculatedToken = s.route[s.route.length - 1].poolKey.token0;
                } else {
                    // Input was token0; output is token1.
                    specifiedToken = s.route[0].poolKey.token0;
                    calculatedToken = s.route[s.route.length - 1].poolKey.token1;
                }

                if (firstSwapAmount.amount < 0) {
                    withdraw(specifiedToken, uint128(-firstSwapAmount.amount), swapper);
                } else {
                    pay(swapper, specifiedToken, uint128(firstSwapAmount.amount));
                }

                if (tokenAmount.amount > 0) {
                    withdraw(calculatedToken, uint128(tokenAmount.amount), swapper);
                } else {
                    pay(swapper, calculatedToken, uint128(-tokenAmount.amount));
                }
            }
            result = abi.encode(results);
        } else {
            // multiMultihopSwap
            (, address swapper, Swap[] memory swaps, int256 calculatedAmountThreshold) =
                abi.decode(data, (bytes1, address, Swap[], int256));

            Delta[][] memory results = new Delta[][](swaps.length);
            unchecked {
                int256 totalCalculated;
                int256 totalSpecified;
                address specifiedToken;
                address calculatedToken;
                for (uint256 i = 0; i < swaps.length; i++) {
                    Swap memory s = swaps[i];
                    results[i] = new Delta[](s.route.length);
                    TokenAmount memory tokenAmount = s.tokenAmount;
                    TokenAmount memory firstSwapAmount;

                    for (uint256 j = 0; j < s.route.length; j++) {
                        RouteNode memory node = s.route[j];
                        uint256 sqrtRatioLimit = FixedPointMathLib.ternary(
                            node.sqrtRatioLimit == 0,
                            FixedPointMathLib.ternary(
                                isPriceIncreasing(tokenAmount.amount, tokenAmount.isToken1),
                                MAX_SQRT_RATIO,
                                MIN_SQRT_RATIO
                            ),
                            node.sqrtRatioLimit
                        );
                        uint128 value = uint128(
                            FixedPointMathLib.ternary(
                                j == 0 && !tokenAmount.isToken1 && node.poolKey.token0 == NATIVE_TOKEN_ADDRESS
                                    && tokenAmount.amount > 0,
                                uint128(tokenAmount.amount),
                                0
                            )
                        );
                        (int128 delta0, int128 delta1) = core.swap{value: value}(
                            node.poolKey,
                            SwapParameters({
                                amount: tokenAmount.amount,
                                isToken1: tokenAmount.isToken1,
                                sqrtRatioLimit: sqrtRatioLimit,
                                skipAhead: node.skipAhead
                            })
                        );
                        results[i][j] = Delta(delta0, delta1);

                        if (j == 0) {
                            firstSwapAmount = tokenAmount.isToken1
                                ? TokenAmount({amount: delta1, isToken1: true})
                                : TokenAmount({amount: delta0 - int128(value), isToken1: false});
                        }

                        if (tokenAmount.isToken1) {
                            if (delta1 != tokenAmount.amount) revert PartialSwapsDisallowed();
                            tokenAmount = TokenAmount({isToken1: false, amount: -delta0});
                        } else {
                            if (delta0 != tokenAmount.amount) revert PartialSwapsDisallowed();
                            tokenAmount = TokenAmount({isToken1: true, amount: -delta1});
                        }
                    }

                    // Assert all swaps use the same input/output tokens.
                    address swapSpecifiedToken =
                        s.tokenAmount.isToken1 ? s.route[0].poolKey.token1 : s.route[0].poolKey.token0;
                    address swapCalculatedToken = s.tokenAmount.isToken1
                        ? s.route[s.route.length - 1].poolKey.token0
                        : s.route[s.route.length - 1].poolKey.token1;
                    if (i == 0) {
                        specifiedToken = swapSpecifiedToken;
                        calculatedToken = swapCalculatedToken;
                    } else {
                        if (specifiedToken != swapSpecifiedToken || calculatedToken != swapCalculatedToken) {
                            revert("Inconsistent tokens across swaps");
                        }
                    }

                    totalSpecified += firstSwapAmount.amount;
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
    }

    function swap(RouteNode calldata node, TokenAmount calldata tokenAmount, int256 calculatedAmountThreshold)
        external
        payable
        returns (Delta memory result)
    {
        result = abi.decode(
            lock(abi.encode(bytes1(0x00), msg.sender, node, tokenAmount, calculatedAmountThreshold)), (Delta)
        );
    }

    function multihopSwap(Swap memory s, int256 calculatedAmountThreshold)
        external
        payable
        returns (Delta[] memory result)
    {
        result = abi.decode(lock(abi.encode(bytes1(0x01), msg.sender, s, calculatedAmountThreshold)), (Delta[]));
    }

    function multiMultihopSwap(Swap[] memory swaps, int256 calculatedAmountThreshold)
        external
        payable
        returns (Delta[][] memory results)
    {
        results = abi.decode(lock(abi.encode(bytes1(0x02), msg.sender, swaps, calculatedAmountThreshold)), (Delta[][]));
    }
}
