#!/usr/bin/env python3
"""Recompile Forge artifact metadata as standard JSON; prove byte identity and label immutable slots via AST.
Usage: python3 script/launch-stdjson.py REPO SOLC SOURCE CONTRACT OUT
Local only. Never deploys or signs.
"""
import json
import subprocess
import sys
from pathlib import Path

repo, solc, source, name, output = sys.argv[1:]
root, out = Path(repo), Path(output)
out.mkdir(parents=True, exist_ok=True)
a = json.loads((root / "out" / Path(source).name / (name + ".json")).read_text())
metadata = json.loads(a["rawMetadata"])
settings = dict(metadata["settings"])
assert settings.pop("compilationTarget") == {source: name}
remaps = settings.get("remappings", [])
sources = {}
for path, info in metadata["sources"].items():
    disk = path
    for rule in remaps:
        prefix, target = rule.split("=", 1)
        if path.startswith(prefix):
            disk = target + path[len(prefix):]
            break
    content = (root / disk).read_bytes()
    assert subprocess.check_output(["cast", "keccak", "0x" + content.hex()], text=True).strip() == info["keccak256"]
    sources[path] = {"content": content.decode()}
settings["outputSelection"] = {"*": {"*": ["evm.bytecode.object", "evm.deployedBytecode.object",
    "evm.deployedBytecode.immutableReferences", "metadata", "abi", "storageLayout"], "": ["ast"]}}
std = {"language": metadata["language"], "sources": sources, "settings": settings}
(out / (name + ".std-input.json")).write_text(json.dumps(std, indent=1) + "\n")
p = subprocess.run([solc, "--standard-json"], input=json.dumps(std), capture_output=True, text=True, check=True)
r = json.loads(p.stdout)
assert not [e for e in r.get("errors", []) if e["severity"] == "error"]
c = r["contracts"][source][name]
assert c["evm"]["bytecode"]["object"] == a["bytecode"]["object"][2:]
assert c["evm"]["deployedBytecode"]["object"] == a["deployedBytecode"]["object"][2:]
assert c["metadata"] == a["rawMetadata"]
refs = c["evm"]["deployedBytecode"]["immutableReferences"]
forge_refs = a["deployedBytecode"]["immutableReferences"]
slots = lambda xs: tuple((x["start"], x["length"]) for x in xs)
forge_ids = {slots(xs): k for k, xs in forge_refs.items()}
assert sorted(forge_ids) == sorted(slots(xs) for xs in refs.values())
names = {}
def walk(node, path):
    if isinstance(node, dict):
        if node.get("nodeType") == "VariableDeclaration" and str(node["id"]) in refs:
            key = str(node["id"])
            names[forge_ids[slots(refs[key])]] = {"source": path, "name": node["name"], "slots": refs[key]}
        for value in node.values():
            walk(value, path)
    elif isinstance(node, list):
        for value in node:
            walk(value, path)
for path, value in r["sources"].items():
    walk(value["ast"], path)
assert set(names) == set(forge_refs)
summary = {"contract": name, "compiler": metadata["compiler"], "settings": metadata["settings"],
    "creation_runtime_metadata_identical_to_forge": True, "immutables": names}
for suffix, data in (("stdjson-summary", summary), ("storage-layout", c["storageLayout"]), ("abi", c["abi"])):
    (out / (name + "." + suffix + ".json")).write_text(json.dumps(data, indent=1) + "\n")
print(name, "byte-identical creation/runtime/metadata; compiler-labelled immutables; storage layout and ABI exported")
