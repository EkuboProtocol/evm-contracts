"""Generate MEVCapture v2.1 quoter/indexer test vectors and cross-check the exact model against the design models.

Run from the repository root:  python3 test/extensions/mevcapture-v21/gen_vectors.py
Writes test/data/mevcapture-v21/{gateScenarios,anchorUpdates,schedules}.json. The forge test MEVCaptureV21VectorsTest checks the contract against it.

Cross-checks (the script fails if any does not hold):
  - gate: every scenario of models/v23_gate_model.py (H1, G1, G2, G3, J1) plus the rev 6 Q1 scenarios is replayed step
    by step through the exact integer model and models/v24_gate_model.py (rev 6 = rev 5 + the EKU-1034 Q1 rule); pass/fail and lRefBits must be identical and the anchor equal within 1e-3 tick.
  - segment schedule: boundaries equal models/v21_attacks.py seg_bounds exactly, and every uncapped segment rate is
    within one 0.16 unit (the ceil) of seg_rate.
"""
import contextlib
import importlib.util
import io
import json
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ref_model as m  # noqa: E402

OUT_DIR = os.path.join(HERE, "..", "..", "data", "mevcapture-v21")
T0 = 1_700_000_000  # base timestamp for scenarios (design models use relative time)


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, "models", name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    with contextlib.redirect_stdout(io.StringIO()):
        spec.loader.exec_module(mod)
    return mod


v24 = _load("v24_gate_model")
v21 = _load("v21_attacks")

CFG = m.Config()
CFG64 = m.Config(j_lin=64)


def liq(bits):
    return 0 if bits == 0 else 1 << (bits - 1)


def s(x):
    return str(x)


def cfg_json(c):
    return {"halfLife": s(c.tau), "slopeK": s(c.slope_k), "segmentExp": s(c.seg_exp), "jLin": s(c.j_lin),
            "maxFee": s(c.max_fee), "clampTicks": s(c.clamp), "mGate": s(c.m_gate), "maxSegments": s(c.max_segments)}


# ---------------------------------------------------------------- gate scenarios (cross-checked against v23)


class Twin:
    """Runs the exact model and the v23 float model side by side and records vector steps."""

    def __init__(self, lref, anchor_ticks=0, lref_from_init=False):
        self.f = v24.Pool6(lref, anchor=float(anchor_ticks))
        self.s = m.State(T0, T0, 0, lref, 0, (T0 - CFG.tau) % m.U32, anchor_ticks * 65536)
        self.initial = self.s
        self.steps = []

    def pos(self, now, bits_before):
        self.f.position_update(now, bits_before)
        self.s = m.position_hook(self.s, liq(bits_before), T0 + now)
        self.steps.append({"op": "position", "timestamp": s(T0 + now), "tick": "0", "liquidity": "0", "liquidityAfter": "0",
                           "activeLiquidity": s(liq(bits_before)), "first": False, "passed": False, "lObs": "0",
                           "eRef": "0", "expected": self.s.to_json()})

    def swap(self, now, tick, bits_now, bits_after=None):
        bits_after = bits_now if bits_after is None else bits_after
        fp = self.f.first_swap(now, tick, bits_now)
        step = {"op": "swap", "timestamp": s(T0 + now), "tick": s(tick), "liquidity": s(liq(bits_now)),
                "liquidityAfter": s(liq(bits_after)), "activeLiquidity": "0", "first": fp is not None,
                "passed": False, "lObs": "0", "eRef": "0"}
        if fp is not None:
            self.s, passed, l_obs, e = m.anchor_update(CFG, self.s, tick, liq(bits_now), T0 + now)
            assert passed == fp, (now, passed, fp)
            step.update({"passed": passed, "lObs": s(l_obs), "eRef": s(e)})
        self.f.after_swap(now, bits_after)
        self.s = m.refresh(CFG, self.s, liq(bits_after), T0 + now)
        assert self.s.l_ref_bits == self.f.lref, (now, self.s.l_ref_bits, self.f.lref)
        assert abs(self.s.anchor_x16 / 65536 - self.f.anchor) < 1e-3, (now, self.s.anchor_x16 / 65536, self.f.anchor)
        step["expected"] = self.s.to_json()
        self.steps.append(step)
        return fp

    def honest_until_pass(self, start, bits=64, tick=1_000_000, period=12, extra=2, limit=400):
        n_after = None
        for i, now in enumerate(range(start, 86_400, period)):
            if i >= limit:
                break
            if self.swap(now, tick, bits) and n_after is None:
                n_after = 0
            if n_after is not None:
                n_after += 1
                if n_after > extra:
                    break

    def vector(self, name, note):
        return {"name": name, "note": note, "initial": self.initial.to_json(), "steps": self.steps}


