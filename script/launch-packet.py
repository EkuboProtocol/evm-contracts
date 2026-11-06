#!/usr/bin/env python3
"""Unsigned launch pair derivation. Local data only; no RPC, signing or broadcast.
Run launch-stdjson.py for both contracts first, then: launch-packet.py REPO OUTPUT
"""
import json
import subprocess
import sys
from pathlib import Path

root, out = map(Path, sys.argv[1:])
CORE = 0x00000000000014AA86C5D3C41765BB24E11BD701
FACTORY = 0x4E59B44847B379578588920CA78FBF26C0B4956C
BASE = 0x28F4114B40904AD1CFBB42175A55AD64187C1B299773BD6318BAA292375CF0DD
def word(x):
    return x.to_bytes(32, "big")
def hx(x):
    return "0x" + x.hex()
def kh(x):
    return bytes.fromhex(subprocess.check_output(["cast", "keccak", hx(x)], text=True).strip()[2:])
def address(x):
    return subprocess.check_output(["cast", "to-check-sum-address", f"0x{x:040x}"], text=True).strip()
def create2(salt, codehash):
    return int.from_bytes(kh(b"\xff" + FACTORY.to_bytes(20, "big") + word(salt) + codehash)[12:], "big")
def artifact(name):
    a = json.loads((root / "out" / (name + ".sol") / (name + ".json")).read_text())
    return a, bytes.fromhex(a["bytecode"]["object"][2:])
def derive(name, args, salt, mine=False):
    a, creation = artifact(name)
    init = creation + args
    codehash = kh(init)
    while mine and create2(salt, codehash) >> 152 != 0x51:
        salt += 1
    deployed = create2(salt, codehash)
    summary = json.loads((out / (name + ".stdjson-summary.json")).read_text())
    runtime = bytearray.fromhex(a["deployedBytecode"]["object"][2:])
    for key, entry in summary["immutables"].items():
        assert entry["name"] in ("CORE", "ACCOUNTANT", "LAUNCH")
        value = EXTENSION if entry["name"] == "LAUNCH" else CORE
        assert entry["slots"] == a["deployedBytecode"]["immutableReferences"][key]
        for slot in entry["slots"]:
            start = slot["start"]
            assert slot["length"] == 32 and runtime[start:start+32] == bytes(32)
            runtime[start:start+32] = word(value)
    data = word(salt) + init
    (out / (name + ".initcode.hex")).write_text(hx(init) + "\n")
    (out / (name + ".runtime.expected.hex")).write_text(hx(runtime) + "\n")
    (out / (name + ".factory-calldata.hex")).write_text(hx(data) + "\n")
    return {"contract": name, "address": address(deployed), "salt": hx(word(salt)), "salt_offset": salt-BASE,
        "constructor_args": hx(args), "creation_bytes": len(creation), "creation_hash": hx(kh(creation)),
        "init_bytes": len(init), "init_hash": hx(codehash), "runtime_bytes": len(runtime), "runtime_hash": hx(kh(runtime)),
        "transaction": {"to": address(FACTORY), "value": "0", "data": hx(data), "gasLimit": "6000000" if mine else "2000000", "chainId": 4663},
        "intrinsic_gas": 21000 + sum(4 if b == 0 else 16 for b in data)}

extension = derive("ZeroSeedLaunch", word(CORE), BASE, True)
EXTENSION = int(extension["address"], 16)
periphery = derive("ZeroSeedLaunchPeriphery", word(CORE) + word(EXTENSION), BASE)
manifest = {"scope": "Unsigned derivation from local build artifacts; no RPC, signing or broadcast",
    "chain_id": 4663, "core": address(CORE), "factory": address(FACTORY), "deployment_salt_base": hx(word(BASE)),
    "required_extension_prefix": "0x51", "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip(),
    "extension": extension, "periphery": periphery,
    "cost_bound": {"direct_gas_limits": ["6000000", "2000000"], "proposed_total_including_account_data_overhead": "9000000",
        "proposed_max_fee_per_gas_wei": "100000000", "proposed_max_total_fee_wei": "900000000000000",
        "formula": "9000000 * 100000000 wei = 0.0009 native; planning bound including wrapper/data overhead, not a live fee quote"},
    "preflight_required": ["Confirm chain 4663 supports pinned Osaka opcodes", "Compare Core/factory runtime to pinned artifacts", "Ensure both predicted addresses have no code", "Confirm extension unregistered", "Use a fresh fee quote"]}
(out / "derivation.json").write_text(json.dumps(manifest, indent=1) + "\n")
print(json.dumps({"extension": extension["address"], "periphery": periphery["address"], "unsigned": True}, indent=1))
