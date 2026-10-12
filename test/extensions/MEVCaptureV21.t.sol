// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {MEVCaptureV21Base} from "./MEVCaptureV21Base.sol";
import {V21Ref, V21Actor, MEVCaptureV21Unregistered} from "./MEVCaptureV21Helpers.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {MEVCaptureV21} from "../../src/extensions/MEVCaptureV21.sol";
import {IMEVCaptureV21} from "../../src/interfaces/extensions/IMEVCaptureV21.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PositionId} from "../../src/types/positionId.sol";
import {SqrtRatio, MIN_SQRT_RATIO, MAX_SQRT_RATIO} from "../../src/types/sqrtRatio.sol";
import {SwapParameters} from "../../src/types/swapParameters.sol";
import {Locker} from "../../src/types/locker.sol";
import {
    createConcentratedPoolConfig,
    createStableswapPoolConfig,
    createFullRangePoolConfig
} from "../../src/types/poolConfig.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {computeFee} from "../../src/math/fee.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING} from "../../src/math/constants.sol";

contract MEVCaptureV21Test is MEVCaptureV21Base {
    using CoreLib for *;

    uint32 internal constant SP = 4096;
    int32 internal constant S = 4096;
    int128 internal constant L66 = int128(1) << 66;

    function _standard() internal {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
    }

    function _limitAt(int32 tick) internal pure returns (SqrtRatio) {
        return tickToSqrtRatio(tick);
    }

    // ================================================================ deployment, init, access (inv 1, 11, 20)

    function test_isRegistered() public view {
        assertTrue(core.isExtensionRegistered(address(v21)));
    }

    function test_getConfig_defaults() public view {
        IMEVCaptureV21.Config memory c = v21.getConfig();
        assertEq(c.halfLife, 120);
        assertEq(c.slopeK, 4);
        assertEq(c.segmentExp, 0);
        assertEq(c.segmentWidthMultiplier, 1);
        assertEq(c.jLin, 16);
        assertEq(c.maxFee, uint64(1) << 63);
        assertEq(c.clampTicks, 2500);
        assertEq(c.mGate, 3);
    }

    function test_init_state(uint32 time, int32 tick, uint64 fee, uint32 tickSpacing) public {
        vm.warp(time);
        tick = int32(bound(tick, MIN_TICK, MAX_TICK));
        fee = uint64(bound(fee, 1, (uint64(1) << 63) - 1));
        tickSpacing = uint32(bound(tickSpacing, 1, MAX_TICK_SPACING));
        createPools(fee, tickSpacing, tick);
        V21Ref.State memory s = _state(pool);
        assertEq(s.lastUpdateTime, time);
        assertEq(s.lRefTime, time);
        assertEq(s.lastPosTime, 0);
        assertEq(s.lRefBits, 0);
        assertEq(s.snapBits, 0);
        unchecked {
            assertEq(s.raiseTime, uint32(time - 120));
        }
        assertEq(s.anchorX16, int256(tick) << 16);
    }

    function test_init_rejects() public {
        vm.expectRevert(IMEVCaptureV21.ConcentratedLiquidityPoolsOnly.selector);
        createPool(address(token0), address(token1), 0, createStableswapPoolConfig(100, 4, 0, address(v21)));
        vm.expectRevert(IMEVCaptureV21.ConcentratedLiquidityPoolsOnly.selector);
        createPool(address(token0), address(token1), 0, createFullRangePoolConfig(100, address(v21)));
        vm.expectRevert(IMEVCaptureV21.NonzeroFeesOnly.selector);
        createPool(address(token0), address(token1), 0, createConcentratedPoolConfig(0, 4, address(v21)));
        vm.expectRevert(IMEVCaptureV21.PoolFeeNotBelowMaxFee.selector);
        createPool(address(token0), address(token1), 0, createConcentratedPoolConfig(uint64(1) << 63, 4, address(v21)));
        vm.expectRevert(IMEVCaptureV21.PoolFeeNotBelowMaxFee.selector);
        createPool(address(token0), address(token1), 0, createConcentratedPoolConfig(type(uint64).max, 4, address(v21)));
    }

    function test_hooks_onlyCore(address caller) public {
        vm.assume(caller != address(core));
        PoolKey memory pk = PoolKey({
            token0: address(token0), token1: address(token1), config: createConcentratedPoolConfig(1, 1, address(v21))
        });
        vm.startPrank(caller);
        vm.expectRevert(UsesCore.CoreOnly.selector);
        v21.beforeInitializePool(caller, pk, 0);
        vm.expectRevert(UsesCore.CoreOnly.selector);
        v21.beforeUpdatePosition(Locker.wrap(bytes32(0)), pk, PositionId.wrap(bytes32(0)), 1);
        vm.stopPrank();
    }

    /// @notice Invariant 20(b): beforeSwap reverts for every caller; Core only skips it when the extension is the locker
    function test_beforeSwap_reverts_for_every_locker(address caller, bytes32 locker, bytes32 params) public {
        PoolKey memory pk = PoolKey({
            token0: address(token0), token1: address(token1), config: createConcentratedPoolConfig(1, 1, address(v21))
        });
        vm.prank(caller);
        vm.expectRevert(IMEVCaptureV21.SwapMustHappenThroughForward.selector);
        v21.beforeSwap(Locker.wrap(locker), pk, SwapParameters.wrap(params));
    }

    function test_direct_core_swap_reverts() public {
        _standard();
        V21Actor.Action[] memory acts = new V21Actor.Action[](1);
        acts[0] = _action(2, pool, SwapParameters.unwrap(_params(false, 1000, MIN_SQRT_RATIO)), 0, address(0));
        vm.expectRevert(IMEVCaptureV21.SwapMustHappenThroughForward.selector);
        actor.run(acts);
        // the router (which forwards) works
        router.swapAllowPartialFill(pool, _params(false, 1000, SqrtRatio.wrap(0)), address(this));
    }

    /// @notice Invariant 11: the constructor rejects every out-of-range immutable
    function test_constructor_rejects_out_of_range() public {
        V21Ref.Cfg memory c = V21Ref.defaults();
        uint256 n;
        for (uint256 i; i < 12; i++) {
            V21Ref.Cfg memory b = V21Ref.Cfg(c.tau, c.slopeK, c.segExp, c.jLin, c.maxFee, c.clamp, c.mGate);
            if (i == 0) b.tau = 0;
            if (i == 1) b.tau = (1 << 20) + 1;
            if (i == 2) b.slopeK = 0;
            if (i == 3) b.slopeK = 17;
            if (i == 4) b.segExp = 9;
            if (i == 5) b.jLin = 0;
            if (i == 6) b.jLin = 65;
            if (i == 7) b.maxFee = 0;
            if (i == 8) b.maxFee = (uint256(1) << 63) + 1;
            if (i == 9) b.clamp = 0;
            if (i == 10) b.clamp = 2 * uint256(uint32(MAX_TICK)) + 1;
            if (i == 11) b.mGate = 17;
            vm.expectRevert(IMEVCaptureV21.InvalidConfig.selector);
            new MEVCaptureV21Unregistered(
                core,
                uint32(b.tau),
                uint8(b.slopeK),
                uint8(b.segExp),
                uint8(b.jLin),
                uint64(b.maxFee),
                uint32(b.clamp),
                uint8(b.mGate)
            );
            n++;
        }
        assertEq(n, 12);
    }

    /// @notice Termination bound: for every allowed configuration the (J_LIN + 28)-th away boundary lies beyond the
    ///   tick range, so at most J_LIN + 28 rate boundaries exist regardless of whether the surcharge reaches its cap
    function test_rate_boundaries_bounded(uint8 segExp, uint8 jLin, uint32 tickSpacing) public pure {
        V21Ref.Cfg memory c = V21Ref.defaults();
        c.segExp = bound(segExp, 0, 8);
        c.jLin = bound(jLin, 1, 64);
        uint256 sp = bound(tickSpacing, 1, MAX_TICK_SPACING);
        int256 anchor = int256(MIN_TICK) << 16;
        assertGt(V21Ref.boundary(c, sp, anchor, true, c.jLin + 28), int256(MAX_TICK) << 16);
        anchor = int256(MAX_TICK) << 16;
        assertLt(V21Ref.boundary(c, sp, anchor, false, c.jLin + 28), int256(MIN_TICK) << 16);
    }

    // ================================================================ inv 1, 2: anchor writes and decay

    function test_anchor_written_only_on_first_swap_of_timestamp() public {
        _standard();
        _warmReference();
        _swapChecked(true, 1e17); // away: price up
        int256 a0 = _anchor();
        advanceTime(12);
        _swapChecked(false, 1e15);
        int256 a1 = _anchor();
        assertTrue(a1 != a0, "first swap of the timestamp moves the anchor");
        _swapChecked(true, 3e16);
        _swapChecked(false, 2e16);
        _lp(bytes24(uint192(9)), -S, S, 1e18);
        assertEq(_anchor(), a1, "later swaps and position updates do not move the anchor");
    }

    function test_differential_fuzz(uint256 seed) public {
        uint64 fee = uint64(bound(uint256(keccak256(abi.encode(seed, 0))), 1, FEE_30BP * 10));
        // power-of-two and arbitrary spacings
        uint32 sp = uint32(bound(uint256(keccak256(abi.encode(seed, 1))), 16, 20_000));
        if (seed % 3 == 0) sp = uint32(1) << uint8(bound(uint256(keccak256(abi.encode(seed, 1))), 4, 14));
        int32 tick = int32(int256(bound(uint256(keccak256(abi.encode(seed, 2))), 0, 2_000_000)) - 1_000_000);
        createPools(fee, sp, tick);
        int32 spI = int32(sp);
        int32 center = (tick / spI) * spI;

        // 1-4 positions, possibly leaving gaps
        uint256 np = 1 + uint256(keccak256(abi.encode(seed, 3))) % 4;
        for (uint256 i; i < np; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, 10 + i)));
            int32 lo = center + int32(int256(r % 64) - 48) * spI;
            int32 hi = lo + int32(int256(1 + (r >> 8) % 64)) * spI;
            if (lo < MIN_TICK || hi > MAX_TICK) continue;
            uint128 maxL = pool.config.concentratedMaxLiquidityPerTick() / 8;
            int128 liq = int128(uint128(bound(r >> 16, 1e12, maxL < 1e26 ? maxL : 1e26)));
            _lp(bytes24(uint192(i + 1)), lo, hi, liq);
        }

        for (uint256 j; j < 10; j++) {
            uint256 r = uint256(keccak256(abi.encode(seed, 100 + j)));
            uint256 dtSel = r % 4;
            if (dtSel == 1) advanceTime(1 + (r >> 8) % 12);
            else if (dtSel == 2) advanceTime(12 + (r >> 8) % 600);
            else if (dtSel == 3) advanceTime((r >> 8) % 7200);
            bool isToken1 = (r >> 40) & 1 == 1;
            bool exactOut = (r >> 41) & 1 == 1;
            int128 amount = int128(uint128(1 + (r >> 48) % 1e20));
            if (exactOut) amount = -amount;
            // always bound the price move: beyond the liquidity every empty bitmap word is one Core call for the
            // extension and for Core's own loop, so a far limit is a few words past the last position
            bool increasing = isToken1 != exactOut;
            int256 dist = (r >> 200) % 3 == 0
                ? int256(1 + (r >> 210) % (80 * uint256(int256(spI))))
                : int256(600 * uint256(int256(spI)));
            int256 lt = int256(_poolState().tick()) + (increasing ? dist : -dist);
            if (lt <= MIN_TICK) lt = MIN_TICK + 1;
            if (lt >= MAX_TICK) lt = MAX_TICK - 1;
            SqrtRatio limit = tickToSqrtRatio(int32(lt));
            _swapChecked(isToken1, amount, limit, (r >> 120) % 4 == 0 ? (r >> 130) % 4 : 0);
        }
    }

    // ================================================================ inv 3: parking

    function _edgePool() internal {
        createPools(FEE_30BP, SP, 0);
        // liquidity ends at +2 spacings: above it the range is empty
        _lp(bytes24(uint192(1)), -40 * S, 2 * S, L66);
        _warmReference();
    }

    function test_park_through_empty_range_gate_fails() public {
        _edgePool();
        int256 a0 = _anchor();
        // end of t: park in the empty range above the liquidity
        _swapChecked(true, type(int128).max >> 8, _limitAt(50_000));
        assertEq(_poolState().tick(), 50_000);
        int256 aPark = _anchor();
        // t+1: the return is the first touch
        advanceTime(12);
        _swapChecked(false, type(int128).max >> 8, _limitAt(0));
        assertTrue(lastWasFirst && lastGateFailed, "gate fails on the empty-range observation");
        assertEq(_anchor(), aPark, "anchor unchanged");
        assertEq(aPark, a0);
    }

    function test_park_return_with_flash_liquidity_at_P() public {
        _edgePool();
        int256 a0 = _anchor();
        _swapChecked(true, type(int128).max >> 8, _limitAt(50_000));
        advanceTime(12);
        // one lock: add liquidity at P, forwarded return swap (first swap of the timestamp), remove
        PositionId pid = _pid(bytes24(uint192(77)), 12 * S, 13 * S);
        V21Actor.Action[] memory acts = new V21Actor.Action[](3);
        acts[0] = _action(0, pool, PositionId.unwrap(pid), int128(1) << 90, address(0));
        acts[1] = _action(
            1, pool, SwapParameters.unwrap(_params(false, type(int128).max >> 8, _limitAt(0))), 0, address(v21)
        );
        acts[2] = _action(0, pool, PositionId.unwrap(pid), -(int128(1) << 90), address(0));
        actor.run(acts);
        assertEq(_anchor(), a0, "flash liquidity at P is never observed");
        V21Ref.State memory s = _state(pool);
        assertEq(s.snapBits, 0, "snapshot taken before the flash add");
        assertEq(s.lastPosTime, _now());
    }

    function _dustPark(uint256 idle) internal returns (uint256 moved) {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 2 * S, L66);
        _warmReference();
        // dust at P held across the boundary: bitlen 64 >= lRefBits(67) - M_GATE
        _lp(bytes24(uint192(2)), 12 * S, 13 * S, int128(1) << 63);
        int256 a0 = _anchor();
        _swapChecked(true, type(int128).max >> 8, _limitAt(50_000));
        advanceTime(idle);
        _swapChecked(false, 1, SqrtRatio.wrap(0));
        assertFalse(lastGateFailed, "dust passes the gate");
        moved = _abs(_anchor() - a0);
    }

    function test_park_with_dust_moves_at_most_clamp_rate() public {
        uint256 moved = _dustPark(12);
        assertEq(moved, (uint256(2500) << 16) * 12 / 120, "drag is exactly the per-update clamp");
    }

    function test_idle_park_moves_at_most_clamp() public {
        uint256 moved = _dustPark(3600);
        assertEq(moved, uint256(2500) << 16, "one idle park earns at most CLAMP");
    }

    function test_park_with_dust_allowance_rounds_up() public {
        uint256 moved = _dustPark(7);
        assertEq(moved, ((uint256(2500) << 16) * 7 + 119) / 120, "fractional allowance rounds up");
    }

    // ================================================================ inv 2 (V12 F-13): frequent updates never slow the anchor

    function _displacedPools(V21Ref.Cfg memory c, int32 displacement)
        internal
        returns (PoolKey memory other, MEVCaptureV21 ext, int256 a0)
    {
        useExtension(deployV21(c, 7), c);
        // liquidity only around the anchor, so the push beyond it is a free empty-range move
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -S, S, L66);
        (other, ext) = createOtherPool(FEE_30BP, SP, 0, 8);
        _lpOn(other, bytes24(uint192(1)), -S, S, L66);
        a0 = _anchor();
        // same timestamp as the initialization: no anchor update runs, the anchor stays at the initial tick
        _swapChecked(true, type(int128).max >> 8, _limitAt(displacement));
        _swapRawOn(other, ext, _params(true, type(int128).max >> 8, _limitAt(displacement)));
        assertEq(_anchor(), a0, "push leaves the anchor");
        assertEq(_state(ext, other).anchorX16, a0);
        assertEq(_poolState().tick(), displacement);
    }

    /// @notice V12 run 57 F-13: with `CLAMP_TICKS = 1` and `HALF_LIFE = 2^20`, a floored per-update allowance was 0
    ///   for every dt < 16, so a zero-amount forward every second consumed the interval without granting movement and
    ///   froze the anchor indefinitely. The allowance rounds up: every consumed interval grants at least one unit
    function test_f13_zero_amount_forwards_every_second_cannot_freeze_anchor() public {
        V21Ref.Cfg memory c = V21Ref.defaults();
        c.tau = 1 << 20;
        c.clamp = 1;
        (PoolKey memory other, MEVCaptureV21 ext, int256 a0) = _displacedPools(c, 1000);
        for (uint256 i; i < 32; i++) {
            advanceTime(1);
            _swapChecked(true, 0, SqrtRatio.wrap(0));
            assertEq(_state(pool).lastUpdateTime, _now(), "the zero-amount forward consumed the interval");
            assertEq(uint256(_anchor() - a0), i + 1, "each touched second grants ceil(2^16 / 2^20) = 1 unit");
        }
        // one update over the same 32 s grants ceil(2^16 * 32 / 2^20) = 2 units: touching never slows the anchor and
        // adds at most one unit per touched timestamp
        _swapRawOn(other, ext, _params(true, 0, SqrtRatio.wrap(0)));
        assertEq(_state(ext, other).anchorX16 - a0, 2, "single update over 32 s");
    }

    /// @notice For any config and clamp-bound displacement, n per-second updates move the anchor exactly
    ///   n * ceil(CLAMP * 2^16 / tau): never less than one update over the same n seconds, and at most n units more
    ///   than the exact rate CLAMP * 2^16 * n / tau
    function test_fuzz_frequent_updates_never_slow_anchor(uint32 tauSeed, uint32 clampSeed, uint8 nSeed) public {
        V21Ref.Cfg memory c = V21Ref.defaults();
        c.tau = bound(tauSeed, 1, 1 << 20);
        c.clamp = bound(clampSeed, 1, 4096);
        uint256 n = bound(nSeed, 1, 48);
        // the clamp binds on every update while the offset exceeds about 2.2 * (CLAMP + 16) ticks; per-second updates
        // move at most CLAMP + 1 ticks each, so this displacement keeps it binding for all n <= 48 updates
        (PoolKey memory other, MEVCaptureV21 ext, int256 a0) = _displacedPools(c, int32(int256(70 * c.clamp + 128)));
        uint256 unitsPerTau = c.clamp << 16;
        for (uint256 i; i < n; i++) {
            advanceTime(1);
            _swapChecked(true, 0, SqrtRatio.wrap(0));
        }
        uint256 touched = uint256(_anchor() - a0);
        assertEq(touched, n * ((unitsPerTau + c.tau - 1) / c.tau), "n per-second updates");

        _swapRawOn(other, ext, _params(true, 0, SqrtRatio.wrap(0)));
        uint256 single = uint256(_state(ext, other).anchorX16 - a0);
        assertEq(single, (unitsPerTau * (n < c.tau ? n : c.tau) + c.tau - 1) / c.tau, "one update over n seconds");

        assertGe(touched, single, "frequent updates slowed the anchor");
        assertLe(touched * c.tau, n * unitsPerTau + n * c.tau, "more than one extra unit per touched second");
    }

    // ================================================================ inv 4: crossing after an empty-range push

    function test_crossing_after_empty_range_push_pays_same_as_from_anchor() public {
        createPools(FEE_30BP, SP, 0);
        // LP only above the anchor
        _lp(bytes24(uint192(1)), 0, 40 * S, L66);
        (PoolKey memory other, MEVCaptureV21 ext) = createOtherPool(FEE_30BP, SP, 0, 1);
        _lpOn(other, bytes24(uint192(1)), 0, 40 * S, L66);

        // attacker pushes the v2.1 pool deep below the anchor through the empty range (free)
        (PoolBalanceUpdate push,) = _swapChecked(false, type(int128).max >> 8, _limitAt(-1_000_000));
        assertEq(push.delta0(), 0, "empty range push is free");
        // the victim swaps up to the same end price on both pools
        (PoolBalanceUpdate crossing,) = _swapChecked(true, type(int128).max >> 8, _limitAt(20 * S + 1234));
        (PoolBalanceUpdate fromAnchor,) =
            _swapRawOn(other, ext, _params(true, type(int128).max >> 8, _limitAt(20 * S + 1234)));
        assertEq(crossing.delta1(), fromAnchor.delta1(), "same input");
        assertEq(crossing.delta0(), fromAnchor.delta0(), "same output");
    }

    // ================================================================ inv 5: split invariance (fixed endpoints, R1/R2)

    function test_split_invariance(uint256 endSeed, uint8 nSeed, uint256 cutSeed) public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _lp(bytes24(uint192(2)), 3 * S, 7 * S, L66 * 3);
        (PoolKey memory other, MEVCaptureV21 ext) = createOtherPool(FEE_30BP, SP, 0, 1);
        _lpOn(other, bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _lpOn(other, bytes24(uint192(2)), 3 * S, 7 * S, L66 * 3);

        int32 endTick = int32(int256(bound(endSeed, 1, 30 * uint256(int256(S)))));
        uint256 n = bound(nSeed, 2, 12);

        (PoolBalanceUpdate single,) = _swapChecked(true, type(int128).max >> 8, _limitAt(endTick));
        uint256 singleCalls = lastCalls;

        // N chunks with random cut points, same timestamp, on the other pool
        int256 total1;
        int256 total0;
        int32 prev = 0;
        uint256 calls;
        for (uint256 i = 1; i <= n; i++) {
            int32 cut = i == n
                ? endTick
                : int32(
                    int256(prev)
                        + int256(bound(uint256(keccak256(abi.encode(cutSeed, i))), 0, uint256(int256(endTick - prev))))
                );
            if (cut <= prev) continue;
            (PoolBalanceUpdate u,) = _swapRawOn(other, ext, _params(true, type(int128).max >> 8, _limitAt(cut)));
            total0 += u.delta0();
            total1 += u.delta1();
            prev = cut;
            calls += 4 + uint256(int256(cut)) / uint256(int256(S));
        }
        // fixed endpoints and constant rates per cut: gross input <= ceil(2/q) and output <= 2 wei per added cut (R2),
        // plus one surcharge rounding per charged call (R1)
        uint256 tol = 4 * (calls + singleCalls);
        assertApproxEqAbs(total1, int256(single.delta1()), tol, "split input");
        assertApproxEqAbs(total0, int256(single.delta0()), tol, "split output");
    }

    // ================================================================ inv 6, 7, 8, 9: fee destination

    function test_same_timestamp_jit_after_swap_collects_nothing() public {
        _standard();
        _swapChecked(true, 1e18);
        assertGt(lastFee0, 0, "the away swap was charged");
        _lp(bytes24(uint192(5)), -S, 20 * S, L66);
        (uint128 f0, uint128 f1) = _collect(pool, bytes24(uint192(5)), -S, 20 * S);
        assertEq(f0, 0);
        assertEq(f1, 0);
    }

    function test_own_range_redirect_collects_nothing_of_victim() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _lp(bytes24(uint192(6)), 20 * S, 21 * S, L66); // attacker's own narrow range
        (PoolBalanceUpdate victim,) = _swapChecked(true, type(int128).max >> 8, _limitAt(10 * S));
        (uint128 a0, uint128 a1) = _collect(pool, bytes24(uint192(6)), 20 * S, 21 * S);
        assertEq(a0 + a1, 0, "victim never traded in the attacker's range");
        (uint128 h0, uint128 h1) = _collect(pool, bytes24(uint192(1)), -40 * S, 40 * S);
        assertGt(h1, 0, "pool fee on the input");
        assertGt(h0, 0, "surcharge on the output");
        assertLe(h1, uint128(victim.delta1()));
        assertLe(h0, lastFee0, "the honest LP collects at most the charged surcharge");

        // attacker parks inside its own range at the next timestamp and collects
        advanceTime(12);
        _swapChecked(true, type(int128).max >> 8, _limitAt(20 * S));
        (PoolBalanceUpdate inside,) = _swapChecked(true, type(int128).max >> 8, _limitAt(20 * S + S / 2));
        (a0, a1) = _collect(pool, bytes24(uint192(6)), 20 * S, 21 * S);
        assertLe(a1, uint128(inside.delta1()) / 2, "attacker only earns a share of its own in-range trade");
        assertLe(a0, lastFee0 / 2 + 1, "attacker only earns its share of the in-range surcharge");
        assertLt(a0, h0, "nothing redirected");
    }

    /// @notice Invariant 8 (R5): nothing is deferred and nothing is lost beyond Core's growth/collection flooring. The
    ///   v2.1 positions collect the twin's pool fees plus the charged surcharge, up to the R2 per-cut allowances on the
    ///   pool fee and the R5 dust on the surcharge; both pools empty out to rounding dust.
    function test_nothing_stranded_and_fee_growth_matches_twin() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, -2 * S, L66);
        _lp(bytes24(uint192(2)), 2 * S, 40 * S, L66);
        _lp(bytes24(uint192(3)), 5 * S, 6 * S, L66 * 4);
        uint256 charged0;
        uint256 charged1;
        uint256 calls;
        _swapChecked(true, type(int128).max >> 8, _limitAt(30 * S));
        (charged0, charged1, calls) = (charged0 + lastFee0, charged1 + lastFee1, calls + lastCalls);
        advanceTime(12);
        _swapChecked(false, 5e18);
        (charged0, charged1, calls) = (charged0 + lastFee0, charged1 + lastFee1, calls + lastCalls);
        advanceTime(300);
        _swapChecked(false, type(int128).max >> 8, _limitAt(-30 * S));
        (charged0, charged1, calls) = (charged0 + lastFee0, charged1 + lastFee1, calls + lastCalls);
        _swapChecked(true, -2e18, SqrtRatio.wrap(0));
        (charged0, charged1, calls) = (charged0 + lastFee0, charged1 + lastFee1, calls + lastCalls);
        assertGt(charged0, 0);
        assertGt(charged1, 0);

        bytes24[3] memory salts = [bytes24(uint192(1)), bytes24(uint192(2)), bytes24(uint192(3))];
        int32[3] memory los = [-40 * S, 2 * S, 5 * S];
        int32[3] memory his = [-2 * S, 40 * S, 6 * S];
        int128[3] memory liqs = [L66, L66, L66 * 4];
        uint256 extra0;
        uint256 extra1;
        for (uint256 i; i < 3; i++) {
            (uint128 p0, uint128 p1) = _collect(pool, salts[i], los[i], his[i]);
            (uint128 t0, uint128 t1) = _collect(twin, salts[i], los[i], his[i]);
            assertGe(p0 + 4 * calls, t0, "v2.1 collects at least the twin's pool fees (R2)");
            assertGe(p1 + 4 * calls, t1, "v2.1 collects at least the twin's pool fees (R2)");
            extra0 += p0 > t0 ? p0 - t0 : 0;
            extra1 += p1 > t1 ? p1 - t1 : 0;
            _lp(salts[i], los[i], his[i], -liqs[i]);
        }
        // R2 allowance on the pool fee per cut plus R5 dust (A accumulations, 3 positions, 1 checkpoint)
        uint256 slack = 4 * calls + calls + 3;
        assertApproxEqAbs(extra0, charged0, slack, "surcharge token0 collected by the LPs");
        assertApproxEqAbs(extra1, charged1, slack, "surcharge token1 collected by the LPs");
        // both pools empty: only rounding dust may remain in Core
        assertLe(token0.balanceOf(address(core)), 64 + slack, "token0 stranded");
        assertLe(token1.balanceOf(address(core)), 64 + slack, "token1 stranded");
    }

    function test_narrow_jit_pays_schedule_per_unit() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        // the arb adds narrow liquidity in segment 4 before swapping through it
        _lp(bytes24(uint192(2)), 3 * S, 4 * S, L66 * 2);
        _swapChecked(true, type(int128).max >> 8, _limitAt(3 * S));
        uint256 before0 = core.getPoolFeesPerLiquidityInside(pool.toPoolId(), 3 * S, 4 * S).value0;
        _swapChecked(true, type(int128).max >> 8, _limitAt(4 * S));
        uint256 after0 = core.getPoolFeesPerLiquidityInside(pool.toPoolId(), 3 * S, 4 * S).value0;
        // segment 4 on the grid from anchor 0: sur = ceil(2 * poolFee * 3.5) = 7 * poolFee; one charged cut call and
        // one uncharged bridge over 4S
        assertEq(lastCharged, 1);
        assertEq(lastBridges, 1);
        assertEq(actor.refCall(0).sur, 7 * poolFee, "segment 4 rate");
        uint256 accrued = ((after0 - before0) * uint256(uint128(L66 * 3))) >> 128;
        assertApproxEqAbs(accrued, lastFee0, 2, "fees per unit liquidity follow the schedule");
        (uint128 honest,) = _collect(pool, bytes24(uint192(1)), -40 * S, 40 * S);
        (uint128 arb,) = _collect(pool, bytes24(uint192(2)), 3 * S, 4 * S);
        assertGt(honest, 0);
        assertApproxEqAbs(uint256(arb), 2 * (accrued / 3), 2, "the JIT position gets its pro-rata share only");
    }

    // ================================================================ inv 10: toward is free, exact-out same schedule

    function test_toward_pays_pool_fee_only() public {
        _standard();
        _swapChecked(true, type(int128).max >> 8, _limitAt(10 * S));
        assertGt(lastFee0, 0);
        _swapChecked(false, type(int128).max >> 8, _limitAt(2 * S));
        assertEq(lastCalls, 1, "toward travel is one Core call");
        assertEq(lastCharged, 0);
        assertEq(lastFee0 + lastFee1, 0, "toward travel pays the pool fee only");
        assertEq(actor.refCall(0).kind, 1);
    }

    /// @notice Invariant 10 on `main`: an exact-out of the exact-in's net output pays the same per-segment rates and
    ///   never more input; the input differs by the spec's O(fee^2) terms between the output-side (exact-in) and the
    ///   net-input gross-up (exact-out) conventions: `sur * poolFee` (the surcharge is grossed up on the net input, not
    ///   on the pool fee) plus `sur * u` from the curve's convexity, `u` the relative sqrt-price move
    function test_exact_out_follows_same_schedule(uint256 amountSeed) public {
        _standard();
        (PoolKey memory other, MEVCaptureV21 ext) = createOtherPool(FEE_30BP, SP, 0, 1);
        _lpOn(other, bytes24(uint192(1)), -40 * S, 40 * S, L66);

        int128 amountIn = int128(uint128(bound(amountSeed, 1e15, 3e18)));
        uint256 sqrtBefore = _poolState().sqrtRatio().toFixed();
        (PoolBalanceUpdate exactIn, PoolState stAfter) = _swapChecked(true, amountIn);
        uint256 calls = lastCalls;
        uint256 maxSur;
        for (uint256 i; i < calls; i++) {
            uint256 s = actor.refCall(i).sur;
            if (s > maxSur) maxSur = s;
        }
        (PoolBalanceUpdate exactOut,) = _swapRawOn(other, ext, _params(false, exactIn.delta0(), SqrtRatio.wrap(0)));
        assertEq(exactOut.delta0(), exactIn.delta0());
        uint256 inIn = uint256(uint128(exactIn.delta1()));
        uint256 inOut = uint256(uint128(exactOut.delta1()));
        uint256 rounding = 8 * calls + 8;
        assertLe(inOut, inIn + rounding, "exact-out never pays more than exact-in");
        uint256 sqrtAfter = stAfter.sqrtRatio().toFixed();
        // inIn - inOut <= inIn * sur * (poolFee + 2u) + rounding, all rates in 0.64
        uint256 u64 = ((sqrtAfter - sqrtBefore) << 64) / sqrtAfter;
        uint256 bound_ = (((inIn * maxSur) >> 64) * (poolFee + 2 * u64)) >> 64;
        assertLe(inIn - inOut, bound_ + rounding, "same schedule up to O(fee^2)");
        assertGt(inOut, inIn - inIn / 100, "sanity: within 1%");
    }

    // ================================================================ inv 13, 14: reference inflation and decay

    function test_flash_lref_inflation_one_lock() public {
        _standard();
        _warmReference();
        uint256 honest = _lRefBits();
        advanceTime(12);
        PositionId pid = _pid(bytes24(uint192(99)), -S, S);
        int128 big = int128(pool.config.concentratedMaxLiquidityPerTick() - uint128(L66) - 1);
        V21Actor.Action[] memory acts = new V21Actor.Action[](3);
        acts[0] = _action(0, pool, PositionId.unwrap(pid), big, address(0));
        acts[1] = _action(1, pool, SwapParameters.unwrap(_params(false, 1, SqrtRatio.wrap(0))), 0, address(v21));
        acts[2] = _action(0, pool, PositionId.unwrap(pid), -big, address(0));
        actor.run(acts);
        assertEq(_lRefBits(), honest, "flash liquidity never raises the reference");
        assertEq(_state(pool).snapBits, honest);
        advanceTime(12);
        _swapChecked(true, 1e15);
        assertFalse(lastGateFailed, "next honest swap passes");
    }

    function _exitReopen(int128 remaining) internal returns (uint256 reopenAfter) {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, L66);
        _warmReference();
        uint32 lastPass = _state(pool).lRefTime;
        _lp(bytes24(uint192(1)), -40 * S, 40 * S, -(L66 - remaining));
        for (uint256 i = 1; i < 200; i++) {
            advanceTime(12);
            this.swapCheckedExt(i % 2 == 0, 1e9, SqrtRatio.wrap(0));
            if (!lastGateFailed) return _now() - lastPass;
        }
        revert("never reopened");
    }

    function test_reference_decay_exit_to_one_sixteenth_reopens_after_one_tau() public {
        assertEq(_exitReopen(int128(1) << 62), 120);
    }

    function test_reference_decay_exit_to_one_1024th_reopens_after_seven_tau() public {
        assertEq(_exitReopen(int128(1) << 56), 840);
    }

    // ================================================================ inv 15: the away loop

    function test_toward_far_is_one_call() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -400 * S, 400 * S, L66);
        _swapChecked(false, type(int128).max >> 8, _limitAt(-150 * S));
        advanceTime(12);
        _swapChecked(true, type(int128).max >> 8, _limitAt(-10 * S));
        assertTrue(lastWasFirst);
        assertEq(lastCalls, 1, "toward across >100 W is a single Core call");
        assertEq(lastFee0 + lastFee1, 0);
    }

    function test_no_zero_length_calls_on_boundaries() public {
        _standard();
        // make +-3s initialized ticks so a decreasing stop there reports tick - 1
        _lp(bytes24(uint192(2)), 3 * S, 10 * S, 1e9);
        _lp(bytes24(uint192(3)), -10 * S, -3 * S, 1e9);
        // end exactly on boundary 3s with the user limit: segments 1, 2, the cut before 3s and the bridge onto it
        _swapChecked(true, type(int128).max >> 8, _limitAt(3 * S));
        assertEq(lastCalls, 4);
        assertEq(lastBridges, 1);
        assertEq(_poolState().tick(), 3 * S);
        // start exactly on a boundary (and on an initialized tick in the increasing tick state): segments 4, 5
        _swapChecked(true, type(int128).max >> 8, _limitAt(5 * S));
        assertEq(lastCalls, 2);
        assertEq(lastBridges, 0);
        // go up, come back down toward the anchor exactly onto boundary 3s (Core then reports tick 3s - 1)
        _swapChecked(true, type(int128).max >> 8, _limitAt(6 * S));
        _swapChecked(false, type(int128).max >> 8, _limitAt(3 * S));
        assertEq(_poolState().tick(), 3 * S - 1);
        // exact-tick state: the zero-width crossing of 3s happens inside the first charged call, no bridge
        _swapChecked(true, type(int128).max >> 8, _limitAt(5 * S));
        assertEq(lastCalls, 2, "boundary the price sits on is skipped");
        assertEq(lastBridges, 0);
        // mirrored: approach -3s from below (toward), then go away downward
        _swapChecked(false, type(int128).max >> 8, _limitAt(-6 * S));
        _swapChecked(true, type(int128).max >> 8, _limitAt(-3 * S));
        assertEq(_poolState().tick(), -3 * S, "increasing stop on an initialized tick reports the tick");
        _swapChecked(false, type(int128).max >> 8, _limitAt(-5 * S));
        assertEq(lastCalls, 2);
        assertEq(lastBridges, 0);
    }

    /// @notice After the surcharge reaches the cap the rate cuts stop, but tick cuts and bridges continue (no "merge
    ///   the rest" branch)
    function test_no_cut_removal_after_cap() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -20_000 * S, 20_000 * S, int128(1) << 40);
        // an initialized tick far beyond the cap
        _lp(bytes24(uint192(2)), 3000 * S, 3001 * S, 1e9);
        _swapChecked(true, type(int128).max >> 8);
        uint256 n = lastCalls;
        uint256 cap = cfg.maxFee - poolFee;
        uint256 firstCapped = type(uint256).max;
        uint256 rateCalls;
        for (uint256 i; i < n; i++) {
            V21Actor.RefCall memory r = actor.refCall(i);
            if (r.kind == 0 && r.sur == cap && firstCapped == type(uint256).max) firstCapped = i;
            if (r.kind == 0 && r.sur != cap) rateCalls++;
            if (r.kind == 0 && i > firstCapped) assertEq(r.sur, cap, "capped from the first capped call on");
        }
        assertTrue(firstCapped != type(uint256).max, "cap reached");
        assertLe(rateCalls, cfg.jLin + 28);
        // 3000S, 3001S and the wide range's upper end at 20000S are all crossed after the cap, each by its own bridge
        assertEq(lastBridges, 3, "every initialized tick beyond the cap is bridged");
        assertEq(SqrtRatio.unwrap(actor.refCall(n - 1).limit), SqrtRatio.unwrap(MAX_SQRT_RATIO), "ends at MAX");
    }

    /// @notice Sparse pool: every away segment is empty except far away; the call count obeys 1 + R + 2I + U + 1
    function test_sparse_pool_calls_bounded() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -400 * S, -300 * S, L66);
        _lp(bytes24(uint192(2)), 300 * S, 400 * S, L66);
        _swapChecked(true, 1e18);
        assertLe(lastCalls, 2 + cfg.jLin + 28 + 2 * 2);
        assertEq(lastBridges, 1, "crosses into the far range");
    }

    // ================================================================ inv 16: checked sums

    function test_large_amounts_never_wrap(uint128 amountSeed, bool isToken1, bool exactOut) public {
        createPools(FEE_30BP, SP, 0);
        int128 big = int128(pool.config.concentratedMaxLiquidityPerTick() / 2);
        _lp(bytes24(uint192(1)), -400 * S, 400 * S, big);
        int128 amount = int128(uint128(bound(amountSeed, uint128(1) << 120, (uint128(1) << 127) - 1)));
        if (exactOut) amount = -amount;
        uint256 b0 = token0.balanceOf(address(this));
        uint256 b1 = token1.balanceOf(address(this));
        try this.externalSwap(isToken1, amount) returns (PoolBalanceUpdate u) {
            // no wrap: the deltas are exactly what moved
            assertEq(int256(b0) - int256(token0.balanceOf(address(this))), u.delta0());
            assertEq(int256(b1) - int256(token1.balanceOf(address(this))), u.delta1());
            int128 specified = isToken1 ? u.delta1() : u.delta0();
            if (exactOut) assertTrue(specified <= 0 && specified >= amount);
            else assertTrue(specified >= 0 && specified <= amount);
        } catch {}
    }

    function externalSwap(bool isToken1, int128 amount) external returns (PoolBalanceUpdate u) {
        (u,) = _swapRaw(isToken1, amount, SqrtRatio.wrap(0), 0);
    }

    // ================================================================ inv 17, 18, 19: H1

    function test_h1_one_block_inflation() public {
        _standard();
        _warmReference();
        uint256 honest = _lRefBits();
        // end of t-1: +20 bits at the price
        _lp(bytes24(uint192(50)), -S, S, L66 << 20);
        advanceTime(12);
        _swapChecked(false, 1); // observes the inflated liquidity
        _lp(bytes24(uint192(50)), -S, S, -(L66 << 20)); // removed in the same timestamp
        assertLe(_lRefBits(), honest + 1, "reference rises at most one bit");
        advanceTime(12);
        _swapChecked(true, 1e15);
        assertFalse(lastGateFailed, "next honest swap passes");
    }

    function _sustained(uint256 nTau) internal returns (uint256 frozen) {
        _standard();
        _warmReference();
        _lp(bytes24(uint192(50)), -S, S, L66 << 20);
        uint32 start = _now();
        while (_now() < start + nTau * cfg.tau) {
            advanceTime(12);
            this.swapCheckedExt(false, 1, SqrtRatio.wrap(0));
        }
        _lp(bytes24(uint192(50)), -S, S, -(L66 << 20));
        uint32 removed = _now();
        for (uint256 i; i < 400; i++) {
            advanceTime(12);
            this.swapCheckedExt(i % 2 == 0, 1e9, SqrtRatio.wrap(0));
            if (!lastGateFailed) return _now() - removed;
        }
        revert("never reopened");
    }

    function _checkSustained(uint256 n) internal {
        uint256 frozen = _sustained(n);
        uint256 bound_ = n > 3 ? (n - 3) * cfg.tau : 0;
        assertLe(frozen, bound_ + 12, "freeze <= (n - 3)+ tau");
    }

    function test_h1_sustained_inflation_1_tau() public {
        _checkSustained(1);
    }

    function test_h1_sustained_inflation_4_tau() public {
        _checkSustained(4);
    }

    function test_h1_sustained_inflation_16_tau() public {
        _checkSustained(16);
    }

    function test_h1_honest_growth_never_fails() public {
        _standard();
        _warmReference();
        _lp(bytes24(uint192(51)), -40 * S, 40 * S, L66 << 20);
        uint256 prevBits = _lRefBits();
        uint32 prevRaise = _state(pool).raiseTime;
        for (uint256 i; i < 60; i++) {
            advanceTime(60);
            this.swapCheckedExt(i % 2 == 0, 1e12, SqrtRatio.wrap(0));
            assertFalse(lastGateFailed, "honest growth never fails the gate");
            V21Ref.State memory s = _state(pool);
            assertLe(s.lRefBits, prevBits + 1);
            if (s.lRefBits > prevBits) assertGe(s.raiseTime - prevRaise, cfg.tau, "at most one bit per tau");
            prevBits = s.lRefBits;
            prevRaise = s.raiseTime;
        }
        assertEq(_lRefBits(), V21Ref.bitlen(uint128(L66) + (uint128(L66) << 20)), "reference caught up");
    }

    // ================================================================ inv 21: N1 fractional anchor

    function test_n1_fractional_anchor_sliver() public {
        _standard();
        _swapChecked(true, type(int128).max >> 8, _limitAt(300));
        advanceTime(12);
        _swapChecked(false, 1, SqrtRatio.wrap(0));
        int256 a = _anchor();
        assertTrue(a & 0xffff != 0, "anchor has a fractional part");
        int256 ceilTick = (a + 0xffff) >> 16;
        // down from ~300 toward the anchor and past it: toward to ceil(anchor), then sliver + away at segment 1 rate
        _swapChecked(false, type(int128).max >> 8, _limitAt(-2 * S - 77));
        V21Actor.RefCall memory toward = actor.refCall(0);
        assertEq(toward.kind, 1);
        assertEq(SqrtRatio.unwrap(toward.limit), SqrtRatio.unwrap(tickToSqrtRatio(int32(ceilTick))));
        V21Actor.RefCall memory first = actor.refCall(1);
        // segment 1 (decreasing): from the exact anchor down to grid point 0
        uint256 den = uint256(SP) << 18;
        uint256 expected = (4 * poolFee * uint256(a) + den - 1) / den;
        assertEq(first.kind, 0);
        assertEq(first.sur, expected, "sliver charged at the first away segment's rate, mid from exact anchor");
        assertEq(SqrtRatio.unwrap(first.limit), SqrtRatio.unwrap(tickToSqrtRatio(0)));
        // selling token0 (exact-in, decreasing): the output and the surcharge are token1
        assertGt(first.fee1, 0, "exact-in decreasing: the surcharge is taken from the token1 output");
        assertEq(first.fee0, 0);
    }

    /// @notice Rev 6 (EKU-1034 Q1): a pool touched less often than tau keeps its warmed reference, so per-timestamp
    ///   empty-range parking still freezes the anchor (with an event per update) instead of dragging it
    function test_quiet_pool_reference_holds_and_j1_freezes() public {
        _edgePool();
        uint256 warmed = _lRefBits();
        for (uint256 i; i < 60; i++) {
            advanceTime(360);
            this.swapCheckedExt(i % 2 == 0, 1, SqrtRatio.wrap(0));
            assertEq(_lRefBits(), warmed, "reference holds on a pool touched every 3 tau");
        }
        int256 a0 = _anchor();
        uint256 failures;
        for (uint256 i; i < 30; i++) {
            this.swapCheckedExt(true, type(int128).max >> 8, _limitAt(50_000));
            advanceTime(12);
            this.swapCheckedExt(false, type(int128).max >> 8, _limitAt(0));
            if (lastGateFailed) failures++;
        }
        assertEq(failures, 30, "gate fails on every parked update");
        assertEq(_anchor(), a0, "anchor frozen, not dragged");
    }

    /// @notice Warm-up correction: from init the reference rises one bit per touch when touches are >= tau apart
    function test_quiet_pool_warmup_one_bit_per_touch() public {
        createPools(FEE_30BP, SP, 0);
        _lp(bytes24(uint192(1)), -40 * S, 2 * S, L66);
        for (uint256 i = 1; i <= 20; i++) {
            advanceTime(360);
            this.swapCheckedExt(i % 2 == 0, 1, SqrtRatio.wrap(0));
            assertEq(_lRefBits(), i);
        }
    }

    /// @notice Rev 6 residual: honest liquidity fell by D bits while the pool was idle; an attacker holding liquidity
    ///   across one boundary restores the stored reference, freezing the anchor for at most (D - 3)+ tau
    function _idleDropRestore(uint256 d) internal returns (uint256 frozen) {
        _edgePool();
        uint256 stored = _lRefBits();
        _lp(bytes24(uint192(1)), -40 * S, 2 * S, -(L66 - (L66 >> d)));
        advanceTime(3600 - 1);
        _lp(bytes24(uint192(60)), -S, S, L66); // held across the boundary into the next timestamp
        advanceTime(1);
        this.swapCheckedExt(false, 1, SqrtRatio.wrap(0));
        assertFalse(lastGateFailed);
        assertEq(_lRefBits(), stored, "restored to the stored reference, not above");
        _lp(bytes24(uint192(60)), -S, S, -L66);
        uint32 removed = _now();
        for (uint256 i; i < 400; i++) {
            advanceTime(12);
            this.swapCheckedExt(i % 2 == 0, 1e9, SqrtRatio.wrap(0));
            if (!lastGateFailed) return _now() - removed;
        }
        revert("never reopened");
    }

    function test_idle_drop_restore_bound_6_bits() public {
        uint256 frozen = _idleDropRestore(6);
        assertLe(frozen, 3 * cfg.tau);
        assertGe(frozen, 3 * cfg.tau - 12, "restore actually happened");
    }

    function test_idle_drop_restore_bound_20_bits() public {
        uint256 frozen = _idleDropRestore(20);
        assertLe(frozen, 17 * cfg.tau);
        assertGe(frozen, 17 * cfg.tau - 12, "restore actually happened");
    }

    // ================================================================ inv 22 / J1

    function test_j1_per_timestamp_parking_freezes_anchor_with_events() public {
        _edgePool();
        int256 a0 = _anchor();
        uint256 failures;
        for (uint256 i; i < 30; i++) {
            // park in the empty range, next timestamp return as the first touch
            this.swapCheckedExt(true, type(int128).max >> 8, _limitAt(50_000));
            advanceTime(12);
            this.swapCheckedExt(false, type(int128).max >> 8, _limitAt(0));
            if (lastGateFailed) failures++;
        }
        assertEq(failures, 30, "gate fails on every update");
        assertEq(_anchor(), a0, "anchor frozen, not dragged");
    }
}