def gate_scenarios():
    out = []
    for b in (4, 6, 10, 20, 49):
        t = Twin(64)
        t.swap(12, 0, 64 + b)
        t.pos(12, 64 + b)
        assert t.s.l_ref_bits <= 65
        t.honest_until_pass(24)
        out.append(t.vector(f"h1_one_block_plus_{b}_bits", "H1 test 1: one-block inflation, removal in the same timestamp"))
    for n in (1, 4, 8, 16):
        t = Twin(64)
        end = n * CFG.tau
        for now in range(12, end + 1, 12):
            t.swap(now, 0, 84)
        t.honest_until_pass(end + 12)
        out.append(t.vector(f"h1_sustained_{n}_tau", "H1 test 2: +20 bits held for n tau, then removed"))
    t = Twin(64)
    for now in range(12, 3_601, 12):
        t.swap(now, 10_000, 64 if now < 600 else 84)
    assert all(st.get("passed", True) for st in t.steps)
    out.append(t.vector("h1_honest_growth_2pow20", "H1 test 3: honest +20 bits in one block; never fails"))
    t = Twin(64)
    t.pos(12, 64)
    t.swap(12, 10_000, 113)
    t.honest_until_pass(24, tick=10_000, limit=20)
    out.append(t.vector("g1_same_lock_flash", "G1: flash liquidity in the swap's lock is never observed"))
    for exit_bits in (4, 10):
        t = Twin(64)
        t.honest_until_pass(12, bits=64 - exit_bits, tick=10_000)
        out.append(t.vector(f"g2_exit_minus_{exit_bits}_bits", "G2: decay from lRefTime while the gate fails"))
    t = Twin(64)
    t.pos(13, 0)
    t.swap(13, 1_000_000, 113)
    out.append(t.vector("g3_1_flash_at_parked_tick", "G3.1: flash liquidity at P, gate fails"))
    t = Twin(64)
    t.swap(3_600, 1_000_000, 61)
    out.append(t.vector("g3_2_idle_park_with_dust", "G3.2: idle park with dust drags at most CLAMP"))
    t = Twin(64)
    for now in range(12, 1_201, 12):
        t.swap(now, 1_000_000, 0)
    out.append(t.vector("j1_per_timestamp_parking", "J1: gate fails every update; anchor frozen"))
    for period in (360, 720):
        t = Twin(64)
        for now in range(period, 6 * 3600 + 1, period):
            t.swap(now, 5_000, 64)
        assert t.s.l_ref_bits == 64
        out.append(t.vector(f"q1_quiet_pool_warmed_touched_every_{period}s", "Rev 6 Q1: a warmed reference holds"))
        t = Twin(0)
        for now in range(period, 6 * 3600 + 1, period):
            t.swap(now, 5_000, 64)
        out.append(t.vector(f"q1_quiet_pool_warmup_every_{period}s", "Rev 6 Q1: warm-up is 1 bit per touch"))
    t = Twin(64)
    for now in range(12, 3_601, 12):
        if now % 360 == 0:
            t.swap(now, 1_000_000, 64)
        else:
            t.swap(now, 1_000_000, 0)
    out.append(t.vector("q1_j1_parking_quiet_pool", "Rev 6 Q1: J1 parking on a pool with honest touches every 360 s"))
    for d in (6, 12, 20):
        t = Twin(64)
        t.swap(3_600, 0, 64)
        t.honest_until_pass(3_612, bits=64 - d, tick=0)
        out.append(t.vector(f"q1_idle_drop_{d}_bits_restore", "Rev 6 residual: restore after an idle drop freezes <= (D-3)+ tau"))
    return out


