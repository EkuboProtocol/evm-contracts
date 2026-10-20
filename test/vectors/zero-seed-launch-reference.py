#!/usr/bin/env python3
"""Independent integer/Decimal checks of the local vectors; no Solidity or network.
Run: python3 test/vectors/zero-seed-launch-reference.py [--export DIR]
--export writes every second of both windows at all rates as JSON rows
[initial, final, duration, elapsed, fee] (all decimal strings) for other implementations.
Numeric producer rules are a CTO-freeze proposal, not live parameters.
"""
import hashlib
import json
import sys
from decimal import Decimal, getcontext
from pathlib import Path

getcontext().prec = 80
v = json.loads(
    Path(__file__).with_name("zero-seed-launch.json").read_text()
)
Q = 1 << 64
i, f = Q * 5 // 100, Q * 3 // 1000
checks = 0


def check(condition):
    global checks
    assert condition, f"reference check {checks + 1} failed"
    checks += 1




Q128 = 1 << 128
TABLE = [int(c) for c in v["fixture"]["fee_decay_table_q128"]]
ZERO_FROM = int(v["fixture"]["fee_decay_zero_from_s"])


def decay(elapsed):
    """Fixed-base chain in Q128: one constant per set bit of the integer exponent, floor after every multiply; the
    operation order is normative. Zero at and above ZERO_FROM, where the table has no constant."""
    if elapsed >= ZERO_FROM:
        return 0
    result = Q128
    for bit, constant in enumerate(TABLE):
        if elapsed >> bit & 1:
            result = result * constant // Q128
    return result


def fee_at(initial, final, duration, elapsed):
    if elapsed <= 0:
        return initial
    if elapsed >= duration:
        return final
    end = decay(duration)
    return final + (initial - final) * (decay(elapsed) - end) // (Q128 - end)


def linear_at(initial, final, duration, elapsed):
    if elapsed <= 0:
        return initial
    if elapsed >= duration:
        return final
    return initial - (initial - final) * elapsed // duration


# Table provenance: round(2**128 * 2**(-2**bit/600)) at 250-digit precision, nonzero constants only.
getcontext().prec = 250
for bit, constant in enumerate(TABLE):
    exact = Decimal(Q128) * Decimal(2) ** (-(Decimal(2) ** bit) / 600)
    check(int(exact.to_integral_value(rounding="ROUND_HALF_EVEN")) == constant)
check(len(TABLE) == 17 and ZERO_FROM == 1 << len(TABLE))
check(int((Decimal(Q128) * Decimal(2) ** (-(Decimal(2) ** len(TABLE)) / 600)).to_integral_value()) == 0)
getcontext().prec = 80
check(decay(0) == Q128 and decay(600) == (Q128 >> 1) - 1 and decay(3600) == (Q128 >> 6) - 1)
check(decay(int(v["fixture"]["fee_decay_first_zero_s"]) - 1) == 1 and decay(int(v["fixture"]["fee_decay_first_zero_s"])) == 0)
check(decay(ZERO_FROM + 1) == 0)
# Exhaustive: the chain never increases over its whole nonzero domain, so every fee schedule is non-increasing.
previous = Q128
for t in range(1, ZERO_FROM + 1):
    value = decay(t)
    check(value <= previous)
    previous = value

for r in v["fee"]:
    t, dur = int(r["t_minus_start"]), int(r["duration"])
    check(int(r["fee_q64"]) == fee_at(i, f, dur, t))

curve = v["fee_curve"]
rates = {k: int(x) for k, x in curve["rates_q64"].items()}
final = int(curve["final_fee_q64"])
check(final == f)
export = []
for dur, digests in curve["all_second_digests_sha256"].items():
    dur = int(dur)
    for label, rate in rates.items():
        digest = bytes(32)
        previous = rate
        for t in range(dur + 1):
            fee = fee_at(rate, final, dur, t)
            check(final <= fee <= previous)
            previous = fee
            digest = hashlib.sha256(digest + fee.to_bytes(8, "big")).digest()
            export.append([str(rate), str(final), str(dur), str(t), str(fee)])
        check(fee_at(rate, final, dur, 0) == rate and fee == final)
        check(digest.hex() == digests[label])


def legacy_pow(factor, exponent):
    result = Q
    while exponent:
        if exponent & 1:
            result = result * factor // Q
        exponent >>= 1
        if exponent:
            factor = factor * factor // Q
    return result


def legacy_fee(initial, final, factor, duration, elapsed):
    if elapsed <= 0:
        return initial
    if elapsed >= duration:
        return final
    end = legacy_pow(factor, duration)
    return final + (initial - final) * (legacy_pow(factor, elapsed) - end) // (Q - end)


legacy = curve["legacy_comparison"]
legacy_factor = int(legacy["legacy_factor_q64"])
for dur, worst in legacy["max_abs_diff_q64_by_duration"].items():
    dur = int(dur)
    check(max(abs(fee_at(rates["50"], final, dur, t) - legacy_fee(rates["50"], final, legacy_factor, dur, t))
              for t in range(dur + 1)) == worst)

for r in v["create"]:
    ask, upper = Decimal(r["ask"]), Decimal(r["upper"])
    supply, liquidity = Decimal(r["installed"]), Decimal(r["liquidity"])
    if r["order"] == "t0":
        lo, hi = Decimal("1.000001") ** (ask / 2), Decimal("1.000001") ** (upper / 2)
        ideal = supply / (1 / lo - 1 / hi)
    else:
        lo, hi = Decimal("1.000001") ** (-upper / 2), Decimal("1.000001") ** (-ask / 2)
        ideal = supply / (hi - lo)
    check(abs(liquidity - ideal) / ideal < Decimal("3e-20"))
    check(0 < int(r["installed"]) <= int(r["requested"]))

for r in v["trade"]:
    if r["step"] == "buyExactIn":
        gross, fee = int(r["gross"]), int(r["fee"])
        check(fee == -(-gross * i // Q))
        check(int(r["net"]) == gross - fee)
    elif r["step"] == "buyExactOut":
        calc, paid = int(r["calcQuote"]), int(r["paid"])
        check(paid == -(-(calc * Q) // (Q - i)))
        check(int(r["fee"]) == paid - calc)

for r in v["residue_metrics"]["scenarios"]:
    residue = int(r["upper_residue_raw_token"])
    check(int(r["position_token_before_exhaust"]) - int(r["delivered_raw_token"]) == residue)
    check(int(r["core_dust_after_exhaust"]["raw_token"]) ==
          int(r["core_dust_before_exhaust"]["raw_token"]) + residue)
    check(int(r["core_dust_after_exhaust"]["raw_quote"]) >= 0)

p = v["start"]["producer_proposal"]
for r in p["vectors"]:
    build, start, expiry = r["buildTime"], r["tradingStart"], r["expiry"]
    supported = (build + p["minMargin_s"] <= start <= build + p["maxDelay_s"]
                 and build < expiry <= start)
    check(supported == r["verdict"].startswith("accept"))

for r in v["start"]["contract"]:
    check((int(r["tradingStart"]) >= r["block_time"]) == r["create"].startswith("ok"))
late = v["start"]["contract_mined_late"]
check(late["previewed_at"] <= late["tradingStart"] < late["mined_at"])

if len(sys.argv) == 3 and sys.argv[1] == "--export":
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    (out / "fee-curve-all-seconds.json").write_text(json.dumps(export) + "\n")
    print(f"exported {len(export)} rows to {out / 'fee-curve-all-seconds.json'}")

print(f"PASS: {checks} independent table, fee, liquidity, dust, start/expiry checks")
