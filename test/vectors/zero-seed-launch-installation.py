#!/usr/bin/env python3
"""Independent integer oracle for the zero-seed installation (liquidity) math; no Solidity or network.
Run: python3 test/vectors/zero-seed-launch-installation.py [--write] [--sweep N] [--solidity]
Checks zero-seed-launch-installation.json against an exact port of tickToSqrtRatio, Core's rounded debits and a
direct big-integer inverse that does not use the contract's mantissa factorization; --write regenerates the vectors,
--sweep N adds N pseudo-random full-domain cases, --solidity prints the vectors as Solidity test rows.
"""
import json
import random
import sys
from pathlib import Path

MIN_TICK, MAX_TICK = -88722835, 88722835
MAX_TICK_SPACING = 698605
Q128 = 1 << 128
U128 = (1 << 128) - 1
I128 = (1 << 127) - 1
BIT_MASK = 0xC00000000000000000000000
# src/math/ticks.sol: one constant per magnitude bit, floored to Q128 after every multiply; bit 0 is a subtraction.
BIT0 = 0x8637B66CD638344DAEF276CD7C5
CONSTANTS = [
    (0x2, 0xFFFFEF390978C398134B4FF3764FE410), (0x4, 0xFFFFDE72140B00A354BD3DC828E976C9),
    (0x8, 0xFFFFBCE42C7BE6C998AD6318193C0B18), (0x10, 0xFFFF79C86A8F6150A32D9778ECEEF97C),
    (0x20, 0xFFFEF3911B7CFF24BA1B3DBB5F8F5974), (0x40, 0xFFFDE72350725CC4EA8FEECE3B5F13C8),
    (0x80, 0xFFFBCE4B06C196E9247AC87695D53C60), (0x100, 0xFFF79CA7A4D1BF1EE8556CEA23CDBAA5),
    (0x200, 0xFFEF3995A5B6A6267530F207142A5764), (0x400, 0xFFDE7444B28145508125D10077BA83B8),
    (0x800, 0xFFBCECEEB791747F10DF216F2E53EC57), (0x1000, 0xFF79EB706B9A64C6431D76E63531E929),
    (0x2000, 0xFEF41D1A5F2AE3A20676BEC6F7F9459A), (0x4000, 0xFDE95287D26D81BEA159C37073122C73),
    (0x8000, 0xFBD701C7CBC4C8A6BB81EFD232D1E4E7), (0x10000, 0xF7BF5211C72F5185F372AEB1D48F937E),
    (0x20000, 0xEFC2BF59DF33ECC28125CF78EC4F167F), (0x40000, 0xE08D35706200796273F0B3A981D90CFD),
    (0x80000, 0xC4F76B68947482DC198A48A54348C4ED), (0x100000, 0x978BCB9894317807E5FA4498EEE7C0FA),
    (0x200000, 0x59B63684B86E9F486EC54727371BA6CA), (0x400000, 0x1F703399D88F6AA83A28B22D4A1F56E3),
    (0x800000, 0x3DC5DAC7376E20FC8679758D1BCDCFC), (0x1000000, 0xEE7E32D61FDB0A5E622B820F681D0),
    (0x2000000, 0xDE2EE4BC381AFA7089AA84BB66), (0x4000000, 0xC0D55D4D7152C25FB139),
]
ZERO_LIQUIDITY = "0x10074548"
LIQUIDITY_ABOVE_TICK_CAP = "0x20ea795f"
checks = 0


def check(condition, what=""):
    global checks
    assert condition, f"installation check {checks + 1} failed {what}"
    checks += 1