# ---------------------------------------------------------------- anchor updates (decay, clamp, gate)


def anchor_updates():
    rng = random.Random(946)
    out = []
    dts = [1, 7, 12, 59, 60, 119, 120, 121, 239, 240, 241, 600, 3_600, 255 * 120, 300 * 120, m.U32 - 1]
    offsets = [0, 1, -1, 65535, -65535, 300 * 65536 + 12345, -(300 * 65536) - 777, 2_499 * 65536, 2_501 * 65536,
               -50_000 * 65536 - 1, 88_000_000 * 65536, -88_000_000 * 65536]
    for i in range(120):
        now = T0 + rng.randrange(0, 1_000_000)
        dt = dts[i % len(dts)] if i < 2 * len(dts) else rng.choice([rng.randrange(1, 400), rng.randrange(1, 20_000)])
        tick = rng.randrange(-1_000_000, 1_000_000)
        off = offsets[i % len(offsets)] if i < 3 * len(offsets) else rng.randrange(-(3_000 << 16), 3_000 << 16)
        anchor = tick * 65536 + off
        if not (m.MIN_TICK * 65536 <= anchor <= m.MAX_TICK * 65536):
            anchor = tick * 65536
        ref_bits = rng.choice([0, 1, 3, 40, 64, 67, 100, 128])
        ref_age = rng.choice([0, 1, 119, 120, 600, 5_000, 100_000])
        raise_age = rng.choice([0, 60, 120, 1_000])
        snap = rng.random() < 0.25
        l_bits = rng.choice([0, 1, 40, 60, 61, 64, 67, 90, 128])
        st = m.State((now - dt) % m.U32, (now - ref_age) % m.U32, now % m.U32 if snap else (now - 5) % m.U32,
                     ref_bits, rng.choice([0, 30, 64, 70]), (now - raise_age) % m.U32, anchor)
        liquidity = liq(l_bits) + (rng.randrange(0, liq(l_bits)) if l_bits > 1 else 0)
        new, passed, l_obs, e = m.anchor_update(CFG, st, tick, liquidity, now)
        out.append({"stateIn": st.to_json(), "tick": s(tick), "liquidity": s(liquidity), "timestamp": s(now % m.U32),
                    "passed": passed, "lObs": s(l_obs), "eRef": s(e), "expected": new.to_json()})
    return out


# ---------------------------------------------------------------- segment schedules (cross-checked against v21)


def check_v21_schedule():
    pool_fee = 196
    v21.GAMMA = pool_fee / 65536
    for a in (0, 4096 * 3, -4096 * 7):
        d_max = 4096 * 200
        bounds = v21.seg_bounds(a, d_max)
        sched = m.schedule(CFG, pool_fee, 4096, a * 65536, True, a, len(bounds) - 1)
        for (lo, hi), seg in zip(zip(bounds[:-1], bounds[1:]), sched):
            assert seg["hiX16"] == (a + hi) * 65536 and seg["loX16"] == (a + lo) * 65536, (a, lo, hi, seg)
            rate = v21.seg_rate(lo, hi)
            if seg["fee"] < CFG.max_fee and rate < v21.CAP:
                sur = (seg["fee"] - pool_fee) / 65536
                assert rate - 1e-12 <= sur <= rate + 1 / 65536, (a, lo, hi, rate, sur)


