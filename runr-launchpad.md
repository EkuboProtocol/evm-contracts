# RUNR launchpad periphery

The launchpad is an additive layer over `ScheduledLaunch` and `LockedLaunchLiquidity`
(see `scheduled-launch-extension.md`). It lives in `src/launchpad/` and never modifies
the extension, Core, or any existing periphery. Seven contracts split three concerns:
launch access and fee capture (`LaunchpadFactory`), revenue routing
(`RevenueAllocator` and its destinations), and RUNR sinks (`BondDepository`,
`RunrRevenueBuybacks`). Nothing in V1 mints RUNR.

```text
creator ──create/swap──▶ LaunchpadFactory ──forward──▶ ScheduledLaunch ──▶ LockedLaunchLiquidity
                              │ claim (anyone)                 (creator fee ledger)   (terminal position fees)
                              ├── creatorBps ──▶ creator
                              └── remainder ──▶ RevenueAllocator ──allocate(token)──┐
     TreasuryVault ◀── 25% ─────────────────────────────────────────────────────────┤
     HolderVault   ◀── 20% (earmark only in V1) ────────────────────────────────────┤
     EarmarkVault  ◀── 30% "RUNR buyback"  ──owner withdraw──▶ RunrRevenueBuybacks ─┤─▶ settle ─▶ TreasuryVault[RUNR_BUYBACK]
     EarmarkVault  ◀── 15% "Ecosystem buyback" ─────────────────────────────────────┤
     OPS address   ◀── 10% ─────────────────────────────────────────────────────────┘
     BondDepository ──asset──▶ TreasuryVault[BOND]; pays RUNR from prefunded inventory
```

## LaunchpadFactory

`LaunchpadFactory` is a `BaseLocker` and the **owner of every launch it creates**: it
overwrites `LaunchConfig.owner` with its own address before forwarding, so it is the
only address that can call `ScheduledLaunch.claimFees` or
`LockedLaunchLiquidity.claimFees` for those launches. The original caller is recorded
as `creator` together with the tier's `creatorBps`, snapshotted at creation so later
tier changes never affect existing launches.

Governance (the factory owner) manages two allowlists: `setQuoteAllowed(token, bool)`
approves quote assets and `setTier(tier, enabled, creatorBps)` defines creator revenue
shares in basis points. Native ETH cannot be allowlisted; every settlement uses ERC20
allowances granted to the factory.

- `create(config, tier)` validates the quote and tier, locks Core, forwards action 0,
  pays `quoteAmount` from the creator with `transferFrom`, stores the registration and
  emits `LaunchRegistered`. Creation is atomic with the extension's own checks.
- `swap(key, params, calculatedLimit, deadline)` forwards action 1 and settles the
  **fee-inclusive** deltas from the trader. `calculatedLimit` is a minimum output for
  exact-input swaps and a maximum input for exact-output swaps, applied to the
  calculated side where the creator fee is charged. `LaunchSwap` reports both deltas
  and the creator fee accrued in each token, read from the extension's fee ledger
  before and after the trade.
- `claim(key)` is permissionless. It claims the launch-phase fee ledger, and, only if
  `LockedLaunchLiquidity.getTerminal(id).owner` is nonzero (the launch has migrated),
  the terminal position fees as well. Each token received is split `creatorBps` to the
  creator and the remainder to `ALLOCATOR`, emitting `FeesSplit`. The factory never
  retains a balance.

After `endTime`, launch swaps revert in the extension. Post-expiry trading happens on
the full-range TWAMM pool returned by `ScheduledLaunch.terminalPool(key)` through the
existing `Router`; the factory adds nothing to that path.

## RevenueAllocator

`allocate(token)` is permissionless and splits everything that arrived since the last
call (`balanceOf - accounted`) into five fixed legs:

| Leg | Share | Destination | Delivery |
| --- | --- | --- | --- |
| Treasury | 25% + rounding dust | `TreasuryVault` | `deposit(token, UNRESTRICTED, amount)` |
| Holders | 20% | `HolderVault` | `deposit(token, amount)` |
| RUNR buyback | 30% | `EarmarkVault("RUNR buyback")` | `deposit(token, amount)` |
| Ecosystem | 15% | `EarmarkVault("Ecosystem buyback")` | `deposit(token, amount)` |
| Ops | 10% | `OPS` address | plain transfer |

