#!/usr/bin/env python3
"""Refresh final-version vectors from a successful local Forge log and compiled artifacts.

forge test --offline --match-path 'test/extensions/ZeroSeedLaunch*.t.sol' > launch-tests.log
python3 test/vectors/zero-seed-launch-freeze.py launch-tests.log
python3 test/vectors/zero-seed-launch-reference.py

The independent reference checks the math; this script records execution and ABI evidence only.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
path = Path(__file__).with_name("zero-seed-launch.json")
v = json.loads(path.read_text())
log = Path(sys.argv[1]).read_text()
assert "0 failed" in log and "[FAIL" not in log, "only freeze a successful run"
rows = {}
for line in log.splitlines():
    if "VEC|" not in line:
        continue
    parts = line.strip().split("|")
    if parts[0] != "VEC":
        continue
    fields = dict(x.split("=", 1) for x in parts[2:] if "=" in x)
    positional = [x for x in parts[2:] if "=" not in x]
    rows.setdefault(parts[1], []).append((fields, positional))

v["version"] = 8
v["fixture"]["tick_spacing"] = 17990
v["create"] = [r for r, _ in rows["create"]]
assert len(v["create"]) == 4
v["trade"] = [{**r, "decimals": r["dec"], "step": p[0]} for r, p in rows["trade"]]
v["router"] = [r for r, _ in rows["router"]]
v["gas"] = [r for r, _ in rows["gas"]]
v["other"] = [{"raw": line.strip()} for line in log.splitlines() if "VEC|dust|" in line or "VEC|recapture|" in line]
v["installation"] = {"reference": "zero-seed-launch-installation.json", "oracle": "zero-seed-launch-installation.py"}
v["metadata"] = {
    "encoding": "Canonical LibString.packOne: first byte length 1..31, next length bytes content, all remaining bytes zero",
    "unit": "bytes, not characters; UTF-8 is a consumer policy, not contract validation",
    "error": "InvalidMetadata()", "checked_in": ["create", "previewInstallation"],
    "decimals": 18,
    "examples": {"Zero Seed": "0x095a65726f205365656400000000000000000000000000000000000000000000",
                 "ZERO": "0x045a45524f000000000000000000000000000000000000000000000000000000"},
    "refused": ["zero", "length 0", "length >31", "nonzero tail"],
    "note": "LibString.packOne assumes memory padding; producers must explicitly zero the tail. No truncation."
}
v["collision"]["rule"] = "CREATE2(extension, keccak256(abi.encode(controller,salt)), keccak256(LaunchToken.creationCode ++ abi.encode(bytes32 name,bytes32 symbol))); logo is excluded"
v["forward_schema"]["create"]["payload"] = "abi.encode(ZERO_SEED_LAUNCH_CREATE, LaunchParameters, string logoUrl)"
v["supply"] = {"min": "1", "max": str(10**30), "type": "uint128", "error": "InvalidSupply()"}
v["spacing"] = {"rule": "s = ceil((upperTick-askTick)/256); ask = ceil(askTick/s)*s; upper = floor(upperTick/s)*s",
                "max": 693148, "skipAhead": 1, "reference": "zero-seed-launch-installation.json"}
v["logo"] = {"location": "second argument of create and final field of LaunchCreated", "default": "",
             "stored": False, "in_preview_or_token_or_pool_identity": False}
v["creator_fee_range"]["unencodable"]["verdict"] = "ABI decoding failure in create(parameters,logoUrl), previewInstallation and forwarded create for either fee word; no truncation"
v["max_rate"]["trades"] = [
    {**r, "decimals": r["dec"], "step": p[0]}
    for r, p in rows["highRate"] if r["rate"] == "max" and p[0] != "dust"
]
assert len(v["max_rate"]["trades"]) == 16
v["max_rate"]["trades_note"] = "Actual maximum-rate fills on the final geometry; oneUnit buys net zero, exact output grosses up the input; see trade rows for exact amounts"
v["max_rate"]["exact_output_bounds"]["vectors"] = [
    {**r, "order": r["order"].replace("(native)", ""), "decimals": "18/18"}
    for r, _ in rows["exactOutBounds"]
]

def typ(p):
    return "(" + ",".join(typ(x) for x in p["components"]) + ")" + p["type"][5:] if p["type"].startswith("tuple") else p["type"]

def signature(a):
    return a["name"] + "(" + ",".join(typ(x) for x in a["inputs"]) + ")"

def keccak(text):
    return subprocess.check_output(["cast", "keccak", text], text=True).strip()

v["abi"] = {}
v["pins"] = {"runtime_templates": {}, "creationCode": {}}
for name in ("ZeroSeedLaunch", "ZeroSeedLaunchPeriphery", "LaunchToken"):
    a = json.loads((ROOT / "out" / (name + ".sol") / (name + ".json")).read_text())
    v["abi"][name] = {
        "selectors": {signature(x): "0x" + a["methodIdentifiers"][signature(x)] for x in a["abi"] if x["type"] == "function"},
        "errors": {signature(x): keccak(signature(x))[:10] for x in a["abi"] if x["type"] == "error"},
        "events": {signature(x): keccak(signature(x)) for x in a["abi"] if x["type"] == "event"},
    }
    for kind, bytecode in (("runtime_templates", a["deployedBytecode"]["object"]), ("creationCode", a["bytecode"]["object"])):
        v["pins"][kind][name] = {"bytes": (len(bytecode) - 2) // 2, "keccak256": keccak(bytecode)}

v["residue_metrics"]["scenarios"] = []
for r in v["trade"]:
    if r["step"] != "upperResidue":
        continue
    same = {x["step"]: x for x in v["trade"] if x["order"] == r["order"] and x["decimals"] == r["decimals"]}
    v["residue_metrics"]["scenarios"].append({
        "order": r["order"], "decimals": r["decimals"], "position_token_before_exhaust": r["positionTokenBefore"],
        "delivered_raw_token": r["delivered"], "upper_residue_raw_token": r["residueToken"],
        **{"core_dust_" + label + "_exhaust": {"raw_token": same[key]["token"], "raw_quote": same[key]["quote"]}
           for label, key in (("before", "dust"), ("after", "dustExhausted"))}
    })

# Keep only this version's configuration and evidence. Historical evidence remains at its source commit.
def clean(x):
    if isinstance(x, dict):
        return {k: clean(y) for k, y in x.items() if k not in ("removed", "changed_from_previous_revision", "previous", "previous_revision") and not k.startswith("previous_")}
    if isinstance(x, list):
        return [clean(y) for y in x]
    return x

v = clean(v)
path.write_text(json.dumps(v, indent=1) + "\n")
installation_path = path.with_name("zero-seed-launch-installation.json")
installation_doc = json.loads(installation_path.read_text())
installation_doc["pins"] = v["pins"]
installation_path.write_text(json.dumps(installation_doc, indent=1) + "\n")

events = []
lines = log.splitlines()
for n, line in enumerate(lines):
    if "FIXTURE|LaunchCreated|logo" in line:
        words = [x.strip() for x in lines[n+1:n+6]]
        assert all(re.fullmatch("0x[0-9a-fA-F]+", x) for x in words)
        events.append({"logo": "" if line.strip().endswith("0") else "https://example.invalid/logo.svg",
                       "topics": words[:4], "data": words[4]})
assert len(events) == 2
receipts = []
for line in lines:
    if not line.strip().startswith("ALL_EVENT|"):
        continue
    fields = dict(x.split("=", 1) for x in line.strip().split("|")[1:])
    encoded = bytes.fromhex(fields.pop("topics")[2:])
    count = int.from_bytes(encoded[32:64], "big")
    fields["topics"] = ["0x" + encoded[64 + 32*i:96 + 32*i].hex() for i in range(count)]
    receipts.append(fields)
covered = {r["topics"][0] for r in receipts}
required = {topic for a in v["abi"].values() for topic in a["events"].values()}
assert required <= covered, "raw receipt fixtures must cover every published event"
Path(__file__).with_name("zero-seed-launch-events.json").write_text(json.dumps({"scope": "Local Forge event fixtures, never deployed", "LaunchCreated": events, "receipt": receipts}, indent=1) + "\n")
print("refreshed final ABI, metadata/supply/spacing, execution and event vectors")
