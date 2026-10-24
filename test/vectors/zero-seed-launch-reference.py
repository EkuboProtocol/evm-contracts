#!/usr/bin/env python3
"""Independent integer/Decimal checks of the local vectors; no Solidity or network.
Run: python3 test/vectors/zero-seed-launch-reference.py [--export DIR]
--export writes the sampled fee schedules behind every pinned digest as JSON rows
[initial, final, decayRateX32, elapsed, fee] (all decimal strings) for other implementations.
Numeric producer rules are a CTO-freeze proposal, not live parameters.
"""
import hashlib
import importlib.util
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
Q32 = 1 << 32
MAX_TICK_MAGNITUDE = 88722835
MAX_DECAY_PRODUCT = ((MAX_TICK_MAGNITUDE + 1) << 32) - 1
U64_MAX = Q - 1

spec = importlib.util.spec_from_file_location(
    "installation", Path(__file__).with_name("zero-seed-launch-installation.py")
)
installation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installation)


def factor(magnitude):
    """toFixed(tickToSqrtRatio(-magnitude)): the exact port of src/math/ticks.sol in the installation oracle."""
    return installation.to_fixed(installation.tick_to_sqrt_ratio(-magnitude))


def fee_at(initial, final, rate_x32, elapsed):
    """src/math/feeDecay.sol decayedFee with the timestamp clamp of ZeroSeedLaunch._feeAt; the operation order is
    normative: saturation check before the helper, floor of the magnitude, floor of the Q128 product."""
    assert 0 <= final <= initial <= U64_MAX and 0 <= rate_x32 <= U64_MAX
    if elapsed <= 0 or rate_x32 == 0:
        return initial
    if elapsed > MAX_DECAY_PRODUCT // rate_x32:
        return final
    magnitude = (rate_x32 * elapsed) >> 32
    return final + (((initial - final) * factor(magnitude)) >> 128)


def ideal_fee(initial, final, rate_x32, elapsed):
    """Real-number F + (I - F) * 1.000001**(-(rate / 2**32) * t / 2) with the exact rational rate."""
    return Decimal(final) + Decimal(initial - final) * Decimal("1.000001") ** (-(Decimal(rate_x32) / Q32) * elapsed / 2)


getcontext().prec = 150
HALF_LIFE_TICKS = 2 * Decimal(2).ln() / Decimal("1.000001").ln()


def rate_for_half_life(seconds):
    return int((HALF_LIFE_TICKS / seconds * Q32).to_integral_value(rounding="ROUND_FLOOR"))


def half_life_of(rate_x32):
    return HALF_LIFE_TICKS * Q32 / rate_x32


fx = v["fixture"]
DEFAULT_RATE = int(fx["fee_decay_rate_x32_default"])
check(DEFAULT_RATE == 68913100933 == rate_for_half_life(86400))
check(int(fx["fee_decay_rates_x32"][1]) == rate_for_half_life(600))
check(abs(half_life_of(DEFAULT_RATE) - 86400) < Decimal("0.0000011"))
check(Decimal(DEFAULT_RATE) / Q32 == Decimal("16.04508164641447365283966064453125"))
check(HALF_LIFE_TICKS.quantize(Decimal("1e-8")) == Decimal("1386295.05426696"))
check((DEFAULT_RATE * 86400) >> 32 == 1386295)
check(MAX_DECAY_PRODUCT == 381061679028371455 and MAX_DECAY_PRODUCT < 1 << 59)
# The helper's range: MAX_TICK_MAGNITUDE is the last magnitude; one beyond is InvalidTick in Solidity.
check(factor(0) == Q128 and factor(MAX_TICK_MAGNITUDE) == 18447191164202170524 > Q)
check(((U64_MAX * factor(MAX_TICK_MAGNITUDE)) >> 128) == 1)
try:
    factor(MAX_TICK_MAGNITUDE + 1)
    check(False)
except AssertionError:
    check(True)
getcontext().prec = 80