def ceil_div(a, b):
    return -(-a // b)


def compact(fixed):
    """types/sqrtRatio.sol toSqrtRatio(fixed, roundUp = false): a 94-bit mantissa and a 2-bit region."""
    if fixed < 1 << 96:
        return fixed >> 2
    if fixed < 1 << 128:
        return (1 << 94) | (fixed >> 34)
    if fixed < 1 << 160:
        return (1 << 95) | (fixed >> 66)
    if fixed < 1 << 192:
        return (3 << 94) | (fixed >> 98)
    raise OverflowError(fixed)


def mantissa_shift(sqrt_ratio):
    return sqrt_ratio & ~BIT_MASK, 2 + ((sqrt_ratio & BIT_MASK) >> 89)


def to_fixed(sqrt_ratio):
    mantissa, shift = mantissa_shift(sqrt_ratio)
    return mantissa << shift


def tick_to_sqrt_ratio(tick):
    """math/ticks.sol tickToSqrtRatio, compact value."""
    magnitude = abs(tick)
    assert magnitude <= MAX_TICK
    ratio = Q128 - (magnitude & 1) * BIT0
    for bit, constant in CONSTANTS:
        if magnitude & bit:
            ratio = (ratio * constant) >> 128
    if tick > 0:
        ratio = ((1 << 256) - 1) // ratio
    return compact(ratio)


def debit0(lower, upper, liquidity):
    """Core's token0 amount for `liquidity` at or below `lower` (math/delta.sol amount0DeltaSorted, roundUp)."""
    first = ceil_div((liquidity << 128) * (upper - lower), upper)
    return ceil_div(first, lower)


def debit1(lower, upper, liquidity):
    """Core's token1 amount for `liquidity` at or above `upper` (amount1DeltaSorted, roundUp)."""
    return ceil_div(liquidity * (upper - lower), Q128)


def exact_token0(lower, upper, supply):
    """Largest liquidity whose token0 debit stays within supply: one big-integer division, no factorization."""
    return (supply * upper * lower) // ((upper - lower) << 128)


def exact_token1(lower, upper, supply):
    return (supply << 128) // (upper - lower)


def search_token0(lower, upper, supply):
    """The same maximum by the rounded-debit inequality only."""
    low, high = 0, 1 << 256
    while low < high:
        mid = (low + high + 1) // 2
        if debit0(lower, upper, mid) <= supply:
            low = mid
        else:
            high = mid - 1
    return low


def previous_token0(lower, upper, supply):
    """math/liquidity.sol maxLiquidityForToken0: floors lower * upper / 2**128 before the supply multiply."""
    return min(U128, (supply * ((lower * upper) >> 128)) // (upper - lower))


def tick_cap(spacing):
    return U128 // (1 + 2 * (MAX_TICK // spacing))


def installation(token_is0, ask, upper, spacing, supply):
    """ZeroSeedLaunch.previewInstallation amounts for economic ticks: a dict with liquidity and installedSupply or
    with error; `previous` carries the shared-helper result for the same inputs."""
    assert 0 < supply <= I128 and 0 < spacing <= MAX_TICK_SPACING and MIN_TICK <= ask < upper <= MAX_TICK
    tick_lower, tick_upper = (ask, upper) if token_is0 else (-upper, -ask)
    assert tick_lower % spacing == 0 and tick_upper % spacing == 0
    lower_c, upper_c = tick_to_sqrt_ratio(tick_lower), tick_to_sqrt_ratio(tick_upper)
    lower_fixed, upper_fixed = to_fixed(lower_c), to_fixed(upper_c)
    if token_is0:
        liquidity = exact_token0(lower_fixed, upper_fixed, supply)
        previous = previous_token0(lower_fixed, upper_fixed, supply)
    else:
        liquidity = previous = exact_token1(lower_fixed, upper_fixed, supply)
    liquidity, cap = min(U128, liquidity), tick_cap(spacing)
    row = {
        "order": "t0" if token_is0 else "t1", "askTick": ask, "upperTick": upper, "tickSpacing": spacing,
        "supply": str(supply), "tickLower": tick_lower, "tickUpper": tick_upper,
        "initialTick": tick_lower if token_is0 else tick_upper,
        "lowerSqrtRatio": str(lower_c), "upperSqrtRatio": str(upper_c),
        "lowerFixed": str(lower_fixed), "upperFixed": str(upper_fixed), "tickCap": str(cap),
    }
    lower, upper = lower_fixed, upper_fixed
    if liquidity == 0:
        return {**row, "error": "ZeroLiquidity", "selector": ZERO_LIQUIDITY, "previousLiquidity": str(previous)}
    if liquidity > cap:
        return {**row, "error": "LiquidityAboveTickCap", "selector": LIQUIDITY_ABOVE_TICK_CAP,
                "liquidity": str(liquidity), "previousLiquidity": str(previous)}
    debit = debit0 if token_is0 else debit1
    installed = debit(lower, upper, liquidity)
    next_debit = debit(lower, upper, liquidity + 1)
    row.update({
        "liquidity": str(liquidity), "installedSupply": str(installed), "sink": str(supply - installed),
        "debitAtLiquidityPlusOne": str(next_debit), "previousLiquidity": str(previous),
    })
    if previous != liquidity:
        row["previousInstalledSupply"] = str(debit(lower, upper, previous)) if previous else "0"
    return row


# Label, order, ask, upper, spacing, supply. Economic ticks: the t1 rows negate and swap them in the pool.
VECTORS = [
    ("fixture 18/18", True, -13815500, -9210300, 100, 10**27),
    ("fixture 18/18", False, -13815500, -9210300, 100, 10**27),
    ("fixture 18/6", True, -41446500, -36841300, 100, 10**27),
    ("fixture 18/6", False, -41446500, -36841300, 100, 10**27),
    ("low price, 1e30", True, -88080384, -85983232, 524288, 10**30),
    ("low price, 1e30", False, -88080384, -85983232, 524288, 10**30),
    ("low price, two liquidity units", True, -88080384, -85983232, 524288, 17380183081064167375),
    ("low price, one unit short", True, -88080384, -85983232, 524288, 17380183081064167374),
    ("low price, below one unit", True, -88080384, -85983232, 524288, 8690091540532083687),
    ("full width, int128 budget", True, -88722835, 88722835, 1, 170141183460469231694794709727778658247),
    ("full width, int128.max", True, -88722835, 88722835, 1, I128),
    ("full width, int128.max", False, -88722835, 88722835, 1, I128),
    ("full width, 1e27", True, -88722835, 88722835, 1, 10**27),
    ("adjacent ticks at the bottom", True, -88722835, -88722834, 1, I128),
    ("adjacent ticks at the bottom", False, -88722835, -88722834, 1, I128),
    ("adjacent ticks at the top", True, 88722834, 88722835, 1, I128),
    ("adjacent ticks at the top", False, 88722834, 88722835, 1, I128),
    ("adjacent ticks at the top", True, 88722834, 88722835, 1, 1),
    ("adjacent ticks at the top, cap", True, 88722834, 88722835, 1, 10**12),
    ("region 2**96 crossing", True, -44361441 - 1, -44361441, 1, 10**27),
    ("region 2**96 crossing", True, -44361441 - 1, -44361441 + 1, 1, I128),
    ("region 2**96 crossing wide", True, -44361442, 0, 1, 10**27),
    ("region 2**128 crossing", True, -1, 1, 1, 10**27),
    ("region 2**128 crossing", False, -1, 1, 1, 10**27),
    ("region 2**160 crossing", True, 44361441, 44361442, 1, 10**27),
    ("region 2**160 crossing", False, 44361441, 44361442, 1, 10**27),
    ("three regions", True, -44361442, 44361442, 2, 10**27),
    ("three regions", False, -44361442, 44361442, 2, 10**27),
    ("max spacing, MIN_TICK aligned", True, -698605 * 127, 698605 * 10, 698605, 10**27),
    ("max spacing, MIN_TICK aligned", False, -698605 * 127, 698605 * 10, 698605, 10**27),
    ("max spacing, full width", True, -698605 * 127, 698605 * 127, 698605, I128),
    ("supply 1", True, -13815500, -9210300, 100, 1),
    ("supply 1", False, -13815500, -9210300, 100, 1),
    ("supply 1, high price", True, 60000000, 70000000, 100, 1),
    ("zero liquidity", True, -80000000, -75394800, 100, 1),
    ("above tick cap", True, 80000000, 84605200, 100, I128),
    ("above tick cap", False, 80000000, 84605200, 100, I128),
    ("int128.max at the fixture", True, -13815500, -9210300, 100, I128),
    ("int128.max at the fixture", False, -13815500, -9210300, 100, I128),
    ("narrow at the fixture", True, -13815500, -13815400, 100, 10**27),
    ("narrow at the fixture", False, -13815500, -13815400, 100, 10**27),
]


def generate():
    rows = []
    for label, token_is0, ask, upper, spacing, supply in VECTORS:
        rows.append({"label": label, **installation(token_is0, ask, upper, spacing, supply)})
    return rows


def verify_row(row):
    token_is0 = row["order"] == "t0"
    recomputed = installation(token_is0, row["askTick"], row["upperTick"], row["tickSpacing"], int(row["supply"]))
    check({k: v for k, v in row.items() if k != "label"} == recomputed, row.get("label"))
    lower, upper = int(row["lowerFixed"]), int(row["upperFixed"])
    supply = int(row["supply"])
    check(to_fixed(tick_to_sqrt_ratio(row["tickLower"])) == lower and to_fixed(tick_to_sqrt_ratio(row["tickUpper"])) == upper)
    if "installedSupply" in row:
        liquidity = int(row["liquidity"])
        debit = debit0 if token_is0 else debit1
        # The direct inequality: the installed liquidity is affordable and the next unit is not.
        check(debit(lower, upper, liquidity) == int(row["installedSupply"]) <= supply)
        check(debit(lower, upper, liquidity + 1) == int(row["debitAtLiquidityPlusOne"]) > supply)
        check(int(row["sink"]) == supply - int(row["installedSupply"]))
        if token_is0:
            check(search_token0(lower, upper, supply) == liquidity)
        check(int(row["previousLiquidity"]) <= liquidity)
        check(0 < liquidity <= int(row["tickCap"]))
    elif row["error"] == "ZeroLiquidity":
        check((debit0 if token_is0 else debit1)(lower, upper, 1) > supply)
    else:
        liquidity = int(row["liquidity"])
        check(liquidity > int(row["tickCap"]))
        check(liquidity == U128 or (debit0 if token_is0 else debit1)(lower, upper, liquidity) <= supply)


def sweep(count, seed=0x5EED):
    """Pseudo-random full-domain cases: both orders, every spacing class, supplies at liquidity-quantization
    boundaries, small and maximal supplies, adjacent and full-width ranges."""
    rng = random.Random(seed)
    improved = 0
    for _ in range(count):
        spacing = rng.choice([1, 2, 100, 200, 1000, 524288, MAX_TICK_SPACING, rng.randint(1, MAX_TICK_SPACING)])
        low_index, high_index = ceil_div(MIN_TICK, spacing), MAX_TICK // spacing
        a = rng.randint(low_index, high_index - 1)
        b = a + 1 if rng.random() < 0.3 else rng.randint(a + 1, high_index)
        lower, upper = to_fixed(tick_to_sqrt_ratio(a * spacing)), to_fixed(tick_to_sqrt_ratio(b * spacing))
        check(0 < lower < upper)
        supply = rng.choice([1, 2, 3, rng.randint(1, 10**6), rng.randint(1, 10**20), rng.randint(1, 10**30), I128,
                             I128 - 1, rng.randint(1, I128)])
        liquidity = exact_token0(lower, upper, supply)
        check(debit0(lower, upper, liquidity) <= supply < debit0(lower, upper, liquidity + 1), (a, b, spacing, supply))
        check(previous_token0(lower, upper, supply) <= liquidity)
        improved += previous_token0(lower, upper, supply) < min(liquidity, U128)
        if liquidity < 1 << 40 or rng.random() < 0.02:
            check(search_token0(lower, upper, supply) == liquidity)
        # Mantissa factorization used by the contract, proven equal to the direct division.
        lower_c, upper_c = compact(lower), compact(upper)
        (m_lower, s_lower), (m_upper, s_upper) = mantissa_shift(lower_c), mantissa_shift(upper_c)
        check(s_lower <= s_upper and (upper - lower) % (1 << s_lower) == 0)
        denominator = ((upper - lower) >> s_lower) << (128 - s_upper)
        check(0 < denominator < 1 << 220 and supply * m_lower * m_upper < 1 << 315)
        check((supply * m_lower * m_upper) // denominator == liquidity and liquidity < 1 << 213)
        # Quantization boundary: a supply equal to a debit affords at least that liquidity, one less does not.
        probe = rng.randint(1, 1 << rng.randint(1, 100))
        at_debit = debit0(lower, upper, probe)
        if at_debit <= I128:
            check(exact_token0(lower, upper, at_debit) >= probe and (at_debit == 1 or exact_token0(lower, upper, at_debit - 1) < probe))
        # Token1 order: the shared helper's single floor is already exact.
        liquidity1 = exact_token1(lower, upper, supply)
        check(debit1(lower, upper, liquidity1) <= supply < debit1(lower, upper, liquidity1 + 1))
    return improved


def main():
    path = Path(__file__).with_name("zero-seed-launch-installation.json")
    args = sys.argv[1:]
    rows = generate()
    if "--write" in args:
        existing = json.loads(path.read_text()) if path.exists() else {}
        document = {
            "version": 1,
            "scope": "LOCAL integer vectors for ZeroSeedLaunch.previewInstallation amounts; economic ticks; no deployment",
            "token0_liquidity": "floor(supply * lowerFixed * upperFixed / (2**128 * (upperFixed - lowerFixed))), the exact inverse of Core's token0 debit ceil(ceil(liquidity * 2**128 * (upperFixed - lowerFixed) / upperFixed) / lowerFixed); computed on chain as floor(supply * mantissaLower * mantissaUpper / (((upperFixed - lowerFixed) >> shiftLower) << (128 - shiftUpper))) from the compact sqrt ratios (mantissa = low 94 bits, shift = 2 + 32 * top two bits); saturates at 2**128 - 1",
            "token1_liquidity": "floor(supply * 2**128 / (upperFixed - lowerFixed)), unchanged shared helper; the exact inverse of ceil(liquidity * (upperFixed - lowerFixed) / 2**128)",
            "installed_supply": "the debit above at the installed liquidity; sink = supply - installedSupply is minted to address(0); totalSupply = supply",
            "refusals": {"ZeroLiquidity": ZERO_LIQUIDITY, "LiquidityAboveTickCap(uint128,uint128)": LIQUIDITY_ABOVE_TICK_CAP,
                         "tick_cap": "floor((2**128 - 1) / (1 + 2 * floor(88722835 / tickSpacing))); liquidity above it, including the uint128 saturation, is refused rather than capped"},
            "previous": "previousLiquidity is math/liquidity.sol maxLiquidityForToken0 (floor(lowerFixed * upperFixed / 2**128) before the supply multiply) for the same inputs; previousInstalledSupply is present where it differs",
            "pins": existing.get("pins", {}),
            "vectors": rows,
        }
        path.write_text(json.dumps(document, indent=1) + "\n")
        print(f"wrote {len(rows)} vectors to {path}")
    document = json.loads(path.read_text())
    check([{k: v for k, v in r.items()} for r in document["vectors"]] == rows)
    for row in document["vectors"]:
        verify_row(row)
    count = int(args[args.index("--sweep") + 1]) if "--sweep" in args else 2000
    improved = sweep(count)
    if "--solidity" in args:
        for row in document["vectors"]:
            print(f'// {row["label"]}: {row.get("error", "liquidity " + row.get("liquidity", ""))}')
            print(f'_row({"true" if row["order"] == "t0" else "false"}, {row["askTick"]}, {row["upperTick"]}, {row["tickSpacing"]}, '
                  f'{row["supply"]}, {row.get("liquidity", 0)}, {row.get("installedSupply", 0)}, {row.get("selector", "0x00000000")});')
    print(f"PASS: {checks} installation checks over {len(rows)} vectors and {count} sweep cases "
          f"({improved} where the previous token0 helper under-installed)")


if __name__ == "__main__":
    main()
