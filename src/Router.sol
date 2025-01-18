// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {CoreLocker} from "./base/CoreLocker.sol";
import {ICore, SwapParameters} from "./interfaces/ICore.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {PoolKey, PositionKey} from "./types/keys.sol";
import {tickToSqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "./math/ticks.sol";
import {maxLiquidity} from "./math/liquidity.sol";
import {isPriceIncreasing} from "./math/swap.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";

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

contract Router is Multicallable, CoreLocker {
    constructor(ICore core) CoreLocker(core) {}

    function handleLockData(bytes calldata data) internal override returns (bytes memory result) {
        (address swapper, Swap[] memory swaps) = abi.decode(data, (address, Swap[]));
        Delta[][] memory results = new Delta[][](swaps.length);
        unchecked {
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

    function swap(RouteNode calldata node, TokenAmount calldata tokenAmount)
        external
        payable
        returns (Delta memory result)
    {
        Swap memory s;
        s.route = new RouteNode[](1);
        s.route[0] = node;
        s.tokenAmount = tokenAmount;
        return multihop_swap(s)[0];
    }

    function multihop_swap(Swap memory s) public payable returns (Delta[] memory result) {
        Swap[] memory swaps = new Swap[](1);
        swaps[0] = s;
        result = multi_multihop_swap(swaps)[0];
    }

    function multi_multihop_swap(Swap[] memory swaps) public payable returns (Delta[][] memory results) {
        results = abi.decode(lock(abi.encode(msg.sender, swaps)), (Delta[][]));
    }
}
