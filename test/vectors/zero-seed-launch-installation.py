#!/usr/bin/env python3
"""Independent integer oracle for the zero-seed installation math; no Solidity or network.
Run: python3 test/vectors/zero-seed-launch-installation.py [--write] [--sweep N] [--solidity]
Checks zero-seed-launch-installation.json against an exact port of tickToSqrtRatio, Core's rounded debits, the
spacing/alignment rule of src/math/launchRange.sol, Core's tick-bitmap word geometry and a direct big-integer
liquidity inverse that does not use the contract's mantissa factorization; --write regenerates the vectors,
--sweep N adds N pseudo-random full-domain cases, --solidity prints the vectors as Solidity test rows.
"""
import json
import random
import sys
from pathlib import Path

MIN_TICK, MAX_TICK = -88722835, 88722835
MAX_TICK_SPACING = 698605
MAX_SUPPLY = 10**30
RANGE_STEPS = 256
TICK_BITMAP_STORAGE_OFFSET = 89421695
Q128 = 1 << 128
U128 = (1 << 128) - 1
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
# Selectors: keccak256 of the error signatures.
INVALID_SUPPLY = "0x15ae6727"
INVALID_TICKS = "0x1434ed7f"
ZERO_LIQUIDITY = "0x10074548"
LIQUIDITY_ABOVE_TICK_CAP = "0x20ea795f"
checks = 0


def check(condition, what=""):
    global checks
    assert condition, f"installation check {checks + 1} failed {what}"
    checks += 1


