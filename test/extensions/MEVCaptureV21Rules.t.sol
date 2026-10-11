// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {MockExtension} from "../FullTest.sol";
import {MEVCaptureV21Base} from "./MEVCaptureV21Base.sol";
import {V21Ref, V21Actor} from "./MEVCaptureV21Helpers.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {Router} from "../../src/Router.sol";
import {MEVCapture, mevCaptureCallPoints} from "../../src/extensions/MEVCapture.sol";
import {MEVCaptureV21, predSqrtRatio, succSqrtRatio} from "../../src/extensions/MEVCaptureV21.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PositionId} from "../../src/types/positionId.sol";
import {FeesPerLiquidity} from "../../src/types/feesPerLiquidity.sol";
import {
    SqrtRatio,
    MIN_SQRT_RATIO,
    MAX_SQRT_RATIO,
    ONE,
    TWO_POW_62,
    TWO_POW_94,
    BIT_MASK,
    isValid,
    toFixed
} from "../../src/types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {tickToSqrtRatio, sqrtRatioToTick} from "../../src/math/ticks.sol";
import {computeFee, amountBeforeFee} from "../../src/math/fee.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {NATIVE_TOKEN_ADDRESS} from "../../src/math/constants.sol";

/// @notice Tests 23-27 and the stateful fuzz of EKU-946 rev 10 §(b-main): every Core call of every checked swap is
///   traced (limit, amount, state before/after, deltas, the `accumulateAsFees` that followed it) and checked
///   directly against Core's bitmap, tick and fee-growth state, independently of the reference model that
///   `MEVCaptureV21Base` replays on the twin pool.
contract MEVCaptureV21RulesTest is MEVCaptureV21Base {
    using CoreLib for *;

    uint32 internal constant SP = 4096;
    int32 internal constant S = 4096;
    int128 internal constant L66 = int128(1) << 66;

    struct Call {
        SqrtRatio limit;
        int128 amount;
        SqrtRatio before;
        int32 tickBefore;
        uint128 liqBefore;
        SqrtRatio after_;
        int32 tickAfter;
        uint128 liqAfter;
        int128 d0;
        int128 d1;
        uint128 fee0;
        uint128 fee1;
    }

    Call[] internal trace;
    /// @notice Counts of the last traced swap: rate-boundary cuts, tick cuts (== bridges), uninitialized endpoints
    uint256 internal traceR;
    uint256 internal traceI;
    uint256 internal traceU;
    /// @notice Core's growth increments of the last traced swap: sum of floor(fee * 2^128 / L_active) per token
    uint256 internal traceGrowth0;
    uint256 internal traceGrowth1;
    /// @notice Sum of the charged calls' active liquidity (for the R5 dust bound), and charged-call count
    uint256 internal traceLiquiditySum;
    uint256 internal traceAccumulations;
    bool internal traceFeeOnlyExit;

    // ------------------------------------------------------------------ trace engine

    function _afterSwapTrace(
        Vm.AccountAccess[] memory accesses,
        Vm.Log[] memory logs,
        PoolState before,
        SwapParameters p
    ) internal override {
        delete trace;
        PoolId poolId = pool.toPoolId();
        // Core swap calls and the accumulateAsFees that follow them, in order
        for (uint256 i; i < accesses.length; i++) {
            Vm.AccountAccess memory a = accesses[i];
            if (a.kind != VmSafe.AccountAccessKind.Call || a.account != address(core) || a.accessor != address(v21)) {
                continue;
            }
            bytes4 sel = bytes4(a.data);
            if (sel == ICore.accumulateAsFees.selector) {
                (, uint128 f0, uint128 f1) = abi.decode(_slice(a.data), (PoolKey, uint128, uint128));
                Call storage last = trace[trace.length - 1];
                assertEq(last.fee0 + last.fee1, 0, "two accumulateAsFees after one call");
                last.fee0 = f0;
                last.fee1 = f1;
            } else if (sel == bytes4(0)) {
                SwapParameters sp;
                bytes memory d = a.data;
                assembly ("memory-safe") {
                    sp := mload(add(d, 132))
                }
                trace.push();
                Call storage c = trace[trace.length - 1];
                c.limit = sp.sqrtRatioLimit();
                c.amount = sp.amount();
            }
        }
        // Core's Swapped is a log0 of locker(20) | poolId(32) | balanceUpdate(32) | stateAfter(32); a call with a
        // zero amount or a limit at the current price is a Core no-op without a log
        uint256 n;
        (SqrtRatio prevSqrt, int32 prevTick, uint128 prevLiq) = before.parse();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(core) || logs[i].topics.length != 0 || logs[i].data.length != 116) continue;
            bytes memory d = logs[i].data;
            bytes32 pid;
            PoolBalanceUpdate u;
            PoolState st;
            assembly ("memory-safe") {
                pid := mload(add(d, 52))
                u := mload(add(d, 84))
                st := mload(add(d, 116))
            }
            if (pid != PoolId.unwrap(poolId)) continue;
            while (n < trace.length && (trace[n].amount == 0 || trace[n].limit == prevSqrt)) {
                Call storage noop = trace[n++];
                (noop.before, noop.tickBefore, noop.liqBefore) = (prevSqrt, prevTick, prevLiq);
                (noop.after_, noop.tickAfter, noop.liqAfter) = (prevSqrt, prevTick, prevLiq);
            }
            assertLt(n, trace.length, "more Swapped logs than Core swap calls");
            Call storage c = trace[n++];
            (c.before, c.tickBefore, c.liqBefore) = (prevSqrt, prevTick, prevLiq);
            (c.after_, c.tickAfter, c.liqAfter) = st.parse();
            (c.d0, c.d1) = (u.delta0(), u.delta1());
            (prevSqrt, prevTick, prevLiq) = (c.after_, c.tickAfter, c.liqAfter);
        }
        while (n < trace.length) {
            Call storage noop = trace[n];
            assertTrue(noop.amount == 0 || noop.limit == prevSqrt, "Core swap call without Swapped");
            (noop.before, noop.tickBefore, noop.liqBefore) = (prevSqrt, prevTick, prevLiq);
            (noop.after_, noop.tickAfter, noop.liqAfter) = (prevSqrt, prevTick, prevLiq);
            n++;
        }
        _assertRules(before, p);
    }

    function _search(int32 fromTick, uint256 skipAhead, bool increasing) internal view returns (int32 t, bool init) {
        PoolId poolId = pool.toPoolId();
        (t, init) = increasing
            ? core.nextInitializedTick(poolId, fromTick, uint32(spacing), skipAhead)
            : core.prevInitializedTick(poolId, fromTick, uint32(spacing), skipAhead);
    }

    function _beyond(bool increasing, SqrtRatio x, SqrtRatio cur) internal pure returns (bool) {
        return increasing ? x > cur : x < cur;
    }

    function _nearer(bool increasing, SqrtRatio a, SqrtRatio b) internal pure returns (SqrtRatio) {
        return increasing ? a.min(b) : a.max(b);
    }

    function _delta(int32 tick) internal view returns (int128 liquidityDelta) {
        (liquidityDelta,) = core.poolTicks(pool.toPoolId(), tick);
    }

    function _applyDelta(uint128 liq, int128 delta, bool increasing) internal pure returns (uint128) {
        int256 r = int256(uint256(liq)) + (increasing ? int256(delta) : -int256(delta));
        return uint128(uint256(r));
    }

    function _onGrid(SqrtRatio x, int256 anchor, bool increasing) internal view returns (bool) {
        for (uint256 k = 1; k <= cfg.jLin + 28; k++) {
            int256 b = V21Ref.boundary(cfg, spacing, anchor, increasing, k);
            int256 t = b / 65536;
            if (t < MIN_TICK || t > MAX_TICK) return false;
            if (tickToSqrtRatio(int32(t)) == x) return true;
        }
        return false;
    }

    /// @notice The spec's state-machine properties, checked against Core for every call of the traced swap
    function _assertRules(PoolState before, SwapParameters p) internal {
        p = p.withDefaultSqrtRatioLimit();
        bool increasing = p.isPriceIncreasing();
        bool isToken1 = p.isToken1();
        bool exactOut = p.isExactOut();
        SqrtRatio userLimit = p.sqrtRatioLimit();
        uint256 skipAhead = p.skipAhead();
        int128 remaining = p.amount();
        uint256 n = trace.length;
        (traceR, traceI, traceU, traceGrowth0, traceGrowth1, traceLiquiditySum, traceAccumulations) =
        (0, 0, 0, 0, 0, 0, 0);
        traceFeeOnlyExit = false;

        if (remaining == 0 || before.sqrtRatio() == userLimit) {
            assertEq(n, 1, "no-op swap is one Core call");
            assertEq(SqrtRatio.unwrap(trace[0].limit), SqrtRatio.unwrap(userLimit));
            assertEq(trace[0].fee0 + trace[0].fee1, 0);
            return;
        }

        int256 anchor = _anchor();
        SqrtRatio anchorSqrt = tickToSqrtRatio(
            V21Ref.clampTick(increasing ? V21Ref.floorDiv(anchor, 65536) : V21Ref.ceilDiv(anchor, 65536))
        );
        uint256 i;
        uint256 bridges;
        if (_beyond(increasing, anchorSqrt, before.sqrtRatio())) {
            assertEq(actor.refCall(0).kind, 1, "reference agrees this is the toward call");
            Call memory t = trace[0];
            assertEq(
                SqrtRatio.unwrap(t.limit), SqrtRatio.unwrap(_nearer(increasing, anchorSqrt, userLimit)), "toward limit"
            );
            assertEq(t.amount, remaining, "toward amount");
            assertEq(t.fee0 + t.fee1, 0, "toward is uncharged");
            remaining -= isToken1 ? t.d1 : t.d0;
            i = 1;
            if (remaining == 0 || t.limit == userLimit || t.after_ != t.limit) {
                assertEq(n, 1, "toward call ends the swap");
                return;
            }
        }

        for (; i < n; i++) {
            Call memory c = trace[i];
            assertEq(c.amount, remaining, "call amount is the remaining amount");
            assertTrue(remaining != 0 && c.before != userLimit, "loop ran past its exit condition");
            // distinct calls
            for (uint256 j; j < i; j++) {
                assertFalse(
                    trace[j].limit == c.limit && trace[j].before == c.before && trace[j].amount == c.amount,
                    "repeated Core call"
                );
            }

            // (1) Core's first search of this call, past an exact-tick crossing
            (int32 t, bool init) = _search(c.tickBefore, skipAhead, increasing);
            SqrtRatio tS = tickToSqrtRatio(t);
            uint128 expectedLiq = c.liqBefore;
            if (tS == c.before) {
                if (init) expectedLiq = _applyDelta(expectedLiq, _delta(t), increasing);
                (t, init) = _search(increasing ? t : t - 1, skipAhead, increasing);
                tS = tickToSqrtRatio(t);
            }
            assertTrue(_beyond(increasing, tS, c.before), "event not beyond the price");
            SqrtRatio cut = init ? (increasing ? predSqrtRatio(tS) : succSqrtRatio(tS)) : tS;

            if (init && cut == c.before) {
                // BRIDGE: one representable step onto the initialized tick, uncharged
                assertEq(SqrtRatio.unwrap(c.limit), SqrtRatio.unwrap(tS), "bridge limit is the tick");
                assertEq(c.fee0 + c.fee1, 0, "bridge is uncharged");
                assertEq(actor.refCall(i).kind, 2, "reference agrees this is a bridge");
                bridges++;
                remaining -= isToken1 ? c.d1 : c.d0;
                if (c.after_ == tS) {
                    assertEq(c.tickAfter, increasing ? t : t - 1, "bridge crosses the tick");
                    assertEq(c.liqAfter, _applyDelta(expectedLiq, _delta(t), increasing), "bridge applies the delta");
                    traceI++;
                } else {
                    assertEq(remaining, 0, "a bridge that does not cross exhausted the amount");
                    assertEq(c.liqAfter, expectedLiq);
                }
                continue;
            }

            // CHARGED: at or before Core's first event, strictly before an initialized tick
            assertTrue(!_beyond(increasing, c.limit, cut), "charged limit beyond the cut");
            assertTrue(!_beyond(increasing, c.after_, c.limit), "Core passed the limit");
            if (init) assertTrue(_beyond(increasing, tS, c.after_), "charged call reached an initialized tick");
            assertEq(c.liqAfter, expectedLiq, "liquidity changed across a charged call");

            int256 specified = isToken1 ? c.d1 : c.d0;
            int256 calculated = isToken1 ? c.d0 : c.d1;
            uint128 fee = isToken1 ? c.fee0 : c.fee1;
            assertEq(isToken1 ? c.fee1 : c.fee0, 0, "surcharge on the specified token");
            uint256 sur = actor.refCall(i).sur;
            assertEq(actor.refCall(i).kind, 0, "reference agrees this is a charged call");
            if (exactOut) {
                uint256 input = uint256(calculated);
                uint256 inNet = input - computeFee(uint128(input), uint64(poolFee));
                // R1: extra = ceil(inNet * sur / (2^64 - sur)) within one unit
                uint256 q = (uint256(1) << 64) - sur;
                assertGe((inNet + fee) * q, inNet << 64, "R1 exact-out lower");
                if (fee != 0) assertLt((inNet + fee - 1) * q, inNet << 64, "R1 exact-out upper");
            } else {
                uint256 out = uint256(-calculated);
                assertGe(uint256(fee) << 64, out * sur, "R1 exact-in lower");
                assertLt(uint256(fee) << 64, out * sur + (uint256(1) << 64), "R1 exact-in upper");
            }
            if (fee != 0) {
                assertGt(c.liqAfter, 0, "surcharge accumulated at zero liquidity");
                assertTrue(calculated != 0, "surcharge without a traded amount");
                traceLiquiditySum += c.liqAfter;
                traceAccumulations++;
                if (isToken1) traceGrowth0 += (uint256(fee) << 128) / c.liqAfter;
                else traceGrowth1 += (uint256(fee) << 128) / c.liqAfter;
            }
            remaining -= int128(specified);

            if (c.after_ == c.before) {
                // fee-only exception: the input was consumed as pool fee without moving the price
                assertFalse(exactOut, "exact-out must move the price");
                assertEq(remaining, 0, "fee-only call did not exhaust the input");
                assertEq(calculated, 0, "fee-only call produced output");
                assertEq(fee, 0, "fee-only call was charged");
                assertEq(i, n - 1, "fee-only call is the last call");
                traceFeeOnlyExit = true;
                continue;
            }
            assertTrue(_beyond(increasing, c.after_, c.before), "charged call did not advance the price");

            // classify the end for the call-count bound
            bool last = remaining == 0 || c.after_ == userLimit;
            if (last) {
                assertEq(i, n - 1, "swap continued after its exit condition");
            } else if (init && c.after_ == cut) {
                // tick cut: the next call is the bridge of this tick
                assertLt(i + 1, n, "tick cut without a bridge");
            } else if (!init && c.after_ == tS) {
                traceU++;
            } else {
                assertTrue(_onGrid(c.after_, anchor, increasing), "charged call ended off every event");
                traceR++;
            }
        }
        Call memory lastCall = trace[n - 1];
        assertTrue(remaining == 0 || lastCall.after_ == userLimit, "exit condition");
        assertLe(traceR, cfg.jLin + 28, "rate boundaries bounded");
        uint256 toward = _beyond(increasing, anchorSqrt, before.sqrtRatio()) ? 1 : 0;
        assertEq(lastCharged, n - bridges - toward, "charged count");
        assertEq(lastBridges, bridges, "bridge count");
    }

    // ------------------------------------------------------------------ fixtures

    function _wide() internal {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
    }

    function _at(int32 tick) internal pure returns (SqrtRatio) {
        return tickToSqrtRatio(tick);
    }

    function _big() internal pure returns (int128) {
        return type(int128).max >> 8;
    }

    // ================================================================ test 23: cuts and progress

    function test_cuts_increasing_ticks_on_and_off_grid() public {
        // W = 4S: ticks at 3S and 7S are off the rate grid, 8S is on it
        V21Ref.Cfg memory c = V21Ref.defaults();
        c.segExp = 2;
        useExtension(deployV21(c, 7), c);
        _wide();
        _lp(bytes24(uint192(2)), 3 * S, 7 * S, L66 * 2);
        _lp(bytes24(uint192(3)), 8 * S, 9 * S, L66);
        _swapChecked(true, _big(), _at(12 * S));
        assertEq(traceI, 4, "3S, 7S, 8S, 9S crossed");
        assertGt(traceR, 0);
        assertEq(traceU, 0);
        assertEq(_poolState().tick(), 12 * S);
    }

    function test_cuts_decreasing_ticks_on_and_off_grid() public {
        V21Ref.Cfg memory c = V21Ref.defaults();
        c.segExp = 2;
        useExtension(deployV21(c, 7), c);
        _wide();
        _lp(bytes24(uint192(2)), -7 * S, -3 * S, L66 * 2);
        _lp(bytes24(uint192(3)), -9 * S, -8 * S, L66);
        _swapChecked(false, _big(), _at(-12 * S));
        assertEq(traceI, 4);
        assertGt(traceR, 0);
        // the limit is not an initialized tick, so Core lands on it without a crossing
        assertEq(_poolState().tick(), -12 * S);
    }

    function test_cuts_start_at_pred_and_succ() public {
        _wide();
        _lp(bytes24(uint192(2)), 3 * S, 7 * S, L66);
        _lp(bytes24(uint192(3)), -7 * S, -3 * S, L66);
        // stop one representable step short of 3S by the user limit, then continue: the first call is the bridge
        _swapChecked(true, _big(), predSqrtRatio(_at(3 * S)));
        assertEq(SqrtRatio.unwrap(_poolState().sqrtRatio()), SqrtRatio.unwrap(predSqrtRatio(_at(3 * S))));
        assertEq(_poolState().tick(), 3 * S - 1, "pred lands in the tick below");
        assertEq(traceI, 0);
        _swapChecked(true, _big(), _at(5 * S));
        assertEq(traceI, 1);
        assertEq(SqrtRatio.unwrap(trace[0].limit), SqrtRatio.unwrap(_at(3 * S)), "first call bridges 3S");
        // mirror
        advanceTime(12);
        _swapChecked(false, _big(), _at(0));
        _swapChecked(false, _big(), succSqrtRatio(_at(-3 * S)));
        assertEq(_poolState().tick(), -3 * S, "succ lands in the tick itself");
        _swapChecked(false, _big(), _at(-5 * S));
        assertEq(SqrtRatio.unwrap(trace[0].limit), SqrtRatio.unwrap(_at(-3 * S)), "first call bridges -3S");
        assertEq(traceI, 1);
    }

    /// @notice The pool is initialized on the initialized tick T = 3S with the anchor there, so both directions
    ///   from T are away and charged; Core's two tick states (`tick = T` and `tick = T - 1`) at the same price are
    ///   produced by arriving from either side
    function test_cuts_exact_tick_both_states_and_reversal() public {
        createPools(FEE_30BP, SP, 3 * S);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _lp(bytes24(uint192(2)), 3 * S, 7 * S, L66);
        assertEq(_poolState().tick(), 3 * S, "Core tick state: tick = T");
        assertEq(_poolState().liquidity(), uint128(L66 * 2));
        // decreasing from tick = T: the decreasing search includes T, so Core crosses it with zero amounts at the
        // start of the first charged call; the extension re-searches and the call trades the post-crossing liquidity
        _swapChecked(false, _big(), _at(2 * S));
        assertEq(traceI, 0, "the zero-width crossing is not a bridge");
        assertEq(trace[0].liqBefore, uint128(L66 * 2));
        assertEq(trace[0].liqAfter, uint128(L66), "post-crossing liquidity traded and charged");
        // back up through T inside the uncut toward call, then down onto T exactly: Core stores tick = T - 1
        _swapChecked(true, _big(), _at(5 * S));
        assertEq(traceI, 0, "the toward call crosses T uncut");
        assertEq(trace[0].liqAfter, uint128(L66 * 2));
        _swapChecked(false, _big(), _at(3 * S));
        assertEq(_poolState().tick(), 3 * S - 1, "Core tick state: tick = T - 1");
        assertEq(_poolState().liquidity(), uint128(L66));
        // increasing from tick = T - 1: the increasing search from T - 1 finds T at the current price; same handling
        _swapChecked(true, _big(), _at(4 * S));
        assertEq(traceI, 0);
        assertEq(trace[0].liqBefore, uint128(L66));
        assertEq(trace[0].liqAfter, uint128(L66 * 2));
        // 1-unit exact-in exactly on T in both states: fee-only, zero surcharge, no FeesAccumulated
        _swapChecked(false, _big(), _at(3 * S));
        assertEq(_poolState().tick(), 3 * S - 1);
        _swapChecked(true, 1, SqrtRatio.wrap(0));
        assertTrue(traceFeeOnlyExit, "1 wei is consumed as pool fee");
        assertEq(lastFee0 + lastFee1, 0);
        assertEq(_poolState().tick(), 3 * S, "the zero-width crossing still happened");
        _swapChecked(false, 1, SqrtRatio.wrap(0));
        assertTrue(traceFeeOnlyExit);
        assertEq(_poolState().tick(), 3 * S - 1);
    }

    function test_cuts_uninitialized_endpoints_skipAhead() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -S, S, L66);
        _lp(bytes24(uint192(2)), 1000 * S, 1001 * S, L66);
        // skipAhead 0: every empty bitmap word beyond S is its own Core call
        _swapChecked(true, _big(), _at(1000 * S + S / 2), 0);
        assertGt(traceU, 1, "uninitialized endpoints reached");
        assertEq(traceI, 2, "S and 1000S crossed");
        uint256 u0 = traceU;
        advanceTime(12);
        // the return is toward (the anchor moved toward the price by at most the clamp): one uncut call plus the
        // short away tail below the anchor
        _swapChecked(false, _big(), _at(0), 0);
        assertEq(traceI, 0);
        // skipAhead 3 skips words: fewer endpoints
        advanceTime(12);
        _swapChecked(true, _big(), _at(1000 * S + S / 2), 3);
        assertLt(traceU, u0, "skipAhead reduces endpoints");
        assertEq(traceI, 2);
    }

    function test_cuts_non_power_of_two_spacing_negative_anchor() public {
        int32 sp = 3000;
        createPools(FEE_30BP, uint32(sp), -123_457);
        _lp(bytes24(uint192(1)), -200 * sp, 100 * sp, L66);
        _lp(bytes24(uint192(2)), -50 * sp, -30 * sp, L66);
        _swapChecked(false, _big(), _at(-80 * sp));
        assertEq(traceI, 1, "-50sp bridged");
        assertGt(traceR, 2);
        advanceTime(12);
        // -50sp re-crossed inside the toward call, -30sp bridged on the away side
        _swapChecked(true, _big(), _at(-20 * sp));
        assertEq(traceI, 1);
        assertGt(traceR, 2);
    }

    function test_cuts_partial_exact_in_and_out(uint256 seed) public {
        _wide();
        _lp(bytes24(uint192(2)), 2 * S, 5 * S, L66);
        _lp(bytes24(uint192(3)), -5 * S, -2 * S, L66);
        // amounts stay inside the wide range (about 6e18 of either token from tick 0 to +-40S)
        int128 a = int128(uint128(bound(seed, 1e15, 4e18)));
        _swapChecked(true, a);
        advanceTime(12);
        _swapChecked(false, -a / 3);
        advanceTime(12);
        _swapChecked(false, a);
        advanceTime(12);
        _swapChecked(true, -a / 7);
    }

    function test_cuts_zero_liquidity_gaps() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -10 * S, -5 * S, L66);
        _lp(bytes24(uint192(2)), 5 * S, 10 * S, L66);
        _swapChecked(true, 1e18);
        assertEq(traceI, 2, "bridge into 5S from the empty gap, then out over 10S");
        assertGt(lastFee0, 0);
        advanceTime(12);
        // the anchor moved toward the price: 10S and 5S are re-crossed inside the uncut toward call (which consumes
        // about the first 1e18); -5S is bridged from the empty gap and -10S on the way out
        _swapChecked(false, 3e18);
        assertEq(traceI, 2, "bridge into -5S from the empty gap, then out over -10S");
        assertGt(lastFee1, 0);
    }

    function test_cuts_equal_liquidity_different_ownership() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -10 * S, 2 * S, L66);
        _lp(bytes24(uint192(2)), 2 * S, 10 * S, L66);
        assertEq(_delta(2 * S), 0, "net delta zero at the shared tick");
        FeesPerLiquidity memory fplB0 = core.getPoolFeesPerLiquidityInside(pool.toPoolId(), 2 * S, 10 * S);
        _swapChecked(true, _big(), _at(2 * S));
        assertEq(traceI, 1, "the shared tick is still bridged");
        FeesPerLiquidity memory fplB1 = core.getPoolFeesPerLiquidityInside(pool.toPoolId(), 2 * S, 10 * S);
        assertEq(fplB1.value0, fplB0.value0, "B earns nothing of the pre-crossing surcharge");
        assertEq(fplB1.value1, fplB0.value1, "B earns nothing of the pre-crossing pool fee");
        (uint128 a0,) = _collect(pool, bytes24(uint192(1)), -10 * S, 2 * S);
        assertEq(uint256(a0), (uint256(uint128(L66)) * traceGrowth0) >> 128, "A collects the integer reference");
        (uint128 b0, uint128 b1) = _collect(pool, bytes24(uint192(2)), 2 * S, 10 * S);
        assertEq(b0 + b1, 0);
    }

    function test_cuts_limits_at_extremes_and_cap_tail() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -20_000 * S, 20_000 * S, int128(1) << 40);
        _lp(bytes24(uint192(2)), 3000 * S, 3001 * S, 1e9);
        _swapChecked(true, _big(), MAX_SQRT_RATIO);
        assertEq(SqrtRatio.unwrap(_poolState().sqrtRatio()), SqrtRatio.unwrap(MAX_SQRT_RATIO));
        assertEq(traceI, 3);
        advanceTime(12);
        _swapChecked(false, _big(), MIN_SQRT_RATIO);
        assertEq(SqrtRatio.unwrap(_poolState().sqrtRatio()), SqrtRatio.unwrap(MIN_SQRT_RATIO));
        // the anchor moved toward MAX by the clamp: 20000S, 3001S and 3000S are re-crossed inside the uncut
        // toward call; -20000S is the only away-side tick
        assertEq(traceI, 1, "-20000S bridged on the way to MIN");
    }

    function _feeOnly(uint64 fee) internal {
        createPools(fee, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        (PoolBalanceUpdate u,) = _swapChecked(true, 1);
        assertTrue(traceFeeOnlyExit);
        assertEq(u.delta1(), 1);
        assertEq(u.delta0(), 0);
        assertEq(lastFee0 + lastFee1, 0);
        assertEq(trace.length, 1);
    }

    function test_cuts_fee_only_exact_in_1ulp() public {
        _feeOnly(1);
    }

    function test_cuts_fee_only_exact_in_30bp() public {
        _feeOnly(FEE_30BP);
    }

    function test_cuts_fee_only_exact_in_25pct() public {
        _feeOnly(FEE_25PCT);
    }

    function _bridgeWithFee(uint64 fee) internal {
        createPools(fee, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _lp(bytes24(uint192(2)), 2 * S, 3 * S, L66);
        _swapChecked(true, _big(), _at(2 * S + S / 2));
        assertEq(traceI, 1);
        advanceTime(12);
        _swapChecked(false, -1e18, SqrtRatio.wrap(0));
        assertEq(traceI, 1);
    }

    function test_bridge_pool_fee_1ulp() public {
        _bridgeWithFee(1);
    }

    function test_bridge_pool_fee_30bp() public {
        _bridgeWithFee(FEE_30BP);
    }

    function test_bridge_pool_fee_25pct() public {
        _bridgeWithFee(FEE_25PCT);
    }

    /// @notice Stateful fuzz: random layouts (gaps, shared ticks, dust), random exact-in/out swaps in both directions
    ///   with random limits and skipAhead, every swap traced and replayed on the twin; the accounting invariants of
    ///   R5 are checked at the end against the integer reference
    function test_cuts_stateful_fuzz(uint256 seed) public {
        uint64 fee = uint64(bound(uint256(keccak256(abi.encode(seed, 0))), 1, FEE_25PCT));
        uint32 sp = uint32(bound(uint256(keccak256(abi.encode(seed, 1))), 1, 30_000));
        int32 tick = int32(int256(bound(uint256(keccak256(abi.encode(seed, 2))), 0, 400_000)) - 200_000);
        V21Ref.Cfg memory c = V21Ref.defaults();
        c.segExp = bound(uint256(keccak256(abi.encode(seed, 4))), 0, 3);
        c.jLin = bound(uint256(keccak256(abi.encode(seed, 5))), 1, 24);
        useExtension(deployV21(c, 9), c);
        createPools(fee, sp, tick);
        int32 spI = int32(sp);
        int32 center = (tick / spI) * spI;
        uint256 np = 1 + uint256(keccak256(abi.encode(seed, 3))) % 5;
        for (uint256 i; i < np; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, 10 + i)));
            int32 lo = center + int32(int256(r % 40) - 30) * spI;
            int32 hi = lo + int32(int256(1 + (r >> 8) % 40)) * spI;
            if (lo < MIN_TICK || hi > MAX_TICK) continue;
            uint128 maxL = pool.config.concentratedMaxLiquidityPerTick() / 8;
            int128 liq = int128(uint128(bound(r >> 16, 1, maxL < 1e27 ? maxL : 1e27)));
            _lp(bytes24(uint192(i + 1)), lo, hi, liq);
        }
        uint256 charged0;
        uint256 charged1;
        uint256 growth0;
        uint256 growth1;
        for (uint256 j; j < 8; j++) {
            uint256 r = uint256(keccak256(abi.encode(seed, 100 + j)));
            if (r % 3 == 1) advanceTime(1 + (r >> 8) % 600);
            bool isToken1 = (r >> 40) & 1 == 1;
            bool exactOut = (r >> 41) & 1 == 1;
            int128 amount = int128(uint128(1 + (r >> 48) % 1e22));
            if ((r >> 44) % 5 == 0) amount = int128(uint128(1 + (r >> 48) % 1000));
            if (exactOut) amount = -amount;
            bool increasing = isToken1 != exactOut;
            int256 dist = int256(1 + (r >> 210) % (120 * uint256(int256(spI))));
            int256 lt = int256(_poolState().tick()) + (increasing ? dist : -dist);
            if (lt <= MIN_TICK) lt = MIN_TICK + 1;
            if (lt >= MAX_TICK) lt = MAX_TICK - 1;
            _swapChecked(isToken1, amount, tickToSqrtRatio(int32(lt)), (r >> 120) % 4 == 0 ? (r >> 130) % 4 : 0);
            charged0 += lastFee0;
            charged1 += lastFee1;
            growth0 += traceGrowth0;
            growth1 += traceGrowth1;
        }
        // growth: the pool's fee growth exceeds the twin's by exactly the sum of Core's accumulateAsFees increments
        FeesPerLiquidity memory fp = core.getPoolFeesPerLiquidity(pool.toPoolId());
        FeesPerLiquidity memory ft = core.getPoolFeesPerLiquidity(twin.toPoolId());
        assertEq(fp.value0 - ft.value0, growth0, "token0 growth == sum of floor(fee * 2^128 / L)");
        assertEq(fp.value1 - ft.value1, growth1, "token1 growth == sum of floor(fee * 2^128 / L)");
    }

    // ================================================================ test 24: recipients

    struct Recipients {
        int32 e;
        bytes24 honest;
        bytes24 dust;
        int32 hLo;
        int32 hHi;
        int32 dLo;
        int32 dHi;
        int128 hL;
        int128 dL;
    }

    function _recipientsFixture(bool increasing, int32 e, int128 dustL) internal returns (Recipients memory r) {
        r.e = e;
        r.honest = bytes24(uint192(1));
        r.dust = bytes24(uint192(2));
        r.hL = L66;
        r.dL = dustL;
        if (increasing) {
            (r.hLo, r.hHi, r.dLo, r.dHi) = (-10 * S, e, e, e + S);
        } else {
            (r.hLo, r.hHi, r.dLo, r.dHi) = (e, 10 * S, e - S, e);
        }
        _lp(r.honest, r.hLo, r.hHi, r.hL);
        if (dustL != 0) _lp(r.dust, r.dLo, r.dHi, r.dL);
    }

    /// @notice The attacker's range, which starts where the honest range ends, receives exactly zero from the trading
    ///   before the crossing; the honest range collects the exact integer reference; growth increments are Core's
    function _recipientsCase(bool increasing, bool exactOut, int32 e, int128 dustL) internal {
        Recipients memory r = _recipientsFixture(increasing, e, dustL);
        PoolId pid = pool.toPoolId();
        FeesPerLiquidity memory dIn0 = core.getPoolFeesPerLiquidityInside(pid, r.dLo, r.dHi);
        FeesPerLiquidity memory p0 = core.getPoolFeesPerLiquidity(pid);
        FeesPerLiquidity memory t0 = core.getPoolFeesPerLiquidity(twin.toPoolId());

        bool isToken1 = increasing != exactOut;
        int128 amount = exactOut ? -_big() : _big();
        _swapChecked(isToken1, amount, _at(e));
        assertEq(SqrtRatio.unwrap(_poolState().sqrtRatio()), SqrtRatio.unwrap(_at(e)));
        assertEq(traceI, 1, "the swap ends with the bridge onto E");
        Call memory bridge = trace[trace.length - 1];
        assertEq(bridge.fee0 + bridge.fee1, 0, "no FeesAccumulated after the bridge");
        assertEq(bridge.liqAfter, uint128(dustL), "post-crossing liquidity is the dust");
        assertGt(lastFee0 + lastFee1, 0, "the swap was charged");

        // growth increments: pool minus twin equals Core's accumulateAsFees formula per charged call
        FeesPerLiquidity memory p1 = core.getPoolFeesPerLiquidity(pid);
        FeesPerLiquidity memory t1 = core.getPoolFeesPerLiquidity(twin.toPoolId());
        assertEq((p1.value0 - p0.value0) - (t1.value0 - t0.value0), traceGrowth0, "growth0");
        assertEq((p1.value1 - p0.value1) - (t1.value1 - t0.value1), traceGrowth1, "growth1");

        // the dust range: inside growth unchanged, collects nothing
        if (dustL != 0) {
            FeesPerLiquidity memory dIn1 = core.getPoolFeesPerLiquidityInside(pid, r.dLo, r.dHi);
            assertEq(dIn1.value0, dIn0.value0, "dust inside growth 0 unchanged");
            assertEq(dIn1.value1, dIn0.value1, "dust inside growth 1 unchanged");
            (uint128 d0, uint128 d1) = _collect(pool, r.dust, r.dLo, r.dHi);
            assertEq(d0 + d1, 0, "dust collects nothing");
        }

        // the honest range collects the integer reference on the surcharge token (always the calculated token); the
        // dust is bounded by R5
        (uint128 h0, uint128 h1) = _collect(pool, r.honest, r.hLo, r.hHi);
        (uint128 w0, uint128 w1) = _collect(twin, r.honest, r.hLo, r.hHi);
        uint256 hL = uint256(uint128(r.hL));
        uint256 surToken = isToken1 ? h0 : h1;
        uint256 twinSurToken = isToken1 ? w0 : w1;
        uint256 growth = isToken1 ? traceGrowth0 : traceGrowth1;
        uint256 charged = isToken1 ? lastFee0 : lastFee1;
        uint256 ref = (hL * growth) >> 128;
        assertEq(isToken1 ? h1 : h0, isToken1 ? w1 : w0, "the other token collects exactly the twin's pool fee");
        if (!exactOut) {
            // exact-in: the output token carries no pool fee, so the collected amount is the reference exactly
            assertEq(twinSurToken, 0, "twin has no fees on the output token");
            assertEq(surToken, ref, "honest collects floor(L * growth / 2^128)");
            uint256 dust = charged - surToken;
            // R5: dust < sum(L_a) / 2^128 + P * C with P = 1, C = 1
            assertLt(dust << 128, traceLiquiditySum + (uint256(1) << 128), "R5 two-term dust bound");
        } else {
            // exact-out: the surcharge shares the input token with the pool fee, so the single collection floor
            // may exceed the sum of the two separate floors by at most one wei
            assertGt(twinSurToken, 0, "twin collects the pool fee on the input");
            assertGe(surToken, twinSurToken + ref, "collected >= twin + reference");
            assertLe(surToken, twinSurToken + ref + 1, "collected <= twin + reference + 1");
            assertLe(surToken - twinSurToken, charged, "never more than charged");
        }
    }

    function test_recipients_increasing_exact_in() public {
        createPools(FEE_30BP, SP, 0);
        _recipientsCase(true, false, 2 * S, 1e6);
    }

    function test_recipients_decreasing_exact_in() public {
        createPools(FEE_30BP, SP, 0);
        _recipientsCase(false, false, -2 * S, 1e6);
    }

    function test_recipients_increasing_exact_out() public {
        createPools(FEE_30BP, SP, 0);
        _recipientsCase(true, true, 2 * S, 1e6);
    }

    function test_recipients_decreasing_exact_out() public {
        createPools(FEE_30BP, SP, 0);
        _recipientsCase(false, true, -2 * S, 1e6);
    }

    function test_recipients_tick_on_rate_boundary() public {
        createPools(FEE_30BP, SP, 0);
        // with anchor 0 and W = S every multiple of S is a rate boundary; E = 3S coincides with boundary 3
        _recipientsCase(true, false, 3 * S, 1e6);
    }

    function test_recipients_equal_sized_disjoint_ranges() public {
        createPools(FEE_30BP, SP, 0);
        _recipientsCase(true, false, 2 * S, L66);
    }

    function test_recipients_no_successor_liquidity() public {
        createPools(FEE_30BP, SP, 0);
        _recipientsFixture(true, 2 * S, 0);
        _swapChecked(true, 1e18, _at(6 * S));
        assertEq(_poolState().tick(), 6 * S, "ran through the empty range to the limit");
        assertEq(traceI, 1);
        // every call after the bridge moved no tokens and was not charged (checked per call in the trace: no
        // surcharge at zero liquidity)
        bool seenBridge;
        for (uint256 i; i < trace.length; i++) {
            if (seenBridge) {
                assertEq(trace[i].d0, 0);
                assertEq(trace[i].d1, 0);
                assertEq(trace[i].fee0 + trace[i].fee1, 0);
            }
            if (trace[i].liqAfter == 0) seenBridge = true;
        }
        assertTrue(seenBridge);
    }

    /// @notice MAX_TICK is a multiple of 698605, so a position can end exactly there: the extreme tick is initialized
    ///   and gets the cut-plus-bridge treatment like any other
    function test_recipients_extremes() public {
        int32 sp = 698605;
        createPools(FEE_30BP, uint32(sp), 0);
        _lp(bytes24(uint192(1)), -10 * sp, 2 * sp, L66);
        _lp(bytes24(uint192(2)), 2 * sp, MAX_TICK, 1e6);
        _swapChecked(true, _big(), MAX_SQRT_RATIO);
        assertEq(traceI, 2, "2sp and MAX_TICK are both bridged");
        assertEq(SqrtRatio.unwrap(_poolState().sqrtRatio()), SqrtRatio.unwrap(MAX_SQRT_RATIO));
        (uint128 d0, uint128 d1) = _collect(pool, bytes24(uint192(2)), 2 * sp, MAX_TICK);
        assertGt(d0, 0, "the range up to MAX_TICK was traded through");
        assertGt(d1, 0);
        advanceTime(12);
        _swapChecked(false, _big(), MIN_SQRT_RATIO);
        assertEq(SqrtRatio.unwrap(_poolState().sqrtRatio()), SqrtRatio.unwrap(MIN_SQRT_RATIO));
    }

    /// @notice Attacker mints at E, the victim's forwarded swap runs inside the same outer lock, the attacker
    ///   collects and burns: it collects nothing
    function test_recipients_same_lock_jit_collects_zero() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -10 * S, 2 * S, L66);
        PositionId dust = _pid(bytes24(uint192(9)), 2 * S, 3 * S);
        V21Actor.Action[] memory acts = new V21Actor.Action[](4);
        acts[0] = _action(0, pool, PositionId.unwrap(dust), 1e12, address(0));
        acts[1] = _action(1, pool, SwapParameters.unwrap(_params(true, _big(), _at(2 * S))), 0, address(v21));
        acts[2] = _action(3, pool, PositionId.unwrap(dust), 0, address(0));
        acts[3] = _action(0, pool, PositionId.unwrap(dust), -1e12, address(0));
        bytes[] memory res = actor.run(acts);
        (uint128 f0, uint128 f1) = abi.decode(res[2], (uint128, uint128));
        assertEq(f0 + f1, 0, "same-lock JIT at E collects nothing");
        assertEq(_poolState().tick(), 2 * S);
    }

    /// @notice v1 on `main` charges the whole swap's surcharge at the next timestamp's first swap to the liquidity
    ///   active then: the dust at E receives the victim's surcharge. v2.1 credits it to the honest range.
    function test_recipients_vs_v1_on_main() public {
        address v1Addr = address(uint160(mevCaptureCallPoints().toUint8()) << 152);
        deployCodeTo("MEVCapture.sol", abi.encode(core), v1Addr);
        MEVCapture v1 = MEVCapture(v1Addr);
        Router v1Router = new Router(core, v1Addr, address(0));
        token0.approve(address(v1Router), type(uint256).max);
        token1.approve(address(v1Router), type(uint256).max);
        PoolKey memory v1Pool =
            createPool(address(token0), address(token1), 0, createConcentratedPoolConfig(FEE_30BP, SP, address(v1)));
        _lpOn(v1Pool, bytes24(uint192(1)), -10 * S, 2 * S, L66);
        _lpOn(v1Pool, bytes24(uint192(2)), 2 * S, 3 * S, L66 / 1000);

        createPools(FEE_30BP, SP, 0);
        _recipientsFixture(true, 2 * S, L66 / 1000);

        // victim swap to E on both
        v1Router.swapAllowPartialFill(v1Pool, _params(true, _big(), _at(2 * S)), address(this));
        _swapChecked(true, _big(), _at(2 * S));
        // next timestamp: a tiny swap triggers v1's deferred accumulation at the post-crossing liquidity (dust)
        advanceTime(12);
        v1Router.swapAllowPartialFill(v1Pool, _params(true, 1, SqrtRatio.wrap(0)), address(this));
        _swapChecked(true, 1, SqrtRatio.wrap(0));

        (uint128 v1Dust0,) = _collect(v1Pool, bytes24(uint192(2)), 2 * S, 3 * S);
        (uint128 v21Dust0,) = _collect(pool, bytes24(uint192(2)), 2 * S, 3 * S);
        assertGt(v1Dust0, 0, "v1: the dust collects the victim's surcharge");
        assertEq(v21Dust0, 0, "v2.1: the dust collects none of it");
        (uint128 v21Honest0,) = _collect(pool, bytes24(uint192(1)), -10 * S, 2 * S);
        assertGt(v21Honest0, 0);
    }

    // ---- R5: Core's growth and collection flooring, with the integer reference and the EKU-1589 vector ----

    int32 internal constant WIDE_SP = 698605;

    /// @notice Core accounting directly: `times` accumulations of `fee` at active liquidity `l`, one collection
    function _r5(uint128 l, uint128 fee, uint256 times) internal returns (uint256 collected, uint256 growth) {
        MockExtension ext = createAndRegisterExtension();
        // the widest spacing allows liquidity up to 2^128 / 255 per tick
        PoolKey memory key = createPool(
            address(token0), address(token1), 0, createConcentratedPoolConfig(1, uint32(WIDE_SP), address(ext))
        );
        _lpOn(key, bytes24(uint192(1)), -WIDE_SP, WIDE_SP, int128(l));
        token0.approve(address(ext), type(uint256).max);
        uint256 g0 = core.getPoolFeesPerLiquidity(key.toPoolId()).value0;
        for (uint256 i; i < times; i++) {
            ext.accumulateFees(key, fee, 0);
            growth += (uint256(fee) << 128) / l;
        }
        assertEq(core.getPoolFeesPerLiquidity(key.toPoolId()).value0 - g0, growth, "growth is the sum of floors");
        (uint128 c0,) = _collect(key, bytes24(uint192(1)), -WIDE_SP, WIDE_SP);
        collected = c0;
        assertEq(collected, (uint256(l) * growth) >> 128, "collection floors once");
    }

    function test_r5_fee_1_at_L_3_collects_0() public {
        (uint256 collected,) = _r5(3, 1, 1);
        assertEq(collected, 0);
    }

    function test_r5_small_vectors(uint8 k, uint128 lSeed, bool plus) public {
        k = uint8(bound(k, 1, 60));
        uint128 l = uint128(bound(lSeed, 1, uint128(1) << 100)) | 1; // odd
        uint128 fee = plus ? (uint128(1) << k) + 1 : (uint128(1) << k) - 1;
        (uint256 collected,) = _r5(l, fee, 1);
        assertLe(collected, fee);
        // dust < L / 2^128 + 1 (A = 1, P = 1, C = 1)
        assertLt((fee - collected) << 128, uint256(l) + (uint256(1) << 128));
    }

    function test_r5_eku1589_vector_2048_fee1_at_2pow119_plus_1() public {
        uint128 l = (uint128(1) << 119) + 1;
        (uint256 collected, uint256 growth) = _r5(l, 1, 2048);
        assertEq(growth, 2048 * 511);
        assertEq(collected, 2044);
        // dust 4 from growth flooring alone; the two-term bound holds, a checkpoint-only bound (1) would not
        uint256 dust = 2048 - collected;
        assertEq(dust, 4);
        assertLt(dust << 128, 2048 * uint256(l) + (uint256(1) << 128));
        assertGt(dust, 1);
    }

    function test_r5_multiple_positions_and_checkpoints() public {
        MockExtension ext = createAndRegisterExtension();
        PoolKey memory key =
            createPool(address(token0), address(token1), 0, createConcentratedPoolConfig(1, SP, address(ext)));
        uint128[3] memory ls = [uint128(3), uint128(7), uint128(1) << 70];
        for (uint256 i; i < 3; i++) {
            _lpOn(key, bytes24(uint192(i + 1)), -S, S, int128(ls[i]));
        }
        uint256 total = ls[0] + ls[1] + ls[2];
        token0.approve(address(ext), type(uint256).max);
        uint256 charged;
        uint256 collected;
        uint256 growthSinceCheckpoint;
        uint256 lSum;
        uint256 checkpoints;
        for (uint256 round; round < 3; round++) {
            for (uint256 j; j < 5; j++) {
                uint128 fee = uint128(1 + (round * 5 + j) * 7919);
                ext.accumulateFees(key, fee, 0);
                charged += fee;
                growthSinceCheckpoint += (uint256(fee) << 128) / total;
                lSum += total;
            }
            for (uint256 i; i < 3; i++) {
                (uint128 c0,) = _collect(key, bytes24(uint192(i + 1)), -S, S);
                assertEq(uint256(c0), (uint256(ls[i]) * growthSinceCheckpoint) >> 128, "position reference");
                collected += c0;
            }
            growthSinceCheckpoint = 0;
            checkpoints++;
        }
        uint256 dust = charged - collected;
        assertLt(dust << 128, lSum + ((3 * checkpoints) << 128), "R5: dust < sum(L_a)/2^128 + P * C");
    }

    // ================================================================ test 25: representable neighbours

    function _checkAdjacent(SqrtRatio x) internal pure {
        SqrtRatio p = predSqrtRatio(x);
        SqrtRatio s = succSqrtRatio(x);
        assertTrue(isValid(p), "pred valid");
        assertTrue(isValid(s), "succ valid");
        assertLt(toFixed(p), toFixed(x), "pred below");
        assertGt(toFixed(s), toFixed(x), "succ above");
        assertEq(SqrtRatio.unwrap(succSqrtRatio(p)), SqrtRatio.unwrap(x), "succ(pred(x)) == x");
        assertEq(SqrtRatio.unwrap(predSqrtRatio(s)), SqrtRatio.unwrap(x), "pred(succ(x)) == x");
        assertEq(SqrtRatio.unwrap(p), SqrtRatio.unwrap(V21Ref.pred(x)), "closed form == step-and-validate model");
        assertEq(SqrtRatio.unwrap(s), SqrtRatio.unwrap(V21Ref.succ(x)), "closed form == step-and-validate model");
    }

    function test_pred_succ_vectors() public pure {
        _checkAdjacent(ONE);
        _checkAdjacent(tickToSqrtRatio(0));
        _checkAdjacent(tickToSqrtRatio(1));
        _checkAdjacent(tickToSqrtRatio(-1));
        // region edges in raw form: minimum mantissa of regions 1..3 jump down, maximum of regions 0..2 jump up
        for (uint96 region = 1; region <= 3; region++) {
            SqrtRatio lowest = SqrtRatio.wrap((region << 94) | TWO_POW_62);
            _checkAdjacent(lowest);
            assertEq(
                SqrtRatio.unwrap(predSqrtRatio(lowest)),
                SqrtRatio.unwrap(SqrtRatio.wrap(((region - 1) << 94) | (uint96(TWO_POW_94) - 1))),
                "region jump down"
            );
            SqrtRatio highestBelow = SqrtRatio.wrap(((region - 1) << 94) | (uint96(TWO_POW_94) - 1));
            assertEq(SqrtRatio.unwrap(succSqrtRatio(highestBelow)), SqrtRatio.unwrap(lowest), "region jump up");
        }
        // 2^96, 2^128, 2^160 in fixed point lie on the region boundaries as valid values
        _checkAdjacent(tickToSqrtRatio(MIN_TICK + 1));
        _checkAdjacent(tickToSqrtRatio(MAX_TICK - 1));
        // MIN and MAX themselves: the inward neighbour exists; the helpers are never applied outward
        assertTrue(isValid(succSqrtRatio(MIN_SQRT_RATIO)));
        assertTrue(isValid(predSqrtRatio(MAX_SQRT_RATIO)));
        assertGt(SqrtRatio.unwrap(predSqrtRatio(MAX_SQRT_RATIO)), SqrtRatio.unwrap(ONE));
        assertLt(SqrtRatio.unwrap(succSqrtRatio(MIN_SQRT_RATIO)), SqrtRatio.unwrap(ONE));
    }

    function test_pred_succ_fuzz_raw(uint96 raw) public pure {
        SqrtRatio x = SqrtRatio.wrap(raw);
        vm.assume(isValid(x) && x > MIN_SQRT_RATIO && x < MAX_SQRT_RATIO);
        _checkAdjacent(x);
    }

    /// @notice No valid value lies strictly between x and its neighbours
    function test_pred_succ_adjacency(uint96 raw, uint96 other) public pure {
        SqrtRatio x = SqrtRatio.wrap(raw);
        SqrtRatio y = SqrtRatio.wrap(other);
        vm.assume(isValid(x) && isValid(y) && x > MIN_SQRT_RATIO && x < MAX_SQRT_RATIO);
        SqrtRatio p = predSqrtRatio(x);
        SqrtRatio s = succSqrtRatio(x);
        assertFalse(toFixed(y) > toFixed(p) && toFixed(y) < toFixed(x), "value strictly between pred and x");
        assertFalse(toFixed(y) > toFixed(x) && toFixed(y) < toFixed(s), "value strictly between x and succ");
    }

    function test_pred_succ_tick_of_neighbour(int32 tick) public pure {
        tick = int32(bound(tick, MIN_TICK + 1, MAX_TICK - 1));
        SqrtRatio tS = tickToSqrtRatio(tick);
        assertEq(sqrtRatioToTick(predSqrtRatio(tS)), tick - 1, "pred lands in the tick below");
        assertEq(sqrtRatioToTick(succSqrtRatio(tS)), tick, "succ stays in the tick");
    }

    /// @notice Core accepts every produced limit, and the loop exits at MIN/MAX and at cur == userLimit
    function test_pred_succ_core_integration(int32 tickSeed) public {
        int32 e = int32(bound(tickSeed, -30, 30)) * S;
        if (e == 0) e = S;
        _wide();
        _lp(bytes24(uint192(2)), e < 0 ? e : -S, e < 0 ? S : e, L66);
        bool increasing = e > 0;
        _swapChecked(increasing, _big(), increasing ? predSqrtRatio(_at(e)) : succSqrtRatio(_at(e)));
        assertEq(
            SqrtRatio.unwrap(_poolState().sqrtRatio()),
            SqrtRatio.unwrap(increasing ? predSqrtRatio(_at(e)) : succSqrtRatio(_at(e))),
            "user limit at the neighbour is reached exactly"
        );
        advanceTime(12);
        _swapChecked(increasing, _big(), increasing ? MAX_SQRT_RATIO : MIN_SQRT_RATIO);
        assertEq(
            SqrtRatio.unwrap(_poolState().sqrtRatio()),
            SqrtRatio.unwrap(increasing ? MAX_SQRT_RATIO : MIN_SQRT_RATIO),
            "exits at the extreme"
        );
    }

    // ================================================================ test 26: amounts

    /// @notice R1 for the surcharge rounding functions over fuzzed bases and rates
    function test_amounts_r1_rounding(uint128 basis, uint64 sur) public pure {
        sur = uint64(bound(sur, 0, (uint64(1) << 63) - 1));
        uint256 fee = computeFee(basis, sur);
        assertGe(fee << 64, uint256(basis) * sur);
        assertLt(fee << 64, uint256(basis) * sur + (uint256(1) << 64));
        basis = uint128(bound(basis, 0, type(uint128).max >> 1));
        uint256 gross = amountBeforeFee(basis, sur);
        uint256 q = (uint256(1) << 64) - sur;
        assertGe(gross * q, uint256(basis) << 64, "gross-up covers the basis");
        if (gross != 0) assertLt((gross - 1) * q, uint256(basis) << 64, "gross-up is the ceiling");
        // the net of the gross-up returns the basis exactly (R3's one-step inverse)
        assertEq(gross - computeFee(uint128(gross), sur), basis);
    }

    /// @notice `MAX_FEE <= 2^63` keeps `amountBeforeFee` of any int128 input below 2^128: the overflow revert is not
    ///   reachable from the extension's amount rule
    function test_amounts_no_gross_up_overflow_at_cap(uint128 inNet) public pure {
        inNet = uint128(bound(inNet, 0, uint128(type(int128).max)));
        uint256 gross = amountBeforeFee(inNet, (uint64(1) << 63) - 1);
        assertLt(gross, uint256(1) << 128);
    }

    /// @notice Specified-side consumption: exact-in never exceeds the specified input; a filled exact-out (price not
    ///   limited) delivers exactly the specified output
    function test_amounts_specified_side(uint256 seed) public {
        _wide();
        _lp(bytes24(uint192(2)), 2 * S, 3 * S, L66);
        int128 a = int128(uint128(bound(seed, 1, 4e18)));
        (PoolBalanceUpdate inU,) = _swapChecked(true, a);
        assertLe(inU.delta1(), a, "exact-in consumption <= specified");
        assertGe(inU.delta1(), 0);
        advanceTime(12);
        (PoolBalanceUpdate outU, PoolState st) = _swapChecked(false, -a);
        if (st.sqrtRatio() != MAX_SQRT_RATIO) assertEq(outU.delta0(), -a, "filled exact-out == specified");
        assertGe(outU.delta1(), 0);
    }

    /// @notice Quotes equal the returned amounts exactly: the router's quote runs the same forward
    function test_amounts_quote_equals_swap(uint256 seed) public {
        _wide();
        _lp(bytes24(uint192(2)), 2 * S, 3 * S, L66);
        _lp(bytes24(uint192(3)), -3 * S, -2 * S, L66 * 3);
        int128 a = int128(uint128(bound(seed, 1, 4e18)));
        bool isToken1 = seed % 2 == 0;
        if (seed % 3 == 0) a = -a;
        (PoolBalanceUpdate quoted,) = router.quote(pool, isToken1, a, SqrtRatio.wrap(0), 0);
        (PoolBalanceUpdate actual,) = _swapChecked(isToken1, a, SqrtRatio.wrap(0));
        assertEq(PoolBalanceUpdate.unwrap(quoted), PoolBalanceUpdate.unwrap(actual), "quote == swap, no tolerance");
    }

    /// @notice 0 and 1-unit amounts, both tokens, both kinds
    function test_amounts_zero_and_one_unit() public {
        _wide();
        (PoolBalanceUpdate u,) = _swapChecked(true, 0);
        assertEq(PoolBalanceUpdate.unwrap(u), 0);
        (u,) = _swapChecked(false, 0);
        assertEq(PoolBalanceUpdate.unwrap(u), 0);
        (u,) = _swapChecked(true, 1);
        assertEq(u.delta1(), 1);
        assertEq(u.delta0(), 0);
        (u,) = _swapChecked(false, 1);
        assertEq(u.delta0(), 1);
        assertEq(u.delta1(), 0);
        // exact-out of one unit: Core moves the price and charges at least one wei of pool fee and surcharge
        (u,) = _swapChecked(true, -1);
        assertEq(u.delta1(), -1);
        assertGe(u.delta0(), 2);
        (u,) = _swapChecked(false, -1);
        assertEq(u.delta0(), -1);
        assertGe(u.delta1(), 2);
    }

    /// @notice Fees at the edges: 1 ulp and just below MAX_FEE, with the surcharge at the cap
    function test_amounts_fee_edges() public {
        createPools(1, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _swapChecked(true, 1e18);
        assertGt(lastFee0, 0);
        uint64 nearMax = (uint64(1) << 63) - 1;
        createPools(nearMax, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _swapChecked(true, 1e18);
        // cap = MAX_FEE - poolFee = 1 ulp of surcharge from the first segment on
        for (uint256 i; i < lastCalls; i++) {
            if (actor.refCall(i).kind == 0) assertEq(actor.refCall(i).sur, 1, "surcharge capped at 1 ulp");
        }
        _swapChecked(true, -1e18, SqrtRatio.wrap(0));
    }

    // ================================================================ test 27: forward debt

    /// @notice A forced revert after the forwarded swap rolls back the pool, the fee growth and the extension state
    function test_forward_revert_rolls_back() public {
        _wide();
        _swapChecked(true, 1e18);
        advanceTime(12);
        bytes32 st0 = PoolState.unwrap(_poolState());
        FeesPerLiquidity memory f0 = core.getPoolFeesPerLiquidity(pool.toPoolId());
        V21Ref.State memory s0 = _state(pool);
        V21Actor.Action[] memory acts = new V21Actor.Action[](2);
        acts[0] = _action(1, pool, SwapParameters.unwrap(_params(true, 1e18, SqrtRatio.wrap(0))), 0, address(v21));
        acts[1] = _action(4, pool, 0, 0, address(0));
        vm.expectRevert(V21Actor.Forced.selector);
        actor.run(acts);
        assertEq(PoolState.unwrap(_poolState()), st0, "pool state rolled back");
        FeesPerLiquidity memory f1 = core.getPoolFeesPerLiquidity(pool.toPoolId());
        assertEq(f1.value0, f0.value0);
        assertEq(f1.value1, f0.value1);
        _assertStateEq(_state(pool), s0);
    }

    /// @notice The forwarded swap inside a nested lock lands its debt on the inner lock; the outer lock has nothing
    ///   to settle and closes clean
    function test_forward_nested_locks() public {
        _wide();
        OuterLocker outer = new OuterLocker(core);
        V21Actor.Action[] memory acts = new V21Actor.Action[](1);
        acts[0] = _action(1, pool, SwapParameters.unwrap(_params(true, 1e18, SqrtRatio.wrap(0))), 0, address(v21));
        uint256 b0 = token0.balanceOf(address(this));
        uint256 b1 = token1.balanceOf(address(this));
        bytes memory r = outer.runInner(actor, acts);
        (PoolBalanceUpdate u,) = abi.decode(abi.decode(r, (bytes[]))[0], (PoolBalanceUpdate, PoolState));
        assertEq(int256(b1) - int256(token1.balanceOf(address(this))), u.delta1(), "payer paid the input + surcharge");
        assertEq(int256(token0.balanceOf(address(this))) - int256(b0), -u.delta0(), "payer received the net output");
    }

    /// @notice Native token pool through the router: value forwarded, surcharge charged, nothing stranded on the
    ///   extension
    function test_forward_native_token() public {
        pool = createPool(
            NATIVE_TOKEN_ADDRESS, address(token1), 0, createConcentratedPoolConfig(FEE_30BP, SP, address(v21))
        );
        poolFee = FEE_30BP;
        spacing = SP;
        createPosition(pool, -40 * S, 40 * S, 1e20, 1e20);
        uint256 e0 = address(this).balance;
        PoolBalanceUpdate u =
            router.swapAllowPartialFill{value: 1e18}(pool, _params(false, 1e18, SqrtRatio.wrap(0)), address(this));
        assertEq(u.delta0(), 1e18);
        assertLt(u.delta1(), 0);
        assertEq(e0 - address(this).balance, 1e18);
        assertEq(address(v21).balance, 0, "no native balance on the extension");
        // exact-out in native: the surcharge is added to the native input; the router refunds the excess
        u = router.swapAllowPartialFill{value: 2e18}(pool, _params(true, -1e17, SqrtRatio.wrap(0)), address(this));
        assertEq(u.delta1(), -1e17);
        assertGt(u.delta0(), 0);
        assertEq(address(v21).balance, 0);
    }

    /// @notice The extension never holds tokens or saved balances: every charged wei is a debt of the forwarding lock
    function test_forward_no_extension_balances() public {
        _wide();
        _swapChecked(true, 1e18);
        _swapChecked(false, -1e17, SqrtRatio.wrap(0));
        assertEq(token0.balanceOf(address(v21)), 0);
        assertEq(token1.balanceOf(address(v21)), 0);
        (uint128 s0, uint128 s1) =
            core.savedBalances(address(v21), address(token0), address(token1), PoolId.unwrap(pool.toPoolId()));
        assertEq(s0 + s1, 0, "no saved balances");
        // Core's token balances equal the pools' deposits plus fees: the payer's balances moved by exactly the deltas
        // (checked per swap by the actor settling the returned amounts)
    }

    // ================================================================ quoter vectors
    // Emits the traced Core calls of deterministic scenarios as JSON lines (the vectors published for the `main`
    // quoter/indexer; run with `-vv --match-test test_vectors`)

    function _st(SqrtRatio r, int32 t, uint128 l) internal pure returns (string memory) {
        return string.concat(
            '{"sqrtRatio":"',
            vm.toString(SqrtRatio.unwrap(r)),
            '","tick":',
            vm.toString(t),
            ',"liquidity":"',
            vm.toString(l),
            '"}'
        );
    }

    function _dump(string memory name, PoolState before, SwapParameters p, PoolBalanceUpdate u, PoolState after_)
        internal
    {
        string memory calls = "[";
        for (uint256 i; i < trace.length; i++) {
            Call memory c = trace[i];
            V21Actor.RefCall memory r = actor.refCall(i);
            calls = string.concat(
                calls,
                i == 0 ? "" : ",",
                '{"limit":"',
                vm.toString(SqrtRatio.unwrap(c.limit)),
                '","amount":"',
                vm.toString(c.amount),
                '","kind":"',
                r.kind == 0 ? "charged" : (r.kind == 1 ? "toward" : "bridge"),
                '","surcharge":"',
                vm.toString(r.sur),
                '","before":',
                _st(c.before, c.tickBefore, c.liqBefore),
                ',"after":',
                _st(c.after_, c.tickAfter, c.liqAfter),
                ',"delta0":"',
                vm.toString(c.d0),
                '","delta1":"',
                vm.toString(c.d1),
                '","fee0":"',
                vm.toString(c.fee0),
                '","fee1":"',
                vm.toString(c.fee1),
                '"}'
            );
        }
        (SqrtRatio br, int32 bt, uint128 bl) = before.parse();
        (SqrtRatio ar, int32 at, uint128 al) = after_.parse();
        emit log_string(string.concat(
                '{"name":"',
                name,
                '","cfg":{"tau":',
                vm.toString(cfg.tau),
                ',"slopeK":',
                vm.toString(cfg.slopeK),
                ',"segExp":',
                vm.toString(cfg.segExp),
                ',"jLin":',
                vm.toString(cfg.jLin),
                ',"maxFee":"',
                vm.toString(cfg.maxFee),
                '","clampTicks":',
                vm.toString(cfg.clamp),
                ',"mGate":',
                vm.toString(cfg.mGate),
                '},"pool":{"fee":"',
                vm.toString(poolFee),
                '","tickSpacing":',
                vm.toString(spacing),
                '},"anchorX16":"',
                vm.toString(_anchor()),
                '","params":{"isToken1":',
                p.isToken1() ? "true" : "false",
                ',"amount":"',
                vm.toString(p.amount()),
                '","sqrtRatioLimit":"',
                vm.toString(SqrtRatio.unwrap(p.withDefaultSqrtRatioLimit().sqrtRatioLimit())),
                '","skipAhead":',
                vm.toString(p.skipAhead()),
                '},"before":',
                _st(br, bt, bl),
                ',"calls":',
                calls,
                '],"total":{"delta0":"',
                vm.toString(u.delta0()),
                '","delta1":"',
                vm.toString(u.delta1()),
                '"},"after":',
                _st(ar, at, al),
                "}"
            ));
    }

    function _vector(string memory name, bool isToken1, int128 amount, SqrtRatio limit, uint256 skipAhead) internal {
        PoolState before = _poolState();
        (PoolBalanceUpdate u, PoolState st) = _swapChecked(isToken1, amount, limit, skipAhead);
        _dump(name, before, _params(isToken1, amount, limit, skipAhead), u, st);
    }

    function test_vectors_increasing_decreasing_cut_bridge() public {
        _wide();
        _lp(bytes24(uint192(2)), 3 * S, 7 * S, L66);
        _lp(bytes24(uint192(3)), -7 * S, -3 * S, L66);
        _vector("inc_exact_in_cut_bridge_rate", true, _big(), _at(12 * S), 0);
        _vector("dec_toward_then_away_exact_in", false, _big(), _at(-12 * S), 0);
        advanceTime(12);
        _vector("inc_exact_out_after_anchor_update", false, -3e18, SqrtRatio.wrap(0), 0);
        _vector("dec_exact_out_partial", true, -2e18, SqrtRatio.wrap(0), 0);
        _vector("inc_exact_in_partial_mid_segment", true, 7e17, SqrtRatio.wrap(0), 0);
    }

    function test_vectors_exact_tick_and_fee_only() public {
        createPools(FEE_30BP, SP, 3 * S);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _lp(bytes24(uint192(2)), 3 * S, 7 * S, L66);
        _vector("exact_tick_state_dec_from_tick_T", false, _big(), _at(2 * S), 0);
        _vector("inc_through_T_toward_uncut", true, _big(), _at(5 * S), 0);
        _vector("dec_onto_T_tick_T_minus_1", false, _big(), _at(3 * S), 0);
        _vector("exact_tick_state_inc_from_tick_T_minus_1", true, _big(), _at(4 * S), 0);
        _vector("dec_onto_T_again", false, _big(), _at(3 * S), 0);
        _vector("fee_only_1_wei_exact_in_at_T", true, 1, SqrtRatio.wrap(0), 0);
    }

    function test_vectors_bridge_25pct_and_1ulp() public {
        createPools(FEE_25PCT, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _lp(bytes24(uint192(2)), 2 * S, 3 * S, L66);
        _vector("bridge_25pct_exact_in", true, _big(), _at(2 * S + S / 2), 0);
        advanceTime(12);
        _vector("bridge_25pct_exact_out_dec", true, -1e18, SqrtRatio.wrap(0), 0);
        createPools(1, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _lp(bytes24(uint192(2)), 2 * S, 3 * S, L66);
        _vector("bridge_1ulp_exact_in", true, _big(), _at(2 * S + S / 2), 0);
    }

    function test_vectors_uninitialized_endpoints_and_cap() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -S, S, L66);
        _lp(bytes24(uint192(2)), 1000 * S, 1001 * S, L66);
        _vector("empty_words_skip0", true, _big(), _at(1000 * S + S / 2), 0);
        advanceTime(12);
        _vector("return_toward_skip0", false, _big(), _at(0), 0);
        advanceTime(12);
        _vector("empty_words_skip3", true, _big(), _at(1000 * S + S / 2), 3);
        // a second pool pair on the same tokens needs another extension instance and a distinct twin key (no pool
        // salt on main): use a different fee
        V21Ref.Cfg memory c = V21Ref.defaults();
        useExtension(deployV21(c, 11), c);
        createPools(FEE_30BP + 1, SP, 0);
        _lp(bytes24(uint192(1)), -20_000 * S, 20_000 * S, int128(1) << 40);
        _lp(bytes24(uint192(2)), 3000 * S, 3001 * S, 1e9);
        _vector("cap_tail_to_max", true, _big(), MAX_SQRT_RATIO, 0);
    }

    function test_vectors_segexp_offgrid_and_negative_anchor() public {
        V21Ref.Cfg memory c = V21Ref.defaults();
        c.segExp = 2;
        useExtension(deployV21(c, 7), c);
        _wide();
        _lp(bytes24(uint192(2)), 3 * S, 7 * S, L66 * 2);
        _lp(bytes24(uint192(3)), 8 * S, 9 * S, L66);
        _vector("segexp2_offgrid_ticks_inc", true, _big(), _at(12 * S), 0);
        int32 sp = 3000;
        createPools(FEE_30BP, uint32(sp), -123_457);
        _lp(bytes24(uint192(1)), -200 * sp, 100 * sp, L66);
        _lp(bytes24(uint192(2)), -50 * sp, -30 * sp, L66);
        _vector("spacing3000_negative_anchor_dec", false, _big(), _at(-80 * sp), 0);
        advanceTime(12);
        _vector("spacing3000_negative_anchor_inc", true, _big(), _at(-20 * sp), 0);
    }
}

/// @notice A locker that runs another locker's action list inside its own (outer) lock
contract OuterLocker is BaseLocker {
    constructor(ICore core) BaseLocker(core) {}

    function runInner(V21Actor inner, V21Actor.Action[] memory acts) external returns (bytes memory) {
        return lock(abi.encode(address(inner), acts));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address inner, V21Actor.Action[] memory acts) = abi.decode(data, (address, V21Actor.Action[]));
        return abi.encode(V21Actor(inner).run(acts));
    }
}
