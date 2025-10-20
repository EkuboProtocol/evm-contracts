// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity >=0.8.30;

import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/poolKey.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {PoolState} from "./types/poolState.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "./types/swapParameters.sol";

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

/// @title Ekubo Protocol Router
/// @author Moody Salem <moody@ekubo.org>
/// @notice Enables swapping and quoting against pools in Ekubo Protocol
/// @dev Provides high-level swap functionality including single-hop, multi-hop, and batch swaps
contract Router is UsesCore, PayableMulticallable, BaseLocker {
    using FlashAccountantLib for *;
    using CoreLib for *;

    uint256 private constant CALL_TYPE_SINGLE_SWAP = 0;
    uint256 private constant CALL_TYPE_MULTIHOP_SWAP = 1;
    uint256 private constant CALL_TYPE_MULTI_MULTIHOP_SWAP = 3; // == 1 | 2
    uint256 private constant CALL_TYPE_QUOTE = 4;

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
    /// @param params The parameters of the swap to make
    /// @return balanceUpdate Change in token0 and token1 balances of the pool
    function _swap(uint256 value, PoolKey memory poolKey, SwapParameters params)
        internal
        virtual
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) = CORE.swap(value, poolKey, params.withDefaultSqrtRatioLimit());
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_SINGLE_SWAP) {
            // swap
            (
                ,
                address swapper,
                PoolKey memory poolKey,
                SwapParameters params,
                int256 calculatedAmountThreshold,
                address recipient
            ) = abi.decode(data, (uint256, address, PoolKey, SwapParameters, int256, address));

            unchecked {
                uint256 value = FixedPointMathLib.ternary(
                    !params.isToken1() && !params.isExactOut() && poolKey.token0 == NATIVE_TOKEN_ADDRESS,
                    uint128(params.amount()),
                    0
                );

                bool increasing = params.isPriceIncreasing();

                (PoolBalanceUpdate balanceUpdate,) = _swap(value, poolKey, params);

                int128 amountCalculated = params.isToken1() ? -balanceUpdate.delta0() : -balanceUpdate.delta1();
                if (amountCalculated < calculatedAmountThreshold) {
                    revert SlippageCheckFailed(calculatedAmountThreshold, amountCalculated);
                }

                if (increasing) {
                    if (balanceUpdate.delta0() != 0) {
                        ACCOUNTANT.withdraw(poolKey.token0, recipient, uint128(-balanceUpdate.delta0()));
                    }
                    if (balanceUpdate.delta1() != 0) {
                        ACCOUNTANT.payFrom(swapper, poolKey.token1, uint128(balanceUpdate.delta1()));
                    }
                } else {
                    if (balanceUpdate.delta1() != 0) {
                        ACCOUNTANT.withdraw(poolKey.token1, recipient, uint128(-balanceUpdate.delta1()));
                    }

                    if (balanceUpdate.delta0() != 0) {
                        if (poolKey.token0 == NATIVE_TOKEN_ADDRESS) {
                            int256 valueDifference = int256(value) - int256(balanceUpdate.delta0());

                            // refund the overpaid ETH to the swapper
                            if (valueDifference > 0) {
                                ACCOUNTANT.withdraw(NATIVE_TOKEN_ADDRESS, swapper, uint128(uint256(valueDifference)));
                            } else if (valueDifference < 0) {
                                SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint128(uint256(-valueDifference)));
                            }
                        } else {
                            ACCOUNTANT.payFrom(swapper, poolKey.token0, uint128(balanceUpdate.delta0()));
                        }
                    }
                }

                result = abi.encode(balanceUpdate);
            }
        } else if ((callType & CALL_TYPE_MULTIHOP_SWAP) != 0) {
            address swapper;
            Swap[] memory swaps;
            int256 calculatedAmountThreshold;

            if (callType == CALL_TYPE_MULTIHOP_SWAP) {
                Swap memory s;
                // multihopSwap
                (, swapper, s, calculatedAmountThreshold) = abi.decode(data, (uint256, address, Swap, int256));

                swaps = new Swap[](1);
                swaps[0] = s;
            } else {
                // multiMultihopSwap
                (, swapper, swaps, calculatedAmountThreshold) = abi.decode(data, (uint256, address, Swap[], int256));
            }

            PoolBalanceUpdate[][] memory results = new PoolBalanceUpdate[][](swaps.length);

            unchecked {
                int256 totalCalculated;
                int256 totalSpecified;
                address specifiedToken;
                address calculatedToken;

                for (uint256 i = 0; i < swaps.length; i++) {
                    Swap memory s = swaps[i];
                    results[i] = new PoolBalanceUpdate[](s.route.length);

                    TokenAmount memory tokenAmount = s.tokenAmount;
                    totalSpecified += tokenAmount.amount;

                    for (uint256 j = 0; j < s.route.length; j++) {
                        RouteNode memory node = s.route[j];

                        bool isToken1 = tokenAmount.token == node.poolKey.token1;
                        require(isToken1 || tokenAmount.token == node.poolKey.token0);

                        (PoolBalanceUpdate update,) = _swap(
                            0,
                            node.poolKey,
                            createSwapParameters({
                                _amount: tokenAmount.amount,
                                _isToken1: isToken1,
                                _sqrtRatioLimit: node.sqrtRatioLimit,
                                _skipAhead: node.skipAhead
                            })
                        );
                        results[i][j] = update;

                        if (isToken1) {
                            if (update.delta1() != tokenAmount.amount) revert PartialSwapsDisallowed();
                            tokenAmount = TokenAmount({token: node.poolKey.token0, amount: -update.delta0()});
                        } else {
                            if (update.delta0() != tokenAmount.amount) revert PartialSwapsDisallowed();
                            tokenAmount = TokenAmount({token: node.poolKey.token1, amount: -update.delta1()});
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
                    ACCOUNTANT.withdraw(specifiedToken, swapper, uint128(uint256(-totalSpecified)));
                } else if (totalSpecified > 0) {
                    if (specifiedToken == NATIVE_TOKEN_ADDRESS) {
                        SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint128(uint256(totalSpecified)));
                    } else {
                        ACCOUNTANT.payFrom(swapper, specifiedToken, uint128(uint256(totalSpecified)));
                    }
                }

                if (totalCalculated > 0) {
                    ACCOUNTANT.withdraw(calculatedToken, swapper, uint128(uint256(totalCalculated)));
                } else if (totalCalculated < 0) {
                    if (calculatedToken == NATIVE_TOKEN_ADDRESS) {
                        SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint128(uint256(-totalCalculated)));
                    } else {
                        ACCOUNTANT.payFrom(swapper, calculatedToken, uint128(uint256(-totalCalculated)));
                    }
                }
            }

            if (callType == CALL_TYPE_MULTIHOP_SWAP) {
                result = abi.encode(results[0]);
            } else {
                result = abi.encode(results);
            }
        } else if (callType == CALL_TYPE_QUOTE) {
            (, PoolKey memory poolKey, SwapParameters params) = abi.decode(data, (uint256, PoolKey, SwapParameters));

            (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) = _swap(0, poolKey, params);

            revert QuoteReturnValue(balanceUpdate, stateAfter);
        }
    }

    /// @notice Executes a single-hop swap with a specified recipient
    /// @param poolKey Pool key identifying the pool to swap against
    /// @param params The swap parameters to execute
    /// @param calculatedAmountThreshold Minimum amount to receive (for slippage protection)
    /// @return balanceUpdate Change in token0 and token1 balance of the pool
    function swap(PoolKey memory poolKey, SwapParameters params, int256 calculatedAmountThreshold)
        public
        payable
        returns (PoolBalanceUpdate balanceUpdate)
    {
        balanceUpdate = swap(poolKey, params, calculatedAmountThreshold, msg.sender);
    }

    /// @notice Executes a single-hop swap with a specified recipient
    /// @param poolKey Pool key identifying the pool to swap against
    /// @param params The swap parameters to execute
    /// @param calculatedAmountThreshold Minimum amount to receive (for slippage protection)
    /// @param recipient Address to receive the output tokens
    /// @return balanceUpdate Change in token0 and token1 balance of the pool
    function swap(PoolKey memory poolKey, SwapParameters params, int256 calculatedAmountThreshold, address recipient)
        public
        payable
        returns (PoolBalanceUpdate balanceUpdate)
    {
        (balanceUpdate) = abi.decode(
            lock(abi.encode(CALL_TYPE_SINGLE_SWAP, msg.sender, poolKey, params, calculatedAmountThreshold, recipient)),
            (PoolBalanceUpdate)
        );
    }

    /// @notice Executes a single-hop swap with a specified recipient
    /// @param poolKey Pool key identifying the pool to swap against
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param sqrtRatioLimit Price limit for the swap (0 for no limit)
    /// @param skipAhead Number of ticks to skip ahead for gas optimization
    /// @param calculatedAmountThreshold Minimum amount to receive (for slippage protection)
    /// @param recipient Address to receive the output tokens
    /// @return balanceUpdate Change in token0 and token1 balance of the pool
    function swap(
        PoolKey memory poolKey,
        bool isToken1,
        int128 amount,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead,
        int256 calculatedAmountThreshold,
        address recipient
    ) public payable returns (PoolBalanceUpdate balanceUpdate) {
        balanceUpdate = swap(
            poolKey,
            createSwapParameters({
                _isToken1: isToken1, _amount: amount, _sqrtRatioLimit: sqrtRatioLimit, _skipAhead: skipAhead
            }),
            calculatedAmountThreshold,
            recipient
        );
    }

    /// @notice Executes a single-hop swap with msg.sender as recipient
    /// @param poolKey Pool key identifying the pool to swap against
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param sqrtRatioLimit Price limit for the swap (0 for no limit)
    /// @param skipAhead Number of ticks to skip ahead for gas optimization
    /// @param calculatedAmountThreshold Minimum amount to receive (for slippage protection)
    /// @return balanceUpdate Change in token0 and token1 balance of the pool
    function swap(
        PoolKey memory poolKey,
        bool isToken1,
        int128 amount,
        SqrtRatio sqrtRatioLimit,
        uint256 skipAhead,
        int256 calculatedAmountThreshold
    ) external payable returns (PoolBalanceUpdate balanceUpdate) {
        balanceUpdate = swap(
            poolKey, isToken1, amount, sqrtRatioLimit, skipAhead, calculatedAmountThreshold, msg.sender
        );
    }

    /// @notice Executes a single-hop swap with no slippage protection
    /// @param poolKey Pool key identifying the pool to swap against
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param sqrtRatioLimit Price limit for the swap (0 for no limit)
    /// @param skipAhead Number of ticks to skip ahead for gas optimization
    /// @return balanceUpdate Change in token0 and token1 balance of the pool
    function swap(PoolKey memory poolKey, bool isToken1, int128 amount, SqrtRatio sqrtRatioLimit, uint256 skipAhead)
        external
        payable
        returns (PoolBalanceUpdate balanceUpdate)
    {
        balanceUpdate = swap(poolKey, isToken1, amount, sqrtRatioLimit, skipAhead, type(int256).min, msg.sender);
    }

    /// @notice Executes a single-hop swap using RouteNode and TokenAmount structs
    /// @param node Route node containing pool and swap parameters
    /// @param tokenAmount Token and amount to swap
    /// @param calculatedAmountThreshold Minimum amount to receive (for slippage protection)
    /// @return balanceUpdate Change in token0 and token1 balance of the pool
    function swap(RouteNode memory node, TokenAmount memory tokenAmount, int256 calculatedAmountThreshold)
        public
        payable
        returns (PoolBalanceUpdate balanceUpdate)
    {
        balanceUpdate = swap(
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
        returns (PoolBalanceUpdate[] memory result)
    {
        result = abi.decode(
            lock(abi.encode(CALL_TYPE_MULTIHOP_SWAP, msg.sender, s, calculatedAmountThreshold)), (PoolBalanceUpdate[])
        );
    }

    /// @notice Executes multiple multi-hop swaps in a single transaction
    /// @param swaps Array of swap structs, each containing a route and initial token amount
    /// @param calculatedAmountThreshold Minimum total final amount to receive (for slippage protection)
    /// @return results Array of delta arrays, one for each swap
    function multiMultihopSwap(Swap[] memory swaps, int256 calculatedAmountThreshold)
        external
        payable
        returns (PoolBalanceUpdate[][] memory results)
    {
        results = abi.decode(
            lock(abi.encode(CALL_TYPE_MULTI_MULTIHOP_SWAP, msg.sender, swaps, calculatedAmountThreshold)),
            (PoolBalanceUpdate[][])
        );
    }

    /// @notice Error used to return quote values from the quote function
    /// @param balanceUpdate Change in token0 and token1 balance of the pool
    /// @param poolState The state after the swap
    error QuoteReturnValue(PoolBalanceUpdate balanceUpdate, PoolState poolState);

    /// @notice Quotes the result of a swap without executing it
    /// @dev Uses a revert-based mechanism to return the quote without state changes
    /// @param poolKey Pool key identifying the pool to quote against
    /// @param isToken1 True if swapping token1, false if swapping token0
    /// @param amount Amount to swap (positive for exact input, negative for exact output)
    /// @param sqrtRatioLimit Price limit for the swap (0 for no limit)
    /// @param skipAhead Number of ticks to skip ahead for gas optimization
    /// @return balanceUpdate The change in pool balances resulting from the swap
    /// @return stateAfter The state of the pool after the swap is complete
    function quote(PoolKey memory poolKey, bool isToken1, int128 amount, SqrtRatio sqrtRatioLimit, uint256 skipAhead)
        external
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        bytes memory revertData = lockAndExpectRevert(
            abi.encode(
                CALL_TYPE_QUOTE,
                poolKey,
                createSwapParameters({
                    _isToken1: isToken1, _amount: amount, _sqrtRatioLimit: sqrtRatioLimit, _skipAhead: skipAhead
                })
            )
        );

        // check that the sig matches the error data

        bytes4 sig;
        assembly ("memory-safe") {
            sig := mload(add(revertData, 32))
        }
        if (sig == QuoteReturnValue.selector && revertData.length == 68) {
            assembly ("memory-safe") {
                balanceUpdate := mload(add(revertData, 36))
                stateAfter := mload(add(revertData, 68))
            }
        } else {
            assembly ("memory-safe") {
                revert(add(revertData, 32), mload(revertData))
            }
        }
    }
}
