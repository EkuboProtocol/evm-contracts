#!/usr/bin/env bun
/**
 * Cyclomatic complexity gate for src/**\/*.sol.
 *
 * Why this is a baseline check and not just `solhint --max-warnings 0`:
 * every contract here is immutable and deployed via CREATE2 with a mined salt
 * (see script/DeployAll.s.sol). solc embeds a hash of the source into the
 * metadata trailer, so *any* edit to a .sol file -- including adding a
 * `// solhint-disable-next-line` comment -- changes the initcode hash, which
 * changes the deploy address, which breaks `deployIfNeeded`'s expectedAddress
 * assertion and makes the contract impossible to redeploy to the same address
 * on a new chain. So the existing violations cannot be suppressed in-source
 * and cannot be refactored away. They are recorded here instead.
 *
 * The gate is therefore "no worse than the baseline", per file:
 *   - a new violating function in any file fails
 *   - an existing function getting more complex fails
 *   - simplifying something passes (run with --update to record the win)
 *
 * Line numbers are deliberately not part of the baseline: they shift whenever
 * anything above them moves, which would make the file fail for unrelated
 * edits. Comparing the sorted complexity values per file is stable under that.
 *
 * solhint is called as a library rather than spawned as a CLI, so this is one
 * program rather than a script shelling out to another script, and the version
 * that runs is the one pinned in package.json rather than whatever a registry
 * hands back at the time.
 */

import { processFile } from "solhint";

// The single source of truth for the threshold. There is deliberately no
// .solhint.json: two files holding the same number is how they drift apart.
const MAX_COMPLEXITY = 7;
const SOLHINT_CONFIG = {
  rules: { "code-complexity": ["warn", MAX_COMPLEXITY] },
};

const BASELINE = "solhint-complexity-baseline.json";
const update = process.argv.includes("--update");

type Baseline = Record<string, number[]>;

function collect(): Baseline {
  const byFile: Baseline = {};

  for (const path of new Bun.Glob("src/**/*.sol").scanSync(".")) {
    for (const message of processFile(path, SOLHINT_CONFIG).messages) {
      if (message.ruleId !== "code-complexity") continue;
      const complexity = Number(/complexity (\d+)/.exec(message.message)![1]);
      (byFile[path] ??= []).push(complexity);
    }
  }

  for (const list of Object.values(byFile)) list.sort((a, b) => b - a);
  return Object.fromEntries(
    Object.entries(byFile).sort(([a], [b]) => a.localeCompare(b)),
  );
}

const current = collect();

if (update) {
  await Bun.write(BASELINE, `${JSON.stringify(current, null, 2)}\n`);
  console.log(`wrote ${BASELINE} (${Object.keys(current).length} files)`);
  process.exit(0);
}

const baseline: Baseline = await Bun.file(BASELINE).json();
const failures: string[] = [];

for (const [file, list] of Object.entries(current)) {
  const allowed = baseline[file] ?? [];

  if (list.length > allowed.length) {
    failures.push(
      `${file}: ${list.length} function(s) over the limit, baseline allows ${allowed.length}` +
        ` (found ${list.join(", ")}; baseline ${allowed.join(", ") || "none"})`,
    );
    continue;
  }

  const worse = list.findIndex((complexity, i) => complexity > allowed[i]!);
  if (worse !== -1) {
    failures.push(
      `${file}: complexity ${list[worse]} exceeds the baseline's ${allowed[worse]}`,
    );
  }
}

const improved = Object.entries(baseline).filter(
  ([file, allowed]) =>
    (current[file]?.length ?? 0) < allowed.length ||
    (current[file] ?? []).some((complexity, i) => complexity < allowed[i]!),
);

if (failures.length > 0) {
  console.error("Cyclomatic complexity regressed:\n");
  for (const failure of failures) console.error(`  ${failure}`);
  console.error(
    "\nDo NOT add a `solhint-disable` comment to fix this: editing a .sol file changes" +
      "\nthe solc metadata hash, and therefore the CREATE2 deploy address. Simplify the" +
      "\nfunction, or split it.\n",
  );
  process.exit(1);
}

console.log(
  `Complexity OK (${Object.keys(current).length} files at or under baseline).`,
);

if (improved.length > 0) {
  console.log(`Improved since the baseline: ${improved.map(([f]) => f).join(", ")}`);
  console.log("Run `bun run lint:update` to lock the improvement in.");
}
