// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/poolKey.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {isPriceIncreasing} from "./math/isPriceIncreasing.sol";
import {SqrtRatio, MIN_SQRT_RATIO_RAW, MAX_SQRT_RATIO_RAW} from "./types/sqrtRatio.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {PoolState} from "./types/poolState.sol";

/// @notice Represents a single hop in a multi-hop swap route
/// @dev Contains pool information and swap parameters for one step
struct RouteNode {
    /// @notice Pool key identifying the pool for this hop
    PoolKey poolKey;
    /// @notice Price limit for this hop (0 for no limit)
    SqrtRatio sqrtRatioLimit;
    /// @notice Number of ticks to skip ahead for gas optimization
    uint256 skipAhead;
}

/// @notice Represents a token and amount pair
/// @dev Used to specify input/output tokens and amounts in swaps
struct TokenAmount {
    /// @notice Address of the token
    address token;
    /// @notice Amount of the token (positive or negative)
    int128 amount;
}

/// @notice Represents a multi-hop swap with route and initial token amount
/// @dev Contains the complete path and starting point for a swap
struct Swap {
    /// @notice Array of route nodes defining the swap path
    RouteNode[] route;
    /// @notice Initial token and amount for the swap
    TokenAmount tokenAmount;
}

/// @notice Represents the change in token balances from a swap
/// @dev Used to track balance deltas for both tokens in a pool
struct Delta {
    /// @notice Change in token0 balance
    int128 amount0;
    /// @notice Change in token1 balance
    int128 amount1;
}

/// @notice Replaces a zero value of sqrtRatioLimit with the minimum or maximum depending on the swap direction
/// @dev Provides default price limits to prevent reverts when no limit is specified
/// @param sqrtRatioLimit The provided sqrt ratio limit (0 for default)
/// @param isToken1 True if swapping token1, false if swapping token0
/// @param amount Amount to swap (positive for exact input, negative for exact output)
/// @return result The sqrt ratio limit to use (original or default)
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

