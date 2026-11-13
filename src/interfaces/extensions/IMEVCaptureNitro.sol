// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity ^0.8.0;

import {IMEVCaptureV21} from "./IMEVCaptureV21.sol";

/// @title MEV Capture Nitro Interface
/// @notice Interface for the MEV Capture v2.1 variant for Arbitrum Nitro chains
/// @dev Identical to MEV Capture v2.1 except for two things. Time is the L2 block number from the ArbSys precompile,
///   so `Config.halfLife` and every time field returned by `getAnchor` are in L2 blocks. And every away segment pays
///   an additional surcharge that grows with the priority fee of the transaction, under the same `maxFee` cap.
interface IMEVCaptureNitro is IMEVCaptureV21 {
    /// @notice The immutable configuration of the priority surcharge. All zero when it is disabled.
    struct PriorityConfig {
        /// @notice Priority fee per gas, in wei, up to which no priority surcharge is charged
        uint64 freePriorityFee;
        /// @notice Priority surcharge, as a 0.64 number, per wei of priority fee per gas above `freePriorityFee`
        uint64 slope;
        /// @notice Cap on the priority surcharge, as a 0.64 number
        uint64 cap;
    }

    /// @notice Thrown when the ArbSys precompile does not return an L2 block number
    error ArbSysUnavailable();

    /// @notice Returns the immutable configuration of the priority surcharge
    function getPriorityConfig() external view returns (PriorityConfig memory);

    /// @notice The surcharge added to every away segment of a swap whose transaction pays `priorityFeePerGas`
    /// @dev The swap pays `min(maxFee - poolFee, segment surcharge + priority surcharge)` on each away segment. The
    ///   extension reads the priority fee of a swap as `tx.gasprice - block.basefee`, or zero if that is negative.
    /// @param priorityFeePerGas The priority fee per gas of the transaction, in wei
    /// @return The priority surcharge, as a 0.64 number
    function prioritySurcharge(uint256 priorityFeePerGas) external view returns (uint64);
}
