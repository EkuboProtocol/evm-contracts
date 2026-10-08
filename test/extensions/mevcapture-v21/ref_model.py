"""Exact integer reference model of MEVCapture v2.1 (EKU-946 design rev 5, section (b)).

Written from the spec text, independently of the Solidity code, in original (not mirrored) coordinates. It is used to
generate the quoter/indexer test vectors (gen_vectors.py) and is cross-checked there against the float design models
in models/ (v23_gate_model.py for the gate, v21_attacks.py for the segment schedule).

Units: ticks are integers, anchors are Q48.16 integers (tick * 65536), fees are 0.16 fixed point (fee / 65536),
liquidity is a uint128 and the gate works on its bit length.
"""
import os
import re
from dataclasses import dataclass, replace

HERE = os.path.dirname(os.path.abspath(__file__))
MIN_TICK, MAX_TICK = -88722835, 88722835
U32 = 1 << 32


def _load_exp2_constants():
    src = open(os.path.join(HERE, "..", "..", "..", "src", "math", "exp2.sol")).read()
    pairs = re.findall(r"x & (0x[0-9a-fA-F]+) != 0\) \{\s*result = result \* (0x[0-9a-fA-F]+) >> 128;", src)
    assert len(pairs) == 64, len(pairs)
    return [(int(m, 16), int(c, 16)) for m, c in pairs]


_EXP2 = _load_exp2_constants()


def exp2(x):
    """2^x for x a 5.64 fixed point number; result is 64.64. Bit-exact port of src/math/exp2.sol."""
    assert x < 0x400000000000000000
    r = 0x80000000000000000000000000000000
    for mask, c in _EXP2:
        if x & mask:
            r = (r * c) >> 128
    return r >> (63 - (x >> 64))


def bitlen(x):
    return x.bit_length()


@dataclass(frozen=True)
class Config:
    tau: int = 120
    slope_k: int = 4
    seg_exp: int = 0
    j_lin: int = 16
    max_fee: int = 1 << 15
    clamp: int = 2500
    m_gate: int = 3

    @property
    def max_segments(self):
        return self.j_lin + 24


@dataclass(frozen=True)
class State:
    last_update_time: int
    l_ref_time: int
    last_pos_time: int
    l_ref_bits: int
    snap_bits: int
    raise_time: int
    anchor_x16: int

    def to_json(self):
        return {
            "lastUpdateTime": str(self.last_update_time),
            "lRefTime": str(self.l_ref_time),
            "lastPosTime": str(self.last_pos_time),
            "lRefBits": str(self.l_ref_bits),
            "snapBits": str(self.snap_bits),
            "lRefRaiseTime": str(self.raise_time),
            "anchorX16": str(self.anchor_x16),
        }


def init_state(cfg, now, tick):
    now %= U32
    return State(now, now, 0, 0, 0, (now - cfg.tau) % U32, tick * 65536)


def since(now, then):
    return (now - then) % U32


def e_ref(cfg, s, now):
    decay = since(now, s.l_ref_time) // cfg.tau
    return 0 if decay >= s.l_ref_bits else s.l_ref_bits - decay


def _raise(cfg, s, e, l_bits, now):
    """raise(e, L): e + 1 if L > e and at least tau since the last raise; returns (value, new raise time)."""
    if l_bits > e and since(now, s.raise_time) >= cfg.tau:
        return e + 1, now
    return e, s.raise_time


def _trunc_div(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b > 0) else -q