/// @title Ekubo Protocol Router
/// @author Moody Salem <moody@ekubo.org>
/// @notice Enables swapping and quoting against pools in Ekubo Protocol
/// @dev Provides high-level swap functionality including single-hop, multi-hop, and batch swaps
contract Router is UsesCore, PayableMulticallable, BaseLocker {
    using CoreLib for *;

    /// @notice Thrown when a swap doesn't consume the full input amount
    error PartialSwapsDisallowed();

    /// @notice Thrown when the calculated amount doesn't meet the minimum threshold
    /// @param expectedAmount The minimum expected amount
    /// @param calculatedAmount The actual calculated amount
    error SlippageCheckFailed(int256 expectedAmount, int256 calculatedAmount);

    /// @notice Thrown when tokens don't match across multiple swaps
    /// @param index The index of the mismatched swap
    error TokensMismatch(uint256 index);

    /// @notice Constructs the Router contract
    /// @param core The core contract instance
    constructor(ICore core) BaseLocker(core) UsesCore(core) {}

    /// @notice Internal function to execute a swap against the core contract
    /// @dev Virtual function that can be overridden by derived contracts
    /// @param value Native token value to send with the swap
    /// @param poolKey Pool key identifying the pool
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @param sqrtRatioLimit Price limit for the swap
    /// @param skipAhead Number of ticks to skip ahead for gas optimization
    /// @return delta0 Change in token0 balance
    /// @return delta1 Change in token1 balance
    function _swap(
        uint256 value,
        PoolKey memory poolKey,
        int128 amount,
        bool isToken1,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead
    ) internal virtual returns (int128 delta0, int128 delta1, PoolState stateAfter) {
        (delta0, delta1, stateAfter) = CORE.swap(value, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);
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

                (int128 delta0, int128 delta1,) = _swap(value, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);

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

                        (int128 delta0, int128 delta1,) =
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

            (int128 delta0, int128 delta1, PoolState stateAfter) =
                _swap(0, poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);

            revert QuoteReturnValue(delta0, delta1, stateAfter);
        }
    }

    /// @notice Executes a single-hop swap with a specified recipient
    /// @param poolKey Pool key identifying the pool to swap against
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param sqrtRatioLimit Price limit for the swap (0 for no limit)
    /// @param skipAhead Number of ticks to skip ahead for gas optimization
    /// @param calculatedAmountThreshold Minimum amount to receive (for slippage protection)
    /// @param recipient Address to receive the output tokens
    /// @return delta0 Change in token0 balance
    /// @return delta1 Change in token1 balance
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

    /// @notice Executes a single-hop swap with msg.sender as recipient
    /// @param poolKey Pool key identifying the pool to swap against
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param sqrtRatioLimit Price limit for the swap (0 for no limit)
    /// @param skipAhead Number of ticks to skip ahead for gas optimization
    /// @param calculatedAmountThreshold Minimum amount to receive (for slippage protection)
    /// @return delta0 Change in token0 balance
    /// @return delta1 Change in token1 balance
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

    /// @notice Executes a single-hop swap with no slippage protection
    /// @param poolKey Pool key identifying the pool to swap against
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param sqrtRatioLimit Price limit for the swap (0 for no limit)
    /// @param skipAhead Number of ticks to skip ahead for gas optimization
    /// @return delta0 Change in token0 balance
    /// @return delta1 Change in token1 balance
    function swap(PoolKey memory poolKey, bool isToken1, int128 amount, SqrtRatio sqrtRatioLimit, uint256 skipAhead)
        external
        payable
        returns (int128 delta0, int128 delta1)
    {
        (delta0, delta1) = swap(poolKey, isToken1, amount, sqrtRatioLimit, skipAhead, type(int256).min, msg.sender);
    }

    /// @notice Executes a single-hop swap using RouteNode and TokenAmount structs
    /// @param node Route node containing pool and swap parameters
    /// @param tokenAmount Token and amount to swap
    /// @param calculatedAmountThreshold Minimum amount to receive (for slippage protection)
    /// @return delta0 Change in token0 balance
    /// @return delta1 Change in token1 balance
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

    /// @notice Executes a multi-hop swap through multiple pools
    /// @param s Swap struct containing the route and initial token amount
    /// @param calculatedAmountThreshold Minimum final amount to receive (for slippage protection)
    /// @return result Array of deltas for each hop in the swap
    function multihopSwap(Swap memory s, int256 calculatedAmountThreshold)
        external
        payable
        returns (Delta[] memory result)
    {
        result = abi.decode(lock(abi.encode(bytes1(0x01), msg.sender, s, calculatedAmountThreshold)), (Delta[]));
    }

    /// @notice Executes multiple multi-hop swaps in a single transaction
    /// @param swaps Array of swap structs, each containing a route and initial token amount
    /// @param calculatedAmountThreshold Minimum total final amount to receive (for slippage protection)
    /// @return results Array of delta arrays, one for each swap
    function multiMultihopSwap(Swap[] memory swaps, int256 calculatedAmountThreshold)
        external
        payable
        returns (Delta[][] memory results)
    {
        results = abi.decode(lock(abi.encode(bytes1(0x02), msg.sender, swaps, calculatedAmountThreshold)), (Delta[][]));
    }

    /// @notice Error used to return quote values from the quote function
    /// @param delta0 Change in token0 balance
    /// @param delta1 Change in token1 balance
    /// @param poolState The state after the swap
    error QuoteReturnValue(int128 delta0, int128 delta1, PoolState poolState);

    /// @notice Quotes the result of a swap without executing it
    /// @dev Uses a revert-based mechanism to return the quote without state changes
    /// @param poolKey Pool key identifying the pool to quote against
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param sqrtRatioLimit Price limit for the swap (0 for no limit)
    /// @param skipAhead Number of ticks to skip ahead for gas optimization
    /// @return delta0 Change in token0 balance
    /// @return delta1 Change in token1 balance
    function quote(PoolKey memory poolKey, bool isToken1, int128 amount, SqrtRatio sqrtRatioLimit, uint256 skipAhead)
        external
        returns (int128 delta0, int128 delta1, PoolState stateAfter)
    {
        sqrtRatioLimit = defaultSqrtRatioLimit(sqrtRatioLimit, isToken1, amount);

        bytes memory revertData =
            lockAndExpectRevert(abi.encode(bytes1(0x03), poolKey, isToken1, amount, sqrtRatioLimit, skipAhead));

        // check that the sig matches the error data

        bytes4 sig;
        assembly ("memory-safe") {
            sig := mload(add(revertData, 32))
        }
        if (sig == QuoteReturnValue.selector && revertData.length == 100) {
            assembly ("memory-safe") {
                delta0 := mload(add(revertData, 36))
                delta1 := mload(add(revertData, 68))
                stateAfter := mload(add(revertData, 100))
            }
        } else {
            assembly ("memory-safe") {
                revert(add(revertData, 32), mload(revertData))
            }
        }
    }
}
