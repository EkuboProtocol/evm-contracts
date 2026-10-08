"""EKU-946 rev 6 gate model: rev 5 (v23_gate_model.py) plus the EKU-1034 Q1 rule.

On a passing first swap the reference restarts at base = max(e_ref, min(lRefBits, L_obs)) (restore toward the stored
value, never above it), then the H1 raise (+1 bit at most, once per tau). Everything else is rev 5. The Pool6 class is
the CSO's model from artifacts/eku-1034/q1_model.py.
Run: python3 v24_gate_model.py
"""
import contextlib
import importlib.util
import io
import os

spec = importlib.util.spec_from_file_location("v23", os.path.join(os.path.dirname(os.path.abspath(__file__)), "v23_gate_model.py"))
v23 = importlib.util.module_from_spec(spec)
with contextlib.redirect_stdout(io.StringIO()):
    spec.loader.exec_module(v23)
TAU, M_GATE, CLAMP, Pool5 = v23.TAU, v23.M_GATE, v23.CLAMP, v23.Pool5


class Pool6(Pool5):
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
            base = max(e, min(self.lref, l_obs))
            self.lref, self.lref_t = self._raised(base, l_obs, now), now
        self.last = now
        return passed


if __name__ == "__main__":
    for period in (120, 360, 720):
        p = Pool6(64)
        q = Pool6(0)
        for now in range(period, 6 * 3600 + 1, period):
            p.first_swap(now, 0, 64); p.after_swap(now, 64)
            q.first_swap(now, 0, 64); q.after_swap(now, 64)
        print(f"touched every {period:>3}s for 6h: warmed 64 -> {p.lref}; from init 0 -> {q.lref}")
