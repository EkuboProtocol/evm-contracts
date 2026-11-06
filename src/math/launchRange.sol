// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

/// @dev Spacing steps a launch range may span after alignment: one tick-bitmap word (`tickBitmap.sol` keeps 256
/// steps per word, and Core's swap loop loads one word per step of `findNext/PrevInitializedTick`). A range of at
/// most 256 steps keeps both of the pool's only initialized ticks within two adjacent words, so every swap, including
/// one that sweeps the whole range, reads at most two bitmap slots wherever the price sits.
uint256 constant LAUNCH_RANGE_STEPS = 256;

/// @dev Largest spacing the rule can produce: the full tick range `MAX_TICK - MIN_TICK = 177445670` divided into
/// 256 steps, rounded up. Below Core's `MAX_TICK_SPACING` of 698605, so the rule never needs a clamp.
uint32 constant MAX_LAUNCH_TICK_SPACING = 693148;

/// @notice Spacing and aligned bounds for an economic launch range. The spacing is the smallest for which the
/// requested width fits in `LAUNCH_RANGE_STEPS` steps, `ceil((upperTick - askTick) / 256)`; the ask then rounds up
/// and the upper bound rounds down to that grid, so the installed range lies inside the requested one: the token
/// never sells below the requested ask and the range never extends above the requested top. Each bound moves by
/// less than one spacing, i.e. less than `width / 256 + 1` ticks.
/// @dev Requires `MIN_TICK <= askTick < upperTick <= MAX_TICK`, checked by the caller. For a width of at most 256
/// the spacing is 1 and nothing moves. Otherwise `2 * spacing < width`, so the aligned bounds stay strictly ordered:
/// `alignedUpper - alignedAsk > width - 2 * spacing > 0`, and
/// `alignedUpper - alignedAsk <= width <= 256 * spacing` bounds the aligned span at 256 steps. The rounded bounds
/// never leave `[MIN_TICK, MAX_TICK]` because they move inward. Solidity's `/` truncates toward zero, so the ask
/// is adjusted upward only when positive and inexact, and the upper bound downward only when negative and inexact.
function alignLaunchRange(int32 askTick, int32 upperTick)
    pure
    returns (uint32 spacing, int32 alignedAsk, int32 alignedUpper)
{
    unchecked {
        int256 ask = askTick;
        int256 upper = upperTick;
        int256 step = ((upper - ask) + int256(LAUNCH_RANGE_STEPS - 1)) / int256(LAUNCH_RANGE_STEPS);
        int256 askSteps = ask / step;
        if (askSteps * step < ask) askSteps++;
        int256 upperSteps = upper / step;
        if (upperSteps * step > upper) upperSteps--;
        spacing = uint32(uint256(step));
        alignedAsk = int32(askSteps * step);
        alignedUpper = int32(upperSteps * step);
    }
}
