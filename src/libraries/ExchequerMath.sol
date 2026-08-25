// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {PoolKey} from "../types/poolKey.sol";
import {createConcentratedPoolConfig} from "../types/poolConfig.sol";
import {PositionId, createPositionId} from "../types/positionId.sol";

/// @notice Every monetary parameter the whitepaper redacts, supplied at construction
struct ExchequerParameters {
    /// @notice $ISSUE issued per day at a multiplier of exactly 1 (whitepaper §5)
    uint128 baseIssuancePerDay;
    /// @notice Multiplier floor, in 1e18 fixed point
    uint64 multiplierMin;
    /// @notice Multiplier ceiling, in 1e18 fixed point
    uint64 multiplierMax;
    /// @notice Multiplier at launch, in 1e18 fixed point
    uint64 multiplierLaunch;
    /// @notice Amount the multiplier falls per contraction epoch, in 1e18 fixed point
    uint64 multiplierCutStep;
    /// @notice Amount the multiplier rises per expansion epoch, in 1e18 fixed point
    uint64 multiplierRaiseStep;
    /// @notice Epoch length in seconds (whitepaper §4)
    uint32 epochLength;
    /// @notice Trading fee as a 0.64 fixed point fraction, always charged in ETH
    uint64 tradingFee;
    /// @notice Concentrated tick spacing of the one canonical pool
    uint32 tickSpacing;
    /// @notice Resolution fee at zero exit pressure, in 1e18 fixed point (whitepaper §9)
    uint64 resolutionFeeFloor;
    /// @notice Resolution fee at or above saturation, in 1e18 fixed point
    uint64 resolutionFeeCeiling;
    /// @notice Exit pressure at which the resolution fee reaches its ceiling, in 1e18 fixed point
    uint64 exitPressureSaturation;
    /// @notice Lower bound on the exit pressure denominator, per eq 9.1
    uint128 exitPressureDenominatorFloor;
    /// @notice Seconds a price must prevail to fully replace the bank's reference price
    uint32 polReferenceWindow;
    /// @notice Seconds over which the redistributed half of each resolution fee is streamed
    uint32 redistributionStreamLength;
    /// @notice Least net ETH inflow, in wei, for an epoch to count as expansion
    uint128 minNetFlow;
}

/// @dev The only pre-mint: protocol-owned liquidity locked into the pool forever (§3)
uint256 constant GENESIS_LIQUIDITY = 100_000_000e18;

/// @dev Cumulative base issuance available across all time (§3)
uint256 constant ISSUANCE_BUDGET = 900_000_000e18;

/// @dev Total $BANK mintable through the free founding distribution (§6)
uint256 constant FOUNDING_BANK_SUPPLY = 1_000e18;

/// @dev Share of protocol ETH routed to the active vault, in basis points (§11)
uint256 constant VAULT_SHARE_BPS = 7000;

/// @dev Share of protocol ETH routed to protocol-owned liquidity, in basis points (§11)
uint256 constant POL_SHARE_BPS = 1500;

/// @dev Number of daily buckets in the trailing exit pressure window (§9)
uint256 constant EXIT_BUCKETS = 7;

/// @dev Salt of every protocol-owned liquidity position: the genesis range and each bid bucket
bytes24 constant POL_SALT = bytes24(0);

/// @dev Salt of the single active buyback bid bucket
bytes24 constant BUYBACK_SALT = bytes24(uint192(1));

/// @dev Fixed point scale for the multiplier and every fee fraction
uint256 constant WAD = 1e18;

