// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "../../src/interfaces/ICore.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PositionId} from "../../src/types/positionId.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {exp2} from "../../src/math/exp2.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {MEVCaptureV21, bitLength} from "../../src/extensions/MEVCaptureV21.sol";
import {MEVCaptureV21PoolState} from "../../src/types/mevCaptureV21PoolState.sol";

/// @notice Independent reference model of the MEVCapture v2.1 rules (EKU-946 rev 5 §(b)), written directly from the
///   spec text in original (not mirrored) coordinates, with naive loops instead of closed forms.
library V21Ref {
    struct Cfg {
        uint256 tau;
        uint256 slopeK;
        uint256 segExp;
        uint256 jLin;
        uint256 maxFee;
        uint256 clamp;
        uint256 mGate;
    }

    struct State {
        uint32 lastUpdateTime;
        uint32 lRefTime;
        uint32 lastPosTime;
        uint256 lRefBits;
        uint256 snapBits;
        uint32 raiseTime;
        int256 anchorX16;
    }

    function defaults() internal pure returns (Cfg memory) {
        return Cfg({tau: 120, slopeK: 4, segExp: 0, jLin: 16, maxFee: 1 << 15, clamp: 2500, mGate: 3});
    }

    function bitlen(uint256 x) internal pure returns (uint256 n) {
        while (x != 0) {
            n++;
            x >>= 1;
        }
    }

    function floorDiv(int256 x, int256 d) internal pure returns (int256 q) {
        q = x / d;
        if (x % d != 0 && (x < 0) != (d < 0)) q -= 1;
    }

    function ceilDiv(int256 x, int256 d) internal pure returns (int256) {
        return -floorDiv(-x, d);
    }

    function since(uint32 nowT, uint32 thenT) internal pure returns (uint256) {
        unchecked {
            return uint32(nowT - thenT);
        }
    }

    function eRef(Cfg memory c, State memory s, uint32 nowT) internal pure returns (uint256) {
        uint256 decay = since(nowT, s.lRefTime) / c.tau;
        return decay >= s.lRefBits ? 0 : s.lRefBits - decay;
    }

    /// @dev raise(e, L): e + 1 if L > e and at least tau since the last raise
    function raise(Cfg memory c, State memory s, uint256 e, uint256 l, uint32 nowT) internal pure returns (uint256) {
        if (l > e && since(nowT, s.raiseTime) >= c.tau) {
            s.raiseTime = nowT;
            return e + 1;
        }
        return e;
    }

    /// @notice First swap of a timestamp. Mutates `s`.
    function anchorUpdate(Cfg memory c, State memory s, int32 tickNow, uint128 liquidityNow, uint32 nowT)
        internal
        pure
        returns (bool passed, uint256 lObs, uint256 e)
    {
        uint256 dt = since(nowT, s.lastUpdateTime);
        require(dt != 0, "ref: same timestamp");
        lObs = s.lastPosTime == nowT ? s.snapBits : bitlen(liquidityNow);
        e = eRef(c, s, nowT);
        passed = lObs + c.mGate >= e;
        if (passed) {
            int256 off = s.anchorX16 - int256(tickNow) * 65536;
            uint256 mag = off < 0 ? uint256(-off) : uint256(off);
            uint256 halvings = dt / c.tau;
            mag = halvings >= 256 ? 0 : mag / (uint256(1) << halvings);
            mag = mag * (uint256(1) << 64) / exp2(((dt % c.tau) * (uint256(1) << 64)) / c.tau);
            int256 offNew = off < 0 ? -int256(mag) : int256(mag);
            int256 lim = int256(c.clamp * 65536 * (dt < c.tau ? dt : c.tau) / c.tau);
            int256 mv = offNew - off;
            if (mv > lim) mv = lim;
            if (mv < -lim) mv = -lim;
            s.anchorX16 += mv;
            s.lRefBits = raise(c, s, e, lObs, nowT);
            s.lRefTime = nowT;
        }
        s.lastUpdateTime = nowT;
    }

    /// @notice Post-swap refresh. Mutates `s`.
    function refresh(Cfg memory c, State memory s, uint128 liquidityAfter, uint32 nowT) internal pure {
        if (s.lastPosTime == nowT) return;
        uint256 e = eRef(c, s, nowT);
        uint256 r = raise(c, s, e, bitlen(liquidityAfter), nowT);
        if (r > e) {
            s.lRefBits = r;
            s.lRefTime = nowT;
        }
    }

    /// @notice Position hook. Mutates `s`.
    function positionHook(State memory s, uint128 activeLiquidityBefore, uint32 nowT) internal pure {
        if (s.lastPosTime != nowT) {
            s.snapBits = bitlen(activeLiquidityBefore);
            s.lastPosTime = nowT;
        }
    }

    /// @notice The k-th (1-based) away boundary, in Q16 ticks, original coordinates
    function boundary(Cfg memory c, uint256 spacing, int256 anchorX16, bool increasing, uint256 k)
        internal
        pure
        returns (int256 b)
    {
        int256 w16 = int256((spacing << c.segExp) * 65536);
        b = increasing ? (floorDiv(anchorX16, w16) + 1) * w16 : (ceilDiv(anchorX16, w16) - 1) * w16;
        int256 width = w16;
        for (uint256 j = 2; j <= k; j++) {
            if (j > c.jLin) width *= 2;
            b = increasing ? b + width : b - width;
        }
    }

    function segmentFee(Cfg memory c, uint256 poolFee, uint256 spacing, int256 lo, int256 hi, int256 anchorX16)
        internal
        pure
        returns (uint256 fee)
    {
        int256 twice = lo + hi - 2 * anchorX16;
        uint256 d = twice < 0 ? uint256(-twice) : uint256(twice);
        uint256 den = 4 * spacing * 65536;
        uint256 num = c.slopeK * poolFee * d;
        fee = poolFee + (num + den - 1) / den;
        if (fee > c.maxFee) fee = c.maxFee;
    }

    function clampTick(int256 t) internal pure returns (int32) {
        if (t < MIN_TICK) return MIN_TICK;
        if (t > MAX_TICK) return MAX_TICK;
        return int32(t);
    }
}

