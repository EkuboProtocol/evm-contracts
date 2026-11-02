"""EKU-946 rev 5: rev 4 gate model plus the H1 rule (reference increases rate-limited to +1 bit per tau).

Rev 5 change (design.md §b rev 5, EKU-966 H1): an increase of lRefBits, either on a passing observation or on the
post-swap refresh, is limited to e_ref + 1 and only allowed if now - lRefRaiseTime >= tau; lRefRaiseTime = now after
an increase. Everything else is the unchanged rev 4 Pool (v22_gate_model.py).
Run: python3 v23_gate_model.py
"""
import contextlib
import importlib.util
import io

spec = importlib.util.spec_from_file_location("v22", __file__.replace("v23_gate_model.py", "v22_gate_model.py"))
v22 = importlib.util.module_from_spec(spec)
with contextlib.redirect_stdout(io.StringIO()):
    spec.loader.exec_module(v22)
TAU, M_GATE, CLAMP = v22.TAU, v22.M_GATE, v22.CLAMP


class Pool5(v22.Pool):
    def __init__(self, lref, anchor=0.0, t0=0):
        super().__init__(lref, anchor, t0)
        self.raise_t = t0 - TAU

    def _raised(self, e, l, now):
        if l > e and now - self.raise_t >= TAU:
            self.raise_t = now
            return e + 1
        return e

    def first_swap(self, now, tick, l_now_bits):
        dt = now - self.last
        if dt == 0:
            return None
        l_obs = self.snap if self.last_pos == now else l_now_bits
        e = self.e_ref(now)
        passed = l_obs + M_GATE >= e
        if passed:
            target = tick + (self.anchor - tick) * 2 ** (-dt / TAU)
            lim = CLAMP * min(dt, TAU) / TAU
            self.anchor += max(-lim, min(lim, target - self.anchor))
            self.lref, self.lref_t = self._raised(e, l_obs, now), now
        self.last = now
        return passed

    def after_swap(self, now, l_after_bits):
        if self.last_pos != now:
            e = self.e_ref(now)
            new = self._raised(e, l_after_bits, now)
            if new > e:
                self.lref, self.lref_t = new, now


def frozen_after(p, start, honest_bits=64, period=12, tick=1_000_000):
    for now in range(start, 86_400, period):
        if p.first_swap(now, tick, honest_bits):
            return now
        p.after_swap(now, honest_bits)
    return None


print("== H1 test 1: one-block +B-bit inflation (persisted across one boundary), honest swaps every 12 s ==")
for B in (4, 6, 10, 20, 49):
    p = Pool5(64)
    p.first_swap(12, 0, 64 + B)
    p.after_swap(12, 64 + B)
    p.position_update(12, 64 + B)  # removal later in the same timestamp
    lref = p.lref
    f = frozen_after(p, 24)
    print(f"B = {B:>2}: lRefBits -> {lref} (honest 64, bound <= 65); next honest swap passes at {f} s "
          f"(rev 4: frozen {max(B - 3, 0):.0f} tau)")

print("\n== H1 test 2: inflation of +20 bits held for n tau (attacker re-observes it every 12 s), then removed ==")
for n in (1, 4, 8, 16):
    p = Pool5(64)
    end = n * TAU
    for now in range(12, end + 1, 12):
        p.first_swap(now, 0, 84)
        p.after_swap(now, 84)
    lref = p.lref
    f = frozen_after(p, end + 12)
    frozen = (f - end) / TAU
    print(f"n = {n:>2} tau: lRefBits -> {lref}; anchor frozen {frozen:4.1f} tau after removal (bound (n - 3)+ = {max(n - 3, 0)})")

print("\n== H1 test 3: honest liquidity grows by 2^20 in one block and stays ==")
p = Pool5(64)
fails = 0
for now in range(12, 3_601, 12):
    l = 64 if now < 600 else 84
    if not p.first_swap(now, 10_000, l):
        fails += 1
    p.after_swap(now, l)
print(f"gate failures over 1 h: {fails}; lRefBits after 1 h {p.lref} (rises 1 bit per tau toward 84)")

print("\n== Regression: rev 4 cases under rev 5 ==")
p = Pool5(64)
p.position_update(12, 64); p.first_swap(12, 10_000, 113); p.after_swap(12, 113)
print(f"G1 same-lock flash inflation: lRefBits {p.lref}; next honest swap passes at {frozen_after(p, 24, tick=10_000)} s")
for exit_bits in (4, 10):
    p = Pool5(64)
    f = frozen_after(p, 12, honest_bits=64 - exit_bits, tick=10_000)
    print(f"G2 LP exit leaving 2^-{exit_bits}: gate reopens at {f} s ({f / TAU:.1f} tau)")
p = Pool5(64); p.position_update(13, 0)
print(f"G3.1 flash at parked tick: gate passed {p.first_swap(13, 1_000_000, 113)}; anchor {p.anchor:.0f}")
p = Pool5(64); p.first_swap(3_600, 1_000_000, 61)
print(f"G3.2 idle park with dust: drag {p.anchor:.0f} ticks (<= CLAMP {CLAMP})")

print("\n== J1 (documented residual, no contract change): per-timestamp empty-range parking on an edge pool ==")
p = Pool5(64)
passes = sum(bool(p.first_swap(now, 1_000_000, 0)) for now in range(12, 3_601, 12))
print(f"1 h of per-block parking: gate passes {passes}; anchor moved {p.anchor:.0f} ticks -> anchor frozen; "
      "covered by the gate-failure / stale-anchor monitor, not by the contract")
