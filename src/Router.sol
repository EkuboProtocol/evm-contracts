// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {Payable} from "./base/Payable.sol";
import {Clearable} from "./base/Clearable.sol";
import {CoreLocker} from "./base/CoreLocker.sol";
import {Core, SwapParameters} from "./Core.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {PoolKey, PositionKey} from "./types/keys.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity} from "./math/liquidity.sol";

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

contract Router is Multicallable, Payable, Clearable, CoreLocker {
    constructor(Core core, WETH weth) CoreLocker(core) Payable(weth) Clearable(weth) {}

    function handleLockData(bytes calldata data) internal override returns (bytes memory result) {
        (Swap[] memory swaps) = abi.decode(data, (Swap[]));
        Delta[][] memory results = new Delta[][](swaps.length);
        for (uint256 i = 0; i < swaps.length; i++) {
            Swap memory s = swaps[i];
            results[i] = new Delta[](s.route.length);

            for (uint256 j = 0; j < s.route.length; j++) {
                RouteNode memory node = s.route[j];
                TokenAmount memory tokenAmount = s.tokenAmount;

                bool isToken1 = tokenAmount.token == node.poolKey.token1;

                (int128 delta0, int128 delta1) = core.swap(
                    node.poolKey,
                    SwapParameters({
                        amount: tokenAmount.amount,
                        isToken1: tokenAmount.token == node.poolKey.token1,
                        sqrtRatioLimit: node.sqrtRatioLimit,
                        skipAhead: node.skipAhead
                    })
                );

                results[i][j] = Delta(delta0, delta1);

                if (isToken1) {
                    tokenAmount = TokenAmount({token: node.poolKey.token0, amount: -delta0});
                } else {
                    tokenAmount = TokenAmount({token: node.poolKey.token1, amount: -delta1});
                }
            }
        }
        return abi.encode(results);
    }

    function swap(RouteNode calldata node, TokenAmount calldata tokenAmount) external returns (Delta memory result) {
        Swap memory s;
        s.route = new RouteNode[](1);
        s.route[0] = node;
        s.tokenAmount = tokenAmount;
        return multihop_swap(s)[0];
    }

    function multihop_swap(Swap memory s) public returns (Delta[] memory result) {
        Swap[] memory swaps = new Swap[](1);
        swaps[0] = s;
        result = multi_multihop_swap(swaps)[0];
    }

    function multi_multihop_swap(Swap[] memory swaps) public returns (Delta[][] memory results) {
        results = abi.decode(lock(abi.encode(swaps)), (Delta[][]));
    }
}
