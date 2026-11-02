#!/usr/bin/env python3
"""Compare offline Solar/solc builds and identical cold Router gas fixtures.

Requires Foundry 1.8.7, standalone Solar 0.3.0 and solc 0.8.33 installed.
Run from the repository root, without other builds/benchmarks on the host.
Results go to a new directory; tracked artifacts/snapshots are never overwritten.
"""

import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--solc", default="0.8.33")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    if args.runs < 1 or args.threads < 1:
        parser.error("runs and threads must be positive")

    root = Path.cwd()
    if not (root / "foundry.toml").is_file():
        parser.error("run from the repository root")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    env = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("FOUNDRY_", "FORGE_", "DAPP_"))
    }

    versions = {}
    for tool in ("forge", "solar"):
        versions[tool] = subprocess.check_output([tool, "--version"], env=env, text=True).strip()
    solar_version = versions["solar"].splitlines()[0].split("+", 1)[0]
    if "Version: 1.8.7" not in versions["forge"] or solar_version != "solar 0.3.0":
        parser.error("expected Foundry 1.8.7 and standalone Solar 0.3.0 on PATH")

    def run(compiler, label, command):
        compiler_env = env | {"FOUNDRY_PROFILE": "solar" if compiler == "solar" else "default"}
        compiler_env["FOUNDRY_SNAPSHOTS"] = str(output / f"{compiler}-snapshots")
        command += ["--use", "solar" if compiler == "solar" else args.solc, "-j", str(args.threads)]
        start = time.perf_counter()
        with (output / f"{label}.log").open("w") as log:
            subprocess.run(command, env=compiler_env, stdout=log, stderr=subprocess.STDOUT, check=True)
        return time.perf_counter() - start

    timings = {"solc": [], "solar": []}
    for index in range(args.runs):
        # Alternate ordering to reduce warm filesystem / host drift effects.
        order = ("solc", "solar") if index % 2 == 0 else ("solar", "solc")
        for compiler in order:
            label = f"{compiler}-build-{index}"
            timings[compiler].append(run(compiler, label, [
                "forge", "build", "--offline", "--no-cache", "--no-lint", "src",
                "--out", str(output / label / "out"),
                "--cache-path", str(output / label / "cache"),
            ]))

    for compiler in ("solc", "solar"):
        label = f"{compiler}-gas"
        run(compiler, label, [
            "forge", "test", "--offline", "--match-contract", "MEVCaptureV21GasTest",
            "--gas-snapshot-check=false", "--gas-snapshot-emit=true",
            "--out", str(output / label / "out"),
            "--cache-path", str(output / label / "cache"),
        ])

    snapshots = {}
    sizes = {}
    for compiler in ("solc", "solar"):
        snapshots[compiler] = json.loads(
            (output / f"{compiler}-snapshots/MEVCaptureV21GasTest.json").read_text()
        )
        sizes[compiler] = {}
        for contract in ("Core", "Router", "MEVCapture", "MEVCaptureV21"):
            artifact = json.loads(
                (output / f"{compiler}-build-0/out/{contract}.sol/{contract}.json").read_text()
            )
            sizes[compiler][contract] = len(artifact["deployedBytecode"]["object"].removeprefix("0x")) // 2

    if snapshots["solc"].keys() != snapshots["solar"].keys():
        raise RuntimeError("compiler gas cases differ")
    gas = {
        name: {
            "solc": int(snapshots["solc"][name]),
            "solar": int(snapshots["solar"][name]),
            "solar_delta_percent": 100 * (int(snapshots["solar"][name]) / int(snapshots["solc"][name]) - 1),
        }
        for name in sorted(snapshots["solc"])
    }
    result = {
        "revision": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
        "working_tree_diff": subprocess.check_output(["git", "diff", "--stat", "HEAD"], text=True),
        "versions": versions,
        "solc_selection": args.solc,
        "cold_source_build_seconds": timings,
        "median_build_seconds": {key: statistics.median(value) for key, value in timings.items()},
        "deployed_bytecode_bytes": sizes,
        "cold_router_gas": gas,
    }
    (output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