The four contract legs are floor-divided; the treasury leg is the remainder, so the
five amounts always sum to the input. `Allocated` carries every leg amount and
`totals(token)` accumulates them per token for analytics. The allocator deploys its
three earmark destinations in its constructor so their immutable `ALLOCATOR` is fixed
to it; the treasury must register the allocator as a depositor before the first call.

Fees denominated in a launch token ("MEME") are split exactly like quote-token fees
and are **held unconverted** by each destination. Converting them is a later
executor's job; nothing in V1 swaps.

## Custody contracts

- `TreasuryVault` is unified ERC20 custody with a ledger per token and category
  (`UNRESTRICTED`, `RUNR_BUYBACK`, `ECO_BUYBACK`, `BOND`). Deposits are pulled with
  `transferFrom` from registered depositors or the owner, so the ledger can only grow
  by tokens that actually arrived. Only the owner can `withdraw` or `reclassify`, and
  neither can exceed the booked amount.
- `EarmarkVault` holds one leg. Only its `ALLOCATOR` can deposit; only its owner can
  withdraw, which is how funds reach a future executor. Cumulative `received` and
  `withdrawn` are tracked per token.
- `HolderVault` is an `EarmarkVault` labelled "RUNR holders". V1 earmarks only: there
  is no claim logic. A V2 distributor will be funded through the owner withdraw.

The treasury owner and the earmark vault owner are separate constructor parameters.
Tests assert that the treasury owner has no path into earmark vault balances and that
the treasury ledger cannot reach beyond its own leg.

## BondDepository

Users deposit an approved asset and receive a linearly vesting RUNR position. The
asset goes straight to `TreasuryVault` under `BOND`; the depository must be a
registered depositor. Payout is `amount * runrPerAsset / 1e18`, where price, remaining
`capacity` (in RUNR) and `vesting` are owner-configured per asset within hard caps:
vesting must be between one day and one year, RUNR itself cannot be a market, and
**every bond must be backed at purchase by unowed inventory** already held by the
depository (`inventory() = balance - owed`). Inventory is prefunded with `fund`; the
owner can only withdraw the unowed part. `claim(bondId)` pays vested RUNR to the bond
owner, fully claimable at `start + duration`. `setPaused` blocks new deposits, never
claims. Events: `BondPurchased`, `BondClaimed`, `MarketConfigured`.

## RunrRevenueBuybacks

`RunrRevenueBuybacks` is `RevenueBuybacks` with `BUY_TOKEN = RUNR`. Revenue arrives
when the RUNR earmark vault's owner withdraws to it; `configure` and `roll` are
inherited. `settle(token, fee, endTime)` collects the order's RUNR proceeds to the
contract and deposits them into the treasury's `RUNR_BUYBACK` ledger, emitting
`Settled`. The inherited `collect` still pays the owner and is not the intended path.

**Canonical-pool prerequisite:** a full-range TWAMM pool for `(token, RUNR)` at the
configured fee must exist with liquidity, otherwise orders cannot execute. Configure
the fee to match that pool.

## Deployment order

1. `TreasuryVault(owner)`.
2. `RevenueAllocator(vaultOwner, treasury, ops)`; it deploys `HolderVault` and both
   `EarmarkVault`s.
3. `LaunchpadFactory(owner, core, scheduledLaunch, allocator)`; allowlist quotes and
   tiers.
4. `BondDepository(owner, runr, treasury)` and
   `RunrRevenueBuybacks(owner, orders, runr, treasury)`.
5. Treasury owner registers the allocator, depository and buybacks as depositors.

## Tests

`test/launchpad/` covers factory create, swap settlement and slippage, fee split
conservation for both token orderings with a fuzzed creator share, the
unregistered-terminal guard, allocator conservation and rounding, per-token totals,
custody separation, bond deposit/vest/claim with cap and inventory enforcement, and a
buyback settlement smoke test on a seeded TWAMM pool.
