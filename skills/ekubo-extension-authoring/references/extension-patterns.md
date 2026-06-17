# Ekubo Extension Patterns

## Core Building Blocks

- `src/base/BaseExtension.sol`
: Base hook contract, auto-registers by default, unimplemented hooks revert.
- `src/base/BaseForwardee.sol`
: Forwarded-call handler for custom extension entrypoints under lock.
- `src/libraries/ExtensionCallPointsLib.sol`
: Core-side dispatch rules for each hook and locker/initializer bypass behavior.
- `src/types/callPoints.sol`
: Bit layout and `toUint8()` encoding used for registration/deployment patterns.

## Existing Extension Archetypes

- `Oracle.sol`
: Passive hook extension. Uses `beforeInitializePool`, `beforeUpdatePosition`, `beforeSwap`.
- `TWAMM.sol`
: Stateful extension with forward flow + hook-triggered execution.
- `MEVCapture.sol`
: Forward-only swap extension. `beforeSwap` reverts direct swap; fee logic in forward path.
- `SignedExclusiveSwap.sol`
: Forward-only + signatures + nonce management + deferred fee donation.
- `BoostedFees.sol`
: Runtime-selected call points (depends on constructor arg), manual registration.

## Hook Selection Heuristics

- `beforeInitializePool`: validate pool config and seed extension state.
- `afterInitializePool`: use when state needs initialized pool context post-core init.
- `beforeSwap`: block direct swaps or update state before price movement.
- `beforeUpdatePosition`: settle extension accounting before liquidity changes.
- `beforeCollectFees`: settle extension accounting before fee collection.

Prefer minimal hooks. Each enabled hook adds dispatch and test surface area.

## Registration Caveats

`BaseExtension` constructor calls `core.registerExtension(getCallPoints())` unless `_registerInConstructor()` returns `false`.

Use `_registerInConstructor() == false` when call points depend on constructor state. Register explicitly after state initialization.

## Forward Flow Caveats

`FlashAccountant.forward(...)` temporarily sets locker to the forwardee address, then calls `forwarded_2374103877(...)`.

Implications:

- The forwardee can make lock-restricted Core calls during that forward.
- `beforeSwap` direct calls can be blocked while allowing forwarded swaps.
- Validate forwarded payload carefully in `handleForwardData(...)`.
- Forwarded extension actions should account with `CORE.updateSavedBalances(...)`; the extension should never custody
  tokens or call ERC20 transfer helpers. A periphery/locker should perform `payFrom` and `withdraw` in the same lock.
- Treat Core saved balances as the canonical token ledger for extension obligations. Use distinct salts or saved-balance
  buckets for distinct obligations so funded reserves, accrued fees, staked balances, and claimable rewards cannot be
  confused.
- Prefer forward-heavy designs when users need to interact with extension-specific accounting. The periphery should
  encode the action, call `forward`, decode the returned accounting result, and settle token payments or withdrawals in
  the same lock.
- Keep router behavior in routers. For example, default sqrt ratio limits for swaps should be applied before forwarding,
  not inside the extension forward handler.

## Custom Swap Entry Points

Extensions are not limited to passive `beforeSwap`/`afterSwap` hooks. If swap behavior differs materially from Core's
default surface, expose an extension-specific swap entry point through a periphery/router and execute it with `forward`.

Typical shape:

- `beforeSwap` reverts direct Core swaps for pools that must use the custom path.
- The periphery/router normalizes user params and calls `forward`.
- `handleForwardData` validates the pool belongs to the extension and parses the custom swap payload.
- The extension applies its custom logic, such as dynamic fees, alternate accounting, pre/post accumulation, or adjusted
  Core swap parameters.
- The extension calls Core swap logic from the forwarded context when it still wants Core liquidity execution.
- The extension records all token obligations with saved balances and returns final balance deltas for periphery
  settlement.

This keeps custom swap policy explicit while preserving Core's lock/saved-balance accounting model.

## Policy vs Accounting

Keep protocol accounting deterministic and local to the extension. Examples include:

- ownership keys or authorization state
- fee growth and claim snapshots
- reward growth and position snapshots
- allocation weights or accumulated weight-seconds
- saved-balance buckets

Keep economic policy pluggable when possible:

- governance emission schedules
- PID/controller-derived emission amounts
- treasury drip rates
- external reward campaigns
- dynamic fee or reward-rate controllers

A controller does not need to be queried from the extension. It can periodically fund or configure the extension through
a periphery/forward flow, and the extension can allocate whatever has been funded according to its own accumulated
accounting state. This reduces bytecode size, avoids coupling pool actions to policy mechanisms, and makes accounting
easier to audit.

## Range-Aware Rewards

When rewards depend on active liquidity, mirror Core's fee accounting shape:

- maintain `rewardsGlobalPerLiquidity`
- maintain `tickRewardsOutsidePerLiquidity` for initialized boundaries
- invert outside values when swaps cross initialized ticks
- store `positionRewardsSnapshotPerLiquidity` for each position
- update the snapshot before position liquidity changes

Do not assume all positions are in range. A global-only per-position snapshot will incorrectly pay out-of-range LPs after
swaps move the price outside their range.
