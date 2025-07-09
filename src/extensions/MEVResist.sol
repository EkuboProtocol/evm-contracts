// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ICore, PoolKey, Bounds, CallPoints, SqrtRatio, UpdatePositionParameters} from "../interfaces/ICore.sol";
import {ILocker, IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {FULL_RANGE_ONLY_TICK_SPACING} from "../math/constants.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

function mevResistCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        // to store the initial tick
        beforeInitializePool: true,
        afterInitializePool: false,
        // so that we can prevent swaps that are not made via forward
        beforeSwap: true,
        afterSwap: false,
        // in order to accumulate any collected fees
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        // in order to accumulate any collected fees
        beforeCollectFees: true,
        afterCollectFees: false
    });
}

/// @notice Charges additional fees based on the relative size of the priority fee
contract MEVResist is BaseExtension, BaseForwardee, ILocker, ExposedStorage {
    error ConcentratedLiquidityPoolsOnly();
    error NonzeroFeesOnly();
    error SwapMustHappenThroughForward();

    constructor(ICore core) BaseExtension(core) BaseForwardee(core) {}

    /// @return lastUpdateTime The last time this pool was updated
    /// @return tickLast The tick from the last time the pool was touched
    function getPoolState(bytes16 poolId) private view returns (uint32 lastUpdateTime, int32 tickLast) {
        assembly ("memory-safe") {
            let v := sload(poolId)
            lastUpdateTime := shr(224, v)
            tickLast := signextend(31, shr(192, v))
        }
    }

    function setPoolState(bytes16 poolId, uint32 lastUpdateTime, int32 tickLast) private {
        assembly ("memory-safe") {
            sstore(poolId, or(shl(224, lastUpdateTime), shr(32, shl(224, tickLast))))
        }
    }

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

        setPoolState({poolId: poolKey.toPoolId(), lastUpdateTime: uint32(block.timestamp), tickLast: tick});
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

        bytes16 poolId = poolKey.toPoolId();

        (uint32 lastUpdateTime,) = getPoolState(poolId);

        uint32 currentTime = uint32(block.timestamp);

        unchecked {
            if (lastUpdateTime != currentTime) {
                (int32 tick, uint128 fees0, uint128 fees1) = loadCoreState(poolId, poolKey.token0, poolKey.token1);

                if (fees0 != 0 || fees1 != 0) {
                    core.accumulateAsFees(poolKey, fees0, fees1);
                    core.updateSavedBalances(
                        poolKey.token0, poolKey.token1, poolId, -int256(uint256(fees0)), -int256(uint256(fees1))
                    );
                }

                setPoolState({poolId: poolId, lastUpdateTime: currentTime, tickLast: tick});
            }
        }
    }

    function loadCoreState(bytes16 poolId, address token0, address token1)
        private
        view
        returns (int32 tick, uint128 fees0, uint128 fees1)
    {
        bytes32 feesSlot = EfficientHashLib.hash(
            bytes32(uint256(uint160(address(this)))),
            bytes32(uint256(uint160(token0))),
            bytes32(uint256(uint160(token1))),
            poolId
        );

        address c = address(core);
        assembly ("memory-safe") {
            let freeMemPointer := mload(64)

            mstore(0, feesSlot)
            mstore(32, 8)
            feesSlot := keccak256(0, 64)

            mstore(0, poolId)
            mstore(32, 2)
            let stateSlot := keccak256(0, 64)

            // cast sig "sload()"
            mstore(0, shl(224, 0x380eb4e0))
            mstore(4, stateSlot)
            mstore(36, feesSlot)

            if iszero(staticcall(gas(), c, 0, 68, 0, 64)) { revert(0, 0) }

            // set 64 back to the original value
            mstore(64, freeMemPointer)

            // tick := shr(96, mload(16))
            tick := shr(224, mload(16))

            let fees := mload(32)

            fees0 := shr(128, fees)
            fees0 := sub(fees0, gt(fees0, 0))

            fees1 := shr(128, shl(128, fees))
            fees1 := sub(fees1, gt(fees1, 0))
        }
    }

    function loadTick(bytes16 poolId) private view returns (int32 tick) {
        address c = address(core);
        assembly ("memory-safe") {
            mstore(0, poolId)
            mstore(32, 2)
            let stateSlot := keccak256(0, 64)

            // cast sig "sload()"
            mstore(0, shl(224, 0x380eb4e0))
            mstore(4, stateSlot)

            if iszero(staticcall(gas(), c, 0, 36, 0, 32)) { revert(0, 0) }

            tick := shr(224, mload(16))
        }
    }

    function handleForwardData(uint256, address, bytes memory data) internal override returns (bytes memory result) {
        unchecked {
            (PoolKey memory poolKey, int128 amount, bool isToken1, SqrtRatio sqrtRatioLimit, uint256 skipAhead) =
                abi.decode(data, (PoolKey, int128, bool, SqrtRatio, uint256));

            bytes16 poolId = poolKey.toPoolId();
            (uint32 lastUpdateTime, int32 tickLast) = getPoolState(poolId);

            uint32 currentTime = uint32(block.timestamp);

            int256 saveDelta0;
            int256 saveDelta1;

            if (lastUpdateTime != currentTime) {
                (int32 tick, uint128 fees0, uint128 fees1) =
                    loadCoreState({poolId: poolId, token0: poolKey.token0, token1: poolKey.token1});

                if (fees0 != 0 || fees1 != 0) {
                    core.accumulateAsFees(poolKey, fees0, fees1);
                    // never overflows int256 container
                    saveDelta0 -= int256(uint256(fees0));
                    saveDelta1 -= int256(uint256(fees1));
                }

                tickLast = tick;
                setPoolState({poolId: poolId, lastUpdateTime: currentTime, tickLast: tickLast});
            }

            (int128 delta0, int128 delta1) = core.swap_611415377(poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);

            int32 tickAfterSwap = loadTick(poolId);

            // however many tick spacings were crossed is the fee multiplier
            uint256 feeMultiplierX64 = (FixedPointMathLib.abs(tickAfterSwap - tickLast) << 64) / poolKey.tickSpacing();
            uint64 poolFee = poolKey.fee();
            uint64 additionalFee = uint64(FixedPointMathLib.min(type(uint64).max, (feeMultiplierX64 * poolFee) >> 64));

            if (additionalFee != 0) {
                if (amount < 0) {
                    // take an additional fee from the calculated input amount equal to the `additionalFee - poolFee`
                    if (delta0 > 0) {
                        uint128 inputAmount = uint128(uint256(int256(delta0)));
                        // first remove the fee to get the original input amount before we compute the additional fee
                        inputAmount -= computeFee(inputAmount, poolFee);
                        int128 fee = SafeCastLib.toInt128(amountBeforeFee(inputAmount, additionalFee) - inputAmount);

                        saveDelta0 += fee;
                        delta0 += fee;
                    } else if (delta1 > 0) {
                        uint128 inputAmount = uint128(uint256(int256(delta1)));
                        // first remove the fee to get the original input amount before we compute the additional fee
                        inputAmount -= computeFee(inputAmount, poolFee);
                        int128 fee = SafeCastLib.toInt128(amountBeforeFee(inputAmount, additionalFee) - inputAmount);

                        saveDelta1 += fee;
                        delta1 += fee;
                    }
                } else {
                    if (delta0 < 0) {
                        uint128 outputAmount = uint128(uint256(-int256(delta0)));
                        int128 fee = SafeCastLib.toInt128(computeFee(outputAmount, additionalFee));

                        saveDelta0 += fee;
                        delta0 += fee;
                    } else if (delta1 < 0) {
                        uint128 outputAmount = uint128(uint256(-int256(delta1)));
                        int128 fee = SafeCastLib.toInt128(computeFee(outputAmount, additionalFee));

                        saveDelta1 += fee;
                        delta1 += fee;
                    }
                }
            }

            if (saveDelta0 != 0 || saveDelta1 != 0) {
                core.updateSavedBalances(poolKey.token0, poolKey.token1, poolId, saveDelta0, saveDelta1);
            }

            result = abi.encode(delta0, delta1);
        }
    }
}
