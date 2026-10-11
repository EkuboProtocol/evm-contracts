// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore, PoolKey, PositionId, CallPoints} from "../interfaces/ICore.sol";
import {IMEVCaptureV21} from "../interfaces/extensions/IMEVCaptureV21.sol";
import {IExtension} from "../interfaces/ICore.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {exp2} from "../math/exp2.sol";
import {amountBeforeFee, computeFee} from "../math/fee.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {MIN_TICK, MAX_TICK} from "../math/constants.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolId} from "../types/poolId.sol";
import {Locker} from "../types/locker.sol";
import {SqrtRatio, BIT_MASK, TWO_POW_62, TWO_POW_94} from "../types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {MEVCaptureV21PoolState, createMEVCaptureV21PoolState} from "../types/mevCaptureV21PoolState.sol";

function mevCaptureV21CallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        // to initialize the anchor and the gate reference
        beforeInitializePool: true,
        afterInitializePool: false,
        // so that swaps can only happen through forward
        beforeSwap: true,
        afterSwap: false,
        // to snapshot active liquidity before the first position update of a timestamp
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

/// @notice Bit length of `x`: 0 for 0, otherwise the index of the most significant set bit plus one
function bitLength(uint256 x) pure returns (uint256 n) {
    assembly ("memory-safe") {
        n := sub(256, clz(x))
    }
}

uint96 constant MANTISSA_MAX = uint96(TWO_POW_94) - 1;

/// @notice The largest valid sqrt ratio strictly below `x`
/// @dev Only called with `x` strictly above the current price, so the result is at least the current price and never
///   below `MIN_SQRT_RATIO`. Jumps regions when the mantissa is at its minimum.
function predSqrtRatio(SqrtRatio x) pure returns (SqrtRatio) {
    uint96 raw = SqrtRatio.unwrap(x);
    uint96 region = raw & BIT_MASK;
    if ((raw & ~BIT_MASK) == TWO_POW_62 && region != 0) {
        return SqrtRatio.wrap((region - TWO_POW_94) | MANTISSA_MAX);
    }
    return SqrtRatio.wrap(raw - 1);
}

/// @notice The smallest valid sqrt ratio strictly above `x`
/// @dev Only called with `x` strictly below the current price, so the result is at most the current price and never
///   above `MAX_SQRT_RATIO`. Jumps regions when the mantissa is at its maximum.
function succSqrtRatio(SqrtRatio x) pure returns (SqrtRatio) {
    uint96 raw = SqrtRatio.unwrap(x);
    uint96 region = raw & BIT_MASK;
    if ((raw & ~BIT_MASK) == MANTISSA_MAX && region != BIT_MASK) {
        return SqrtRatio.wrap((region + TWO_POW_94) | TWO_POW_62);
    }
    return SqrtRatio.wrap(raw + 1);
}

