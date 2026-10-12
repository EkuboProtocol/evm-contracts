// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "../../src/interfaces/ICore.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PositionId} from "../../src/types/positionId.sol";
import {SqrtRatio, BIT_MASK, TWO_POW_62, TWO_POW_94, isValid} from "../../src/types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {exp2} from "../../src/math/exp2.sol";
import {computeFee, amountBeforeFee} from "../../src/math/fee.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {MEVCaptureV21, bitLength} from "../../src/extensions/MEVCaptureV21.sol";
import {MEVCaptureV21PoolState} from "../../src/types/mevCaptureV21PoolState.sol";

/// @notice Independent reference model of the MEVCapture v2.1 rules for the current Core (EKU-946 rev 10 §(b-main)),
///   written directly from the spec text in original (not mirrored) coordinates, with naive loops instead of closed
///   forms.
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
        return Cfg({tau: 120, slopeK: 4, segExp: 0, jLin: 16, maxFee: 1 << 63, clamp: 2500, mGate: 3});
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
            // rounded up (F-13): a consumed interval always grants at least one unit
            int256 lim = int256((c.clamp * 65536 * (dt < c.tau ? dt : c.tau) + c.tau - 1) / c.tau);
            int256 mv = offNew - off;
            if (mv > lim) mv = lim;
            if (mv < -lim) mv = -lim;
            s.anchorX16 += mv;
            // rev 6: restore toward the stored reference (never above it), then the H1 raise
            uint256 base = s.lRefBits < lObs ? s.lRefBits : lObs;
            if (base < e) base = e;
            s.lRefBits = raise(c, s, base, lObs, nowT);
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

    /// @notice Surcharge rate of a segment (0.64), additional to the pool fee and capped at `maxFee - poolFee`
    function surcharge(Cfg memory c, uint256 poolFee, uint256 spacing, int256 lo, int256 hi, int256 anchorX16)
        internal
        pure
        returns (uint256 sur)
    {
        int256 twice = lo + hi - 2 * anchorX16;
        uint256 d = twice < 0 ? uint256(-twice) : uint256(twice);
        uint256 den = 4 * spacing * 65536;
        uint256 num = c.slopeK * poolFee * d;
        sur = (num + den - 1) / den;
        uint256 cap = c.maxFee - poolFee;
        if (sur > cap) sur = cap;
    }

    function clampTick(int256 t) internal pure returns (int32) {
        if (t < MIN_TICK) return MIN_TICK;
        if (t > MAX_TICK) return MAX_TICK;
        return int32(t);
    }

    /// @notice The adjacent valid sqrt ratio below `x`, found by stepping the raw value and jumping the region when
    ///   the result is not a valid value (the spec's closed form is checked against this in test 25)
    function pred(SqrtRatio x) internal pure returns (SqrtRatio r) {
        uint96 raw = SqrtRatio.unwrap(x) - 1;
        r = SqrtRatio.wrap(raw);
        if (!isValid(r)) {
            uint96 region = raw & BIT_MASK;
            r = SqrtRatio.wrap((region - TWO_POW_94) | (uint96(TWO_POW_94) - 1));
        }
    }

    function succ(SqrtRatio x) internal pure returns (SqrtRatio r) {
        uint96 raw = SqrtRatio.unwrap(x) + 1;
        r = SqrtRatio.wrap(raw);
        if (!isValid(r)) {
            uint96 region = raw & BIT_MASK;
            r = SqrtRatio.wrap((region + TWO_POW_94) | TWO_POW_62);
        }
    }

    /// @notice The amount rule (v1 convention): exact-in takes the surcharge from the output, exact-out grosses up the
    ///   net input. Returns the fee on the calculated token.
    function chargeFor(PoolBalanceUpdate u, bool isToken1, bool exactOut, uint64 poolFee, uint64 sur)
        internal
        pure
        returns (uint128 fee)
    {
        int256 calculated = isToken1 ? u.delta0() : u.delta1();
        if (exactOut) {
            uint128 input = uint128(uint256(calculated));
            uint128 net = input - computeFee(input, poolFee);
            fee = amountBeforeFee(net, sur) - net;
        } else {
            fee = computeFee(uint128(uint256(-calculated)), sur);
        }
    }
}