/// @notice Test locker: executes arbitrary action lists in one lock (flash-liquidity scenarios) and runs the reference
///   segment schedule against a twin pool without the extension.
contract V21Actor is BaseLocker {
    using CoreLib for *;
    using FlashAccountantLib for *;

    uint8 internal constant UPDATE_POSITION = 0;
    uint8 internal constant FORWARD_SWAP = 1;
    uint8 internal constant CORE_SWAP = 2;
    uint8 internal constant COLLECT = 3;

    struct Action {
        uint8 kind;
        PoolKey poolKey;
        bytes32 a;
        int256 b;
        address target;
    }

    /// @notice Record of one Core call the reference made
    struct RefCall {
        SqrtRatio limit;
        uint16 fee;
        int128 amount;
    }

    ICore internal immutable core;
    address internal immutable payer;

    RefCall[] public lastRefCalls;

    constructor(ICore _core, address _payer) BaseLocker(_core) {
        core = _core;
        payer = _payer;
    }

    function refCallsLength() external view returns (uint256) {
        return lastRefCalls.length;
    }

    function refCall(uint256 i) external view returns (RefCall memory) {
        return lastRefCalls[i];
    }

    function run(Action[] memory actions) external returns (bytes[] memory results) {
        results = abi.decode(lock(abi.encode(uint256(0), abi.encode(actions))), (bytes[]));
    }

    function runReference(
        V21Ref.Cfg memory c,
        PoolKey memory twin,
        SwapParameters params,
        int256 anchorX16,
        uint256 poolFee,
        uint256 spacing
    ) external returns (PoolBalanceUpdate total, PoolState stateAfter) {
        delete lastRefCalls;
        (total, stateAfter) = abi.decode(
            lock(abi.encode(uint256(1), abi.encode(c, twin, params, anchorX16, poolFee, spacing))),
            (PoolBalanceUpdate, PoolState)
        );
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        (uint256 mode, bytes memory inner) = abi.decode(data, (uint256, bytes));
        if (mode == 0) {
            Action[] memory actions = abi.decode(inner, (Action[]));
            bytes[] memory results = new bytes[](actions.length);
            for (uint256 i; i < actions.length; i++) {
                Action memory act = actions[i];
                if (act.kind == UPDATE_POSITION) {
                    PoolBalanceUpdate u = core.updatePosition(act.poolKey, PositionId.wrap(act.a), int128(act.b));
                    results[i] = abi.encode(u);
                    _settle(act.poolKey, u.delta0(), u.delta1());
                } else if (act.kind == FORWARD_SWAP) {
                    bytes memory r = ACCOUNTANT.forward(act.target, abi.encode(act.poolKey, SwapParameters.wrap(act.a)));
                    (PoolBalanceUpdate u,) = abi.decode(r, (PoolBalanceUpdate, PoolState));
                    results[i] = r;
                    _settle(act.poolKey, u.delta0(), u.delta1());
                } else if (act.kind == CORE_SWAP) {
                    (PoolBalanceUpdate u, PoolState st) = core.swap(0, act.poolKey, SwapParameters.wrap(act.a));
                    results[i] = abi.encode(u, st);
                    _settle(act.poolKey, u.delta0(), u.delta1());
                } else if (act.kind == COLLECT) {
                    (uint128 f0, uint128 f1) = core.collectFees(act.poolKey, PositionId.wrap(act.a));
                    results[i] = abi.encode(f0, f1);
                    _settle(act.poolKey, -int128(f0), -int128(f1));
                }
            }
            result = abi.encode(results);
        } else {
            (
                V21Ref.Cfg memory c,
                PoolKey memory twin,
                SwapParameters params,
                int256 anchorX16,
                uint256 poolFee,
                uint256 spacing
            ) = abi.decode(inner, (V21Ref.Cfg, PoolKey, SwapParameters, int256, uint256, uint256));
            (PoolBalanceUpdate total, PoolState st) = _reference(c, twin, params, anchorX16, poolFee, spacing);
            _settle(twin, total.delta0(), total.delta1());
            result = abi.encode(total, st);
        }
    }

    function _settle(PoolKey memory poolKey, int128 d0, int128 d1) internal {
        if (d0 > 0) ACCOUNTANT.payFrom(payer, poolKey.token0, uint128(d0));
        else if (d0 < 0) ACCOUNTANT.withdraw(poolKey.token0, payer, uint128(-d0));
        if (d1 > 0) ACCOUNTANT.payFrom(payer, poolKey.token1, uint128(d1));
        else if (d1 < 0) ACCOUNTANT.withdraw(poolKey.token1, payer, uint128(-d1));
    }

    function _call(PoolKey memory twin, SwapParameters params, SqrtRatio limit, int128 amount, uint256 fee)
        internal
        returns (PoolBalanceUpdate u, PoolState st)
    {
        lastRefCalls.push(RefCall({limit: limit, fee: uint16(fee), amount: amount}));
        (u, st) = core.swap(
            0,
            twin,
            createSwapParameters({
                _sqrtRatioLimit: limit,
                _amount: amount,
                _isToken1: params.isToken1(),
                _skipAhead: params.skipAhead(),
                _minFee: uint16(fee)
            })
        );
    }

    struct Loop {
        bool increasing;
        SqrtRatio userLimit;
        SqrtRatio current;
        int128 remaining;
        int256 sum0;
        int256 sum1;
        uint256 n;
        uint256 maxSegments;
    }

    /// @dev The schedule straight from the spec: one toward call to the rounded anchor, then away segments by index,
    ///   skipping any whose end is not strictly beyond the current sqrt ratio, merging at MAX_FEE or the budget.
    function _reference(
        V21Ref.Cfg memory c,
        PoolKey memory twin,
        SwapParameters params,
        int256 anchorX16,
        uint256 poolFee,
        uint256 spacing
    ) internal returns (PoolBalanceUpdate, PoolState st) {
        params = params.withDefaultSqrtRatioLimit();
        Loop memory l;
        l.increasing = params.isPriceIncreasing();
        l.userLimit = params.sqrtRatioLimit();
        l.remaining = params.amount();
        l.maxSegments = c.jLin + 24;
        st = core.poolState(twin.toPoolId());
        l.current = st.sqrtRatio();
        if (l.remaining == 0 || l.current == l.userLimit) {
            PoolBalanceUpdate u0;
            (u0, st) = core.swap(0, twin, params);
            return (u0, st);
        }

        SqrtRatio anchorSqrt = tickToSqrtRatio(
            V21Ref.clampTick(l.increasing ? V21Ref.floorDiv(anchorX16, 65536) : V21Ref.ceilDiv(anchorX16, 65536))
        );
        if (l.increasing ? l.current < anchorSqrt : l.current > anchorSqrt) {
            SqrtRatio lim = l.increasing ? anchorSqrt.min(l.userLimit) : anchorSqrt.max(l.userLimit);
            PoolBalanceUpdate u;
            (u, st) = _call(twin, params, lim, l.remaining, params.minFee());
            l.sum0 += u.delta0();
            l.sum1 += u.delta1();
            l.remaining -= params.isToken1() ? u.delta1() : u.delta0();
            if (l.remaining == 0 || lim == l.userLimit || st.sqrtRatio() != lim) {
                return (createPoolBalanceUpdate(int128(l.sum0), int128(l.sum1)), st);
            }
            l.current = lim;
        }

        for (uint256 k = 1;; k++) {
            int256 lo = k == 1 ? anchorX16 : V21Ref.boundary(c, spacing, anchorX16, l.increasing, k - 1);
            int256 hi = V21Ref.boundary(c, spacing, anchorX16, l.increasing, k);
            uint256 fee = V21Ref.segmentFee(c, poolFee, spacing, lo, hi, anchorX16);
            SqrtRatio lim = l.userLimit;
            if (fee != c.maxFee && l.n + 1 != l.maxSegments) {
                int256 hiTick = hi / 65536;
                if (hiTick >= MIN_TICK && hiTick <= MAX_TICK) {
                    SqrtRatio b = tickToSqrtRatio(int32(hiTick));
                    if (l.increasing ? b <= l.current : b >= l.current) continue;
                    lim = l.increasing ? b.min(l.userLimit) : b.max(l.userLimit);
                }
            }
            uint256 minFee = params.minFee();
            PoolBalanceUpdate u;
            (u, st) = _call(twin, params, lim, l.remaining, fee > minFee ? fee : minFee);
            l.sum0 += u.delta0();
            l.sum1 += u.delta1();
            l.remaining -= params.isToken1() ? u.delta1() : u.delta0();
            l.n++;
            if (l.remaining == 0 || lim == l.userLimit || st.sqrtRatio() != lim) break;
            l.current = lim;
        }
        return (createPoolBalanceUpdate(int128(l.sum0), int128(l.sum1)), st);
    }
}

