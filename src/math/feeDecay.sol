// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @dev 2**64: the Q0.64 unit and the representation of exactly 100%.
uint256 constant Q64 = 0x10000000000000000;

/// @notice `factor ** exponent` in Q0.64 by exponentiation by squaring, flooring after every multiply.
/// @dev The operation order is normative across implementations: for each set exponent bit, multiply the running
/// result by the current factor and floor; shift; square and floor the factor only if bits remain. The chain is
/// non-increasing in `exponent` for every `factor < 2**64`: dropping the trailing ones of an exponent for the next
/// bit never raises a floored product chain. Products fit in 256 bits because both operands are at most 2**64.
function powQ64(uint64 factor, uint256 exponent) pure returns (uint256 result) {
    result = Q64;
    uint256 base = factor;
    unchecked {
        while (exponent != 0) {
            if (exponent & 1 != 0) result = (result * base) >> 64;
            exponent >>= 1;
            if (exponent != 0) base = (base * base) >> 64;
        }
    }
}

/// @notice Creator fee `elapsed` seconds into a window: an exponential from `initialFee` towards zero, rescaled so
/// that it leaves `initialFee` at zero and reaches `finalFee` exactly at `duration`, then stays there.
/// @dev Requires `finalFee <= initialFee < 2**64`, `0 < decayFactor < 2**64` and `duration > 0`, all enforced at
/// launch creation. `decayFactor` is the per-second Q0.64 multiplier before normalization, not a half-life.
/// With E = powQ64(decayFactor, duration) < 2**64, the interior value is
/// `finalFee + floor((initialFee - finalFee) * (powQ64(decayFactor, elapsed) - E) / (2**64 - E))`, which lies in
/// `[finalFee, initialFee]` and does not increase with `elapsed`.
function decayedFee(uint64 initialFee, uint64 finalFee, uint64 decayFactor, uint32 duration, uint256 elapsed)
    pure
    returns (uint64)
{
    if (elapsed == 0) return initialFee;
    if (elapsed >= duration) return finalFee;
    uint256 endpoint = powQ64(decayFactor, duration);
    return
        finalFee + uint64(uint256(initialFee - finalFee) * (powQ64(decayFactor, elapsed) - endpoint) / (Q64 - endpoint));
}
