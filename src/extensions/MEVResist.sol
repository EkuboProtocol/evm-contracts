// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ICore, PoolKey, Bounds, CallPoints, SqrtRatio} from "../interfaces/ICore.sol";
import {IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/// @notice Charges additional fees based on the relative size of the priority fee
contract MEVResist is BaseExtension, BaseForwardee {
    using CoreLib for *;

    constructor(ICore core) BaseExtension(core) BaseForwardee(core) {}

    /// @notice We only allow swapping via forward to this extension
    function getCallPoints() internal pure override returns (CallPoints memory) {
        return CallPoints({
            beforeInitializePool: false,
            afterInitializePool: false,
            beforeSwap: true,
            afterSwap: false,
            beforeUpdatePosition: false,
            afterUpdatePosition: false,
            beforeCollectFees: true,
            afterCollectFees: false
        });
    }

    error SwapMustHappenThroughForward();

    /// @notice We only allow swapping via forward to this extension
    function beforeSwap(address, PoolKey memory, int128, bool, SqrtRatio, uint256) external pure override {
        revert SwapMustHappenThroughForward();
    }

    function beforeCollectFees(address, PoolKey memory, bytes32, Bounds memory) external pure override {
        // todo: accumulate fees for the pool so they can be collected
        revert CallPointNotImplemented();
    }

    struct PoolState {
        // The last time we touched this pool
        uint32 lastUpdateTime;
        // The tick from the last time the pool was touched
        int32 tickLast;
        // The amount of additional fees that have been collected since the last time the pool was touched
        uint96 fees0;
        uint96 fees1;
    }

    /// @notice The state of each pool
    mapping(bytes32 poolId => PoolState) private poolState;

    function handleForwardData(uint256, address, bytes memory data) internal override returns (bytes memory result) {
        (PoolKey memory poolKey, int128 amount, bool isToken1, SqrtRatio sqrtRatioLimit, uint256 skipAhead) =
            abi.decode(data, (PoolKey, int128, bool, SqrtRatio, uint256));

        bytes32 poolId = poolKey.toPoolId();
        PoolState memory ps = poolState[poolId];

        // first thing's first, update the last update time
        if (ps.lastUpdateTime != uint32(block.timestamp)) {
            if (ps.fees0 != 0 || ps.fees1 != 0) {
                core.accumulateAsFees(poolKey, ps.fees0, ps.fees1);
                core.load(poolKey.token0, poolKey.token1, bytes32(0), ps.fees0, ps.fees1);
                ps.fees0 = 0;
                ps.fees1 = 0;
            }
            (, ps.tickLast,) = core.poolState(poolId);
            ps.lastUpdateTime = uint32(block.timestamp);
        }

        // todo: always charge the fee on the calculated amount
        (int128 delta0, int128 delta1) = core.swap_611415377(poolKey, amount, isToken1, sqrtRatioLimit, skipAhead);

        (, int32 tickAfterSwap,) = core.poolState(poolId);

        // however many tick spacings were crossed is the multiplier
        uint256 feeMultiplier = FixedPointMathLib.abs(tickAfterSwap - ps.tickLast) / poolKey.tickSpacing();

        if (feeMultiplier != 0) {
            uint64 poolFee = poolKey.fee();
            uint64 additionalFee = uint64(FixedPointMathLib.min(type(uint64).max, feeMultiplier * poolFee));
            bool isExactOutput = amount < 0;

            // take an additional fee from the swapper equal to the `additionalFee`
            if (delta0 > 0) {
                uint128 fee;
                unchecked {
                    uint128 inputAmount = uint128(uint256(int256(delta0)));
                    // first remove the fee to get the original input amount before we compute the additional fee
                    inputAmount -= computeFee(inputAmount, poolFee);
                    fee = amountBeforeFee(inputAmount, additionalFee) - inputAmount;
                }

                core.save(address(this), poolKey.token0, poolKey.token1, bytes32(0), fee, 0);
                delta0 += SafeCastLib.toInt128(fee);

                unchecked {
                    ps.fees0 = uint96(FixedPointMathLib.min(type(uint96).max, uint256(ps.fees0) + fee));
                }
            } else if (delta1 > 0) {
                uint128 fee;
                unchecked {
                    uint128 inputAmount = uint128(uint256(int256(delta1)));
                    // first remove the fee to get the original input amount before we compute the additional fee
                    inputAmount -= computeFee(inputAmount, poolFee);
                    fee = amountBeforeFee(inputAmount, additionalFee) - inputAmount;
                }

                core.save(address(this), poolKey.token0, poolKey.token1, bytes32(0), 0, fee);
                delta1 += SafeCastLib.toInt128(fee);

                unchecked {
                    // saturated addition of the fees
                    ps.fees1 = uint96(FixedPointMathLib.min(type(uint96).max, uint256(ps.fees1) + fee));
                }
            }
        }

        poolState[poolId] = ps;

        result = abi.encode(delta0, delta1);
    }
}
