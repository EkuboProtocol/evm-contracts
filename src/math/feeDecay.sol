// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {MAX_TICK_MAGNITUDE} from "./constants.sol";
import {tickToSqrtRatio} from "./ticks.sol";

/// @dev Largest `decayRateX32 * elapsed` whose tick magnitude `floor(product / 2**32)` the tick helper supports:
/// `(MAX_TICK_MAGNITUDE + 1) * 2**32 - 1`, below 2**59. Any larger product has a magnitude of at least
/// `MAX_TICK_MAGNITUDE + 1`, where the schedule saturates to `finalFee` instead of calling the helper.
uint256 constant MAX_DECAY_PRODUCT = ((uint256(MAX_TICK_MAGNITUDE) + 1) << 32) - 1;

/// @notice Creator fee `elapsed` seconds after trading starts: `finalFee` plus the excess `initialFee - finalFee`
/// shrunk by `tickToSqrtRatio(-m)`, i.e. about `1.000001**(-m / 2)`, where `m = floor(decayRateX32 * elapsed / 2**32)`
/// is the integer tick magnitude the Q32.32 rate (ticks per second) has accumulated. `finalFee` is the long-run
/// floor the schedule approaches; it is reached exactly only by rounding or, once `m` exceeds the supported tick
/// magnitude (88,722,835), by saturation.
/// @dev `decayRateX32 == 0` leaves the fee flat at `initialFee`, and `finalFee == initialFee` is flat at that value;
/// both fall out of the formula and are not refused. Requires `finalFee <= initialFee`, enforced at launch creation.
/// The magnitude is guarded before any multiplication: `elapsed <= MAX_DECAY_PRODUCT / decayRateX32` is exactly
/// `decayRateX32 * elapsed <= MAX_DECAY_PRODUCT`, so the product is below 2**59, `m <= MAX_TICK_MAGNITUDE` fits an
/// `int32`, and the helper never reverts; every larger `elapsed`, up to `type(uint256).max`, returns `finalFee`. The
/// Q128 factor is at most 2**128 (exactly 2**128 at `m == 0`, so `elapsed` below one tick step returns `initialFee`),
/// the product with the excess is below 2**192, and the floored quotient is at most the excess, so the sum fits a
/// `uint64` and lies in `[finalFee, initialFee]`. `tickToSqrtRatio` is strictly increasing and `m` is non-decreasing
/// in `elapsed`, so the fee never increases with time. The result is `finalFee + floor(excess * R / 2**128)` with
/// `R = tickToSqrtRatio(-m).toFixed()`, the compact (94-bit mantissa, rounded down) value the pool math uses; this
/// operation order is normative for every other implementation.
function decayedFee(uint64 initialFee, uint64 finalFee, uint64 decayRateX32, uint256 elapsed) pure returns (uint64) {
    if (decayRateX32 == 0) return initialFee;
    if (elapsed > MAX_DECAY_PRODUCT / decayRateX32) return finalFee;
    unchecked {
        uint256 magnitude = (uint256(decayRateX32) * elapsed) >> 32;
        uint256 factor = tickToSqrtRatio(-int32(int256(magnitude))).toFixed();
        return finalFee + uint64((uint256(initialFee - finalFee) * factor) >> 128);
    }
}