def ceil_div(a, b):
    return -(-a // b)


def floor_div(a, b):
    return a // b


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


def shared_helper_token0(lower, upper, supply):
    """math/liquidity.sol maxLiquidityForToken0: floors lower * upper / 2**128 before the supply multiply; never
    above the exact inverse."""
    return min(U128, (supply * ((lower * upper) >> 128)) // (upper - lower))


def tick_cap(spacing):
    return U128 // (1 + 2 * (MAX_TICK // spacing))


def align(ask, upper):
    """src/math/launchRange.sol alignLaunchRange: the spacing is ceil(width / 256); the ask rounds up and the upper
    bound rounds down onto that grid."""
    assert MIN_TICK <= ask < upper <= MAX_TICK
    spacing = ceil_div(upper - ask, RANGE_STEPS)
    return spacing, ceil_div(ask, spacing) * spacing, floor_div(upper, spacing) * spacing


def bitmap_word(tick, spacing):
    """math/tickBitmap.sol tickToBitmapWordAndIndex: the storage word holding the tick's bit."""
    return (floor_div(tick, spacing) + TICK_BITMAP_STORAGE_OFFSET) >> 8


def installation(token_is0, ask, upper, supply):
    """ZeroSeedLaunch.previewInstallation for economic ticks and a supply: a dict with the derived spacing, the
    aligned bounds, the liquidity and installed supply, or with the refusal."""
    row = {"order": "t0" if token_is0 else "t1", "askTick": ask, "upperTick": upper, "supply": str(supply)}
    if not 0 < supply <= MAX_SUPPLY:
        return {**row, "error": "InvalidSupply", "selector": INVALID_SUPPLY}
    if not MIN_TICK <= ask < upper <= MAX_TICK:
        return {**row, "error": "InvalidTicks", "selector": INVALID_TICKS}
    spacing, aligned_ask, aligned_upper = align(ask, upper)
    tick_lower, tick_upper = (aligned_ask, aligned_upper) if token_is0 else (-aligned_upper, -aligned_ask)
    assert tick_lower % spacing == 0 and tick_upper % spacing == 0 and MIN_TICK <= tick_lower < tick_upper <= MAX_TICK
    lower_c, upper_c = tick_to_sqrt_ratio(tick_lower), tick_to_sqrt_ratio(tick_upper)
    lower_fixed, upper_fixed = to_fixed(lower_c), to_fixed(upper_c)
    if token_is0:
        liquidity = exact_token0(lower_fixed, upper_fixed, supply)
    else:
        liquidity = exact_token1(lower_fixed, upper_fixed, supply)
    liquidity, cap = min(U128, liquidity), tick_cap(spacing)
    debit = debit0 if token_is0 else debit1
    min_supply = debit(lower_fixed, upper_fixed, 1)
    max_supply = min(MAX_SUPPLY, debit(lower_fixed, upper_fixed, cap + 1) - 1)
    row.update({
        "tickSpacing": spacing, "alignedAskTick": aligned_ask, "alignedUpperTick": aligned_upper,
        "steps": (aligned_upper - aligned_ask) // spacing,
        "bitmapWords": bitmap_word(tick_upper, spacing) - bitmap_word(tick_lower, spacing) + 1,
        "tickLower": tick_lower, "tickUpper": tick_upper, "initialTick": tick_lower if token_is0 else tick_upper,
        "lowerSqrtRatio": str(lower_c), "upperSqrtRatio": str(upper_c),
        "lowerFixed": str(lower_fixed), "upperFixed": str(upper_fixed), "tickCap": str(cap),
        "supplyEnvelope": {"minimum": str(min_supply), "maximum": str(max_supply),
                           "nonempty": min_supply <= max_supply},
    })
    if liquidity == 0:
        return {**row, "error": "ZeroLiquidity", "selector": ZERO_LIQUIDITY}
    if liquidity > cap:
        return {**row, "error": "LiquidityAboveTickCap", "selector": LIQUIDITY_ABOVE_TICK_CAP, "liquidity": str(liquidity)}
    installed = debit(lower_fixed, upper_fixed, liquidity)
    row.update({
        "liquidity": str(liquidity), "installedSupply": str(installed), "sink": str(supply - installed),
        "debitAtLiquidityPlusOne": str(debit(lower_fixed, upper_fixed, liquidity + 1)),
    })
    return row


# Label, order, ask, upper, supply. Economic ticks as requested; the rows carry the derived spacing and bounds.
VECTORS = [
    ("fixture 18/18", True, -13815500, -9210300, 10**27),
    ("fixture 18/18", False, -13815500, -9210300, 10**27),
    ("fixture 18/6", True, -41446500, -36841300, 10**27),
    ("fixture 18/6", False, -41446500, -36841300, 10**27),
    ("fixture 18/18, supply cap", True, -13815500, -9210300, MAX_SUPPLY),
    ("fixture 18/18, supply cap", False, -13815500, -9210300, MAX_SUPPLY),
    ("fixture 18/18, supply cap + 1", True, -13815500, -9210300, MAX_SUPPLY + 1),
    ("fixture 18/18, supply cap + 1", False, -13815500, -9210300, MAX_SUPPLY + 1),
    ("fixture 18/18, supply 0", True, -13815500, -9210300, 0),
    ("fixture 18/18, uint128 max", True, -13815500, -9210300, U128),
    ("fixture 18/18, inverted ticks", True, -9210300, -13815500, 10**27),
    ("fixture 18/18, equal ticks", True, -13815500, -13815500, 10**27),
    ("below MIN_TICK", True, MIN_TICK - 1, 0, 10**27),
    ("above MAX_TICK", True, 0, MAX_TICK + 1, 10**27),
    ("low price, 1e30", True, -88080384, -85983232, MAX_SUPPLY),
    ("low price, 1e30", False, -88080384, -85983232, MAX_SUPPLY),
    ("low price, two liquidity units", True, -88080384, -85983232, 17380183081064167375),
    ("low price, one unit short", True, -88080384, -85983232, 17380183081064167374),
    ("low price, below one unit", True, -88080384, -85983232, 8690091540532083687),
    ("full width, supply cap", True, MIN_TICK, MAX_TICK, MAX_SUPPLY),
    ("full width, supply cap", False, MIN_TICK, MAX_TICK, MAX_SUPPLY),
    ("full width, 1e27", True, MIN_TICK, MAX_TICK, 10**27),
    ("full width, 1e27", False, MIN_TICK, MAX_TICK, 10**27),
    ("full width, supply 1", True, MIN_TICK, MAX_TICK, 1),
    ("adjacent ticks at the bottom", True, MIN_TICK, MIN_TICK + 1, MAX_SUPPLY),
    ("adjacent ticks at the bottom", False, MIN_TICK, MIN_TICK + 1, MAX_SUPPLY),
    ("adjacent ticks at the top", True, MAX_TICK - 1, MAX_TICK, MAX_SUPPLY),
    ("adjacent ticks at the top", False, MAX_TICK - 1, MAX_TICK, MAX_SUPPLY),
    ("adjacent ticks at the top, supply 1", True, MAX_TICK - 1, MAX_TICK, 1),
    ("adjacent ticks at the top, cap", True, MAX_TICK - 1, MAX_TICK, 10**12),
    ("one word wide at spacing 1", True, -13815500, -13815500 + 256, 10**27),
    ("one word wide at spacing 1", False, -13815500, -13815500 + 256, 10**27),
    ("one word wide at spacing 1, supply cap", True, -13815500, -13815500 + 256, MAX_SUPPLY),
    ("one word wide at spacing 1, supply cap", False, -13815500, -13815500 + 256, MAX_SUPPLY),
    ("first rounded width", True, -13815500, -13815500 + 257, 10**27),
    ("first rounded width", False, -13815500, -13815500 + 257, 10**27),
    ("region 2**96 crossing", True, -44361442, -44361441, 10**27),
    ("region 2**96 crossing", True, -44361442, -44361440, MAX_SUPPLY),
    ("region 2**96 crossing wide", True, -44361442, 0, 10**27),
    ("region 2**128 crossing", True, -1, 1, 10**27),
    ("region 2**128 crossing", False, -1, 1, 10**27),
    ("region 2**160 crossing", True, 44361441, 44361442, 10**27),
    ("region 2**160 crossing", False, 44361441, 44361442, 10**27),
    ("three regions", True, -44361442, 44361442, 10**27),
    ("three regions", False, -44361442, 44361442, 10**27),
    ("positive ticks, both bounds rounded", True, 60000000, 70000000, 1),
    ("positive ticks, both bounds rounded", False, 60000000, 70000000, 10**27),
    ("negative ticks, both bounds rounded", True, -70000000, -60000000, 10**27),
    ("negative ticks, both bounds rounded", False, -70000000, -60000000, 10**27),
    ("range across zero, both bounds rounded", True, -5000001, 4999999, 10**27),
    ("range across zero, both bounds rounded", False, -5000001, 4999999, 10**27),
    ("supply 1", True, -13815500, -9210300, 1),
    ("supply 1", False, -13815500, -9210300, 1),
    ("zero liquidity", True, -80000000, -75394800, 1),
    ("above tick cap", True, 80000000, 84605200, MAX_SUPPLY),
    ("above tick cap", False, 80000000, 84605200, MAX_SUPPLY),
    ("narrow at the fixture", True, -13815500, -13815400, 10**27),
    ("narrow at the fixture", False, -13815500, -13815400, 10**27),
    ("narrow at the fixture, supply cap", True, -13815500, -13815400, MAX_SUPPLY),
    ("narrow at the fixture, supply cap", False, -13815500, -13815400, MAX_SUPPLY),
    ("ten percent wide at the fixture, supply cap", True, -13815500, -13720200, MAX_SUPPLY),
    ("ten percent wide at the fixture, supply cap", False, -13815500, -13720200, MAX_SUPPLY),
    ("two times wide at the fixture, supply cap", True, -13815500, -13122400, MAX_SUPPLY),
    ("two times wide at the fixture, supply cap", False, -13815500, -13122400, MAX_SUPPLY),
]


def generate():
    rows = []
    for label, token_is0, ask, upper, supply in VECTORS:
        rows.append({"label": label, **installation(token_is0, ask, upper, supply)})
    return rows


def verify_alignment(ask, upper, spacing, aligned_ask, aligned_upper):
    width = upper - ask
    check(spacing == ceil_div(width, RANGE_STEPS) and 1 <= spacing <= MAX_TICK_SPACING)
    check(spacing == 1 if width <= RANGE_STEPS else spacing < width)
    check(aligned_ask % spacing == 0 and aligned_upper % spacing == 0)
    check(ask <= aligned_ask < aligned_upper <= upper, (ask, upper))
    check(aligned_ask - ask < spacing and upper - aligned_upper < spacing)
    check(0 < (aligned_upper - aligned_ask) // spacing <= RANGE_STEPS)
    for lower_t, upper_t in ((aligned_ask, aligned_upper), (-aligned_upper, -aligned_ask)):
        check(bitmap_word(upper_t, spacing) - bitmap_word(lower_t, spacing) <= 1)


def verify_row(row):
    token_is0 = row["order"] == "t0"
    recomputed = installation(token_is0, row["askTick"], row["upperTick"], int(row["supply"]))
    check({k: v for k, v in row.items() if k != "label"} == recomputed, row.get("label"))
    supply = int(row["supply"])
    if row.get("error") in ("InvalidSupply", "InvalidTicks"):
        check((row["error"] == "InvalidSupply") == (not 0 < supply <= MAX_SUPPLY))
        return
    verify_alignment(row["askTick"], row["upperTick"], row["tickSpacing"], row["alignedAskTick"], row["alignedUpperTick"])
    check(row["steps"] <= RANGE_STEPS and row["bitmapWords"] in (1, 2))
    lower, upper = int(row["lowerFixed"]), int(row["upperFixed"])
    check(to_fixed(tick_to_sqrt_ratio(row["tickLower"])) == lower and to_fixed(tick_to_sqrt_ratio(row["tickUpper"])) == upper)
    check(int(row["tickCap"]) == tick_cap(row["tickSpacing"]))
    envelope = row["supplyEnvelope"]
    minimum, maximum = int(envelope["minimum"]), int(envelope["maximum"])
    inverse = exact_token0 if token_is0 else exact_token1
    check(envelope["nonempty"] == (minimum <= maximum))
    if minimum <= maximum:
        check(inverse(lower, upper, minimum) >= 1 and inverse(lower, upper, minimum - 1) == 0)
        check(1 <= inverse(lower, upper, maximum) <= int(row["tickCap"]))
        check(maximum == MAX_SUPPLY or inverse(lower, upper, maximum + 1) > int(row["tickCap"]))
    if "installedSupply" in row:
        liquidity = int(row["liquidity"])
        debit = debit0 if token_is0 else debit1
        # The direct inequality: the installed liquidity is affordable and the next unit is not.
        check(debit(lower, upper, liquidity) == int(row["installedSupply"]) <= supply)
        check(debit(lower, upper, liquidity + 1) == int(row["debitAtLiquidityPlusOne"]) > supply)
        check(int(row["sink"]) == supply - int(row["installedSupply"]))
        if token_is0:
            check(search_token0(lower, upper, supply) == liquidity)
            check(shared_helper_token0(lower, upper, supply) <= liquidity)
        check(0 < liquidity <= int(row["tickCap"]))
    elif row["error"] == "ZeroLiquidity":
        check((debit0 if token_is0 else debit1)(lower, upper, 1) > supply)
    else:
        liquidity = int(row["liquidity"])
        check(liquidity > int(row["tickCap"]))
        check(liquidity == U128 or (debit0 if token_is0 else debit1)(lower, upper, liquidity) <= supply)


def sweep(count, seed=0x5EED):
    """Pseudo-random full-domain cases: both orders, every width class from adjacent ticks to the full range, supplies
    at liquidity-quantization boundaries, small and maximal supplies, negative, positive and zero-crossing ranges."""
    rng = random.Random(seed)
    for _ in range(count):
        width_class = rng.choice(["adjacent", "word", "narrow", "typical", "wide", "full", "any"])
        if width_class == "full":
            ask, upper = MIN_TICK, MAX_TICK
        else:
            width = {"adjacent": 1, "word": rng.randint(2, 256), "narrow": rng.randint(257, 100000),
                     "typical": rng.randint(100000, 10**7), "wide": rng.randint(10**7, 10**8),
                     "any": rng.randint(1, MAX_TICK - MIN_TICK)}[width_class]
            ask = rng.randint(MIN_TICK, MAX_TICK - width)
            upper = ask + width
        spacing, aligned_ask, aligned_upper = align(ask, upper)
        verify_alignment(ask, upper, spacing, aligned_ask, aligned_upper)
        token_is0 = rng.random() < 0.5
        tick_lower, tick_upper = (aligned_ask, aligned_upper) if token_is0 else (-aligned_upper, -aligned_ask)
        lower, upper_f = to_fixed(tick_to_sqrt_ratio(tick_lower)), to_fixed(tick_to_sqrt_ratio(tick_upper))
        check(0 < lower < upper_f)
        supply = rng.choice([1, 2, 3, rng.randint(1, 10**6), rng.randint(1, 10**20), rng.randint(1, 10**27),
                             MAX_SUPPLY, MAX_SUPPLY - 1, rng.randint(1, MAX_SUPPLY)])
        row = installation(token_is0, ask, upper, supply)
        check(row["tickSpacing"] == spacing and row["alignedAskTick"] == aligned_ask and row["alignedUpperTick"] == aligned_upper)
        if token_is0:
            liquidity = exact_token0(lower, upper_f, supply)
            check(debit0(lower, upper_f, liquidity) <= supply < debit0(lower, upper_f, liquidity + 1), (ask, upper, supply))
            check(shared_helper_token0(lower, upper_f, supply) <= liquidity)
            if liquidity < 1 << 40 or rng.random() < 0.02:
                check(search_token0(lower, upper_f, supply) == liquidity)
            # Mantissa factorization used by the contract, proven equal to the direct division.
            (m_lower, s_lower), (m_upper, s_upper) = mantissa_shift(compact(lower)), mantissa_shift(compact(upper_f))
            check(s_lower <= s_upper and (upper_f - lower) % (1 << s_lower) == 0)
            denominator = ((upper_f - lower) >> s_lower) << (128 - s_upper)
            check(0 < denominator < 1 << 220 and supply * m_lower * m_upper < 1 << 315)
            check((supply * m_lower * m_upper) // denominator == liquidity and liquidity < 1 << 213)
            # Quantization boundary: a supply equal to a debit affords at least that liquidity, one less does not.
            probe = rng.randint(1, 1 << rng.randint(1, 100))
            at_debit = debit0(lower, upper_f, probe)
            if at_debit <= MAX_SUPPLY:
                check(exact_token0(lower, upper_f, at_debit) >= probe and (at_debit == 1 or exact_token0(lower, upper_f, at_debit - 1) < probe))
        else:
            liquidity = exact_token1(lower, upper_f, supply)
            check(debit1(lower, upper_f, liquidity) <= supply < debit1(lower, upper_f, liquidity + 1))
        liquidity = min(U128, liquidity)
        if liquidity == 0:
            check(row["error"] == "ZeroLiquidity")
        elif liquidity > tick_cap(spacing):
            check(row["error"] == "LiquidityAboveTickCap" and int(row["liquidity"]) == liquidity)
        else:
            check(int(row["liquidity"]) == liquidity and "error" not in row)


def main():
    path = Path(__file__).with_name("zero-seed-launch-installation.json")
    args = sys.argv[1:]
    rows = generate()
    if "--write" in args:
        existing = json.loads(path.read_text()) if path.exists() else {}
        document = {
            "version": 2,
            "scope": "LOCAL integer vectors for ZeroSeedLaunch.previewInstallation; economic ticks as requested; no deployment",
            "supply": f"1 <= supply <= {MAX_SUPPLY} base units (InvalidSupply {INVALID_SUPPLY} outside); decimals are always 18",
            "ticks": f"MIN_TICK <= askTick < upperTick <= MAX_TICK (InvalidTicks {INVALID_TICKS} outside)",
            "spacing_rule": "tickSpacing = ceil((upperTick - askTick) / 256); alignedAskTick = ceil(askTick / tickSpacing) * tickSpacing; alignedUpperTick = floor(upperTick / tickSpacing) * tickSpacing (src/math/launchRange.sol). The aligned range spans at most 256 steps, so its two initialized ticks occupy at most two adjacent tick-bitmap words (bitmapWords) in either token order; the spacing never exceeds 693148 < MAX_TICK_SPACING",
            "pool_ticks": "token0 launch: [alignedAskTick, alignedUpperTick], initial tick = lower; token1 launch: [-alignedUpperTick, -alignedAskTick], initial tick = upper",
            "token0_liquidity": "floor(supply * lowerFixed * upperFixed / (2**128 * (upperFixed - lowerFixed))), the exact inverse of Core's token0 debit ceil(ceil(liquidity * 2**128 * (upperFixed - lowerFixed) / upperFixed) / lowerFixed); computed on chain as floor(supply * mantissaLower * mantissaUpper / (((upperFixed - lowerFixed) >> shiftLower) << (128 - shiftUpper))) from the compact sqrt ratios (mantissa = low 94 bits, shift = 2 + 32 * top two bits); saturates at 2**128 - 1",
            "token1_liquidity": "floor(supply * 2**128 / (upperFixed - lowerFixed)), the shared helper; the exact inverse of ceil(liquidity * (upperFixed - lowerFixed) / 2**128)",
            "installed_supply": "the debit above at the installed liquidity; sink = supply - installedSupply is minted to address(0); totalSupply = supply",
            "refusals": {"ZeroLiquidity": ZERO_LIQUIDITY, "LiquidityAboveTickCap(uint128,uint128)": LIQUIDITY_ABOVE_TICK_CAP,
                         "tick_cap": "floor((2**128 - 1) / (1 + 2 * floor(88722835 / tickSpacing))); liquidity above it, including the uint128 saturation, is refused rather than capped"},
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
    sweep(count)
    if "--solidity" in args:
        for row in document["vectors"]:
            print(f'// {row["label"]}: {row.get("error", "liquidity " + row.get("liquidity", ""))}')
            print(f'_row({"true" if row["order"] == "t0" else "false"}, {row["askTick"]}, {row["upperTick"]}, {row["supply"]}, '
                  f'{row.get("tickSpacing", 0)}, {row.get("alignedAskTick", 0)}, {row.get("alignedUpperTick", 0)}, '
                  f'{row.get("liquidity", 0)}, {row.get("installedSupply", 0)}, {row.get("selector", "0x00000000")});')
    print(f"PASS: {checks} installation checks over {len(rows)} vectors and {count} sweep cases")


if __name__ == "__main__":
    main()
