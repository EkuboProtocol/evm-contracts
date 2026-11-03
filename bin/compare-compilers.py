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
    parser.add_argument(
        "--mixed-core", action="store_true",
        help="Also evaluate solc Core with Solar periphery in a controlled test fixture (not a deployment build)",
    )
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

    def run(compiler, label, command, *, profile=None, snapshot_group=None):
        compiler_env = env | {"FOUNDRY_PROFILE": profile or ("solar" if compiler == "solar" else "default")}
        compiler_env["FOUNDRY_SNAPSHOTS"] = str(output / f"{snapshot_group or compiler}-snapshots")
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
    if args.mixed_core:
        solc_core_path = output / "solc-gas/out/Core.sol/Core.json"
        solc_core = json.loads(solc_core_path.read_text())
        solar_core = json.loads((output / "solar-gas/out/Core.sol/Core.json").read_text())
        for artifact in (solc_core, solar_core):
            if artifact["deployedBytecode"].get("immutableReferences"):
                raise RuntimeError("mixed fixture requires Core without immutables")
            if artifact["deployedBytecode"].get("linkReferences"):
                raise RuntimeError("mixed fixture requires unlinked Core")
        canonical_abi = lambda artifact: sorted(json.dumps(entry, sort_keys=True) for entry in artifact["abi"])
        if canonical_abi(solc_core) != canonical_abi(solar_core) or solc_core["methodIdentifiers"] != solar_core["methodIdentifiers"]:
            raise RuntimeError("mixed fixture requires identical Core ABIs and selectors")

        fixture_dir = output / "mixed-test"
        config_dir = output / "mixed-config"
        fixture_dir.mkdir()
        config_dir.mkdir()
        # Core has no immutables. Both fixtures start with the same constructor
        # state and pool layout; only one fixture substitutes Core runtime code.
        # Isolation must be declared on BOTH derived tests (it is not inherited).
        (fixture_dir / "MixedGas.t.sol").write_text(
            '// SPDX-License-Identifier: ekubo-license-v1.eth\npragma solidity =0.8.33;\n'
            'import {MEVCaptureV21GasTest} from "test/extensions/MEVCaptureV21Gas.t.sol";\n'
            '/// forge-config: default.isolate = true\n'
            'contract CompilerMixedGasTest is MEVCaptureV21GasTest {\n'
            '    function setUp() public override {\n'
            '        super.setUp();\n'
            f'        vm.etch(address(core), vm.getDeployedCode({json.dumps(str(solc_core_path))}));\n'
            '    }\n}\n'
            '/// forge-config: default.isolate = true\n'
            'contract CompilerSolarControlGasTest is MEVCaptureV21GasTest {}\n'
        )
        config = config_dir / "foundry.toml"
        config.write_text(
            '[profile.default]\n'
            f'src = {json.dumps(str(root / "test"))}\n'
            f'test = {json.dumps(str(fixture_dir))}\n'
            f'out = {json.dumps(str(output / "mixed-gas/out"))}\n'
            f'cache_path = {json.dumps(str(output / "mixed-gas/cache"))}\n'
            f'libs = [{json.dumps(str(root / "lib"))}]\n'
            f'remappings = [{json.dumps("test/=" + str(root / "test") + "/")}]\n'
            'evm_version = "osaka"\noptimizer = true\noptimizer_runs = 9999999\nvia_ir = true\nisolate = false\n'
            'gas_snapshot_check = false\ngas_snapshot_emit = true\n'
            f'fs_permissions = [{{ access = "read", path = {json.dumps(str(solc_core_path))} }}]\n'
        )
        run("solar", "mixed-gas", [
            "forge", "test", "--offline", "--config-path", str(config),
            "--match-contract", "Compiler(Mixed|SolarControl)GasTest",
        ], profile="default", snapshot_group="mixed")
        control = json.loads((output / "mixed-snapshots/CompilerSolarControlGasTest.json").read_text())
        mixed = json.loads((output / "mixed-snapshots/CompilerMixedGasTest.json").read_text())
        if control != snapshots["solar"]:
            raise RuntimeError("mixed fixture's pure-Solar control differs; do not compare incompatible settings")
        if mixed.keys() != snapshots["solc"].keys():
            raise RuntimeError("mixed gas cases differ")
        result["mixed_core_gas"] = {
            name: {
                "solc": int(snapshots["solc"][name]), "solar": int(snapshots["solar"][name]),
                "mixed": int(mixed[name]),
                "mixed_delta_solc_percent": 100 * (int(mixed[name]) / int(snapshots["solc"][name]) - 1),
            }
            for name in sorted(mixed)
        }
        result["mixed_fixture_solar_control_matches"] = True
        result["mixed_core_scope"] = "Test-only Core runtime substitution; not a deployable mixed-compiler build or full-suite equivalence proof"
    (output / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
