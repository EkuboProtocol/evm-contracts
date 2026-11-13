// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "../interfaces/ICore.sol";
import {IMEVCaptureNitro} from "../interfaces/extensions/IMEVCaptureNitro.sol";
import {MEVCaptureV21} from "./MEVCaptureV21.sol";

/// @notice The L2 block number from the ArbSys precompile at `0x64`
/// @dev `block.number` is the parent chain's block number on a Nitro chain and `block.timestamp` has a resolution of
///   one second, so this is the only clock that advances with every L2 block. Reverts with `ArbSysUnavailable()` if
///   the call fails or returns fewer than 32 bytes, which is what an address without code returns.
function arbBlockNumber() view returns (uint256 blockNumber) {
    bool success;
    assembly ("memory-safe") {
        // cast sig "arbBlockNumber()"
        mstore(0, 0xa3b1b31d)
        success := and(gt(returndatasize(), 0x1f), staticcall(gas(), 0x64, 0x1c, 0x04, 0, 0x20))
        blockNumber := mload(0)
    }
    if (!success) revert IMEVCaptureNitro.ArbSysUnavailable();
}

/// @title MEV Capture v2.1 for Arbitrum Nitro chains
/// @notice MEV Capture v2.1 with two changes. The clock is the L2 block number, so the anchor moves once per L2 block
///   and `HALF_LIFE` is in L2 blocks. And every away segment pays a priority surcharge on top of its segment
///   surcharge: a rate that grows linearly with the priority fee the transaction pays above a free allowance, up to a
///   cap. The sum stays under `MAX_FEE` and is credited to the active liquidity through the same
///   `Core.accumulateAsFees` call as the segment surcharge.
/// @dev The priority fee is `tx.gasprice - block.basefee`, which is zero on a chain that does not collect tips. With
///   the priority surcharge disabled and a clock that returns `block.timestamp`, every result equals MEV Capture
///   v2.1's.
contract MEVCaptureNitro is IMEVCaptureNitro, MEVCaptureV21 {
    uint256 internal immutable PRIORITY_FREE;
    uint256 internal immutable PRIORITY_SLOPE;
    uint256 internal immutable PRIORITY_CAP;

    constructor(
        ICore core,
        uint32 halfLife,
        uint8 slopeK,
        uint8 segmentExp,
        uint8 jLin,
        uint64 maxFee,
        uint32 clampTicks,
        uint8 mGate,
        uint64 priorityFree,
        uint64 prioritySlope,
        uint64 priorityCap
    ) MEVCaptureV21(core, halfLife, slopeK, segmentExp, jLin, maxFee, clampTicks, mGate) {
        // disabled is all zero; enabled needs a slope and a cap that leaves room under the fee cap
        if (prioritySlope == 0 ? (priorityFree != 0 || priorityCap != 0) : (priorityCap == 0 || priorityCap >= maxFee))
        {
            revert InvalidConfig();
        }

        PRIORITY_FREE = priorityFree;
        PRIORITY_SLOPE = prioritySlope;
        PRIORITY_CAP = priorityCap;

        // not deployable on a chain without the precompile
        arbBlockNumber();
    }

    /// @inheritdoc IMEVCaptureNitro
    function getPriorityConfig() external view returns (PriorityConfig memory) {
        return PriorityConfig({
            freePriorityFee: uint64(PRIORITY_FREE), slope: uint64(PRIORITY_SLOPE), cap: uint64(PRIORITY_CAP)
        });
    }

    /// @inheritdoc IMEVCaptureNitro
    function prioritySurcharge(uint256 priorityFeePerGas) external view returns (uint64) {
        return uint64(_prioritySurcharge(priorityFeePerGas));
    }

    /// @notice The low 32 bits of the L2 block number. The base contract takes differences modulo 2^32.
    function _currentTime() internal view override returns (uint32) {
        return uint32(arbBlockNumber());
    }

    /// @notice min(PRIORITY_CAP, PRIORITY_SLOPE * max(0, priorityFeePerGas - PRIORITY_FREE))
    function _prioritySurcharge(uint256 priorityFeePerGas) internal view returns (uint256 rate) {
        unchecked {
            if (priorityFeePerGas > PRIORITY_FREE) {
                uint256 excess = priorityFeePerGas - PRIORITY_FREE;
                // the slope is below 2^64, so the product of a 128-bit excess cannot overflow
                if (excess > type(uint128).max) excess = type(uint128).max;
                rate = excess * PRIORITY_SLOPE;
                if (rate > PRIORITY_CAP) rate = PRIORITY_CAP;
            }
        }
    }

    /// @notice The segment surcharge plus the priority surcharge of this transaction, capped so that the total fee
    ///   does not exceed MAX_FEE
    /// @dev `tx.gasprice` and `block.basefee` are constant within a transaction, so the priority surcharge is the same
    ///   for every segment of a swap. A simulated call can carry a gas price below the base fee, which counts as no
    ///   priority fee.
    function _surcharge(uint256 poolFee, uint256 twiceMidOffsetX16, uint256 spacing)
        internal
        view
        override
        returns (uint256 sur)
    {
        sur = super._surcharge(poolFee, twiceMidOffsetX16, spacing);
        unchecked {
            uint256 gasPrice = tx.gasprice;
            uint256 baseFee = block.basefee;
            if (gasPrice > baseFee) {
                // both terms are below 2^64
                sur += _prioritySurcharge(gasPrice - baseFee);
                uint256 cap = MAX_FEE - poolFee;
                if (sur > cap) sur = cap;
            }
        }
    }
}
