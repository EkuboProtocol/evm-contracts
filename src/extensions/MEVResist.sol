// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ICore, PoolKey, Bounds, CallPoints, SqrtRatio, UpdatePositionParameters} from "../interfaces/ICore.sol";
import {IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ILocker} from "../interfaces/IFlashAccountant.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";

function mevResistCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        // to store the initial tick
        beforeInitializePool: true,
        afterInitializePool: false,
        // so that we can prevent swaps that are not made via forward
        beforeSwap: true,
        afterSwap: false,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        // in order to accumulate any collected fees
        beforeCollectFees: true,
        afterCollectFees: false
    });
}

/// @notice Charges additional fees based on the relative size of the priority fee
contract MEVResist is BaseExtension, BaseForwardee, ILocker {
    using CoreLib for *;

    error ConcentratedLiquidityPoolsOnly();
    error NonzeroFeesOnly();
    error SwapMustHappenThroughForward();

    /// @return lastUpdateTime The last time this pool was updated
    /// @return tickLast The tick from the last time the pool was touched
    /// @return fees0 The fees in token0 collected since the last time the pool was touched that will be donated in the next block that it is touched again
    /// @return fees1 The fees in token1 collected since the last time the pool was touched that will be donated in the next block that it is touched again
    function getPoolState(bytes32 poolId)
        public
        view
        returns (uint32 lastUpdateTime, int32 tickLast, uint96 fees0, uint96 fees1)
    {
        assembly ("memory-safe") {
            let v := sload(poolId)
            lastUpdateTime := shr(224, v)
            tickLast := signextend(31, shr(192, v))
            fees0 := shr(160, shl(64, v))
            fees1 := shr(160, shl(160, v))
        }
    }

    function setPoolState(bytes32 poolId, uint32 lastUpdateTime, int32 tickLast, uint96 fees0, uint96 fees1) private {
        assembly ("memory-safe") {
            sstore(
                poolId,
                or(
                    or(or(shl(224, lastUpdateTime), shr(32, shl(224, tickLast))), shr(64, shl(160, fees0))),
                    shr(160, shl(160, fees1))
                )
            )
        }
    }

    constructor(ICore core) BaseExtension(core) BaseForwardee(core) {}

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return mevResistCallPoints();
    }

    function beforeInitializePool(address, PoolKey memory poolKey, int32 tick) external override {
        if (poolKey.tickSpacing() == FULL_RANGE_ONLY_TICK_SPACING) {
            revert ConcentratedLiquidityPoolsOnly();
        }
        if (poolKey.fee() == 0) {
            // nothing to multiply == no-op extension
            revert NonzeroFeesOnly();
        }

        setPoolState({
            poolId: poolKey.toPoolId(),
            lastUpdateTime: uint32(block.timestamp),
            tickLast: tick,
            fees0: 0,
            fees1: 0
        });
    }

    /// @notice We only allow swapping via forward to this extension
    function beforeSwap(address, PoolKey memory, int128, bool, SqrtRatio, uint256) external pure override {
        revert SwapMustHappenThroughForward();
    }

    // Allows users to collect pending fees before the first swap in the block happens
    function beforeCollectFees(address, PoolKey memory poolKey, bytes32, Bounds memory) external override {
        accumulatePoolFees(poolKey);
    }

    /// Prevents new liquidity from collecting on fees
    function beforeUpdatePosition(address, PoolKey memory poolKey, UpdatePositionParameters memory) external override {
        accumulatePoolFees(poolKey);
    }

    /// @notice Accumulates any pool fees from past blocks
    function accumulatePoolFees(PoolKey memory poolKey) public {
        // the only thing we lock for is accumulating fees, so all we need to encode is the pool key
        address target = address(core);
        assembly ("memory-safe") {
            let o := mload(0x40)
            mstore(o, shl(224, 0xf83d08ba))
            mcopy(add(o, 4), poolKey, 96)

            // If the call failed, pass through the revert
            if iszero(call(gas(), target, 0, o, 100, 0, 0)) {
                returndatacopy(o, 0, returndatasize())
                revert(o, returndatasize())
            }
        }
    }

    // Executes virtual orders for the specified initialized pool key. Protected because it is only called by core.
    function locked(uint256) external override onlyCore {
        PoolKey memory poolKey;
        assembly ("memory-safe") {
            poolKey := mload(0x40)
            // points the free memory pointer at pointer + 96
            mstore(0x40, add(poolKey, 96))

            // copy the poolkey out of calldata at the free memory pointer
            calldatacopy(poolKey, 36, 96)
        }

        bytes32 poolId = poolKey.toPoolId();

        (uint32 lastUpdateTime,, uint96 fees0, uint96 fees1) = getPoolState(poolId);

        uint32 currentTime = uint32(block.timestamp);

        unchecked {
            if (lastUpdateTime != currentTime) {
                (uint96 f0Pay, uint96 f1Pay) =
                    (uint96(FixedPointMathLib.zeroFloorSub(fees0, 1)), uint96(FixedPointMathLib.zeroFloorSub(fees1, 1)));

                if (f0Pay != 0 || f1Pay != 0) {
                    core.accumulateAsFees(poolKey, f0Pay, f1Pay);
                    core.load(poolKey.token0, poolKey.token1, bytes32(0), f0Pay, f1Pay);
                }

                (, int32 tick,) = core.poolState(poolId);

                setPoolState({
                    poolId: poolId,
                    lastUpdateTime: currentTime,
                    tickLast: tick,
                    fees0: fees0 - f0Pay,
                    fees1: fees1 - f1Pay
                });
            }
        }
    }

    function handleForwardData(uint256, address, bytes memory data) internal override returns (bytes memory result) {
        (PoolKey memory poolKey, int128 amount, bool isToken1, SqrtRatio sqrtRatioLimit, uint256 skipAhead) =
            abi.decode(data, (PoolKey, int128, bool, SqrtRatio, uint256));

        bytes32 poolId = poolKey.toPoolId();
        (uint32 lastUpdateTime, int32 tickLast, uint96 fees0, uint96 fees1) = getPoolState(poolId);

        uint32 currentTime = uint32(block.timestamp);

        unchecked {
            if (lastUpdateTime != currentTime) {
                (uint96 f0Pay, uint96 f1Pay) =
                    (uint96(FixedPointMathLib.zeroFloorSub(fees0, 1)), uint96(FixedPointMathLib.zeroFloorSub(fees1, 1)));

                if (f0Pay != 0 || f1Pay != 0) {
                    core.accumulateAsFees(poolKey, f0Pay, f1Pay);
                    core.load(poolKey.token0, poolKey.token1, bytes32(0), f0Pay, f1Pay);
                }

                (, tickLast,) = core.poolState(poolId);
                fees0 -= f0Pay;
                fees1 -= f1Pay;
            }
        }

        (int128 delta0, int128 delta1) = core.swap_611415377(poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);

        (, int32 tickAfterSwap,) = core.poolState(poolId);

        // however many tick spacings were crossed is the fee multiplier
        uint256 feeMultiplierX64 = (FixedPointMathLib.abs(tickAfterSwap - tickLast) << 64) / poolKey.tickSpacing();
        uint64 poolFee = poolKey.fee();
        uint64 additionalFee = uint64(FixedPointMathLib.min(type(uint64).max, (feeMultiplierX64 * poolFee) >> 64));

        if (additionalFee != 0) {
            if (amount < 0) {
                // take an additional fee from the calculated input amount equal to the `additionalFee - poolFee`
                if (delta0 > 0) {
                    uint128 fee;
                    unchecked {
                        uint128 inputAmount = uint128(uint256(int256(delta0)));
                        // first remove the fee to get the original input amount before we compute the additional fee
                        inputAmount -= computeFee(inputAmount, poolFee);
                        fee = amountBeforeFee(inputAmount, additionalFee) - inputAmount;
                    }

                    unchecked {
                        fees0 = uint96(FixedPointMathLib.min(type(uint96).max, uint256(fee) + fees0));
                        // we save the entire amount even if it overflows
                        core.save(address(this), poolKey.token0, poolKey.token1, bytes32(0), fee, 0);
                    }
                    delta0 += SafeCastLib.toInt128(fee);
                } else if (delta1 > 0) {
                    uint128 fee;
                    unchecked {
                        uint128 inputAmount = uint128(uint256(int256(delta1)));
                        // first remove the fee to get the original input amount before we compute the additional fee
                        inputAmount -= computeFee(inputAmount, poolFee);
                        fee = amountBeforeFee(inputAmount, additionalFee) - inputAmount;
                    }

                    unchecked {
                        fees1 = uint96(FixedPointMathLib.min(type(uint96).max, uint256(fee) + fees1));
                        // we save the entire amount even if it overflows
                        core.save(address(this), poolKey.token0, poolKey.token1, bytes32(0), 0, fee);
                    }
                    delta1 += SafeCastLib.toInt128(fee);
                }
            } else {
                if (delta0 < 0) {
                    uint128 fee;
                    unchecked {
                        uint128 outputAmount = uint128(uint256(-int256(delta0)));
                        fee = computeFee(outputAmount, additionalFee);
                    }

                    unchecked {
                        fees0 = uint96(FixedPointMathLib.min(type(uint96).max, uint256(fee) + fees0));
                        // we save the entire amount even if it overflows
                        core.save(address(this), poolKey.token0, poolKey.token1, bytes32(0), fee, 0);
                    }
                    delta0 += SafeCastLib.toInt128(fee);
                } else if (delta1 < 0) {
                    uint128 fee;
                    unchecked {
                        uint128 outputAmount = uint128(uint256(-int256(delta1)));
                        fee = computeFee(outputAmount, additionalFee);
                    }

                    unchecked {
                        fees1 = uint96(FixedPointMathLib.min(type(uint96).max, uint256(fee) + fees1));
                        // we save the entire amount even if it overflows
                        core.save(address(this), poolKey.token0, poolKey.token1, bytes32(0), 0, fee);
                    }
                    delta1 += SafeCastLib.toInt128(fee);
                }
            }
        }

        setPoolState({poolId: poolId, lastUpdateTime: currentTime, tickLast: tickLast, fees0: fees0, fees1: fees1});

        result = abi.encode(delta0, delta1);
    }
}
