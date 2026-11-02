// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore, PoolKey, PositionId, CallPoints} from "../interfaces/ICore.sol";
import {IMEVCaptureV21} from "../interfaces/extensions/IMEVCaptureV21.sol";
import {IExtension} from "../interfaces/ICore.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {ExposedStorage} from "../base/ExposedStorage.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {exp2} from "../math/exp2.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {MIN_TICK, MAX_TICK} from "../math/constants.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolId} from "../types/poolId.sol";
import {Locker} from "../types/locker.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
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

/// @title MEV Capture v2.1
/// @notice Charges swaps that move the price away from a time-decaying anchor a surcharge that grows linearly with the
///   displacement from the anchor. The surcharge is charged inside the swap by Core through `SwapParameters.minFee`,
///   one constant-rate segment at a time, so it accrues to the liquidity in range exactly like the pool fee.
/// @dev Specification: EKU-946 design rev 5, §(b). Every swap must go through `forward`.
contract MEVCaptureV21 is IMEVCaptureV21, BaseExtension, BaseForwardee, ExposedStorage {
    using CoreLib for *;

    /// @notice Number of doubling-width away segments after the `J_LIN` equal-width ones
    uint256 internal constant DOUBLING_SEGMENTS = 24;

    uint256 internal immutable HALF_LIFE;
    uint256 internal immutable SLOPE_K;
    uint256 internal immutable SEGMENT_EXP;
    uint256 internal immutable J_LIN;
    uint256 internal immutable MAX_FEE;
    uint256 internal immutable CLAMP_TICKS;
    uint256 internal immutable M_GATE;
    uint256 internal immutable MAX_SEGMENTS;

    constructor(
        ICore core,
        uint32 halfLife,
        uint8 slopeK,
        uint8 segmentExp,
        uint8 jLin,
        uint16 maxFee,
        uint32 clampTicks,
        uint8 mGate
    ) BaseExtension(core) BaseForwardee(core) {
        if (
            halfLife == 0 || halfLife > (1 << 20) || slopeK == 0 || slopeK > 16 || segmentExp > 8 || jLin == 0
                || jLin > 64 || maxFee == 0 || maxFee > (1 << 15) || clampTicks == 0
                || uint256(clampTicks) > 2 * uint256(uint32(MAX_TICK)) || mGate > 16
        ) {
            revert InvalidConfig();
        }

        // Budget lemma: the (jLin + 24)-th away segment starts more than W * (jLin - 1 + 2^24 - 2) beyond the anchor,
        // so with poolFee >= 1 its fee is at least 1 + slopeK * 2^segmentExp * (jLin + 2^24 - 3) / 2, which must reach
        // maxFee. Holds for every allowed configuration; checked so that it cannot silently break.
        if (uint256(slopeK) * (uint256(jLin) + (1 << 24) - 3) << segmentExp < 2 * (uint256(maxFee) - 1)) {
            revert SegmentBudgetTooSmall();
        }

        HALF_LIFE = halfLife;
        SLOPE_K = slopeK;
        SEGMENT_EXP = segmentExp;
        J_LIN = jLin;
        MAX_FEE = maxFee;
        CLAMP_TICKS = clampTicks;
        M_GATE = mGate;
        MAX_SEGMENTS = uint256(jLin) + DOUBLING_SEGMENTS;
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
            jLin: uint8(J_LIN),
            maxFee: uint16(MAX_FEE),
            clampTicks: uint32(CLAMP_TICKS),
            mGate: uint8(M_GATE),
            maxSegments: uint8(MAX_SEGMENTS)
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
    function _boundary(uint256 k, int256 g1, int256 gJ, uint256 wShift) internal view returns (int256) {
        unchecked {
            if (k <= J_LIN) return g1 + (int256(k - 1) << wShift);
            return gJ + (int256((uint256(1) << (k - J_LIN + 1)) - 2) << wShift);
        }
    }

    /// @notice Index of the first away boundary strictly beyond the mirrored integer tick position `p`
    function _firstSegment(int256 p, int256 g1, int256 gJ, uint256 wShift) internal view returns (uint256 k) {
        unchecked {
            int256 p16 = p << 16;
            if (p16 < g1) return 1;
            if (p16 < gJ) return uint256((p16 - g1) >> wShift) + 2;
            return J_LIN - 1 + bitLength(uint256((p16 - gJ) >> wShift) + 2);
        }
    }

    /// @notice Total fee of an away segment: ceil(poolFee + SLOPE_K/2 * poolFee * |mid - anchor| / tickSpacing),
    ///   capped at MAX_FEE
    /// @param twiceMidOffsetX16 lo + hi - 2 * anchor, in Q16 ticks, i.e. twice the midpoint displacement
    function _segmentFee(uint256 poolFee, uint256 twiceMidOffsetX16, uint256 spacingExp)
        internal
        view
        returns (uint256 fee)
    {
        unchecked {
            uint256 shift = spacingExp + 18;
            uint256 numerator = SLOPE_K * poolFee * twiceMidOffsetX16;
            fee = poolFee + ((numerator + (uint256(1) << shift) - 1) >> shift);
            if (fee > MAX_FEE) fee = MAX_FEE;
        }
    }

    function _coreSwap(PoolKey memory poolKey, SwapParameters params, SqrtRatio limit, int128 amount, uint256 fee)
        internal
        returns (PoolBalanceUpdate balanceUpdate, PoolState stateAfter)
    {
        (balanceUpdate, stateAfter) = CORE.swap(
            0,
            poolKey,
            createSwapParameters({
                _sqrtRatioLimit: limit,
                _amount: amount,
                _isToken1: params.isToken1(),
                _skipAhead: params.skipAhead(),
                _minFee: uint16(fee)
            })
        );
    }

    /// @notice Executes the swap as one toward call (to the anchor) plus one Core call per away segment
    function _swapThroughSegments(PoolKey memory poolKey, SwapParameters params, int256 anchor, PoolState stateBefore)
        internal
        returns (PoolBalanceUpdate, PoolState stateAfter)
    {
        SqrtRatio userLimit = params.sqrtRatioLimit();
        int128 remaining = params.amount();
        (SqrtRatio sqrtRatio, int32 tick,) = stateBefore.parse();
        if (remaining == 0 || sqrtRatio == userLimit) return CORE.swap(0, poolKey, params);

        bool increasing = params.isPriceIncreasing();
        bool isToken1 = params.isToken1();
        // mirrored coordinates: the swap always moves toward larger values
        int256 a = increasing ? anchor : -anchor;
        int128 sum0;
        int128 sum1;

        {
            // the toward call ends at or before the true anchor: floor when approaching from below, ceil from above
            int256 anchorTick = a >> 16;
            if (!increasing) anchorTick = -anchorTick;
            if (anchorTick < MIN_TICK) anchorTick = MIN_TICK;
            else if (anchorTick > MAX_TICK) anchorTick = MAX_TICK;
            SqrtRatio anchorSqrtRatio = tickToSqrtRatio(int32(anchorTick));

            if (increasing ? sqrtRatio < anchorSqrtRatio : sqrtRatio > anchorSqrtRatio) {
                SqrtRatio limit = increasing ? anchorSqrtRatio.min(userLimit) : anchorSqrtRatio.max(userLimit);
                PoolBalanceUpdate update;
                (update, stateAfter) = _coreSwap(poolKey, params, limit, remaining, params.minFee());
                sum0 = update.delta0();
                sum1 = update.delta1();
                remaining -= isToken1 ? sum1 : sum0;
                if (remaining == 0 || limit == userLimit || stateAfter.sqrtRatio() != limit) {
                    return (createPoolBalanceUpdate(sum0, sum1), stateAfter);
                }
                // N1: the away loop starts from the same rounded sqrt ratio the toward call ended at
                sqrtRatio = limit;
                tick = stateAfter.tick();
            }
        }

        uint256 spacingExp = poolKey.config.tickSpacingExp();
        uint256 wShift = spacingExp + SEGMENT_EXP + 16;
        int256 g1 = ((a >> wShift) + 1) << wShift;
        int256 gJ = g1 + (int256(J_LIN - 1) << wShift);
        // mirrored integer tick p such that the boundaries strictly beyond the price are those > p (up to one exact
        // boundary hit, handled below by comparing sqrt ratios)
        uint256 k = _firstSegment(increasing ? int256(tick) : -int256(tick) - 1, g1, gJ, wShift);
        uint256 poolFee = poolKey.config.fee();
        uint256 minFee = params.minFee();
        uint256 n;

        int256 lo = k == 1 ? a : _boundary(k - 1, g1, gJ, wShift);
        while (true) {
            int256 hi = _boundary(k, g1, gJ, wShift);
            uint256 fee = _segmentFee(poolFee, uint256(lo + hi - 2 * a), spacingExp);

            SqrtRatio limit = userLimit;
            if (fee != MAX_FEE && n != MAX_SEGMENTS - 1) {
                int256 hiTick = hi >> 16;
                if (hiTick <= MAX_TICK) {
                    SqrtRatio boundary = tickToSqrtRatio(int32(increasing ? hiTick : -hiTick));
                    // segment membership is by sqrt ratio: skip a boundary the price already sits on
                    if (increasing ? boundary <= sqrtRatio : boundary >= sqrtRatio) {
                        lo = hi;
                        unchecked {
                            k++;
                        }
                        continue;
                    }
                    limit = increasing ? boundary.min(userLimit) : boundary.max(userLimit);
                }
            }

            PoolBalanceUpdate update;
            (update, stateAfter) = _coreSwap(poolKey, params, limit, remaining, fee > minFee ? fee : minFee);
            // S3: checked int128 sums
            sum0 += update.delta0();
            sum1 += update.delta1();
            remaining -= isToken1 ? update.delta1() : update.delta0();
            unchecked {
                n++;
            }

            if (remaining == 0 || limit == userLimit || stateAfter.sqrtRatio() != limit) break;
            sqrtRatio = limit;
            lo = hi;
            unchecked {
                k++;
            }
        }

        return (createPoolBalanceUpdate(sum0, sum1), stateAfter);
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
