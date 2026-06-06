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

## 3) Enforce Safety Invariants

Apply these checks consistently:

- Restrict hook callbacks with `onlyCore` when they should never be externally callable.
- Validate pool ownership before mutating extension state:
  - `poolKey.config.extension() == address(this)`
  - pool initialized when required (`CORE.poolState(poolId).isInitialized()`).
- For forward-only swap designs, make `beforeSwap(...)` revert and expose swap through extension forward entrypoints.
- If extension economics require specific pool config (e.g., fee=0, full-range only, concentrated only), validate at pool init.
- If accumulating saved fees, update saved balances and LP fee accounting atomically during lock callbacks.

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
