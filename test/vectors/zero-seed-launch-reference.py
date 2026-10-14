#!/usr/bin/env python3
"""Independent integer/Decimal checks of the local vectors; no Solidity or network.
Run: python3 test/vectors/zero-seed-launch-reference.py
Numeric producer rules are a CTO-freeze proposal, not live parameters.
"""
import json
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


for r in v["fee"]:
    t, dur = int(r["t_minus_start"]), int(r["duration"])
    expected = i if t <= 0 else f if t >= dur else i - (i - f) * t // dur
    check(int(r["fee_q64"]) == expected)

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

print(f"PASS: {checks} independent fee, liquidity, dust, start/expiry checks")