/// @notice Deployable anywhere (skips Core registration) to test constructor validation
contract MEVCaptureV21Unregistered is MEVCaptureV21 {
    constructor(ICore core, uint32 a, uint8 b, uint8 c, uint8 d, uint16 e, uint32 f, uint8 g)
        MEVCaptureV21(core, a, b, c, d, e, f, g)
    {}

    function _registerInConstructor() internal pure override returns (bool) {
        return false;
    }
}

/// @notice Exposes the extension's internal rules for vector tests
contract MEVCaptureV21Harness is MEVCaptureV21Unregistered {
    constructor(ICore core, uint32 a, uint8 b, uint8 c, uint8 d, uint16 e, uint32 f, uint8 g)
        MEVCaptureV21Unregistered(core, a, b, c, d, e, f, g)
    {}

    function anchorUpdate(bytes32 state, int32 tickNow, uint128 liquidityNow, uint32 currentTime)
        external
        view
        returns (bytes32 next, bool passed, uint256 lObs, uint256 eRef)
    {
        MEVCaptureV21PoolState n;
        (n, passed, lObs, eRef) = _anchorUpdate(MEVCaptureV21PoolState.wrap(state), tickNow, liquidityNow, currentTime);
        next = MEVCaptureV21PoolState.unwrap(n);
    }

    function refresh(bytes32 state, uint128 liquidityAfter, uint32 currentTime) external view returns (bytes32) {
        return MEVCaptureV21PoolState.unwrap(_refresh(MEVCaptureV21PoolState.wrap(state), liquidityAfter, currentTime));
    }

    function snapshot(bytes32 state, uint128 activeLiquidity, uint32 currentTime) external pure returns (bytes32) {
        MEVCaptureV21PoolState s = MEVCaptureV21PoolState.wrap(state);
        if (s.lastPosTime() == currentTime) return state;
        return MEVCaptureV21PoolState.unwrap(s.withSnapshot(currentTime, uint8(bitLength(activeLiquidity))));
    }

    /// @notice `count` away segments in original coordinates starting with the first boundary beyond Core tick `tick`
    ///   (before the sqrt-ratio check that skips a boundary the price sits on): (hiX16, fee) pairs
    function segments(int64 anchorX16, bool increasing, int32 tick, uint256 poolFee, uint8 spacingExp, uint256 count)
        external
        view
        returns (int256[] memory his, uint256[] memory fees, uint256 firstK)
    {
        int256 a = increasing ? int256(anchorX16) : -int256(anchorX16);
        uint256 wShift = uint256(spacingExp) + SEGMENT_EXP + 16;
        int256 g1 = ((a >> wShift) + 1) << wShift;
        int256 gJ = g1 + (int256(J_LIN - 1) << wShift);
        int256 p = increasing ? int256(tick) : -int256(tick) - 1;
        firstK = _firstSegment(p, g1, gJ, wShift);
        his = new int256[](count);
        fees = new uint256[](count);
        for (uint256 i; i < count; i++) {
            uint256 k = firstK + i;
            int256 hi = _boundary(k, g1, gJ, wShift);
            int256 lo = k == 1 ? a : _boundary(k - 1, g1, gJ, wShift);
            his[i] = increasing ? hi : -hi;
            fees[i] = _segmentFee(poolFee, uint256(lo + hi - 2 * a), spacingExp);
        }
    }

    function halfLife() external view returns (uint256) {
        return HALF_LIFE;
    }
}
