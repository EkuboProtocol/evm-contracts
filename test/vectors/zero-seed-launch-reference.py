#!/usr/bin/env python3
"""Independent integer/Decimal checks of the local vectors; no Solidity or network.
Run: python3 test/vectors/zero-seed-launch-reference.py [--export DIR]
--export writes every second of both study schedules at all six rates as JSON rows
[initial, final, duration, factor, elapsed, fee] (all decimal strings) for other implementations.
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




def power(factor, exponent):
    """Square-and-multiply in Q0.64, floor after every multiply; the operation order is normative."""
    result = Q
    while exponent:
        if exponent & 1:
            result = result * factor // Q
        exponent >>= 1
        if exponent:
            factor = factor * factor // Q
    return result


def fee_at(initial, final, duration, factor, elapsed):
    if elapsed <= 0:
        return initial
    if elapsed >= duration:
        return final
    end = power(factor, duration)
    return final + (initial - final) * (power(factor, elapsed) - end) // (Q - end)


def linear_at(initial, final, duration, elapsed):
    if elapsed <= 0:
        return initial
    if elapsed >= duration:
        return final
    return initial - (initial - final) * elapsed // duration


factors = {int(k): int(x) for k, x in v["fixture"]["fee_decay_factors_q64"].items()}
for r in v["fee"]:
    t, dur = int(r["t_minus_start"]), int(r["duration"])
    check(int(r["decay_factor_q64"]) == factors[dur])
    check(int(r["fee_q64"]) == fee_at(i, f, dur, factors[dur], t))

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
            fee = fee_at(rate, final, dur, factors[dur], t)
            check(final <= fee <= previous)
            check(fee <= linear_at(rate, final, dur, t))
            previous = fee
            digest = hashlib.sha256(digest + fee.to_bytes(8, "big")).digest()
            export.append([str(rate), str(final), str(dur), str(factors[dur]), str(t), str(fee)])
        check(fee_at(rate, final, dur, factors[dur], 0) == rate and fee == final)
        check(digest.hex() == digests[label])

half = curve["half_life_fixture"]
for r in half["values"]:
    check(int(r["fee_q64"]) == fee_at(int(half["initial_q64"]), int(half["final_q64"]), half["duration"],
                                      int(half["factor_q64"]), r["t"]))

for r in curve["integer_chord_exceptions"]["rows"]:
    initial, terminal = int(r["initial"]), int(r["final"])
    fee = fee_at(initial, terminal, r["duration"], int(r["factor"]), r["elapsed"])
    chord = linear_at(initial, terminal, r["duration"], r["elapsed"])
    check(fee == int(r["exponential"]) and chord == int(r["linear"]))
    check(fee > chord and fee - chord == int(r["excess_q64"]))
    check(terminal <= fee <= initial)
    check(fee_at(initial, terminal, r["duration"], int(r["factor"]), r["elapsed"] + 1) <= fee)

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

print(f"PASS: {checks} independent fee, liquidity, dust, start/expiry checks")