/// @title MEV Capture v2.1 for the current Core
/// @notice Charges swaps that move the price away from a time-decaying anchor a surcharge that grows linearly with the
///   displacement from the anchor. The surcharge is charged by the extension through `Core.accumulateAsFees` right
///   after each charged Core call, so it accrues to exactly the liquidity that was active during that call. Every
///   charged Core call is cut to end strictly before the next initialized tick; each initialized tick is crossed by its
///   own uncharged bridge call of one representable sqrt-ratio step.
/// @dev Specification: EKU-946 design rev 10, §(b-main). Every swap must go through `forward`.
contract MEVCaptureV21 is IMEVCaptureV21, BaseExtension, BaseForwardee, ExposedStorage {
    using CoreLib for *;

    uint256 internal immutable HALF_LIFE;
    uint256 internal immutable SLOPE_K;
    uint256 internal immutable SEGMENT_EXP;
    uint256 internal immutable J_LIN;
    uint256 internal immutable MAX_FEE;
    uint256 internal immutable CLAMP_TICKS;
    uint256 internal immutable M_GATE;

    constructor(
        ICore core,
        uint32 halfLife,
        uint8 slopeK,
        uint8 segmentExp,
        uint8 jLin,
        uint64 maxFee,
        uint32 clampTicks,
        uint8 mGate
    ) BaseExtension(core) BaseForwardee(core) {
        if (
            halfLife == 0 || halfLife > (1 << 20) || slopeK == 0 || slopeK > 16 || segmentExp > 8 || jLin == 0
                || jLin > 64 || maxFee == 0 || maxFee > (1 << 63) || clampTicks == 0
                || uint256(clampTicks) > 2 * uint256(uint32(MAX_TICK)) || mGate > 16
        ) {
            revert InvalidConfig();
        }

        HALF_LIFE = halfLife;
        SLOPE_K = slopeK;
        SEGMENT_EXP = segmentExp;
        J_LIN = jLin;
        MAX_FEE = maxFee;
        CLAMP_TICKS = clampTicks;
        M_GATE = mGate;
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return mevCaptureV21CallPoints();
    }

    function _getPoolState(PoolId poolId) internal view returns (MEVCaptureV21PoolState state) {
        assembly ("memory-safe") {
            state := sload(poolId)
        }
    }

    function _setPoolState(PoolId poolId, MEVCaptureV21PoolState state) internal {
        assembly ("memory-safe") {
            sstore(poolId, state)
        }
    }

    /// @inheritdoc IMEVCaptureV21
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
        )
    {
        MEVCaptureV21PoolState s = _getPoolState(poolId);
        return (
            s.lastUpdateTime(),
            s.lRefTime(),
            s.lastPosTime(),
            s.lRefBits(),
            s.snapBits(),
            s.lRefRaiseTime(),
            s.anchorX16()
        );
    }

    /// @inheritdoc IMEVCaptureV21
    function getConfig() external view returns (Config memory) {
        return Config({
            halfLife: uint32(HALF_LIFE),
            slopeK: uint8(SLOPE_K),
            segmentExp: uint8(SEGMENT_EXP),
            segmentWidthMultiplier: uint32(1) << SEGMENT_EXP,
            jLin: uint8(J_LIN),
            maxFee: uint64(MAX_FEE),
            clampTicks: uint32(CLAMP_TICKS),
            mGate: uint8(M_GATE)
        });
    }

    function beforeInitializePool(address, PoolKey calldata poolKey, int32 tick)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        if (poolKey.config.isStableswap()) revert ConcentratedLiquidityPoolsOnly();
        uint256 poolFee = poolKey.config.fee();
        if (poolFee == 0) revert NonzeroFeesOnly();
        if (poolFee >= MAX_FEE) revert PoolFeeNotBelowMaxFee();

        uint32 currentTime = uint32(block.timestamp);
        unchecked {
            _setPoolState(
                poolKey.toPoolId(),
                createMEVCaptureV21PoolState({
                    _lastUpdateTime: currentTime,
                    _lRefTime: currentTime,
                    _lastPosTime: 0,
                    _lRefBits: 0,
                    _snapBits: 0,
                    // the first increase of the reference is allowed immediately
                    _lRefRaiseTime: currentTime - uint32(HALF_LIFE),
                    _anchorX16: int64(tick) << 16
                })
            );
        }
    }

    /// @notice Swaps are only allowed through forward. Core skips this call when the extension itself is the locker.
    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override(BaseExtension, IExtension) {
        revert SwapMustHappenThroughForward();
    }

    /// @notice Snapshots the bit length of the active liquidity before the first position update of each timestamp,
    ///   so that the gate never observes liquidity added in the same timestamp as the swap that reads it.
    function beforeUpdatePosition(Locker, PoolKey memory poolKey, PositionId, int128)
        external
        override(BaseExtension, IExtension)
        onlyCore
    {
        PoolId poolId = poolKey.toPoolId();
        MEVCaptureV21PoolState state = _getPoolState(poolId);
        uint32 currentTime = uint32(block.timestamp);
        if (state.lastPosTime() != currentTime) {
            uint256 bits = bitLength(CORE.poolState(poolId).liquidity());
            _setPoolState(poolId, state.withSnapshot(currentTime, uint8(bits)));
        }
    }

    /// @notice The gate reference decayed by one bit per elapsed half-life since `lRefTime`
    function _decayedReference(MEVCaptureV21PoolState state, uint32 currentTime) internal view returns (uint256 e) {
        unchecked {
            uint256 bits = state.lRefBits();
            uint256 decay = uint256(uint32(currentTime - state.lRefTime())) / HALF_LIFE;
            e = decay >= bits ? 0 : bits - decay;
        }
    }

    /// @notice The reference may rise by one bit, at most once per half-life (H1)
    function _raise(uint256 e, uint256 observedBits, uint32 currentTime, uint32 raiseTime)
        internal
        view
        returns (uint256, uint32)
    {
        unchecked {
            if (observedBits > e && uint256(uint32(currentTime - raiseTime)) >= HALF_LIFE) {
                return (e + 1, currentTime);
            }
            return (e, raiseTime);
        }
    }

    /// @notice Anchor update run on the first swap of a timestamp, before the swap
    /// @dev Requires `state.lastUpdateTime() != currentTime`
    /// @return next The updated state
    /// @return passed Whether the liquidity gate passed and the anchor was allowed to move
    /// @return lObs The observed active liquidity, as a bit length
    /// @return eRef The decayed gate reference, as a bit length
    function _anchorUpdate(MEVCaptureV21PoolState state, int32 tickNow, uint128 liquidityNow, uint32 currentTime)
        internal
        view
        returns (MEVCaptureV21PoolState next, bool passed, uint256 lObs, uint256 eRef)
    {
        unchecked {
            uint256 dt = uint32(currentTime - state.lastUpdateTime());
            lObs = state.lastPosTime() == currentTime ? state.snapBits() : bitLength(liquidityNow);
            eRef = _decayedReference(state, currentTime);

            int256 anchor = state.anchorX16();
            uint256 refBits = state.lRefBits();
            uint32 refTime = state.lRefTime();
            uint32 raiseTime = state.lRefRaiseTime();

            passed = lObs + M_GATE >= eRef;
            if (passed) {
                int256 offset = anchor - (int256(tickNow) << 16);
                uint256 magnitude = offset < 0 ? uint256(-offset) : uint256(offset);
                // |offset| * 2^(-dt / tau), rounded toward zero; shifts of 256 or more yield 0
                magnitude = ((magnitude >> (dt / HALF_LIFE)) << 64) / exp2(((dt % HALF_LIFE) << 64) / HALF_LIFE);
                int256 decayed = offset < 0 ? -int256(magnitude) : int256(magnitude);

                int256 limit = int256(((CLAMP_TICKS << 16) * (dt < HALF_LIFE ? dt : HALF_LIFE)) / HALF_LIFE);
                int256 move = decayed - offset;
                if (move > limit) move = limit;
                else if (move < -limit) move = -limit;
                anchor += move;

                // rev 6 (EKU-1034 Q1): a pass restores the reference toward its stored value, never above it, so
                // decay over idle time between passes is recovered; then the H1 raise (+1 bit, once per tau)
                uint256 base = lObs < refBits ? lObs : refBits;
                if (base < eRef) base = eRef;
                (refBits, raiseTime) = _raise(base, lObs, currentTime, raiseTime);
                refTime = currentTime;
            }

            next = createMEVCaptureV21PoolState({
                _lastUpdateTime: currentTime,
                _lRefTime: refTime,
                _lastPosTime: state.lastPosTime(),
                _lRefBits: uint8(refBits),
                _snapBits: state.snapBits(),
                _lRefRaiseTime: raiseTime,
                _anchorX16: int64(anchor)
            });
        }
    }

    /// @notice Post-swap refresh: raises the reference from the liquidity after the swap, unless a position changed in
    ///   this timestamp
    function _refresh(MEVCaptureV21PoolState state, uint128 liquidityAfter, uint32 currentTime)
        internal
        view
        returns (MEVCaptureV21PoolState)
    {
        if (state.lastPosTime() == currentTime) return state;
        uint256 e = _decayedReference(state, currentTime);
        (uint256 raised, uint32 raiseTime) = _raise(e, bitLength(liquidityAfter), currentTime, state.lRefRaiseTime());
        if (raised == e) return state;
        return createMEVCaptureV21PoolState({
            _lastUpdateTime: state.lastUpdateTime(),
            _lRefTime: currentTime,
            _lastPosTime: state.lastPosTime(),
            _lRefBits: uint8(raised),
            _snapBits: state.snapBits(),
            _lRefRaiseTime: raiseTime,
            _anchorX16: state.anchorX16()
        });
    }

    /// @notice Away boundary `k` (1-based), in Q16 ticks in the swap's mirrored coordinates
    /// @dev The first `J_LIN` boundaries lie on the absolute W grid starting at `g1`, the first grid point strictly
    ///   beyond the anchor. After `gJ` (the `J_LIN`-th), widths double: 2W, 4W, ...
    function _boundary(uint256 k, int256 g1, int256 gJ, int256 w16) internal view returns (int256) {
        unchecked {
            if (k <= J_LIN) return g1 + int256(k - 1) * w16;
            return gJ + int256((uint256(1) << (k - J_LIN + 1)) - 2) * w16;
        }
    }

    /// @notice Index of the first away boundary strictly beyond the mirrored integer tick position `p`
    function _firstSegment(int256 p, int256 g1, int256 gJ, int256 w16) internal view returns (uint256 k) {
        unchecked {
            int256 p16 = p << 16;
            if (p16 < g1) return 1;
            if (p16 < gJ) return uint256((p16 - g1) / w16) + 2;
            return J_LIN - 1 + bitLength(uint256((p16 - gJ) / w16) + 2);
        }
    }

    /// @notice Surcharge rate of an away segment: ceil(SLOPE_K/2 * poolFee * |mid - anchor| / tickSpacing), capped so
    ///   that the total fee does not exceed MAX_FEE
    /// @param twiceMidOffsetX16 lo + hi - 2 * anchor, in Q16 ticks, i.e. twice the midpoint displacement
    function _surcharge(uint256 poolFee, uint256 twiceMidOffsetX16, uint256 spacing)
        internal
        view
        returns (uint256 sur)
    {
        unchecked {
            uint256 den = spacing << 18;
            uint256 num = SLOPE_K * poolFee * twiceMidOffsetX16;
            sur = (num + den - 1) / den;
            uint256 cap = MAX_FEE - poolFee;
            if (sur > cap) sur = cap;
        }
    }

    function _coreSwap(PoolKey memory poolKey, SwapParameters params, SqrtRatio limit, int128 amount)
        internal
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) = CORE.swap(
            0,
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: limit, _amount: amount, _isToken1: params.isToken1(), _skipAhead: params.skipAhead()
            })
        );
    }

    /// @notice The first tick event strictly beyond `fromTick` in the direction of travel, exactly as Core's swap loop
    ///   searches it: an initialized tick, an uninitialized bitmap-word endpoint, or the extreme tick
    function _tickEvent(PoolId poolId, int32 fromTick, uint32 spacing, uint256 skipAhead, bool increasing)
        internal
        view
        returns (int32, bool)
    {
        return increasing
            ? CORE.nextInitializedTick(poolId, fromTick, spacing, skipAhead)
            : CORE.prevInitializedTick(poolId, fromTick, spacing, skipAhead);
    }

    /// @notice Charges the surcharge of a charged call on its calculated token and credits it to the active liquidity
    /// @dev Exact-in: the surcharge is taken from the output. Exact-out: the input is grossed up so that the swapper
    ///   pays the surcharge on top of the pool fee. Nothing is charged (and `accumulateAsFees` is not called) when the
    ///   call moved no tokens, so a nonzero charge always credits the liquidity that traded.
    function _charge(
        PoolKey memory poolKey,
        PoolBalanceUpdate update,
        bool isToken1,
        bool exactOut,
        uint64 poolFee,
        uint64 sur
    ) internal returns (int256 d0, int256 d1) {
        d0 = update.delta0();
        d1 = update.delta1();
        // the calculated token is token0 when token1 is specified and vice versa
        int256 calculated = isToken1 ? d0 : d1;
        uint128 fee;
        if (exactOut) {
            // the calculated token is the input
            uint128 input = uint128(uint256(calculated));
            uint128 inputNet = input - computeFee(input, poolFee);
            fee = amountBeforeFee(inputNet, sur) - inputNet;
        } else {
            // the calculated token is the output
            fee = computeFee(uint128(uint256(-calculated)), sur);
        }
        if (fee != 0) {
            if (isToken1) {
                CORE.accumulateAsFees(poolKey, fee, 0);
                d0 += int256(uint256(fee));
            } else {
                CORE.accumulateAsFees(poolKey, 0, fee);
                d1 += int256(uint256(fee));
            }
        }
    }

    struct Away {
        bool increasing;
        bool isToken1;
        bool exactOut;
        SqrtRatio userLimit;
        SqrtRatio sqrtRatio;
        int32 tick;
        int128 remaining;
        int256 sum0;
        int256 sum1;
        uint64 poolFee;
        uint32 spacing;
        uint256 skipAhead;
        int256 a;
        int256 w16;
        int256 g1;
        int256 gJ;
        uint256 k;
        int256 lo;
    }

    /// @notice Executes the swap as one uncut toward call (to the anchor) followed by the away state machine: charged
    ///   calls cut before the next rate boundary and before the next initialized tick, and one uncharged bridge call
    ///   per initialized tick crossed
    function _swapThroughSegments(PoolKey memory poolKey, SwapParameters params, int256 anchor, PoolState stateBefore)
        internal
        returns (PoolBalanceUpdate, PoolState stateAfter)
    {
        Away memory l;
        l.userLimit = params.sqrtRatioLimit();
        l.remaining = params.amount();
        (l.sqrtRatio, l.tick,) = stateBefore.parse();
        if (l.remaining == 0 || l.sqrtRatio == l.userLimit) return CORE.swap(0, poolKey, params);

        l.increasing = params.isPriceIncreasing();
        l.isToken1 = params.isToken1();
        l.exactOut = params.isExactOut();
        // mirrored coordinates: the swap always moves toward larger values
        l.a = l.increasing ? anchor : -anchor;

        {
            // the toward call ends at or before the true anchor: floor when approaching from below, ceil from above
            int256 anchorTick = l.a >> 16;
            if (!l.increasing) anchorTick = -anchorTick;
            if (anchorTick < MIN_TICK) anchorTick = MIN_TICK;
            else if (anchorTick > MAX_TICK) anchorTick = MAX_TICK;
            SqrtRatio anchorSqrtRatio = tickToSqrtRatio(int32(anchorTick));

            if (l.increasing ? l.sqrtRatio < anchorSqrtRatio : l.sqrtRatio > anchorSqrtRatio) {
                SqrtRatio limit = l.increasing ? anchorSqrtRatio.min(l.userLimit) : anchorSqrtRatio.max(l.userLimit);
                PoolBalanceUpdate update;
                (update, stateAfter) = _coreSwap(poolKey, params, limit, l.remaining);
                l.sum0 = update.delta0();
                l.sum1 = update.delta1();
                l.remaining -= l.isToken1 ? update.delta1() : update.delta0();
                if (l.remaining == 0 || limit == l.userLimit || stateAfter.sqrtRatio() != limit) {
                    return (createPoolBalanceUpdate(int128(l.sum0), int128(l.sum1)), stateAfter);
                }
                // N1: the away loop starts from the same rounded sqrt ratio the toward call ended at
                l.sqrtRatio = limit;
                l.tick = stateAfter.tick();
            }
        }

        l.poolFee = poolKey.config.fee();
        l.spacing = poolKey.config.concentratedTickSpacing();
        l.skipAhead = params.skipAhead();
        PoolId poolId = poolKey.toPoolId();

        l.w16 = int256(uint256(l.spacing) << (SEGMENT_EXP + 16));
        {
            // first grid point strictly beyond the anchor (floor division for negative anchors)
            int256 q = l.a / l.w16;
            if (l.a < 0 && l.a % l.w16 != 0) q -= 1;
            l.g1 = (q + 1) * l.w16;
        }
        l.gJ = l.g1 + int256(J_LIN - 1) * l.w16;
        // mirrored integer tick p such that the boundaries strictly beyond the price are those > p (up to one exact
        // boundary hit, handled below by comparing sqrt ratios)
        l.k = _firstSegment(l.increasing ? int256(l.tick) : -int256(l.tick) - 1, l.g1, l.gJ, l.w16);
        l.lo = l.k == 1 ? l.a : _boundary(l.k - 1, l.g1, l.gJ, l.w16);

        while (true) {
            // (2) rate boundary: the end of the segment containing the current price, or none once the surcharge is
            //     capped or the boundary lies beyond the last tick
            int256 hi = _boundary(l.k, l.g1, l.gJ, l.w16);
            uint256 sur = _surcharge(l.poolFee, uint256(l.lo + hi - 2 * l.a), l.spacing);
            SqrtRatio limit = l.userLimit;
            if (sur != MAX_FEE - l.poolFee) {
                int256 hiTick = hi >> 16;
                if (hiTick <= MAX_TICK) {
                    SqrtRatio boundary = tickToSqrtRatio(int32(l.increasing ? hiTick : -hiTick));
                    // segment membership is by sqrt ratio: skip a boundary the price already sits on
                    if (l.increasing ? boundary <= l.sqrtRatio : boundary >= l.sqrtRatio) {
                        l.lo = hi;
                        unchecked {
                            l.k++;
                        }
                        continue;
                    }
                    limit = l.increasing ? boundary.min(limit) : boundary.max(limit);
                }
            }

            // (1) tick event: Core's first search of the next call. In the exact-tick state (price on a tick reached
            //     from the other direction) Core will cross it with zero amounts at the start of the call; look past it
            (int32 eventTick, bool initialized) = _tickEvent(poolId, l.tick, l.spacing, l.skipAhead, l.increasing);
            SqrtRatio eventSqrtRatio = tickToSqrtRatio(eventTick);
            if (eventSqrtRatio == l.sqrtRatio) {
                unchecked {
                    (eventTick, initialized) = _tickEvent(
                        poolId, l.increasing ? eventTick : eventTick - 1, l.spacing, l.skipAhead, l.increasing
                    );
                }
                eventSqrtRatio = tickToSqrtRatio(eventTick);
            }

            // (3) choose the call: an initialized tick one representable step away is crossed by its own uncharged
            //     bridge call; otherwise a charged call that stops one step short of an initialized tick, or exactly
            //     on an uninitialized endpoint, and before the rate boundary and the user's limit
            bool bridge;
            if (initialized) {
                SqrtRatio cut = l.increasing ? predSqrtRatio(eventSqrtRatio) : succSqrtRatio(eventSqrtRatio);
                if (cut == l.sqrtRatio) {
                    bridge = true;
                    limit = l.increasing ? eventSqrtRatio.min(l.userLimit) : eventSqrtRatio.max(l.userLimit);
                } else {
                    limit = l.increasing ? cut.min(limit) : cut.max(limit);
                }
            } else {
                limit = l.increasing ? eventSqrtRatio.min(limit) : eventSqrtRatio.max(limit);
            }

            PoolBalanceUpdate update;
            (update, stateAfter) = _coreSwap(poolKey, params, limit, l.remaining);
            if (bridge || sur == 0) {
                l.sum0 += update.delta0();
                l.sum1 += update.delta1();
            } else {
                (int256 d0, int256 d1) = _charge(poolKey, update, l.isToken1, l.exactOut, l.poolFee, uint64(sur));
                l.sum0 += d0;
                l.sum1 += d1;
            }
            // the specified token's delta is Core's; the surcharge is always on the calculated token
            l.remaining -= l.isToken1 ? update.delta1() : update.delta0();

            (l.sqrtRatio, l.tick,) = stateAfter.parse();
            if (l.remaining == 0 || l.sqrtRatio == l.userLimit) break;
        }

        // S3: checked int128 sums
        return (createPoolBalanceUpdate(SafeCastLib.toInt128(l.sum0), SafeCastLib.toInt128(l.sum1)), stateAfter);
    }

    function handleForwardData(Locker, bytes memory data) internal override returns (bytes memory result) {
        (PoolKey memory poolKey, SwapParameters params) = abi.decode(data, (PoolKey, SwapParameters));
        params = params.withDefaultSqrtRatioLimit();

        PoolId poolId = poolKey.toPoolId();
        MEVCaptureV21PoolState state = _getPoolState(poolId);
        MEVCaptureV21PoolState next = state;
        PoolState poolState = CORE.poolState(poolId);
        uint32 currentTime = uint32(block.timestamp);

        if (state.lastUpdateTime() != currentTime) {
            bool passed;
            uint256 lObs;
            uint256 eRef;
            (next, passed, lObs, eRef) = _anchorUpdate(state, poolState.tick(), poolState.liquidity(), currentTime);
            if (!passed) emit AnchorGateFailed(poolId, uint8(lObs), uint8(eRef));
        }

        (PoolBalanceUpdate balanceUpdate, PoolState stateAfter) =
            _swapThroughSegments(poolKey, params, next.anchorX16(), poolState);

        next = _refresh(next, stateAfter.liquidity(), currentTime);

        if (MEVCaptureV21PoolState.unwrap(next) != MEVCaptureV21PoolState.unwrap(state)) _setPoolState(poolId, next);

        result = abi.encode(balanceUpdate, stateAfter);
    }
}
