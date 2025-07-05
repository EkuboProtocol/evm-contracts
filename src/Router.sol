// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {IForwardee} from "./interfaces/IFlashAccountant.sol";
import {ICore} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/poolKey.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {isPriceIncreasing} from "./math/isPriceIncreasing.sol";
import {Permittable} from "./base/Permittable.sol";
import {SlippageChecker} from "./base/SlippageChecker.sol";
import {SqrtRatio, toSqrtRatio, MIN_SQRT_RATIO_RAW, MAX_SQRT_RATIO_RAW} from "./types/sqrtRatio.sol";
import {MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "./types/sqrtRatio.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {CoreLib} from "./libraries/CoreLib.sol";

struct RouteNode {
    PoolKey poolKey;
    SqrtRatio sqrtRatioLimit;
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

/// Replaces a zero value of sqrtRatioLimit with the minimum or maximum depending on the swap direction without any jumps
function defaultSqrtRatioLimit(SqrtRatio sqrtRatioLimit, bool isToken1, int128 amount)
    pure
    returns (SqrtRatio result)
{
    assembly ("memory-safe") {
        let increasing := xor(isToken1, slt(amount, 0))
        let defaultValue := add(mul(increasing, MAX_SQRT_RATIO_RAW), mul(iszero(increasing), MIN_SQRT_RATIO_RAW))
        result := add(sqrtRatioLimit, mul(iszero(sqrtRatioLimit), defaultValue))
    }
}

/// @title Ekubo Router
/// @author Moody Salem <moody@ekubo.org>
/// @notice Enables swapping and quoting against pools in Ekubo Protocol
contract Router is UsesCore, PayableMulticallable, SlippageChecker, Permittable, BaseLocker {
    using CoreLib for *;

    error PartialSwapsDisallowed();
    error SlippageCheckFailed(int256 expectedAmount, int256 calculatedAmount);
    error TokensMismatch(uint256 index);

    constructor(ICore core) BaseLocker(core) UsesCore(core) {}

    function _swap(
        uint256 value,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) internal virtual returns (int128 delta0, int128 delta1) {
        (delta0, delta1) = core.swap(value, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        bytes1 callType = data[0];

        if (callType == bytes1(0x00)) {
            // swap
            (
                ,
                address swapper,
                PoolKey memory poolKey,
                bool isToken1,
                int128 amount,
                SqrtRatio sqrtRatioLimit,
                uint256 skipAhead,
                int256 calculatedAmountThreshold,
                address recipient
            ) = abi.decode(data, (bytes1, address, PoolKey, bool, int128, SqrtRatio, uint256, int256, address));

            unchecked {
                uint256 value = FixedPointMathLib.ternary(
                    !isToken1 && poolKey.token0 == NATIVE_TOKEN_ADDRESS && amount > 0, uint128(amount), 0
                );

                bool increasing = isPriceIncreasing(amount, isToken1);

                sqrtRatioLimit = defaultSqrtRatioLimit(sqrtRatioLimit, isToken1, amount);

                (int128 delta0, int128 delta1) = _swap(value, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);

                int128 amountCalculated = isToken1 ? -delta0 : -delta1;
                if (amountCalculated < calculatedAmountThreshold) {
                    revert SlippageCheckFailed(calculatedAmountThreshold, amountCalculated);
                }

                if (increasing) {
                    withdraw(poolKey.token0, uint128(-delta0), recipient);
                    pay(swapper, poolKey.token1, uint128(delta1));
                } else {
                    withdraw(poolKey.token1, uint128(-delta1), recipient);
                    if (uint128(delta0) <= value) {
                        withdraw(poolKey.token0, uint128(value) - uint128(delta0), swapper);
                    } else {
                        pay(swapper, poolKey.token0, uint128(delta0));
                    }
                }

                result = abi.encode(delta0, delta1);
            }
        } else if (callType == bytes1(0x01) || callType == bytes1(0x02)) {
            address swapper;
            Swap[] memory swaps;
            int256 calculatedAmountThreshold;

            if (callType == bytes1(0x01)) {
                Swap memory s;
                // multihopSwap
                (, swapper, s, calculatedAmountThreshold) = abi.decode(data, (bytes1, address, Swap, int256));

                swaps = new Swap[](1);
                swaps[0] = s;
            } else {
                // multiMultihopSwap
                (, swapper, swaps, calculatedAmountThreshold) = abi.decode(data, (bytes1, address, Swap[], int256));
            }

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
                    totalSpecified += tokenAmount.amount;

                    for (uint256 j = 0; j < s.route.length; j++) {
                        RouteNode memory node = s.route[j];

                        bool isToken1 = tokenAmount.token == node.poolKey.token1;
                        require(isToken1 || tokenAmount.token == node.poolKey.token0);

                        SqrtRatio sqrtRatioLimit =
                            defaultSqrtRatioLimit(node.sqrtRatioLimit, isToken1, tokenAmount.amount);

                        (int128 delta0, int128 delta1) =
                            _swap(0, node.poolKey, tokenAmount.amount, isToken1, sqrtRatioLimit, node.skipAhead);
                        results[i][j] = Delta(delta0, delta1);

                        if (isToken1) {
                            if (delta1 != tokenAmount.amount) revert PartialSwapsDisallowed();
                            tokenAmount = TokenAmount({token: node.poolKey.token0, amount: -delta0});
                        } else {
                            if (delta0 != tokenAmount.amount) revert PartialSwapsDisallowed();
                            tokenAmount = TokenAmount({token: node.poolKey.token1, amount: -delta1});
                        }
                    }

                    totalCalculated += tokenAmount.amount;

                    if (i == 0) {
                        specifiedToken = s.tokenAmount.token;
                        calculatedToken = tokenAmount.token;
                    } else {
                        if (specifiedToken != s.tokenAmount.token || calculatedToken != tokenAmount.token) {
                            revert TokensMismatch(i);
                        }
                    }
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

            if (callType == bytes1(0x01)) {
                result = abi.encode(results[0]);
            } else {
                result = abi.encode(results);
            }
        } else if (callType == bytes1(0x03)) {
            (, PoolKey memory poolKey, bool isToken1, int128 amount, SqrtRatio sqrtRatioLimit, uint256 skipAhead) =
                abi.decode(data, (bytes1, PoolKey, bool, int128, SqrtRatio, uint256));

            (int128 delta0, int128 delta1) = _swap(0, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);

            revert QuoteReturnValue(delta0, delta1);
        }
    }

    function swap(
        PoolKey memory poolKey,
        bool isToken1,
        int128 amount,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead,
        int256 calculatedAmountThreshold,
        address recipient
    ) public payable returns (int128 delta0, int128 delta1) {
        (delta0, delta1) = abi.decode(
            lock(
                abi.encode(
                    bytes1(0x00),
                    msg.sender,
                    poolKey,
                    isToken1,
                    amount,
                    sqrtRatioLimit,
                    skipAhead,
                    calculatedAmountThreshold,
                    recipient
                )
            ),
            (int128, int128)
        );
    }

    function swap(
        PoolKey memory poolKey,
        bool isToken1,
        int128 amount,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead,
        int256 calculatedAmountThreshold
    ) external payable returns (int128 delta0, int128 delta1) {
        (delta0, delta1) =
            swap(poolKey, isToken1, amount, sqrtRatioLimit, skipAhead, calculatedAmountThreshold, msg.sender);
    }

    function swap(PoolKey memory poolKey, bool isToken1, int128 amount, SqrtRatio sqrtRatioLimit, uint256 skipAhead)
        external
        payable
        returns (int128 delta0, int128 delta1)
    {
        (delta0, delta1) = swap(poolKey, isToken1, amount, sqrtRatioLimit, skipAhead, type(int256).min, msg.sender);
    }

    function swap(RouteNode memory node, TokenAmount memory tokenAmount, int256 calculatedAmountThreshold)
        public
        payable
        returns (int128 delta0, int128 delta1)
    {
        (delta0, delta1) = swap(
            node.poolKey,
            node.poolKey.token1 == tokenAmount.token,
            tokenAmount.amount,
            node.sqrtRatioLimit,
            node.skipAhead,
            calculatedAmountThreshold,
            msg.sender
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

    error QuoteReturnValue(int128 delta0, int128 delta1);

    function quote(PoolKey memory poolKey, bool isToken1, int128 amount, SqrtRatio sqrtRatioLimit, uint256 skipAhead)
        external
        returns (int128 delta0, int128 delta1)
    {
        sqrtRatioLimit = defaultSqrtRatioLimit(sqrtRatioLimit, isToken1, amount);

        bytes memory revertData =
            lockAndExpectRevert(abi.encode(bytes1(0x03), poolKey, isToken1, amount, sqrtRatioLimit, skipAhead));

        // check that the sig matches the error data

        bytes4 sig;
        assembly ("memory-safe") {
            sig := mload(add(revertData, 32))
        }
        if (sig == QuoteReturnValue.selector && revertData.length == 68) {
            assembly ("memory-safe") {
                delta0 := mload(add(revertData, 36))
                delta1 := mload(add(revertData, 68))
            }
        } else {
            assembly ("memory-safe") {
                revert(add(revertData, 32), mload(revertData))
            }
        }
    }
}