def anchor_update(cfg, s, tick_now, liquidity_now, now):
    """First swap of a timestamp. Returns (state, passed, l_obs, e_ref)."""
    now %= U32
    dt = since(now, s.last_update_time)
    assert dt != 0
    l_obs = s.snap_bits if s.last_pos_time == now else bitlen(liquidity_now)
    e = e_ref(cfg, s, now)
    passed = l_obs + cfg.m_gate >= e
    if not passed:
        return replace(s, last_update_time=now), False, l_obs, e
    off = s.anchor_x16 - tick_now * 65536
    halvings = dt // cfg.tau
    mag = abs(off) >> halvings if halvings < 256 else 0
    mag = (mag << 64) // exp2(((dt % cfg.tau) << 64) // cfg.tau)
    off_new = -mag if off < 0 else mag
    lim = (cfg.clamp << 16) * min(dt, cfg.tau) // cfg.tau
    move = max(-lim, min(lim, off_new - off))
    bits, raise_time = _raise(cfg, s, e, l_obs, now)
    return (
        replace(s, last_update_time=now, l_ref_time=now, l_ref_bits=bits, raise_time=raise_time,
                anchor_x16=s.anchor_x16 + move),
        True,
        l_obs,
        e,
    )


def refresh(cfg, s, liquidity_after, now):
    """After every swap: raise from the post-swap liquidity unless a position changed in this timestamp."""
    now %= U32
    if s.last_pos_time == now:
        return s
    e = e_ref(cfg, s, now)
    bits, raise_time = _raise(cfg, s, e, bitlen(liquidity_after), now)
    if bits > e:
        return replace(s, l_ref_bits=bits, l_ref_time=now, raise_time=raise_time)
    return s


def position_hook(s, active_liquidity_before, now):
    now %= U32
    if s.last_pos_time != now:
        return replace(s, last_pos_time=now, snap_bits=bitlen(active_liquidity_before))
    return s


# ---------------------------------------------------------------- segment schedule


def _floor_div(a, b):
    return a // b


def _ceil_div(a, b):
    return -((-a) // b)


def boundary(cfg, spacing, anchor_x16, increasing, k):
    """k-th (1-based) away boundary in Q16 ticks, original coordinates."""
    w16 = (spacing << cfg.seg_exp) * 65536
    b = (_floor_div(anchor_x16, w16) + 1) * w16 if increasing else (_ceil_div(anchor_x16, w16) - 1) * w16
    width = w16
    for j in range(2, k + 1):
        if j > cfg.j_lin:
            width *= 2
        b = b + width if increasing else b - width
    return b


def segment_fee(cfg, pool_fee, spacing, lo, hi, anchor_x16):
    """min(MAX_FEE, ceil(poolFee + SLOPE_K/2 * poolFee * |mid - anchor| / spacing)) with mid = (lo + hi) / 2."""
    twice = abs(lo + hi - 2 * anchor_x16)
    den = 4 * spacing * 65536
    return min(cfg.max_fee, pool_fee + _ceil_div(cfg.slope_k * pool_fee * twice, den))


def toward_tick(anchor_x16, increasing):
    """The toward call ends at the rounded anchor: floor from below (increasing), ceil from above (decreasing)."""
    t = _floor_div(anchor_x16, 65536) if increasing else _ceil_div(anchor_x16, 65536)
    return max(MIN_TICK, min(MAX_TICK, t))


def schedule(cfg, pool_fee, spacing, anchor_x16, increasing, core_tick, count):
    """`count` away segments starting with the first boundary strictly beyond a price strictly inside Core tick
    `core_tick` (i.e. sqrt(core_tick) < price < sqrt(core_tick + 1)). When the price sits exactly on a boundary, the
    swap additionally skips that boundary (segment membership by sqrt ratio)."""
    k = 1
    while True:
        hi = boundary(cfg, spacing, anchor_x16, increasing, k)
        hi_tick = hi // 65536
        if (hi_tick > core_tick) if increasing else (hi_tick <= core_tick):
            break
        k += 1
    out = []
    for i in range(count):
        kk = k + i
        lo = anchor_x16 if kk == 1 else boundary(cfg, spacing, anchor_x16, increasing, kk - 1)
        hi = boundary(cfg, spacing, anchor_x16, increasing, kk)
        out.append({"k": kk, "loX16": lo, "hiX16": hi, "hiTick": hi // 65536,
                    "fee": segment_fee(cfg, pool_fee, spacing, lo, hi, anchor_x16)})
    return out
