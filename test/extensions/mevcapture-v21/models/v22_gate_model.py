"""EKU-946 rev 4: reference model of the rev 4 anchor-update rules (design.md §b rev 4) for the EKU-965 cases.

Rev 4 rules modelled here (ticks; liquidity as bit lengths):
  - beforeUpdatePosition hook: on the first position update of a timestamp, snapshot snapBits = bitlen(active L) and
    set lastPosTime = now (taken before the position changes, so it excludes liquidity added in this timestamp).
  - observation at the first swap of a timestamp: L_obs = snapBits if lastPosTime == now else bitlen(L_now).
  - reference: e_ref = lRefBits - floor((now - lRefTime) / tau), measured from the stored lRefTime (G2 fix).
    On a passing observation: lRefBits = max(e_ref, L_obs), lRefTime = now (so it decays only while the gate fails).
    Also raised from post-swap liquidity when lastPosTime != now (no position change yet in this timestamp).
  - gate: L_obs + M_GATE >= e_ref; move = exact decay toward tick, clamped to CLAMP * min(dt, tau) / tau (G3 fix).
Run: python3 v22_gate_model.py
"""
import math

TAU, M_GATE, CLAMP = 120, 3, 2500


class Pool:
    def __init__(self, lref, anchor=0.0, t0=0):
        self.anchor, self.last, self.lref, self.lref_t = anchor, t0, lref, t0
        self.last_pos, self.snap = -1, 0
        self.drag_ok = 0

    def e_ref(self, now):
        return self.lref - min(self.lref, (now - self.lref_t) // TAU)

    def position_update(self, now, active_bits_before):
        if self.last_pos != now:
            self.snap, self.last_pos = active_bits_before, now

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
        if passed:
            # the reference decays only while the gate fails; a passing observation restarts it at max(e, l_obs)
            self.lref, self.lref_t = max(e, l_obs), now
        self.last = now
        return passed

    def after_swap(self, now, l_after_bits):
        if self.last_pos != now and l_after_bits > self.e_ref(now):
            self.lref, self.lref_t = l_after_bits, now


print("== G1: same-lock flash liquidity (64 -> 113 bits) around a forwarded swap, then honest swaps ==")
for period in (1, 12, 60, 119, 120, 240):
    p = Pool(64)
    p.position_update(period, 64)          # flash add: hook snapshots the pre-add liquidity
    p.first_swap(period, 10_000, 113)      # swap sees 113 bits live, but the observation is the snapshot
    p.after_swap(period, 113)              # no refresh: a position changed in this timestamp
    first = None
    for now in range(2 * period, 86_400, period):
        if p.first_swap(now, 10_000, 64) and first is None:
            first = now
        p.after_swap(now, 64)
    print(f"honest swaps every {period:>3} s: lRefBits after attack {p.lref} (honest 64); gate first passes at "
          f"{first} s; anchor {p.anchor:.0f}/10000 after 24 h")

print("\n== G2: no attacker. Honest LP exit, frequent swaps; reference decays from lRefTime ==")
for exit_bits, label in ((4, "1/16 left"), (10, "1/1024 left")):
    for period in (12, 119, 120):
        p = Pool(64)
        first = None
        for now in range(period, 86_400, period):
            if p.first_swap(now, 10_000, 64 - exit_bits) and first is None:
                first = now
            p.after_swap(now, 64 - exit_bits)
        print(f"{label:12s} swaps every {period:>3} s: gate first passes at {first} s ({first / TAU:.1f} tau)")

print("\n== G3.1: park through an empty range at end of t; top of t+1: flash liquidity at P + return swap ==")
p = Pool(64)
p.position_update(13, 0)                    # flash add at P: active liquidity at P before the add is 0
passed = p.first_swap(13, 1_000_000, 113)   # live liquidity is the flash, observation is the snapshot (0)
print(f"gate passed: {passed}; anchor moved {p.anchor:.0f} ticks (rev 3: passes, drag CLAMP*dt/tau)")

print("\n== G3.2: idle park (one park, next touch after 1 h) ==")
for bits_at_p, label in ((0, "empty range at P"), (61, "dust >= L_ref/8 at P, held across the boundary")):
    p = Pool(64)
    p.first_swap(3_600, 1_000_000, bits_at_p)
    print(f"{label:48s}: anchor moved {p.anchor:6.0f} ticks (rev 3: {CLAMP * 3600 / TAU if bits_at_p else 0:.0f})")

print("\n== Sustained dust parking every 12 s, attacker also blocks post-swap refreshes with a position update ==")
p = Pool(64)
for now in range(12, 3_601, 12):
    need = p.e_ref(now) - M_GATE
    p.first_swap(now, 1_000_000, max(need, 0))   # attacker holds just enough persisted dust at P
    if now in (120, 600, 1_800, 3_600):
        print(f"t = {now:>5} s: drag {p.anchor:6.0f} ticks ({p.anchor / 100:5.1f} bp); dust needed >= 2^{need} "
              f"(honest 2^64); bound CLAMP*t/tau = {CLAMP * now / TAU:.0f}")

print("\n== C1: anchor catch-up after a real gap (rev 4 limit = CLAMP per tau, idle-capped) ==")
for gap_bp in (200, 500, 1000, 2000):
    g = gap_bp * 100
    t2 = max(0.0, math.log2(g / 2500)) * TAU
    off, t = g, 0
    while off > 2500:
        off = max(off * 0.5 if off * 0.5 >= off - CLAMP else off - CLAMP, 0)
        t += TAU
    print(f"gap {gap_bp:>5} bp: offset < 25 bp after {t / 60:6.1f} min (rev 2 exponential: {t2 / 60:5.1f} min)")
print("Economic effect: calib/run_v22.py (24 and 400 injected gaps): gap-only recapture and uninformed loss are within "
      "1-3 points of the unclamped mechanism at CLAMP = 25 bp/tau; see design.md §(d) rev 4.")
