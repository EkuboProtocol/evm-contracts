// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {PoolKey} from "../../types/poolKey.sol";
import {ILocker, IForwardee} from "../IFlashAccountant.sol";
import {IExtension} from "../ICore.sol";
import {IExposedStorage} from "../IExposedStorage.sol";

/// @title MEV Capture Interface
/// @notice Interface for the Ekubo MEV Capture Extension
/// @dev Extension that charges additional fees based on the relative size of the priority fee and tick movement during swaps
interface IMEVCapture is IExposedStorage, ILocker, IForwardee, IExtension {
    /// @notice Thrown when trying to use MEV capture on a full-range-only pool
    /// @dev MEV capture only works with concentrated liquidity pools that have discrete tick spacing
    error ConcentratedLiquidityPoolsOnly();

    /// @notice Thrown when trying to use MEV capture on a pool with zero fees
    /// @dev MEV capture multiplies the base fee, so a zero fee would result in no additional fees
    error NonzeroFeesOnly();

    /// @notice Thrown when attempting to swap directly without using the forward mechanism
    /// @dev All swaps must go through the forward mechanism to ensure proper MEV fee calculation
    error SwapMustHappenThroughForward();

    /// @notice Accumulates any pending pool fees from past blocks
    /// @dev This function can be called by anyone to trigger fee accumulation for a pool
    /// @dev Fees are accumulated when the pool hasn't been updated in the current block
    /// @param poolKey The pool key identifying the pool to accumulate fees for
    function accumulatePoolFees(PoolKey memory poolKey) external;
}
