// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Vm, VmSafe} from "forge-std/Vm.sol";
import {FullTest} from "../FullTest.sol";
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
///   through `_swapChecked` is replayed on the twin by the independent reference schedule and must match exactly:
///   balance deltas, the pool state after, the extension state, the Core call sequence and the gate event.
abstract contract MEVCaptureV21Base is FullTest {
    using CoreLib for *;

    bytes32 internal constant GATE_FAILED_TOPIC = keccak256("AnchorGateFailed(bytes32,uint8,uint8)");

    MEVCaptureV21 internal v21;
    V21Actor internal actor;
    V21Ref.Cfg internal cfg;

    PoolKey internal pool;
    PoolKey internal twin;
    uint256 internal poolFee;
    uint256 internal spacing;

    /// @notice Number of Core swap calls the last checked swap made
    uint256 internal lastCalls;
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

    function createPools(uint16 fee, uint8 spacingExp, int32 tick) internal {
        pool = createPool(
            address(token0), address(token1), tick, createConcentratedPoolConfig(fee, spacingExp, address(v21), 0)
        );
        twin = createPool(
            address(token0), address(token1), tick, createConcentratedPoolConfig(fee, spacingExp, address(0), 0)
        );
        poolFee = fee;
        spacing = uint256(1) << spacingExp;
    }

    // ------------------------------------------------------------------ state helpers

    function _state(PoolKey memory pk) internal view returns (V21Ref.State memory s) {
        uint8 refBits;
        uint8 snap;
        int64 anchor;
        (s.lastUpdateTime, s.lRefTime, s.lastPosTime, refBits, snap, s.raiseTime, anchor) = v21.getAnchor(pk.toPoolId());
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

    function _collect(PoolKey memory pk, bytes24 salt, int32 lo, int32 hi) internal returns (uint128 f0, uint128 f1) {
        V21Actor.Action[] memory acts = new V21Actor.Action[](1);
        acts[0] = _action(3, pk, PositionId.unwrap(_pid(salt, lo, hi)), 0, address(0));
        (f0, f1) = abi.decode(actor.run(acts)[0], (uint128, uint128));
    }

    // ------------------------------------------------------------------ swap helpers

    function _params(bool isToken1, int128 amount, SqrtRatio limit, uint16 minFee)
        internal
        pure
        returns (SwapParameters)
    {
        return createSwapParameters({
            _sqrtRatioLimit: limit, _amount: amount, _isToken1: isToken1, _skipAhead: 0, _minFee: minFee
        });
    }

    /// @notice Unchecked forwarded swap through the actor (no reference replay)
    function _swapRaw(bool isToken1, int128 amount, SqrtRatio limit, uint16 minFee)
        internal
        returns (PoolBalanceUpdate u, PoolState st)
    {
        V21Actor.Action[] memory acts = new V21Actor.Action[](1);
        acts[0] = _action(1, pool, SwapParameters.unwrap(_params(isToken1, amount, limit, minFee)), 0, address(v21));
        (u, st) = abi.decode(actor.run(acts)[0], (PoolBalanceUpdate, PoolState));
    }

    /// @notice Forwarded swap checked against the reference model on the twin pool
    function _swapChecked(bool isToken1, int128 amount, SqrtRatio limit, uint16 minFee)
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

        SwapParameters p = _params(isToken1, amount, limit, minFee);
        (PoolBalanceUpdate ur, PoolState str) = actor.runReference(cfg, twin, p, s.anchorX16, poolFee, spacing);
        uint256 nCalls = actor.refCallsLength();

        vm.recordLogs();
        vm.startStateDiffRecording();
        (u, st) = _swapRaw(isToken1, amount, limit, minFee);
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        _checkCoreCalls(accesses, nCalls);

        uint256 gateEvents;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(v21) && logs[i].topics[0] == GATE_FAILED_TOPIC) {
                gateEvents++;
                (bytes32 pid, uint8 lo, uint8 er) = abi.decode(logs[i].data, (bytes32, uint8, uint8));
                assertEq(pid, PoolId.unwrap(pool.toPoolId()), "event pool");
                assertEq(lo, lObs, "event lObs");
                assertEq(er, eRef, "event eRef");
            }
        }
        lastGateFailed = !passed;
        assertEq(gateEvents, lastWasFirst && !passed ? 1 : 0, "AnchorGateFailed emitted iff the gate failed");

        assertEq(PoolBalanceUpdate.unwrap(u), PoolBalanceUpdate.unwrap(ur), "balance update vs reference");
        assertEq(PoolState.unwrap(st), PoolState.unwrap(str), "state after vs reference");

        if (lastWasFirst) _checkDecay(anchorBefore, s.anchorX16, before.tick(), dtBefore, passed);
        V21Ref.refresh(cfg, s, st.liquidity(), nowT);
        _assertStateEq(_state(pool), s);
        lastCalls = nCalls == 0 ? 1 : nCalls;
    }

    /// @notice The extension must make exactly the reference's Core swap calls (limit, fee, amount, in order), and never
    ///   update a position from the forwarded handler (G1 a)
    function _checkCoreCalls(Vm.AccountAccess[] memory accesses, uint256 nCalls) internal view {
        uint256 seen;
        for (uint256 i; i < accesses.length; i++) {
            Vm.AccountAccess memory a = accesses[i];
            if (a.kind != VmSafe.AccountAccessKind.Call || a.account != address(core) || a.accessor != address(v21)) {
                continue;
            }
            bytes4 sel = bytes4(a.data);
            assertTrue(sel != ICore.updatePosition.selector, "forwarded handler called updatePosition");
            if (sel != bytes4(0)) continue;
            SwapParameters p;
            bytes memory d = a.data;
            assembly ("memory-safe") {
                p := mload(add(d, 132))
            }
            // every segment fee is at most MAX_FEE unless the caller asked for more (invariant 10)
            assertLe(p.minFee(), cfg.maxFee > p.minFee() ? cfg.maxFee : p.minFee(), "segment fee cap");
            if (nCalls != 0) {
                V21Actor.RefCall memory r = actor.refCall(seen);
                assertEq(SqrtRatio.unwrap(p.sqrtRatioLimit()), SqrtRatio.unwrap(r.limit), "call limit");
                assertEq(p.minFee(), r.fee, "call fee");
                assertEq(p.amount(), r.amount, "call amount");
            }
            seen++;
        }
        assertEq(seen, nCalls == 0 ? 1 : nCalls, "number of Core swap calls");
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
    function swapCheckedExt(bool isToken1, int128 amount, SqrtRatio limit, uint16 minFee)
        external
        returns (PoolBalanceUpdate u, PoolState st)
    {
        require(msg.sender == address(this));
        return _swapChecked(isToken1, amount, limit, minFee);
    }

    function _swapChecked(bool isToken1, int128 amount) internal returns (PoolBalanceUpdate u, PoolState st) {
        return _swapChecked(isToken1, amount, SqrtRatio.wrap(0), 0);
    }

    /// @notice Raises the gate reference to the bit length of the current active liquidity with one tiny swap per
    ///   half tau. (Touching only once per tau would not work: the pass decays the reference by one bit before the +1
    ///   raise, see test_quiet_pool_reference_cannot_climb.)
    function _warmReference() internal {
        uint256 target = V21Ref.bitlen(_poolState().liquidity());
        for (uint256 i; i < 400 && _lRefBits() < target; i++) {
            advanceTime(cfg.tau / 2);
            this.swapCheckedExt(i % 2 == 0, 1, SqrtRatio.wrap(0), 0);
        }
        assertEq(_lRefBits(), target, "reference warmed");
    }
}
