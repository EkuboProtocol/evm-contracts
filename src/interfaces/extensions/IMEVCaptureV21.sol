// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {IForwardee} from "../IFlashAccountant.sol";
import {IExtension} from "../ICore.sol";
import {IExposedStorage} from "../IExposedStorage.sol";
import {PoolId} from "../../types/poolId.sol";

/// @title MEV Capture v2.1 Interface
/// @notice Interface for the Ekubo MEV Capture v2.1 extension
/// @dev Swaps pay an away-from-anchor surcharge charged inside the swap by Core through `SwapParameters.minFee`,
///   segment by segment. The anchor decays toward the pool tick with half-life `HALF_LIFE`, moves at most
///   `CLAMP_TICKS` per `HALF_LIFE`, and only moves when the active liquidity passes a gate against a reference that
///   rises and falls by at most one bit per `HALF_LIFE`.
interface IMEVCaptureV21 is IExposedStorage, IForwardee, IExtension {
    /// @notice The immutable configuration of the extension
    struct Config {
        /// @notice Anchor decay half-life in seconds (tau)
        uint32 halfLife;
        /// @notice Twice the surcharge slope k, so the slope is `slopeK / 2`
        uint8 slopeK;
        /// @notice Segment width exponent: the segment width is `tickSpacing << segmentExp`
        uint8 segmentExp;
        /// @notice Number of equal-width away segments before the widths double
        uint8 jLin;
        /// @notice Cap on the total fee of a segment, as a 0.16 number
        uint16 maxFee;
        /// @notice Maximum anchor movement per half-life, in ticks
        uint32 clampTicks;
        /// @notice Gate tolerance in bits
        uint8 mGate;
        /// @notice Maximum number of Core swap calls spent on away segments, `jLin + 24`
        uint8 maxSegments;
    }

    /// @notice Emitted when the anchor update of a timestamp fails the liquidity gate and the anchor does not move
    /// @param poolId The pool whose anchor did not move
    /// @param lObs The observed active liquidity, as a bit length
    /// @param eRef The decayed gate reference, as a bit length
    event AnchorGateFailed(PoolId poolId, uint8 lObs, uint8 eRef);

    /// @notice Thrown when trying to use the extension on a stableswap or full-range pool
    error ConcentratedLiquidityPoolsOnly();

    /// @notice Thrown when trying to use the extension on a pool with zero fee
    error NonzeroFeesOnly();

    /// @notice Thrown when the pool fee is not below `MAX_FEE`
    error PoolFeeNotBelowMaxFee();

    /// @notice Thrown when attempting to swap directly without using the forward mechanism
    error SwapMustHappenThroughForward();

    /// @notice Thrown by the constructor when an immutable is out of range
    error InvalidConfig();

    /// @notice Thrown by the constructor when the segment budget does not provably reach `MAX_FEE`
    error SegmentBudgetTooSmall();

    /// @notice Returns the decoded per-pool state
    function getAnchor(PoolId poolId)
        external
        view
        returns (
            uint32 lastUpdateTime,
            uint32 lRefTime,
            uint32 lastPosTime,
            uint8 lRefBits,
            uint8 snapBits,
            uint32 lRefRaiseTime,
            int64 anchorX16
        );

    /// @notice Returns the immutable configuration
    function getConfig() external view returns (Config memory);
}
