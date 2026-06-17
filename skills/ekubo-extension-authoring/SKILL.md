---
name: ekubo-extension-authoring
description: Write or review Ekubo Protocol pool extensions in this repository. Use when implementing a new extension contract, selecting Core hook call points, wiring lock/forward flows, enforcing extension-only invariants, or adding extension tests under test/extensions.
---

# Ekubo Extension Authoring

Build Ekubo extensions using the same architecture and guardrails as `src/extensions/*.sol`.

Read `references/extension-patterns.md` first for hook and architecture choices. Read `references/testing-checklist.md` before writing tests.

## Workflow

1. Define behavior and choose call points.
2. Pick architecture (`BaseExtension` only vs `BaseExtension + BaseForwardee`).
3. Implement hooks and internal state transitions.
4. Add lock/forward entrypoints if users should call extension methods directly.
5. Add tests in `test/extensions` with the established deployment pattern.
6. Run format/build/tests.

Design extensions to be as unopinionated as the product allows. Keep deterministic accounting local to the extension,
and keep economic policy controls outside unless they are essential to the extension's invariant. Governance, PID
controllers, treasury schedules, or other policy mechanisms can fund or configure an extension through explicit calls;
the extension should not need to query policy during pool actions.

## 1) Choose Call Points First

Implement `getCallPoints()` and return a minimal `CallPoints` set.

- Use `beforeSwap` to block direct Core swaps for forward-only designs (`MEVCapture`, `SignedExclusiveSwap`).
- Use `beforeUpdatePosition` and `beforeCollectFees` when fees/state must be settled before LP operations.
- Use `beforeInitializePool` or `afterInitializePool` to enforce pool-type/config constraints and initialize extension state.
- Keep unused hooks unimplemented so `BaseExtension` reverts by default.

If call points depend on constructor params, follow `BoostedFees`: override `_registerInConstructor()` to `false`, then call `core.registerExtension(getCallPoints())` after immutables are set.

## 2) Pick the Contract Shape

Use `BaseExtension` for passive hooks only.

Use `BaseExtension + BaseForwardee` when the extension needs explicit user entrypoints that call Core under lock (for example custom swap/order operations). In this pattern:

- Parse forwarded calldata in `handleForwardData(...)`.
- Call Core methods from the forwarded context.
- Return raw encoded results.
- Keep Core callbacks (`locked_...`) `onlyCore`.
- Never custody tokens in an extension and do not perform ERC20 transfers there. Account token movement with Core saved
  balances, and put actual `payFrom`/`withdraw` settlement in a locker/periphery contract that calls `forward`.
- Use Core saved balances as the extension's token accounting ledger. Prefer separate saved-balance salts/buckets for
  distinct obligations such as funded reserves, accrued fees, staked balances, and claimable rewards.
- Make liberal use of `forward` for user-facing actions that need token settlement or lock-restricted Core calls. A
  periphery can expose clean functions, call `forward`, then settle the saved-balance deltas in the same lock.
- Only use forward for actions that must settle tokens or must call Core under lock. Pure accounting actions such as
  voting can be ordinary external calls, with ownership checked against the stake/position owner.

## 3) Enforce Safety Invariants

Apply these checks consistently:

- Restrict hook callbacks with `onlyCore` when they should never be externally callable.
- Validate pool ownership before mutating extension state:
  - `poolKey.config.extension() == address(this)`
  - pool initialized when required (`CORE.poolState(poolId).isInitialized()`).
- For forward-only swap designs, make `beforeSwap(...)` revert and expose swap through extension forward entrypoints.
- Extensions can implement custom swap behavior by exposing their own forwarded swap function. The forward handler can
  validate/adjust params, call Core swap logic, update saved balances, and return the final deltas to the periphery.
- If extension economics require specific pool config (e.g., fee=0, full-range only, concentrated only), validate at pool init.
- If accumulating saved fees, update saved balances and LP fee accounting atomically during lock callbacks.
- For forward-only swaps, do not apply router conveniences such as default sqrt ratio limits inside the extension.
  The router or periphery should normalize swap params before forwarding.
- If LP rewards are range-based, track reward growth outside initialized ticks and snapshot reward growth inside each
  position's tick range. A single global reward-per-liquidity snapshot is only correct when every position is always
  in range.
- For reward units, name values with `PerLiquidity` when they are scaled per unit of liquidity, and `Snapshot` when
  they represent a saved position or tick snapshot.
- If an extension accepts funded rewards or emissions, prefer treating funding as adding to an unallocated reserve unless
  the rate mechanism is itself part of the extension's accounting invariants. Schedules, PID controllers, and
  governance-controlled rates are policy and should usually live outside the extension.

## 4) Testing Pattern

Mirror tests in `test/extensions/*.t.sol`.

- Deploy extension at deterministic address derived from call points:
  - `address(uint160(callPoints.toUint8()) << 152)`
  - then `deployCodeTo(...)`.
- Verify registration and init constraints.
- Add revert-path tests for direct hook/user misuse.
- Add state-transition tests for each enabled hook.
- If using forward flow, test both authorized path and direct Core call rejection.

## 5) Commands In This Repo

Always follow repository command policy:

- `forge fmt`
- `forge build --offline`
- `forge test --offline`

Use focused runs while iterating (for example `forge test --offline --match-contract MEVCaptureTest`).
