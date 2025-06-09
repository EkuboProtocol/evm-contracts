// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ICore, PoolKey, Bounds, CallPoints, SqrtRatio} from "../interfaces/ICore.sol";
import {IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
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
        beforeUpdatePosition: false,
        afterUpdatePosition: false,
        // in order to accumulate any collected fees
        beforeCollectFees: true,
        afterCollectFees: false
    });
}

/// @notice Charges additional fees based on the relative size of the priority fee
contract MEVResist is BaseExtension, BaseForwardee, ILocker, ExposedStorage {
    using CoreLib for *;

    error ConcentratedLiquidityPoolsOnly();
    error NonzeroFeesOnly();
    error SwapMustHappenThroughForward();

    struct PoolState {
        // The last time we touched this pool
        uint32 lastUpdateTime;
        // The tick from the last time the pool was touched
        int32 tickLast;
    }

    /// @notice The state of each pool
    mapping(bytes32 poolId => PoolState) private poolState;

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

        poolState[poolKey.toPoolId()] = PoolState({lastUpdateTime: uint32(block.timestamp), tickLast: tick});
    }

    /// @notice We only allow swapping via forward to this extension
    function beforeSwap(address, PoolKey memory, int128, bool, SqrtRatio, uint256) external pure override {
        revert SwapMustHappenThroughForward();
    }

    function beforeCollectFees(address, PoolKey memory poolKey, bytes32, Bounds memory) external override {
        accumulatePoolFees(poolKey);
    }

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
        _getAndUpdatePoolState(poolKey.toPoolId(), poolKey);
    }

    function _getAndUpdatePoolState(bytes32 poolId, PoolKey memory poolKey) private returns (int32 tick) {
        PoolState storage state = poolState[poolId];

        uint32 currentTime = uint32(block.timestamp);
        // first thing's first, update the last update time
        if (state.lastUpdateTime != currentTime) {
            (uint128 s0, uint128 s1) = core.savedBalances(address(this), poolKey.token0, poolKey.token1, poolId);
            (uint128 f0, uint128 f1) =
                (uint128(FixedPointMathLib.zeroFloorSub(s0, 1)), uint128(FixedPointMathLib.zeroFloorSub(s1, 1)));

            if (f0 != 0 || f1 != 0) {
                core.accumulateAsFees(poolKey, f0, f1);
                core.load(poolKey.token0, poolKey.token1, poolId, f0, f1);
            }

            (, tick,) = core.poolState(poolId);
            (state.lastUpdateTime, state.tickLast) = (currentTime, tick);
        } else {
            tick = state.tickLast;
        }
    }

    function handleForwardData(uint256, address, bytes memory data) internal override returns (bytes memory result) {
        (PoolKey memory poolKey, int128 amount, bool isToken1, SqrtRatio sqrtRatioLimit, uint256 skipAhead) =
            abi.decode(data, (PoolKey, int128, bool, SqrtRatio, uint256));

        bytes32 poolId = poolKey.toPoolId();
        int32 tickStart = _getAndUpdatePoolState(poolId, poolKey);

        (int128 delta0, int128 delta1) = core.swap_611415377(poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);
        (, int32 tickAfterSwap,) = core.poolState(poolId);

        // however many tick spacings were crossed is the fee multiplier
        uint256 feeMultiplier = FixedPointMathLib.abs(tickAfterSwap - tickStart) / poolKey.tickSpacing();

        if (feeMultiplier != 0) {
            uint64 poolFee = poolKey.fee();
            uint64 additionalFee = uint64(FixedPointMathLib.min(type(uint64).max, feeMultiplier * poolFee));

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

                    core.save(address(this), poolKey.token0, poolKey.token1, poolId, fee, 0);
                    delta0 += SafeCastLib.toInt128(fee);
                } else if (delta1 > 0) {
                    uint128 fee;
                    unchecked {
                        uint128 inputAmount = uint128(uint256(int256(delta1)));
                        // first remove the fee to get the original input amount before we compute the additional fee
                        inputAmount -= computeFee(inputAmount, poolFee);
                        fee = amountBeforeFee(inputAmount, additionalFee) - inputAmount;
                    }

                    core.save(address(this), poolKey.token0, poolKey.token1, poolId, 0, fee);
                    delta1 += SafeCastLib.toInt128(fee);
                }
            } else {
                if (delta0 < 0) {
                    uint128 fee;
                    unchecked {
                        uint128 outputAmount = uint128(uint256(-int256(delta0)));
                        fee = computeFee(outputAmount, additionalFee);
                    }

                    core.save(address(this), poolKey.token0, poolKey.token1, poolId, fee, 0);
                    delta0 += SafeCastLib.toInt128(fee);
                } else if (delta1 < 0) {
                    uint128 fee;
                    unchecked {
                        uint128 outputAmount = uint128(uint256(-int256(delta1)));
                        fee = computeFee(outputAmount, additionalFee);
                    }

                    core.save(address(this), poolKey.token0, poolKey.token1, poolId, 0, fee);
                    delta1 += SafeCastLib.toInt128(fee);
                }
            }
        }

        result = abi.encode(delta0, delta1);
    }
}
