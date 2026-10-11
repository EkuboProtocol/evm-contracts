"""EKU-946 rev 3: reference model of the v2.1 rules (design.md §b rev 3) against the EKU-959 attacks.

v2.1 surcharge: segments on the absolute W grid (plus a boundary at the anchor); every unit of input traded inside
an away segment pays that segment's constant rate (charged in-swap by Core via minFee); toward segments pay only the
pool fee. Because Core applies the segment rate to whatever amount trades inside the segment, the charge equals the
schedule's integral exactly for ANY liquidity distribution: there is no averaging step left to exploit.
Units: ticks; L(u) = input amount per tick at displacement u; rates as fractions. Run: python3 v21_attacks.py
"""

K, GAMMA, S = 2, 0.003, 4096
W = S
CAP = 0.5
J_LIN = 16


def seg_bounds(a, d_max):
    """Away segment boundaries (displacements from the anchor, >= 0) for the anchor at absolute tick a, upward."""
    out = [0.0]
    g = (a // W + 1) * W  # first grid point strictly above a
    width = W
    j = 0
    while out[-1] < d_max:
        out.append(g - a)
        j += 1
        if j >= J_LIN:
            width *= 2
        g += width
    return out


def seg_rate(lo, hi):
    return min(CAP, K * GAMMA * 0.5 * (lo + hi) / S)


def v21_surcharge(L, a, d0, d1, n_per_seg=400):
    """Surcharge for an upward swap from displacement d0 to d1 (d0 may be negative: toward part is free)."""
    tot = 0.0
    b = seg_bounds(a, d1)
    for lo, hi in zip(b[:-1], b[1:]):
        x0, x1 = max(lo, d0, 0.0), min(hi, d1)
        if x1 <= x0:
            continue
        h = (x1 - x0) / n_per_seg
        amt = sum(L(x0 + (i + 0.5) * h) for i in range(n_per_seg)) * h
        tot += seg_rate(lo, hi) * amt
    return tot


def linear_ideal(L, d0, d1, n=20000):
    h = (d1 - d0) / n
    return sum(min(CAP, K * GAMMA * max(u, 0) / S) * L(u) for u in (d0 + (i + 0.5) * h for i in range(n))) * h


D = 20_000
A = 0.0  # anchor on a grid point for the comparisons below

print("== F2: crossing after an empty-range push (CSO table 1) ==")
for a_lp in (0, 2_000, 10_000):
    L = lambda u, a=a_lp: 1.0 if -a <= u <= 30_000 else 0.0
    honest = v21_surcharge(L, A, 0, D)
    for M in (100_000, 1_000_000, 10_000_000):
        attack = v21_surcharge(L, A, -M, D)
        print(f"LP below anchor {a_lp:>6}, push depth {M:>9}: attack/honest = {attack / honest:.4f}")

print("\n== F4: back-loaded liquidity within the move (CSO table 3) ==")
for frac in (0.5, 0.1, 0.01):
    L = lambda u, f=frac: 1.0 if (1 - f) * D <= u <= D else 0.0
    one = v21_surcharge(L, A, 0, D)
    split = sum(v21_surcharge(L, A, D * i / 8, D * (i + 1) / 8) for i in range(8))
    print(f"liquidity in last {frac:>4.0%}: single/8-way split = {one / split:.6f}; v2.1 / linear ideal = {one / linear_ideal(L, 0, D):.3f}")
print("(v2.1 is exact against its own stepped schedule; vs the linear ideal the error is at most half a step: "
      "rate error <= k*gamma*W/(2s) per unit, i.e. <= 1 pool fee for k=2, W=s)")

print("\n== F1: parking drag under the liquidity gate + movement rate limit ==")
TAU = 120.0
CLAMP = 0.0025 / 1e-6  # 25 bp of log price per tau, in ticks
print("empty-range park: observation has zero active liquidity -> gate fails -> anchor does not move (drag 0).")
for dt, label in ((12, "Ethereum, park every block"), (1, "1 s chain, park every second")):
    for hours in (0.1, 1.0):
        n = int(hours * 3600 / dt)
        drag = min(n * CLAMP * dt / TAU, 10_000_000)
        print(f"{label:30s} {hours:>4} h: max drag {drag:>8.0f} ticks ({drag * 1e-6 * 1e4:5.0f} bp); "
              f"seller extra rate <= {min(CAP, K * GAMMA * drag / S):.2%}; requires {n} park+return cycles and "
              f"dust >= L_ref/8 at the parked tick on every cycle")
print("Honest catch-up: the rate limit binds only when |offset| * (1 - 2^(-dt/tau)) > CLAMP * dt / tau, i.e. "
      f"for offsets above ~{CLAMP / 0.693 * 1e-6 * 1e4:.0f} bp; the calibrated Ethereum run shows no measurable change.")
