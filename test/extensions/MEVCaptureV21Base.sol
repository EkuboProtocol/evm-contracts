// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {Router} from "../../src/Router.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PositionId, createPositionId} from "../../src/types/positionId.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {MEVCaptureV21, mevCaptureV21CallPoints} from "../../src/extensions/MEVCaptureV21.sol";
import {IMEVCaptureV21} from "../../src/interfaces/extensions/IMEVCaptureV21.sol";
import {V21Ref, V21Actor} from "./MEVCaptureV21Helpers.sol";

/// @notice Shared setup: a v2.1 pool plus a twin pool without extension that mirrors every position. Every swap made
///   through `_swapChecked` is replayed on the twin by the independent reference state machine and must match exactly:
///   balance deltas, the pool state after, the extension state, the Core call sequence (swap limits and amounts, the
///   `accumulateAsFees` amounts after each charged call), the `FeesAccumulated` events and the gate event.
abstract contract MEVCaptureV21Base is FullTest {
    using CoreLib for *;

    bytes32 internal constant GATE_FAILED_TOPIC = keccak256("AnchorGateFailed(bytes32,uint8,uint8)");
    bytes32 internal constant FEES_ACCUMULATED_TOPIC = keccak256("FeesAccumulated(bytes32,uint128,uint128)");

    uint64 internal constant FEE_30BP = 55340232221128654; // 0.30% as a 0.64 number (floor)
    uint64 internal constant FEE_1BP = 1844674407370955; // 0.01%
    uint64 internal constant FEE_25PCT = uint64(1) << 62;

    MEVCaptureV21 internal v21;
    V21Actor internal actor;
    V21Ref.Cfg internal cfg;

    PoolKey internal pool;
    PoolKey internal twin;
    uint256 internal poolFee;
    uint256 internal spacing;

    /// @notice Number of Core swap calls the last checked swap made
    uint256 internal lastCalls;
    /// @notice Number of charged, toward and bridge calls of the last checked swap
    uint256 internal lastCharged;
    uint256 internal lastBridges;
    /// @notice Total surcharge the last checked swap charged, per token
    uint256 internal lastFee0;
    uint256 internal lastFee1;
    /// @notice Whether the last checked swap ran a gate that failed
    bool internal lastGateFailed;
    /// @notice Whether the last checked swap was the first of its timestamp
    bool internal lastWasFirst;

    function setUp() public virtual override {
        FullTest.setUp();
        cfg = V21Ref.defaults();
        v21 = deployV21(cfg, 0);
        router = new Router(core, address(v21), address(0));
        actor = new V21Actor(core, address(this));
        token0.approve(address(actor), type(uint256).max);
        token1.approve(address(actor), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
    }

    function deployV21(V21Ref.Cfg memory c, uint160 index) internal returns (MEVCaptureV21 ext) {
        address a = address((uint160(mevCaptureV21CallPoints().toUint8()) << 152) + 0x1000 + index);
        deployCodeTo(
            "MEVCaptureV21.sol:MEVCaptureV21",
            abi.encode(core, c.tau, c.slopeK, c.segExp, c.jLin, c.maxFee, c.clamp, c.mGate),
            a
        );
        ext = MEVCaptureV21(a);
    }

    function useExtension(MEVCaptureV21 ext, V21Ref.Cfg memory c) internal {
        v21 = ext;
        cfg = c;
    }

    function createPools(uint64 fee, uint32 tickSpacing, int32 tick) internal {
        pool = createPool(
            address(token0), address(token1), tick, createConcentratedPoolConfig(fee, tickSpacing, address(v21))
        );
        twin = createPool(
            address(token0), address(token1), tick, createConcentratedPoolConfig(fee, tickSpacing, address(0))
        );
        poolFee = fee;
        spacing = tickSpacing;
    }

    /// @notice A second v2.1 pool with the same tokens and config on another extension instance (pools on `main`
    ///   have no salt)
    function createOtherPool(uint64 fee, uint32 tickSpacing, int32 tick, uint160 index)
        internal
        returns (PoolKey memory other, MEVCaptureV21 ext)
    {
        ext = deployV21(cfg, index);
        other = createPool(
            address(token0), address(token1), tick, createConcentratedPoolConfig(fee, tickSpacing, address(ext))
        );
    }

    // ------------------------------------------------------------------ state helpers

    function _state(PoolKey memory pk) internal view returns (V21Ref.State memory s) {
        return _state(v21, pk);
    }

    function _state(MEVCaptureV21 ext, PoolKey memory pk) internal view returns (V21Ref.State memory s) {
        uint8 refBits;
        uint8 snap;
        int64 anchor;
        (s.lastUpdateTime, s.lRefTime, s.lastPosTime, refBits, snap, s.raiseTime, anchor) = ext.getAnchor(pk.toPoolId());
        s.lRefBits = refBits;
        s.snapBits = snap;
        s.anchorX16 = anchor;
    }

    function _assertStateEq(V21Ref.State memory a, V21Ref.State memory b) internal pure {
        assertEq(a.lastUpdateTime, b.lastUpdateTime, "lastUpdateTime");
        assertEq(a.lRefTime, b.lRefTime, "lRefTime");
        assertEq(a.lastPosTime, b.lastPosTime, "lastPosTime");
        assertEq(a.lRefBits, b.lRefBits, "lRefBits");
        assertEq(a.snapBits, b.snapBits, "snapBits");
        assertEq(a.raiseTime, b.raiseTime, "lRefRaiseTime");
        assertEq(a.anchorX16, b.anchorX16, "anchorX16");
    }

    function _anchor() internal view returns (int256) {
        return _state(pool).anchorX16;
    }

    function _lRefBits() internal view returns (uint256) {
        return _state(pool).lRefBits;
    }

    function _now() internal view returns (uint32) {
        return uint32(vm.getBlockTimestamp());
    }

    function _poolState() internal view returns (PoolState) {
        return core.poolState(pool.toPoolId());
    }

    // ------------------------------------------------------------------ position helpers

    function _action(uint8 kind, PoolKey memory pk, bytes32 a, int256 b, address target)
        internal
        pure
        returns (V21Actor.Action memory)
    {
        return V21Actor.Action({kind: kind, poolKey: pk, a: a, b: b, target: target});
    }

    function _pid(bytes24 salt, int32 lo, int32 hi) internal pure returns (PositionId) {
        return createPositionId(salt, lo, hi);
    }

    /// @notice Updates a position on the v2.1 pool and the twin, checking the snapshot hook against the reference
    function _lp(bytes24 salt, int32 lo, int32 hi, int128 liquidityDelta) internal {
        V21Ref.State memory s = _state(pool);
        V21Ref.positionHook(s, _poolState().liquidity(), _now());
        V21Actor.Action[] memory acts = new V21Actor.Action[](2);
        acts[0] = _action(0, pool, PositionId.unwrap(_pid(salt, lo, hi)), liquidityDelta, address(0));
        acts[1] = _action(0, twin, PositionId.unwrap(_pid(salt, lo, hi)), liquidityDelta, address(0));
        actor.run(acts);
        _assertStateEq(_state(pool), s);
    }

    /// @notice Updates a position on one pool only (no twin)
    function _lpOn(PoolKey memory pk, bytes24 salt, int32 lo, int32 hi, int128 liquidityDelta) internal {
        V21Actor.Action[] memory acts = new V21Actor.Action[](1);
        acts[0] = _action(0, pk, PositionId.unwrap(_pid(salt, lo, hi)), liquidityDelta, address(0));
        actor.run(acts);
    }

    function _collect(PoolKey memory pk, bytes24 salt, int32 lo, int32 hi) internal returns (uint128 f0, uint128 f1) {
        V21Actor.Action[] memory acts = new V21Actor.Action[](1);
        acts[0] = _action(3, pk, PositionId.unwrap(_pid(salt, lo, hi)), 0, address(0));
        (f0, f1) = abi.decode(actor.run(acts)[0], (uint128, uint128));
    }

    // ------------------------------------------------------------------ swap helpers

    function _params(bool isToken1, int128 amount, SqrtRatio limit) internal pure returns (SwapParameters) {
        return _params(isToken1, amount, limit, 0);
    }

    function _params(bool isToken1, int128 amount, SqrtRatio limit, uint256 skipAhead)
        internal
        pure
        returns (SwapParameters)
    {
        return
            createSwapParameters({_sqrtRatioLimit: limit, _amount: amount, _isToken1: isToken1, _skipAhead: skipAhead});
    }

    /// @notice Unchecked forwarded swap through the actor (no reference replay)
    function _swapRaw(bool isToken1, int128 amount, SqrtRatio limit, uint256 skipAhead)
        internal
        returns (PoolBalanceUpdate u, PoolState st)
    {
        return _swapRawOn(pool, v21, _params(isToken1, amount, limit, skipAhead));
    }

    function _swapRawOn(PoolKey memory pk, MEVCaptureV21 ext, SwapParameters p)
        internal
        returns (PoolBalanceUpdate u, PoolState st)
    {
        V21Actor.Action[] memory acts = new V21Actor.Action[](1);
        acts[0] = _action(1, pk, SwapParameters.unwrap(p), 0, address(ext));
        (u, st) = abi.decode(actor.run(acts)[0], (PoolBalanceUpdate, PoolState));
    }

    function _swapChecked(bool isToken1, int128 amount, SqrtRatio limit)
        internal
        returns (PoolBalanceUpdate u, PoolState st)
    {
        return _swapChecked(isToken1, amount, limit, 0);
    }

    /// @notice Forwarded swap checked against the reference model on the twin pool
    function _swapChecked(bool isToken1, int128 amount, SqrtRatio limit, uint256 skipAhead)
        internal
        returns (PoolBalanceUpdate u, PoolState st)
    {
        PoolState before = _poolState();
        assertEq(
            PoolState.unwrap(before), PoolState.unwrap(core.poolState(twin.toPoolId())), "twin diverged before swap"
        );

        V21Ref.State memory s = _state(pool);
        uint32 nowT = _now();
        lastWasFirst = s.lastUpdateTime != nowT;
        int256 anchorBefore = s.anchorX16;
        uint256 dtBefore;
        unchecked {
            dtBefore = uint32(nowT - s.lastUpdateTime);
        }
        bool passed = true;
        uint256 lObs;
        uint256 eRef;
        if (lastWasFirst) (passed, lObs, eRef) = V21Ref.anchorUpdate(cfg, s, before.tick(), before.liquidity(), nowT);

        SwapParameters p = _params(isToken1, amount, limit, skipAhead);
        (PoolBalanceUpdate ur, PoolState str) = actor.runReference(cfg, twin, p, s.anchorX16, poolFee, spacing);
        uint256 nCalls = actor.refCallsLength();

        vm.recordLogs();
        vm.startStateDiffRecording();
        (u, st) = _swapRaw(isToken1, amount, limit, skipAhead);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _checkCoreCalls(accesses, nCalls);
        _checkEvents(logs, passed, lObs, eRef);
        _afterSwapTrace(accesses, logs, before, p);

        assertEq(PoolBalanceUpdate.unwrap(u), PoolBalanceUpdate.unwrap(ur), "balance update vs reference");
        assertEq(PoolState.unwrap(st), PoolState.unwrap(str), "state after vs reference");

        if (lastWasFirst) _checkDecay(anchorBefore, s.anchorX16, before.tick(), dtBefore, passed);
        V21Ref.refresh(cfg, s, st.liquidity(), nowT);
        _assertStateEq(_state(pool), s);
        lastCalls = nCalls;
    }

    /// @notice Hook for tests that check the recorded Core calls and logs of a checked swap directly against Core's
    ///   state, independently of the reference model
    function _afterSwapTrace(Vm.AccountAccess[] memory, Vm.Log[] memory, PoolState, SwapParameters) internal virtual {}

    /// @notice The extension must make exactly the reference's Core swap calls (limit, amount, in order), call
    ///   `accumulateAsFees` with the reference's surcharge right after each charged call with a nonzero fee and never
    ///   otherwise, and never update a position from the forwarded handler (G1 a)
    function _checkCoreCalls(Vm.AccountAccess[] memory accesses, uint256 nCalls) internal {
        uint256 seen;
        uint256 charged;
        uint256 bridges;
        uint256 fee0;
        uint256 fee1;
        bool expectFees;
        uint128 expectFee0;
        uint128 expectFee1;
        for (uint256 i; i < accesses.length; i++) {
            Vm.AccountAccess memory a = accesses[i];
            if (a.kind != VmSafe.AccountAccessKind.Call || a.account != address(core) || a.accessor != address(v21)) {
                continue;
            }
            bytes4 sel = bytes4(a.data);
            assertTrue(sel != ICore.updatePosition.selector, "forwarded handler called updatePosition");
            if (sel == ICore.accumulateAsFees.selector) {
                assertTrue(expectFees, "accumulateAsFees without a preceding charged call");
                (, uint128 f0, uint128 f1) = abi.decode(_slice(a.data), (PoolKey, uint128, uint128));
                assertEq(f0, expectFee0, "accumulateAsFees amount0");
                assertEq(f1, expectFee1, "accumulateAsFees amount1");
                assertTrue(f0 != 0 || f1 != 0, "accumulateAsFees with zero amounts");
                expectFees = false;
                continue;
            }
            if (sel != bytes4(0)) continue;
            assertFalse(expectFees, "charged call not followed by accumulateAsFees");
            SwapParameters p;
            bytes memory d = a.data;
            assembly ("memory-safe") {
                p := mload(add(d, 132))
            }
            V21Actor.RefCall memory r = actor.refCall(seen);
            assertEq(SqrtRatio.unwrap(p.sqrtRatioLimit()), SqrtRatio.unwrap(r.limit), "call limit");
            assertEq(p.amount(), r.amount, "call amount");
            if (r.kind == 0) charged++;
            if (r.kind == 2) bridges++;
            fee0 += r.fee0;
            fee1 += r.fee1;
            if (r.fee0 != 0 || r.fee1 != 0) {
                expectFees = true;
                expectFee0 = r.fee0;
                expectFee1 = r.fee1;
            }
            seen++;
        }
        assertFalse(expectFees, "last charged call not followed by accumulateAsFees");
        assertEq(seen, nCalls, "number of Core swap calls");
        lastCharged = charged;
        lastBridges = bridges;
        lastFee0 = fee0;
        lastFee1 = fee1;
    }

    function _checkEvents(Vm.Log[] memory logs, bool passed, uint256 lObs, uint256 eRef) internal {
        uint256 gateEvents;
        uint256 feeEvents;
        uint256 f0Sum;
        uint256 f1Sum;
        for (uint256 i; i < logs.length; i++) {
            // Core's Swapped is a log0
            if (logs[i].topics.length == 0) continue;
            if (logs[i].emitter == address(v21) && logs[i].topics[0] == GATE_FAILED_TOPIC) {
                gateEvents++;
                bytes32 pid = logs[i].topics[1];
                (uint8 lo, uint8 er) = abi.decode(logs[i].data, (uint8, uint8));
                assertEq(pid, PoolId.unwrap(pool.toPoolId()), "event pool");
                assertEq(lo, lObs, "event lObs");
                assertEq(er, eRef, "event eRef");
            } else if (logs[i].emitter == address(core) && logs[i].topics[0] == FEES_ACCUMULATED_TOPIC) {
                feeEvents++;
                (bytes32 pid, uint128 f0, uint128 f1) = abi.decode(logs[i].data, (bytes32, uint128, uint128));
                assertEq(pid, PoolId.unwrap(pool.toPoolId()), "FeesAccumulated pool");
                f0Sum += f0;
                f1Sum += f1;
            }
        }
        lastGateFailed = !passed;
        assertEq(gateEvents, lastWasFirst && !passed ? 1 : 0, "AnchorGateFailed emitted iff the gate failed");
        assertEq(f0Sum, lastFee0, "FeesAccumulated total 0");
        assertEq(f1Sum, lastFee1, "FeesAccumulated total 1");
    }

    function _slice(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }

    /// @notice Invariant 2: same sign, |offset| non-increasing, |move| <= CLAMP * min(dt, tau) / tau, no move on a fail
    function _checkDecay(int256 a0, int256 a1, int32 tick, uint256 dt, bool passed) internal view {
        if (!passed) {
            assertEq(a1, a0, "anchor moved on a failed gate");
            return;
        }
        int256 t16 = int256(tick) << 16;
        int256 o0 = a0 - t16;
        int256 o1 = a1 - t16;
        assertTrue(o1 == 0 || (o0 < 0) == (o1 < 0), "decay changed sign");
        assertLe(_abs(o1), _abs(o0), "offset grew");
        uint256 lim = (cfg.clamp << 16) * (dt < cfg.tau ? dt : cfg.tau) / cfg.tau;
        assertLe(_abs(a1 - a0), lim, "move beyond clamp");
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    /// @notice External wrapper so long loops do not accumulate memory in one frame
    function swapCheckedExt(bool isToken1, int128 amount, SqrtRatio limit)
        external
        returns (PoolBalanceUpdate u, PoolState st)
    {
        require(msg.sender == address(this));
        return _swapChecked(isToken1, amount, limit, 0);
    }

    function _swapChecked(bool isToken1, int128 amount) internal returns (PoolBalanceUpdate u, PoolState st) {
        return _swapChecked(isToken1, amount, SqrtRatio.wrap(0), 0);
    }

    /// @notice Raises the gate reference to the bit length of the current active liquidity with one tiny swap per
    ///   half tau (one bit per tau)
    function _warmReference() internal {
        uint256 target = V21Ref.bitlen(_poolState().liquidity());
        for (uint256 i; i < 400 && _lRefBits() < target; i++) {
            advanceTime(cfg.tau / 2);
            this.swapCheckedExt(i % 2 == 0, 1, SqrtRatio.wrap(0));
        }
        assertEq(_lRefBits(), target, "reference warmed");
    }
}