for r in v["fee"]:
    t, rate = int(r["t_minus_start"]), int(r["decayRateX32"])
    check(int(r["fee_q64"]) == fee_at(i, f, rate, t))
    if r["tick_magnitude"] is not None:
        check(int(r["tick_magnitude"]) == (rate * t) >> 32 <= MAX_TICK_MAGNITUDE)
    else:
        check(t <= 0 or t > MAX_DECAY_PRODUCT // rate)

curve = v["fee_curve"]
rates = {k: int(x) for k, x in curve["rates_q64"].items()}
final = int(curve["final_fee_q64"])
check(final == f)
for label, rate in curve["decay_rates_x32"].items():
    rate = int(rate)
    if label in curve["saturation_second"]:
        s = int(curve["saturation_second"][label])
        check(s == MAX_DECAY_PRODUCT // rate)
        check((rate * s) >> 32 <= MAX_TICK_MAGNITUDE < (rate * (s + 1)) >> 32)
        check(fee_at(U64_MAX, 0, rate, s + 1) == 0 and fee_at(U64_MAX, f, rate, s + 1) == f)
        check(fee_at(U64_MAX, f, rate, U64_MAX) == f and fee_at(U64_MAX, f, rate, (1 << 256) - 1) == f)
        if (rate * s) >> 32 == MAX_TICK_MAGNITUDE:
            check(fee_at(U64_MAX, 0, rate, s) == 1)
export = []
for d in curve["digests_sha256"]:
    initial, fin, rate = int(d["initialFee"]), int(d["finalFee"]), int(d["decayRateX32"])
    digest = bytes(32)
    previous = initial
    for t in range(0, int(d["last"]) + 1, int(d["step"])):
        fee = fee_at(initial, fin, rate, t)
        check(fin <= fee <= previous)
        previous = fee
        digest = hashlib.sha256(digest + fee.to_bytes(8, "big")).digest()
        export.append([str(initial), str(fin), str(rate), str(t), str(fee)])
    check(fee_at(initial, fin, rate, 0) == initial)
    check(digest.hex() == d["digest"])
for name, rows in curve["tables"].items():
    initial = {"default_one_day_50_to_0.3": rates["50"], "two_ticks_per_second_50_to_0.3": rates["50"],
               "two_ticks_per_second_99.9_to_0": rates["99.9"], "default_one_day_max_to_0": U64_MAX,
               "min_rate_max_to_0": U64_MAX}[name]
    fin = f if name.endswith("0.3") else 0
    rate = {"default": DEFAULT_RATE, "two_tic": 2 << 32, "min_rat": 1}[name[:7]]
    for r in rows:
        t = int(r["t"])
        check(int(r["fee_q64"]) == fee_at(initial, fin, rate, t))
        check(Decimal(r["pct"]) == (Decimal(int(r["fee_q64"])) / Q * 100).quantize(Decimal("1e-10")))
        if "tick_magnitude" in r:
            check(int(r["tick_magnitude"]) == (rate * t) >> 32)
for step in curve["tick_steps"]:
    rate = int(step["decayRateX32"])
    initial, fin = (f + 1, f) if "one-unit" in step["note"] else (rates["50"], f)
    for r in step["rows"]:
        check(int(r["fee_q64"]) == fee_at(initial, fin, rate, int(r["t"])))
# Design-discussion figures at 2 ticks/s and the default after one day.
check(fee_at(rates["50"], f, 2 << 32, 86400) == 8464509350746382498)
check(fee_at(rates["50"], f, 2 << 32, 30 * 86400) == 741753037726786584)
check(fee_at(rates["99.9"], 0, 2 << 32, 30 * 86400) == 1379731172434914028)
check(MAX_DECAY_PRODUCT // (2 << 32) == 44361417)
check(fee_at(rates["50"], f, DEFAULT_RATE, 86400) == 4639356258918185573)
check((Decimal(4639356258918185573) / Q * 100).quantize(Decimal("1e-10")) == Decimal("25.1500006743"))
# Error against the real-number formula: below one whole tick of the excess (5e-7), the quantization of m.
getcontext().prec = 150
bounds = curve["oracle_error_bounds"]
worst = Decimal(0)
worst_at = None
for t in list(range(0, 3601)) + list(range(3600, 30 * 86400 + 1, 600)):
    err = abs(Decimal(fee_at(rates["50"], f, DEFAULT_RATE, t)) - ideal_fee(rates["50"], f, DEFAULT_RATE, t))
    if err > worst:
        worst, worst_at = err, t
check(worst.quantize(Decimal("0.001")) == Decimal(bounds["max_abs_q64"]) and worst_at == int(bounds["at_t"]))
check(worst / Decimal(rates["50"] - f) < 1 - Decimal("1.000001") ** Decimal("-0.5"))
getcontext().prec = 80

# Exact installation oracle (tick table port, Core's rounded debits, direct inverse): every creation row installs
# the largest liquidity its requested supply pays for, in both orders.
for r in v["create"]:
    exact = installation.installation(
        r["order"] == "t0", int(r["ask"]), int(r["upper"]), v["fixture"]["tick_spacing"], int(r["requested"])
    )
    check(int(exact["liquidity"]) == int(r["liquidity"]) and int(exact["installedSupply"]) == int(r["installed"]))
    check(int(exact["debitAtLiquidityPlusOne"]) > int(r["requested"]))
for r in v["installation"]["vectors"]:
    exact = installation.installation(r["order"] == "t0", int(r["ask"]), int(r["upper"]), int(r["spacing"]), int(r["supply"]))
    check(int(exact["liquidity"]) == int(r["liquidity"]) and int(exact["installedSupply"]) == int(r["installed"]))
    check(int(exact["previousLiquidity"]) == int(r["previous_liquidity"]) < int(r["liquidity"]))

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


# Creator fee range: the whole uint64, no ceiling below the type; 2**64 is not encodable; schedule shape only.
fee_range = v["creator_fee_range"]
check(int(fee_range["max_q64"]) == U64_MAX and int(fee_range["min_q64"]) == 0)
check(int(v["fixture"]["max_creator_fee_q64"]) == U64_MAX)
check(int(fee_range["unencodable"]["value"]) == Q)
check(int(fee_range["unencodable"]["dirty_high_bits"]["value"]) == Q | U64_MAX)


def fee_verdict(initial, final, rate_x32):
    if initial > U64_MAX or final > U64_MAX or rate_x32 > U64_MAX:
        return "abi_decoding_failure"
    if final > initial:
        return "InvalidFeeSchedule"
    return "accept"


for r in fee_range["vectors"]:
    check(fee_verdict(int(r["initialFee"]), int(r["finalFee"]), int(r["decayRateX32"])) == r["verdict"])
    if r["verdict"] == "accept":
        initial, final, rate = int(r["initialFee"]), int(r["finalFee"]), int(r["decayRateX32"])
        check(fee_at(initial, final, rate, 0) == initial)
        check(fee_at(initial, final, rate, (1 << 256) - 1) == (initial if rate == 0 else final))
        previous = initial
        for t in (1, 2, 599, 600, 1800, 3600, 86400, 30 * 86400, MAX_DECAY_PRODUCT, MAX_DECAY_PRODUCT + 1, U64_MAX):
            fee = fee_at(initial, final, rate, t)
            check(final <= fee <= previous)
            previous = fee
        if rate >= Q32 and final < initial:
            check(fee_at(initial, final, rate, 1) < initial)
        if rate == U64_MAX:
            check(fee_at(initial, final, rate, 1) == final)
for label in ("fixture", "consumer_default"):
    s_ = fee_range["reference_schedules"][label]
    check(fee_verdict(int(s_["initialFee"]), int(s_["finalFee"]), int(s_["decayRateX32"])) == "accept")
    check(int(s_["decayRateX32"]) == DEFAULT_RATE)
cd = fee_range["reference_schedules"]["consumer_default"]
check(int(cd["initialFee"]) == Q // 2 and int(cd["fee_after_one_day_q64"]) == fee_at(Q // 2, f, DEFAULT_RATE, 86400))
check(int(fee_range["reference_schedules"]["fixture"]["initialFee"]) == i)
check(fee_range["removed"]["selector"] == "0xcd4e6167")
check(int(curve["rates_q64"]["max"]) == U64_MAX)

# Maximum rate: exact input nets floor(gross / 2**64); exact output pays calc * 2**64; both representation limits.
max_rate = v["max_rate"]
for r in max_rate["trades"]:
    if r["step"] in ("oneUnit", "buyExactIn"):
        gross, fee, net = int(r["gross"]), int(r["fee"]), int(r["net"])
        check(net == gross >> 64 and fee == gross - net)
        check(fee == -(-gross * U64_MAX // Q))
        check((r["step"] == "oneUnit") == (net == 0))
    elif r["step"] == "buyExactOut":
        calc, paid, fee = int(r["calcQuote"]), int(r["paid"]), int(r["fee"])
        check(paid == calc << 64 and fee == paid - calc)
        check(paid == -(-(calc * Q) // (Q - U64_MAX)))
    elif r["step"] == "sellAll":
        gross, fee, out = int(r["grossQuote"]), int(r["fee"]), int(r["quoteOut"])
        check(out == gross >> 64 and fee == gross - out)
bounds = max_rate["exact_output_bounds"]
check(int(bounds["signed_bound_calc"]) == (1 << 63) - 1 and int(bounds["helper_bound_calc"]) == U64_MAX)
for r in bounds["vectors"]:
    calc, paid = int(r["calc"]), int(r["paid"])
    check(calc == (1 << 63) - 1 and paid == calc << 64 and paid < 1 << 127)
    check((calc + 1) << 64 == 1 << 127)
    check(int(r["firstSignedOverflowTokenOut"]) == int(r["lastValidTokenOut"]) + 1)
    check(int(r["firstHelperOverflowTokenOut"]) == int(r["lastSignedOverflowTokenOut"]) + 1)
    check(int(r["lastSignedOverflowTokenOut"]) > int(r["firstSignedOverflowTokenOut"]))
    installed = {c["order"]: int(c["installed"]) for c in v["create"] if c["dec"] == "18/18"}
    check(int(r["firstHelperOverflowTokenOut"]) < installed[r["order"]])

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
    (out / "fee-curve-samples.json").write_text(json.dumps(export) + "\n")
    print(f"exported {len(export)} rows to {out / 'fee-curve-samples.json'}")

print(f"PASS: {checks} independent tick-rate fee, liquidity, dust, start/expiry checks")
