# AGENTS.md

## Command Policy
- Always run Foundry commands with `--offline`.
- Use `forge test --offline` for tests.
- Use `forge build --offline` for builds.
- Use `forge script --offline` for scripts.
- Run `forge snapshot --offline` before committing or pushing changes.

## Solidity Editing Policy
- After making any changes to Solidity files (`*.sol`), run `forge fmt`.

## Complexity Policy
- Run `node bin/check-complexity.mjs` after changing any `*.sol` file. CI runs it too.
- The gate is a baseline, not a hard threshold: it fails on *new* functions over
  cyclomatic complexity 7, and on existing ones getting worse. `solhint-complexity-baseline.json`
  records what is already over the line.
- **Never** silence it with a `// solhint-disable` comment. Every contract here is
  immutable and deployed with a mined CREATE2 salt, and solc embeds a hash of the
  source in the metadata trailer — so editing a `.sol` file at all, comments
  included, changes the initcode hash and therefore the deploy address. That breaks
  `deployIfNeeded`'s `expectedAddress` assertion and makes the contract impossible
  to redeploy to its existing address on a new chain. Simplify or split the function
  instead.
- If you genuinely simplified something, run `node bin/check-complexity.mjs --update`
  and commit the tightened baseline.