/// @title Exchequer Math
/// @notice The whitepaper's arithmetic, in one place, used both by the bank to settle and by its
///         readers to project. A projection can therefore never disagree with a settlement.
library ExchequerMath {
    /// @notice Whether a net flow is large enough to count as expansion
    /// @dev §4 says the signal is "denominated in real capital", which a pure sign test is not: a
    ///      one-wei buy would make an epoch expansionary. Anything below `minNetFlow` is treated as
    ///      zero, and zero is a contraction, per §5.
    function isExpansion(int256 flow, uint256 minNetFlow) internal pure returns (bool) {
        return flow > 0 && uint256(flow) >= minNetFlow;
    }

    /// @notice The multiplier for the next epoch given the trailing two-epoch signal
    function nextMultiplier(uint256 m, int256 signal, ExchequerParameters memory p)
        internal
        pure
        returns (uint256 next)
    {
        unchecked {
            if (isExpansion(signal, p.minNetFlow)) {
                uint256 raised = m + p.multiplierRaiseStep;
                next = raised > p.multiplierMax ? p.multiplierMax : raised;
            } else {
                next = m > uint256(p.multiplierMin) + p.multiplierCutStep ? m - p.multiplierCutStep : p.multiplierMin;
            }
        }
    }

    /// @notice Sum of the multiplier over `count` consecutive contraction epochs, and its end value
    /// @dev The multiplier falls by `cut` per epoch and holds at `floor_`
    function decayMultiplier(uint256 m, uint256 count, uint256 floor_, uint256 cut)
        internal
        pure
        returns (uint256 sum, uint256 mAfter)
    {
        uint256 span = m - floor_;
        if (cut == 0) return (m * count, m);

        unchecked {
            // Number of whole steps the multiplier can take before reaching the floor
            uint256 steps = span / cut;
            uint256 remainder = span % cut;

            uint256 full = count < steps ? count : steps;
            sum = full * (floor_ + span) - cut * ((full * (full - 1)) / 2);

            if (count > full) {
                // The step at index `steps` lands `remainder` above the floor; every later one is at it
                sum += floor_ * (count - full) + remainder;
            }

            if (count < steps) {
                mAfter = floor_ + span - count * cut;
            } else if (count == steps) {
                mAfter = floor_ + remainder;
            } else {
                mAfter = floor_;
            }
        }
    }

    /// @notice Walks the epoch clock from `last` to `nowTs` without touching storage
    /// @param p The bank's parameters
    /// @param m Multiplier in force at `last`
    /// @param epochStart Start of the epoch in progress at `last`
    /// @param last Timestamp through which issuance has already been accrued
    /// @param currentFlow Net flow of the epoch in progress
    /// @param prevFlow Net flow of the previously completed epoch
    /// @param nowTs The current time
    /// @return weightedSeconds Sum over segments of (duration) * (multiplier in force)
    /// @return finalM Multiplier in force at `nowTs`
    /// @return finalEpochStart Start of the epoch in progress at `nowTs`
    /// @return rolls Number of epoch boundaries crossed
    function walk(
        ExchequerParameters memory p,
        uint256 m,
        uint256 epochStart,
        uint256 last,
        int256 currentFlow,
        int256 prevFlow,
        uint256 nowTs
    ) internal pure returns (uint256 weightedSeconds, uint256 finalM, uint256 finalEpochStart, uint256 rolls) {
        uint256 epochLength = p.epochLength;

        unchecked {
            uint256 epochEnd = epochStart + epochLength;

            if (nowTs >= epochEnd) {
                weightedSeconds += (epochEnd - last) * m;

                // Issuance follows the two most recently completed epochs: the slow lever (§4)
                m = nextMultiplier(m, currentFlow + prevFlow, p);
                prevFlow = currentFlow;
                epochStart = epochEnd;
                rolls = 1;

                // Nothing touched the bank at any later boundary, so those epochs saw zero flow
                uint256 skipped = (nowTs - epochStart) / epochLength;

                // The first two still carry pre-gap flow in their signal, so they roll individually
                uint256 individual = skipped < 2 ? skipped : 2;
                for (uint256 i; i < individual; ++i) {
                    weightedSeconds += epochLength * m;
                    m = nextMultiplier(m, prevFlow, p);
                    prevFlow = 0;
                    epochStart += epochLength;
                }
                rolls += individual;

                uint256 remaining = skipped - individual;
                if (remaining != 0) {
                    // Every remaining epoch has a zero signal, so the multiplier is cut each time.
                    // Closed form, so catching up after months of silence stays O(1).
                    (uint256 sumM, uint256 mAfter) = decayMultiplier(m, remaining, p.multiplierMin, p.multiplierCutStep);
                    weightedSeconds += epochLength * sumM;
                    m = mAfter;
                    epochStart += remaining * epochLength;
                    rolls += remaining;
                }

                last = epochStart;
            }

            weightedSeconds += (nowTs - last) * m;
        }

        finalM = m;
        finalEpochStart = epochStart;
    }

    /// @notice Base issuance owed for `weightedSeconds`, capped at what is left of the budget
    function baseIssuance(uint256 weightedSeconds, uint256 baseIssuancePerDay, uint256 cumulativeIssuance)
        internal
        pure
        returns (uint256 amount)
    {
        if (weightedSeconds == 0) return 0;
        amount = FixedPointMathLib.fullMulDiv(weightedSeconds, baseIssuancePerDay, WAD * 1 days);
        unchecked {
            uint256 headroom = ISSUANCE_BUDGET - cumulativeIssuance;
            if (amount > headroom) amount = headroom;
        }
    }

    /// @notice Share of the redistribution stream released between `last` and `nowTs`
    /// @dev Linear over the remaining life of the stream
    function streamRelease(uint256 remaining, uint256 end, uint256 last, uint256 nowTs)
        internal
        pure
        returns (uint256)
    {
        if (remaining == 0) return 0;
        if (nowTs >= end) return remaining;
        unchecked {
            return (remaining * (nowTs - last)) / (end - last);
        }
    }

    /// @notice The end time of a stream after `added` joins `remaining`, weighted by amount
    /// @dev A dust exit cannot stretch a stream already in flight, and no stream is brought forward
    function streamEndAfterDeposit(
        uint256 remaining,
        uint256 currentEnd,
        uint256 added,
        uint256 streamLength,
        uint256 nowTs
    ) internal pure returns (uint256 end) {
        end = nowTs + streamLength;
        if (remaining != 0) {
            if (currentEnd < nowTs) currentEnd = nowTs;
            end = (remaining * currentEnd + added * end) / (remaining + added);
        }
    }

    /// @notice The resolution fee an exit of `exiting` pays, in 1e18 fixed point (eq 9.1)
    /// @dev Quadratic between the floor and the ceiling, saturating once `exitPressureSaturation`
    ///      of the bank has tried to leave inside the trailing window. The exit being priced counts
    ///      toward the window, so an exit large enough to be a run on its own is priced as one.
    /// @param trailing System-wide withdrawals over the trailing window, before this exit
    /// @param exiting The exit being priced
    /// @param ledger Everything still held at the bank, before this exit
    function resolutionFeeRate(ExchequerParameters memory p, uint256 trailing, uint256 exiting, uint256 ledger)
        internal
        pure
        returns (uint256 rate)
    {
        uint256 w = trailing + exiting;
        if (w == 0) return p.resolutionFeeFloor;

        // `D` after this exit plus `W` including it is the same sum as before it
        uint256 denominator = ledger + trailing;
        if (denominator < p.exitPressureDenominatorFloor) denominator = p.exitPressureDenominatorFloor;

        uint256 pressure = FixedPointMathLib.fullMulDiv(w, WAD, denominator);
        uint256 x = pressure >= p.exitPressureSaturation
            ? WAD
            : FixedPointMathLib.fullMulDiv(pressure, WAD, p.exitPressureSaturation);

        unchecked {
            rate = p.resolutionFeeFloor
                + FixedPointMathLib.fullMulDiv(uint256(p.resolutionFeeCeiling) - p.resolutionFeeFloor, x * x, WAD * WAD);
        }
    }

    /// @notice Folds the time the last observed tick has prevailed into the reference
    /// @dev A price pulls the reference toward itself in proportion to how long it prevailed, and a
    ///      price that lasts a full `window` replaces it outright. A price that exists only inside
    ///      one block has prevailed for zero seconds and moves nothing.
    function foldedReferenceX24(
        int256 referenceX24,
        int32 lastObservedTick,
        uint256 lastObservationTime,
        uint256 window,
        uint256 nowTs
    ) internal pure returns (int256) {
        uint256 elapsed = nowTs - lastObservationTime;
        if (elapsed == 0) return referenceX24;
        if (elapsed > window) elapsed = window;

        int256 target = int256(lastObservedTick) << 24;
        return referenceX24 + ((target - referenceX24) * int256(elapsed)) / int256(window);
    }

    /// @notice The first grid tick strictly above both the market and the bank's reference
    /// @dev Never below the reference, so a same-block pump cannot pull a bid up to meet it.
    ///      Reverts if there is no room below the top of the range.
    function bidLowerTick(int32 spot, int32 anchor, int32 grid, int32 upper) internal pure returns (int32) {
        int256 floorTick = int256(spot);
        if (anchor > floorTick) floorTick = anchor;

        // Floor division, so that negative ticks round toward the lower grid line as well
        int256 line = floorTick / grid;
        if (floorTick < 0 && floorTick % grid != 0) line -= 1;

        int256 lowerTick = (line + 1) * grid;
        require(lowerTick < upper, NoRoomAboveThePrice());
        return int32(lowerTick);
    }

    error NoRoomAboveThePrice();

    /// @notice Lower bound of the genesis position, the lowest aligned tick
    function polTickLower(uint32 tickSpacing) internal pure returns (int32) {
        int32 spacing = int32(tickSpacing);
        return (MIN_TICK / spacing) * spacing;
    }

    /// @notice Upper bound of every protocol-owned position, the highest aligned tick
    function polTickUpper(uint32 tickSpacing) internal pure returns (int32) {
        int32 spacing = int32(tickSpacing);
        return (MAX_TICK / spacing) * spacing;
    }

    /// @notice Spacing of the grid on which bid buckets are placed, ten tick spacings
    function polBidGrid(uint32 tickSpacing) internal pure returns (int32) {
        return int32(tickSpacing) * 10;
    }

    /// @notice The one canonical market: ETH against $ISSUE, with no pool fee of its own
    function poolKey(address issueToken, uint32 tickSpacing, address bank) internal pure returns (PoolKey memory key) {
        key.token0 = NATIVE_TOKEN_ADDRESS;
        key.token1 = issueToken;
        key.config = createConcentratedPoolConfig(0, tickSpacing, bank);
    }

    /// @notice The full-range genesis position, which has no withdrawal path
    function polPositionId(uint32 tickSpacing) internal pure returns (PositionId) {
        return createPositionId(POL_SALT, polTickLower(tickSpacing), polTickUpper(tickSpacing));
    }

    /// @notice A protocol-owned bid bucket, which likewise has no withdrawal path
    function polBidPositionId(int32 lowerTick, uint32 tickSpacing) internal pure returns (PositionId) {
        return createPositionId(POL_SALT, lowerTick, polTickUpper(tickSpacing));
    }

    /// @notice A buyback bid bucket
    function buybackPositionId(int32 lowerTick, uint32 tickSpacing) internal pure returns (PositionId) {
        return createPositionId(BUYBACK_SALT, lowerTick, polTickUpper(tickSpacing));
    }

    /// @notice Price at which a day's auction opens (§8): pinned by the day's first sale, else a
    ///         multiple of yesterday's close, else a multiple of the floor if yesterday sold nothing
    /// @param lastWord Packed last close: price (low 128) | day (high 64)
    /// @param openWord Packed day open: price (low 128) | day (high 64)
    function auctionStartPrice(bytes32 lastWord, bytes32 openWord, uint256 floorPrice, uint256 multiple, uint256 nowTs)
        internal
        pure
        returns (uint256)
    {
        uint256 today = nowTs / 1 days;

        uint256 openDay = uint256(openWord) >> 128;
        if (openDay == today) return uint128(uint256(openWord));

        uint256 lastClose = uint128(uint256(lastWord));
        uint256 lastCloseDay = uint256(lastWord) >> 128;
        uint256 anchor = lastCloseDay + 1 == today ? lastClose : floorPrice;
        uint256 start = anchor * multiple;
        return start < floorPrice ? floorPrice : start;
    }

    /// @notice Falling-price curve of eq 7.1: `P(t) = P_start * (P_floor / P_start) ^ (t / 24h)`
    /// @dev The floor exists only to prevent literal-zero sales; buyers set the price
    function dutchPrice(uint256 startPrice, uint256 floorPrice, uint256 elapsed) internal pure returns (uint256) {
        if (startPrice <= floorPrice) return floorPrice;
        if (elapsed >= 1 days) return floorPrice;
        // A zero floor makes the geometric decay undefined, so the price simply holds
        if (floorPrice == 0) return startPrice;

        int256 ratio = int256(FixedPointMathLib.fullMulDiv(floorPrice, WAD, startPrice));
        if (ratio <= 0) return floorPrice;

        int256 exponent = int256(FixedPointMathLib.fullMulDiv(elapsed, WAD, 1 days));
        uint256 factor = uint256(FixedPointMathLib.powWad(ratio, exponent));

        uint256 price = FixedPointMathLib.fullMulDiv(startPrice, factor, WAD);
        return price < floorPrice ? floorPrice : price;
    }
}