/// @notice Test locker: executes arbitrary action lists in one lock (flash-liquidity scenarios) and runs the reference
///   state machine against a twin pool without the extension.
contract V21Actor is BaseLocker {
    using CoreLib for *;
    using FlashAccountantLib for *;

    uint8 internal constant UPDATE_POSITION = 0;
    uint8 internal constant FORWARD_SWAP = 1;
    uint8 internal constant CORE_SWAP = 2;
    uint8 internal constant COLLECT = 3;
    uint8 internal constant REVERT = 4;

    error Forced();

    struct Action {
        uint8 kind;
        PoolKey poolKey;
        bytes32 a;
        int256 b;
        address target;
    }

    /// @notice Record of one Core swap call the reference made, and the surcharge it charged right after
    struct RefCall {
        SqrtRatio limit;
        int128 amount;
        /// @notice 0 = charged (possibly with a zero fee), 1 = toward, 2 = bridge
        uint8 kind;
        uint64 sur;
        uint128 fee0;
        uint128 fee1;
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
                } else if (act.kind == REVERT) {
                    revert Forced();
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
            (PoolBalanceUpdate total, PoolState st, int256 raw0, int256 raw1) =
                _reference(c, twin, params, anchorX16, poolFee, spacing);
            // the twin owes Core's deltas only: the surcharge is not credited there
            _settle(twin, int128(raw0), int128(raw1));
            result = abi.encode(total, st);
        }
    }

    function _settle(PoolKey memory poolKey, int128 d0, int128 d1) internal {
        if (d0 > 0) ACCOUNTANT.payFrom(payer, poolKey.token0, uint128(d0));
        else if (d0 < 0) ACCOUNTANT.withdraw(poolKey.token0, payer, uint128(-d0));
        if (d1 > 0) ACCOUNTANT.payFrom(payer, poolKey.token1, uint128(d1));
        else if (d1 < 0) ACCOUNTANT.withdraw(poolKey.token1, payer, uint128(-d1));
    }

    function _call(PoolKey memory twin, SwapParameters params, SqrtRatio limit, int128 amount, uint8 kind, uint64 sur)
        internal
        returns (PoolBalanceUpdate u, PoolState st)
    {
        (u, st) = core.swap(
            0,
            twin,
            createSwapParameters({
                _sqrtRatioLimit: limit, _amount: amount, _isToken1: params.isToken1(), _skipAhead: params.skipAhead()
            })
        );
        lastRefCalls.push(RefCall({limit: limit, amount: amount, kind: kind, sur: sur, fee0: 0, fee1: 0}));
    }

    struct Loop {
        bool increasing;
        bool isToken1;
        bool exactOut;
        SqrtRatio userLimit;
        SqrtRatio current;
        int32 tick;
        int128 remaining;
        int256 sum0;
        int256 sum1;
        int256 raw0;
        int256 raw1;
        uint256 k;
    }

    function _nearer(bool increasing, SqrtRatio a, SqrtRatio b) internal pure returns (SqrtRatio) {
        return increasing ? a.min(b) : a.max(b);
    }

    function _beyond(bool increasing, SqrtRatio x, SqrtRatio current) internal pure returns (bool) {
        return increasing ? x > current : x < current;
    }

    function _event(PoolId twinId, int32 fromTick, uint256 spacing, uint256 skipAhead, bool increasing)
        internal
        view
        returns (int32 t, bool init)
    {
        (t, init) = increasing
            ? core.nextInitializedTick(twinId, fromTick, uint32(spacing), skipAhead)
            : core.prevInitializedTick(twinId, fromTick, uint32(spacing), skipAhead);
    }

    /// @dev The state machine straight from the spec: one uncut toward call to the rounded anchor, then away calls
    ///   cut before the next rate boundary and one step short of the next initialized tick (or on an uninitialized
    ///   endpoint), with an uncharged bridge over each initialized tick. The surcharge of a charged call is computed
    ///   by the amount rule and added to the sums; it is not credited on the twin.
    function _reference(
        V21Ref.Cfg memory c,
        PoolKey memory twin,
        SwapParameters params,
        int256 anchorX16,
        uint256 poolFee,
        uint256 spacing
    ) internal returns (PoolBalanceUpdate, PoolState st, int256, int256) {
        params = params.withDefaultSqrtRatioLimit();
        Loop memory l;
        l.increasing = params.isPriceIncreasing();
        l.isToken1 = params.isToken1();
        l.exactOut = params.isExactOut();
        l.userLimit = params.sqrtRatioLimit();
        l.remaining = params.amount();
        st = core.poolState(twin.toPoolId());
        (l.current, l.tick,) = st.parse();
        if (l.remaining == 0 || l.current == l.userLimit) {
            PoolBalanceUpdate u0;
            (u0, st) = _call(twin, params, l.userLimit, l.remaining, 1, 0);
            return (u0, st, u0.delta0(), u0.delta1());
        }

        SqrtRatio anchorSqrt = tickToSqrtRatio(
            V21Ref.clampTick(l.increasing ? V21Ref.floorDiv(anchorX16, 65536) : V21Ref.ceilDiv(anchorX16, 65536))
        );
        if (_beyond(l.increasing, anchorSqrt, l.current)) {
            SqrtRatio lim = _nearer(l.increasing, anchorSqrt, l.userLimit);
            PoolBalanceUpdate u;
            (u, st) = _call(twin, params, lim, l.remaining, 1, 0);
            l.sum0 += u.delta0();
            l.sum1 += u.delta1();
            l.raw0 += u.delta0();
            l.raw1 += u.delta1();
            l.remaining -= l.isToken1 ? u.delta1() : u.delta0();
            if (l.remaining == 0 || lim == l.userLimit || st.sqrtRatio() != lim) {
                return (createPoolBalanceUpdate(int128(l.sum0), int128(l.sum1)), st, l.raw0, l.raw1);
            }
            (l.current, l.tick,) = st.parse();
        }

        PoolId twinId = twin.toPoolId();
        l.k = 1;
        while (true) {
            // (2) rate boundary of the segment containing the current price
            int256 lo = l.k == 1 ? anchorX16 : V21Ref.boundary(c, spacing, anchorX16, l.increasing, l.k - 1);
            int256 hi = V21Ref.boundary(c, spacing, anchorX16, l.increasing, l.k);
            uint256 sur = V21Ref.surcharge(c, poolFee, spacing, lo, hi, anchorX16);
            SqrtRatio lim = l.userLimit;
            if (sur != c.maxFee - poolFee) {
                int256 hiTick = hi / 65536;
                if (hiTick >= MIN_TICK && hiTick <= MAX_TICK) {
                    SqrtRatio b = tickToSqrtRatio(int32(hiTick));
                    if (!_beyond(l.increasing, b, l.current)) {
                        l.k++;
                        continue;
                    }
                    lim = _nearer(l.increasing, b, l.userLimit);
                }
            }

            // (1) tick event: Core's first search of the next call, past an exact-tick crossing
            (int32 t, bool init) = _event(twinId, l.tick, spacing, params.skipAhead(), l.increasing);
            SqrtRatio tS = tickToSqrtRatio(t);
            if (tS == l.current) {
                (t, init) = _event(twinId, l.increasing ? t : t - 1, spacing, params.skipAhead(), l.increasing);
                tS = tickToSqrtRatio(t);
            }
            require(_beyond(l.increasing, tS, l.current), "ref: event not beyond");

            // (3) choose the call
            PoolBalanceUpdate u;
            SqrtRatio cut = init ? (l.increasing ? V21Ref.pred(tS) : V21Ref.succ(tS)) : tS;
            if (init && cut == l.current) {
                lim = _nearer(l.increasing, tS, l.userLimit);
                require(_beyond(l.increasing, lim, l.current), "ref: zero-length bridge");
                (u, st) = _call(twin, params, lim, l.remaining, 2, 0);
                l.sum0 += u.delta0();
                l.sum1 += u.delta1();
            } else {
                lim = _nearer(l.increasing, cut, lim);
                require(_beyond(l.increasing, lim, l.current), "ref: zero-length call");
                (u, st) = _call(twin, params, lim, l.remaining, 0, uint64(sur));
                uint128 fee = V21Ref.chargeFor(u, l.isToken1, l.exactOut, uint64(poolFee), uint64(sur));
                RefCall storage r = lastRefCalls[lastRefCalls.length - 1];
                if (l.isToken1) {
                    r.fee0 = fee;
                    l.sum0 += u.delta0() + int256(uint256(fee));
                    l.sum1 += u.delta1();
                } else {
                    r.fee1 = fee;
                    l.sum0 += u.delta0();
                    l.sum1 += u.delta1() + int256(uint256(fee));
                }
            }
            l.raw0 += u.delta0();
            l.raw1 += u.delta1();
            l.remaining -= l.isToken1 ? u.delta1() : u.delta0();
            (l.current, l.tick,) = st.parse();
            if (l.remaining == 0 || l.current == l.userLimit) break;
        }
        return (createPoolBalanceUpdate(int128(l.sum0), int128(l.sum1)), st, l.raw0, l.raw1);
    }
}

