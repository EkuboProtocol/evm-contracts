#!/usr/bin/env node
// Cyclomatic complexity gate for src/**/*.sol.
//
// Why this is a baseline check and not just `solhint --max-warnings 0`:
// every contract here is immutable and deployed via CREATE2 with a mined salt
// (see script/DeployAll.s.sol). solc embeds a hash of the source into the
// metadata trailer, so *any* edit to a .sol file — including adding a
// `// solhint-disable-next-line` comment — changes the initcode hash, which
// changes the deploy address, which breaks `deployIfNeeded`'s expectedAddress
// assertion and makes the contract impossible to redeploy to the same address
// on a new chain. So the existing violations cannot be suppressed in-source
// and cannot be refactored away. They are recorded here instead.
//
// The gate is therefore "no worse than the baseline", per file:
//   - a new violating function in any file fails
//   - an existing function getting more complex fails
//   - simplifying something passes (run with --update to record the win)
//
// Line numbers are deliberately not part of the baseline: they shift whenever
// anything above them moves, which would make the file fail for unrelated
// edits. Comparing the sorted complexity values per file is stable under that.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const SOLHINT = "solhint@6.2.4";
const BASELINE = "solhint-complexity-baseline.json";
const update = process.argv.includes("--update");

function collect() {
  let stdout;
  try {
    stdout = execFileSync(
      "npx",
      ["-y", SOLHINT, "--disc", "--noPoster", "-c", ".solhint.json", "-f", "json", "src/**/*.sol"],
      { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 },
    );
  } catch (err) {
    // solhint exits non-zero when it reports anything; the JSON is still on stdout.
    if (err.stdout === undefined) throw err;
    stdout = err.stdout;
  }
  const report = JSON.parse(stdout.slice(stdout.indexOf("[")));
  const byFile = {};
  for (const m of report) {
    if (m.ruleId !== "code-complexity") continue;
    const n = Number(/complexity (\d+)/.exec(m.message)[1]);
    (byFile[m.filePath] ??= []).push(n);
  }
  for (const list of Object.values(byFile)) list.sort((a, b) => b - a);
  return Object.fromEntries(Object.entries(byFile).sort(([a], [b]) => a.localeCompare(b)));
}

const current = collect();

if (update) {
  writeFileSync(BASELINE, JSON.stringify(current, null, 2) + "\n");
  console.log(`wrote ${BASELINE} (${Object.keys(current).length} files)`);
  process.exit(0);
}

const baseline = JSON.parse(readFileSync(BASELINE, "utf8"));
const failures = [];

for (const [file, list] of Object.entries(current)) {
  const allowed = baseline[file] ?? [];
  if (list.length > allowed.length) {
    failures.push(
      `${file}: ${list.length} function(s) over the limit, baseline allows ${allowed.length}` +
        ` (found ${list.join(", ")}; baseline ${allowed.join(", ") || "none"})`,
    );
    continue;
  }
  for (let i = 0; i < list.length; i++) {
    if (list[i] > allowed[i]) {
      failures.push(`${file}: complexity ${list[i]} exceeds the baseline's ${allowed[i]}`);
      break;
    }
  }
}

const improved = Object.entries(baseline).filter(
  ([f, l]) => (current[f]?.length ?? 0) < l.length || (current[f] ?? []).some((n, i) => n < l[i]),
);

if (failures.length) {
  console.error("Cyclomatic complexity regressed:\n");
  for (const f of failures) console.error(`  ${f}`);
  console.error(
    "\nDo NOT add a `solhint-disable` comment to fix this: editing a .sol file changes" +
      "\nthe solc metadata hash, and therefore the CREATE2 deploy address. Simplify the" +
      "\nfunction, or split it.\n",
  );
  process.exit(1);
}

console.log(`Complexity OK (${Object.keys(current).length} files at or under baseline).`);
if (improved.length) {
  console.log(`Improved since the baseline: ${improved.map(([f]) => f).join(", ")}`);
  console.log(`Run \`node bin/check-complexity.mjs --update\` to lock the improvement in.`);
}
