#!/usr/bin/env python3
"""Generates the fixed-base creator-fee decay table in `src/math/feeDecay.sol` and checks it exhaustively.

Adapted from the tick-math generator in EkuboProtocol/starknet-contracts `scripts/codegen/gen-tick-math.ts`
(commit 48d8653): one Q128 constant per exponent bit, `round(2**128 * base**(2**i))`, applied by
multiply-and-shift for every set bit of the integer exponent. Here the exponent is elapsed seconds and the base
is the per-second decay factor 2**(-1/600): a 600 second half-life, so six halvings over the 3,600 second
canonical window. Only nonzero constants are emitted; the chain is exactly zero for exponents at or above
2**len(table).

Run from the repository root:
  python3 test/vectors/gen-fee-decay-table.py            # prints the Solidity constants and the check summary
  python3 test/vectors/gen-fee-decay-table.py --json OUT # also writes the integer vectors for other languages
"""
import argparse
import hashlib
import json
from decimal import Decimal, getcontext

getcontext().prec = 250

Q64 = 1 << 64
Q128 = 1 << 128
HALF_LIFE_SECONDS = 600
# floor(2**64 * 2**(-1/600)): the per-second Q0.64 factor of the previous variable-base implementation.
OLD_FACTOR = 18425445863997925462
MAX_CREATOR_FEE = 18262276632972456099
FEE_50 = Q64 // 2
FEE_03 = Q64 * 3 // 1000


def generate_table():
    base = Decimal(2) ** (Decimal(-1) / HALF_LIFE_SECONDS)
    table = []
    i = 0
    while True:
        value = int((Decimal(Q128) * base ** (Decimal(2) ** i)).to_integral_value(rounding="ROUND_HALF_EVEN"))
        if value == 0:
            return table
        table.append(value)
        i += 1


TABLE = generate_table()


def decay_q128(elapsed):
    """Normative: start at 2**128, multiply by the constant of every set bit and floor to Q128 after each."""
    if elapsed >= 1 << len(TABLE):
        return 0
    result = Q128
    for i, constant in enumerate(TABLE):
        if elapsed >> i & 1:
            result = result * constant >> 128
    return result


def decayed_fee(initial, final, duration, elapsed):
    if elapsed == 0:
        return initial
    if elapsed >= duration:
        return final
    endpoint = decay_q128(duration)
    return final + (initial - final) * (decay_q128(elapsed) - endpoint) // (Q128 - endpoint)


def old_pow_q64(factor, exponent):
    result = Q64
    while exponent:
        if exponent & 1:
            result = result * factor >> 64
        exponent >>= 1
        if exponent:
            factor = factor * factor >> 64
    return result


def old_decayed_fee(initial, final, factor, duration, elapsed):
    if elapsed == 0:
        return initial
    if elapsed >= duration:
        return final
    endpoint = old_pow_q64(factor, duration)
    return final + (initial - final) * (old_pow_q64(factor, elapsed) - endpoint) // (Q64 - endpoint)


def exhaustive_checks():
    limit = 1 << len(TABLE)
    previous = Q128
    worst_error = Decimal(0)
    first_zero = None
    base = Decimal(2) ** (Decimal(-1) / HALF_LIFE_SECONDS)
    for t in range(1, limit + 1):
        value = decay_q128(t)
        assert value <= previous, f"decay not monotone at {t}"
        if value == 0 and first_zero is None:
            first_zero = t
        if t < limit:
            exact = Decimal(Q128) * base ** t
            worst_error = max(worst_error, abs(Decimal(value) - exact))
        previous = value
    assert decay_q128(0) == Q128
    # Every bit above the table is ignored by the chain, so the explicit zero cutoff at `limit` is load-bearing:
    # without it 2**17 + 1 would alias to 1.
    assert decay_q128(limit) == 0 and decay_q128(limit + 1) == 0
    return limit, worst_error, first_zero


def canonical_comparison(duration):
    worst = 0
    worst_at = 0
    monotone = True
    previous = FEE_50
    for t in range(0, duration + 1):
        new = decayed_fee(FEE_50, FEE_03, duration, t)
        old = old_decayed_fee(FEE_50, FEE_03, OLD_FACTOR, duration, t)
        if abs(new - old) > worst:
            worst, worst_at = abs(new - old), t
        if new > previous:
            monotone = False
        previous = new
    return worst, worst_at, monotone


def digest(initial, final, duration):
    h = bytes(32)
    for t in range(duration + 1):
        h = hashlib.sha256(h + decayed_fee(initial, final, duration, t).to_bytes(8, "big")).digest()
    return h.hex()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--json")
    args = parser.parse_args()

    print(f"// base = 2**(-1/{HALF_LIFE_SECONDS}), {len(TABLE)} nonzero Q128 constants, zero at or above 2**{len(TABLE)}")
    for i, constant in enumerate(TABLE):
        print(f"bit {i:2d} (2**{i:<5d} s): 0x{constant:032x}")
    limit, worst_error, first_zero = exhaustive_checks()
    print(
        f"decay_q128 non-increasing on [0, {limit}] (exhaustive); first zero at t={first_zero};"
        f" max |table - exact| = {worst_error:.3f} ulp of 2**-128"
    )
    for duration in (600, 1800, 3600, 7200, 86400):
        worst, worst_at, monotone = canonical_comparison(duration)
        print(
            f"50% -> 0.3% over {duration:>5d} s: max |new - old| = {worst} Q64 units (at t={worst_at}),"
            f" fee non-increasing: {monotone}"
        )

    if args.json:
        rates = {"50": FEE_50, "75": Q64 * 3 // 4, "90": Q64 * 9 // 10, "99": MAX_CREATOR_FEE, "max": Q64 - 1}
        rows = [
            {"initial": str(rate), "final": str(FEE_03), "duration": duration, "elapsed": t,
             "fee": str(decayed_fee(rate, FEE_03, duration, t))}
            for duration in (600, 3600)
            for rate in rates.values()
            for t in sorted({0, 1, 2, 3, 7, 8, 15, 16, 60, 255, 256, 599, 600, 601, 1800, 3599, 3600, 3601, 4095, 4096})
        ]
        out = {
            "base": f"2**(-1/{HALF_LIFE_SECONDS})",
            "fixed_point": "Q128 chain; fee result Q0.64",
            "table_q128": [str(c) for c in TABLE],
            "zero_at_or_above": 1 << len(TABLE),
            "decay_formula": "decay(t) = prod over set bits i of t: floor(prev * table[i] / 2**128), starting at 2**128; 0 for t >= zero_at_or_above",
            "fee_formula": "final + floor((initial - final) * (decay(t) - decay(D)) / (2**128 - decay(D))) for 0 < t < D; initial at t == 0; final at t >= D",
            "decay_samples": [{"t": t, "decay_q128": str(decay_q128(t))} for t in
                              (0, 1, 2, 3, 600, 1200, 3599, 3600, 4095, 4096, 65535, 65536, 131071, 131072)],
            "fee_rows": rows,
            "all_second_digests_sha256": {
                str(duration): {label: digest(rate, FEE_03, duration) for label, rate in rates.items()}
                for duration in (600, 3600)
            },
            "old_factor_q64": str(OLD_FACTOR),
            "canonical_max_abs_diff_vs_old_q64": {
                str(d): canonical_comparison(d)[0] for d in (600, 1800, 3600, 7200, 86400)
            },
        }
        with open(args.json, "w") as f:
            json.dump(out, f, indent=1)
        print(f"wrote {args.json}")


if __name__ == "__main__":
    main()