/// @notice Deployable anywhere (skips Core registration) to test constructor validation
contract MEVCaptureV21Unregistered is MEVCaptureV21 {
    constructor(ICore core, uint32 a, uint8 b, uint8 c, uint8 d, uint64 e, uint32 f, uint8 g)
        MEVCaptureV21(core, a, b, c, d, e, f, g)
    {}

    function _registerInConstructor() internal pure override returns (bool) {
        return false;
    }
}

/// @notice Exposes the extension's internal rules for vector tests
contract MEVCaptureV21Harness is MEVCaptureV21Unregistered {
    constructor(ICore core, uint32 a, uint8 b, uint8 c, uint8 d, uint64 e, uint32 f, uint8 g)
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
    ///   (before the sqrt-ratio check that skips a boundary the price sits on): (hiX16, surcharge) pairs
    function segments(int64 anchorX16, bool increasing, int32 tick, uint64 poolFee, uint32 spacing, uint256 count)
        external
        view
        returns (int256[] memory his, uint256[] memory surs, uint256 firstK)
    {
        int256 a = increasing ? int256(anchorX16) : -int256(anchorX16);
        int256 w16 = int256(uint256(spacing) << (SEGMENT_EXP + 16));
        int256 q = a / w16;
        if (a < 0 && a % w16 != 0) q -= 1;
        int256 g1 = (q + 1) * w16;
        int256 gJ = g1 + int256(J_LIN - 1) * w16;
        int256 p = increasing ? int256(tick) : -int256(tick) - 1;
        firstK = _firstSegment(p, g1, gJ, w16);
        his = new int256[](count);
        surs = new uint256[](count);
        for (uint256 i; i < count; i++) {
            uint256 k = firstK + i;
            int256 hi = _boundary(k, g1, gJ, w16);
            int256 lo = k == 1 ? a : _boundary(k - 1, g1, gJ, w16);
            his[i] = increasing ? hi : -hi;
            surs[i] = _surcharge(poolFee, uint256(lo + hi - 2 * a), spacing);
        }
    }

    function halfLife() external view returns (uint256) {
        return HALF_LIFE;
    }
}
