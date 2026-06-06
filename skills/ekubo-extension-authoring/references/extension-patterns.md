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