def schedules():
    out = []
    cases = []
    for cfg in (CFG, CFG64):
        for pool_fee, exp in ((196, 12), (13, 7), (1, 0), (3_000, 4), (32_767, 10)):
            if cfg is CFG64 and (pool_fee, exp) != (196, 12):
                continue
            sp = 1 << exp
            for anchor in (0, 20 * 65536 + 12_345, -(20 * 65536 + 12_345), 7 * sp * 65536, 7 * sp * 65536 - 1,
                           -3 * sp * 65536 + 1):
                for inc in (True, False):
                    a_tick = anchor >> 16
                    for start in (a_tick, a_tick + (1 if inc else -1) * 5 * sp, a_tick + (1 if inc else -1) * 50 * sp,
                                  a_tick + (1 if inc else -1) * 3_000 * sp):
                        cases.append((cfg, pool_fee, exp, anchor, inc, start))
    for cfg, pool_fee, exp, anchor, inc, start in cases:
        if not (m.MIN_TICK < start < m.MAX_TICK):
            continue
        segs = m.schedule(cfg, pool_fee, 1 << exp, anchor, inc, start, 1)
        while segs[-1]["fee"] < cfg.max_fee and len(segs) < cfg.max_segments and abs(segs[-1]["hiTick"]) <= m.MAX_TICK:
            segs = m.schedule(cfg, pool_fee, 1 << exp, anchor, inc, start, len(segs) + 1)
        out.append({
            "jLin": s(cfg.j_lin), "poolFee": s(pool_fee), "spacingExp": s(exp), "anchorX16": s(anchor),
            "increasing": inc, "coreTick": s(start), "towardTick": s(m.toward_tick(anchor, inc)),
            "segments": [{k: s(v) for k, v in seg.items()} for seg in segs],
        })
    return out


def main():
    check_v21_schedule()
    vec = {
        "spec": "EKU-946 design rev 5 section (b); contract src/extensions/MEVCaptureV21.sol",
        "units": "ticks int; anchorX16 = tick * 65536 (Q48.16); fees 0.16 fixed point; times uint32 seconds; "
                 "all integers are decimal strings",
        "config": cfg_json(CFG),
        "rules": {
            "eRef": "lRefBits - min(lRefBits, (now - lRefTime) / tau)",
            "gate": "lObs + mGate >= eRef, lObs = snapBits if lastPosTime == now else bitlen(activeLiquidity)",
            "decay": "off = anchor - tick*65536; |off'| = ((|off| >> (dt / tau)) << 64) / exp2(((dt % tau) << 64) / tau)"
                     " (src/math/exp2.sol, 5.64 in, 64.64 out); move = clamp(off' - off, +-(clamp << 16) * min(dt, tau) / tau)",
            "raise": "e + 1 if L > e and now - lRefRaiseTime >= tau (then lRefRaiseTime = now), else e",
            "segmentFee": "min(maxFee, poolFee + ceil(slopeK * poolFee * (lo + hi - 2 * anchor) / (4 * spacing * 65536)))",
            "boundaries": "first jLin on the W grid strictly beyond the anchor, then widths 2W, 4W, ...; "
                          "segments are visited starting with the first boundary strictly beyond the current sqrt ratio",
            "toward": "one call with the caller's minFee to tickToSqrtRatio(floor(anchor)) (increasing) or ceil (decreasing)",
            "budget": "at most jLin + 24 away calls; merge to the user limit once the fee is maxFee or at the last call",
        },
        "gateScenarios": gate_scenarios(),
        "anchorUpdates": anchor_updates(),
        "schedules": schedules(),
    }
    os.makedirs(OUT_DIR, exist_ok=True)
    meta = {k: vec[k] for k in ("spec", "units", "config", "rules")}
    for name in ("gateScenarios", "anchorUpdates", "schedules"):
        with open(os.path.join(OUT_DIR, name + ".json"), "w") as f:
            json.dump({**meta, name: vec[name]}, f, indent=1)
            f.write("\n")
    print(f"wrote {OUT_DIR}: {len(vec['gateScenarios'])} gate scenarios, {len(vec['anchorUpdates'])} anchor updates, "
          f"{len(vec['schedules'])} schedules; cross-checks against v24_gate_model (rev 6) and v21_attacks passed")

if __name__ == "__main__":
    main()
