// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity ^0.8.30;

import {ICore, PoolKey, PositionId, CallPoints} from "../interfaces/ICore.sol";
import {IMEVCapture} from "../interfaces/extensions/IMEVCapture.sol";
import {IExtension} from "../interfaces/ICore.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {ExposedStorageLib} from "../libraries/ExposedStorageLib.sol";
import {CoreStorageLayout} from "../libraries/CoreStorageLayout.sol";
import {PoolState} from "../types/poolState.sol";
import {MEVCapturePoolState, createMEVCapturePoolState} from "../types/mevCapturePoolState.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {PoolId} from "../types/poolId.sol";
import {Locker} from "../types/locker.sol";
import {StorageSlot} from "../types/storageSlot.sol";

function mevCaptureCallPoints() pure returns (CallPoints memory) {
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
contract MEVCapture is IMEVCapture, BaseExtension, BaseForwardee, ExposedStorage {
    using CoreLib for *;
    using ExposedStorageLib for *;

    constructor(ICore core) BaseExtension(core) BaseForwardee(core) {}

    function getPoolState(PoolId poolId) private view returns (MEVCapturePoolState state) {
        assembly ("memory-safe") {
            state := sload(poolId)
        }
    }

    function setPoolState(PoolId poolId, MEVCapturePoolState state) private {
        assembly ("memory-safe") {
            sstore(poolId, state)
        }
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return mevCaptureCallPoints();
    }

    function beforeInitializePool(address, PoolKey memory poolKey, int32 tick)
        external
        override(BaseExtension, IExtension)
    {
        if (poolKey.config.isFullRange()) {
            revert ConcentratedLiquidityPoolsOnly();
        }
        if (poolKey.config.fee() == 0) {
            // nothing to multiply == no-op extension
            revert NonzeroFeesOnly();
        }

        setPoolState({
            poolId: poolKey.toPoolId(),
            state: createMEVCapturePoolState({_lastUpdateTime: uint32(block.timestamp), _tickLast: tick})
        });
    }

    /// @notice We only allow swapping via forward to this extension
    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override(BaseExtension, IExtension) {
        revert SwapMustHappenThroughForward();
    }

    // Allows users to collect pending fees before the first swap in the block happens
    function beforeCollectFees(Locker, PoolKey memory poolKey, PositionId)
        external
        override(BaseExtension, IExtension)
    {
        accumulatePoolFees(poolKey);
    }

    /// Prevents new liquidity from collecting on fees
    function beforeUpdatePosition(Locker, PoolKey memory poolKey, PositionId, int128)
        external
        override(BaseExtension, IExtension)
    {
        accumulatePoolFees(poolKey);
    }

    /// @inheritdoc IMEVCapture
    function accumulatePoolFees(PoolKey memory poolKey) public {
        // the only thing we lock for is accumulating fees, so all we need to encode is the pool key
        address target = address(CORE);
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

    function locked_6416899205(uint256) external onlyCore {
        PoolKey memory poolKey;
        assembly ("memory-safe") {
            poolKey := mload(0x40)
            // points the free memory pointer at pointer + 96
            mstore(0x40, add(poolKey, 96))

            // copy the poolkey out of calldata at the free memory pointer
            calldatacopy(poolKey, 36, 96)
        }

        PoolId poolId = poolKey.toPoolId();

        MEVCapturePoolState state = getPoolState(poolId);
        uint32 lastUpdateTime = state.lastUpdateTime();

        uint32 currentTime = uint32(block.timestamp);

        unchecked {
            if (lastUpdateTime != currentTime) {
                (int32 tick, uint128 fees0, uint128 fees1) = loadCoreState(poolId, poolKey.token0, poolKey.token1);

                if (fees0 != 0 || fees1 != 0) {
                    CORE.accumulateAsFees(poolKey, fees0, fees1);
                    CORE.updateSavedBalances(
                        poolKey.token0,
                        poolKey.token1,
                        PoolId.unwrap(poolId),
                        -int256(uint256(fees0)),
                        -int256(uint256(fees1))
                    );
                }

                setPoolState({
                    poolId: poolId,
                    state: createMEVCapturePoolState({_lastUpdateTime: currentTime, _tickLast: tick})
                });
            }
        }
    }

    function loadCoreState(PoolId poolId, address token0, address token1)
        private
        view
        returns (int32 tick, uint128 fees0, uint128 fees1)
    {
        StorageSlot stateSlot = CoreStorageLayout.poolStateSlot(poolId);
        StorageSlot feesSlot = CoreStorageLayout.savedBalancesSlot(address(this), token0, token1, PoolId.unwrap(poolId));

        (bytes32 v0, bytes32 v1) = CORE.sload(stateSlot, feesSlot);
        tick = PoolState.wrap(v0).tick();

        assembly ("memory-safe") {
            fees0 := shr(128, v1)
            fees0 := sub(fees0, gt(fees0, 0))

            fees1 := shr(128, shl(128, v1))
            fees1 := sub(fees1, gt(fees1, 0))
        }
    }

    function handleForwardData(Locker, bytes memory data) internal override returns (bytes memory result) {
        unchecked {
            (PoolKey memory poolKey, SwapParameters params) = abi.decode(data, (PoolKey, SwapParameters));

            PoolId poolId = poolKey.toPoolId();
            MEVCapturePoolState state = getPoolState(poolId);
            uint32 lastUpdateTime = state.lastUpdateTime();
            int32 tickLast = state.tickLast();

            uint32 currentTime = uint32(block.timestamp);

            int256 saveDelta0;
            int256 saveDelta1;

            if (lastUpdateTime != currentTime) {
                (int32 tick, uint128 fees0, uint128 fees1) =
                    loadCoreState({poolId: poolId, token0: poolKey.token0, token1: poolKey.token1});

                if (fees0 != 0 || fees1 != 0) {
                    CORE.accumulateAsFees(poolKey, fees0, fees1);
                    // never overflows int256 container
                    saveDelta0 -= int256(uint256(fees0));
                    saveDelta1 -= int256(uint256(fees1));
                }

                tickLast = tick;
                setPoolState({
                    poolId: poolId,
                    state: createMEVCapturePoolState({_lastUpdateTime: currentTime, _tickLast: tickLast})
                });
            }

            (int128 delta0, int128 delta1, PoolState stateAfter) = CORE.swap_1773245541(poolKey, params);

            // however many tick spacings were crossed is the fee multiplier
            uint256 feeMultiplierX64 =
                (FixedPointMathLib.abs(stateAfter.tick() - tickLast) << 64) / poolKey.config.concentratedTickSpacing();
            uint64 poolFee = poolKey.config.fee();
            uint64 additionalFee = uint64(FixedPointMathLib.min(type(uint64).max, (feeMultiplierX64 * poolFee) >> 64));

            if (additionalFee != 0) {
                if (params.isExactOut()) {
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
                CORE.updateSavedBalances(poolKey.token0, poolKey.token1, PoolId.unwrap(poolId), saveDelta0, saveDelta1);
            }

            result = abi.encode(delta0, delta1, stateAfter);
        }
    }
}
