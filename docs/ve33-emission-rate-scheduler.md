# Ve33 Emission Rate Scheduler

This document explains `Ve33EmissionRateScheduler` from an operator and governance perspective. Read it before the
contract if you want the intended behavior, launch procedure, and keeper expectations without first working through
the Q32 arithmetic and Ve33 scheduling internals.

## Purpose

The scheduler maintains a minimum aggregate Ve33 emissions rate by scheduling only the missing rate and paying for it
from its own prefunded balance. Anyone can call it, while only the owner can change policy.

The scheduler has three jobs:

1. Apply emission-policy changes at governance-selected timestamps.
2. Convert those arbitrary policy timestamps into schedules accepted by Ve33's existing timestamp-validity rules.
3. When projected emissions are below the configured minimum, pay only the tokens required to reach the fitted Ve33
   execution rate.

`minEmissionsRate` is a floor, not an additive emissions stream. If another Ve33 schedule supplies part of the
minimum, this scheduler pays only the amount needed to reach the fitted execution rate. If projected emissions are
already at or above the minimum, it pays nothing.

The scheduler never calls a token mint interface. Its Ve33 stake token may be an ERC-20 or the native token:

- ERC-20 payments are transferred directly from the scheduler to the flash accountant.
- When `stakeToken()` is `address(0)`, native-token payments are sent as ETH from the scheduler to the flash
  accountant.

Every scheduling transaction reverts atomically if the scheduler does not have enough of the stake token.

## Configuration values

An emission-rate configuration contains:

- `minEmissionsRate`: the minimum global Ve33 emissions rate, expressed as Q32 token units per second.
- `scheduleDuration`: how far beyond the current block a keeper call may preschedule policy.

`minEmissionsRate` may not exceed `MAX_MIN_EMISSIONS_RATE()`. The scheduler may compress a policy amount into a
shorter Ve33-valid interval, which raises the physical rate. The bound is chosen so that even a maximum-length
`uint32` policy interval compressed into one second remains within Ve33's per-timestamp rate-delta limit. It also
guarantees that every amount computed by the scheduler fits Ve33's `uint128` funding path. Unsafe rates are rejected
when a configuration is set or queued, rather than when that policy later becomes due.

For an intended daily amount, the Q32 rate is:

```text
rate = ceil(daily token amount in wei * 2^32 / 86,400)
```

The launch configuration uses a one-week `scheduleDuration`.

The active state is a single packed `ScheduledVe33EmissionRateConfig`. It contains:

- the active `Ve33EmissionRateConfig`, which is a packed `uint192`; and
- `nextConfigTime`, a `uint64` pointer to the head of the scheduled-configuration list.

Future configurations use the same packed type and are stored in `scheduledConfigs[startTime]`.

`getConfigState()` returns the current packed configuration and every queued start timestamp in ascending order. This
lets an offchain client discover the complete linked-list key set with one call before reading any desired
`scheduledConfigs(timestamp)` values or raw storage slots.

## Arbitrary policy timestamps

Governance can queue a configuration for any future Unix timestamp. The timestamp does not need to satisfy Ve33's
time-validity rules.

The scheduler keeps future updates in a timestamp-ordered singly linked list:

```text
active config
    |
    v
nextConfigTime -> scheduled config -> scheduled config -> 0
```

Each mapping entry contains the configuration that starts at its mapping key and the timestamp of the following
entry. Insertion and cancellation take a `previousConfigTime` hint so the contract does not have to walk an unbounded
list onchain:

- use `0` when inserting or removing the head;
- otherwise pass the timestamp of the immediately preceding node.

An incorrect hint reverts without modifying the queue.

## Policy time versus Ve33 execution time

The scheduler tracks two different timelines:

- `lastScheduledTime` is the arbitrary policy-time cursor. It records exactly how far the configured policy has been
  accounted.
- `emissionEnd` is the execution-time cursor through which projected emissions have been covered. When it is in the
  future, it is a timestamp accepted by Ve33. An immediate config update only advances a stale cursor to the current
  block timestamp; it never rewinds a future cursor or already-funded emissions.

These values are intentionally different. A governance update may begin at an arbitrary timestamp, but Ve33 still
requires schedule endpoints to be valid according to its existing time rules.

The scheduler does not relax or bypass those rules. Instead, it:

1. Calculates the whole-token policy amount accrued between policy timestamps, flooring any fractional smallest unit
   for that call.
2. Chooses a Ve33-valid execution interval no longer than the corresponding minimum-rate interval.
3. Fits the policy amount into that interval.

Because the chosen interval is no longer than the ideal interval, its fitted minimum rate is at least the configured
`minEmissionsRate`. This can make the physical stream slightly faster and shorter than the ideal policy interval.
Policy accounting and configuration activation still happen at the exact arbitrary timestamps.

## What `scheduleEmissions()` does

`scheduleEmissions()` is permissionless. A successful call performs the following work atomically:

1. Activate a queued configuration if the policy cursor is exactly at its start timestamp.
   A disabled zero-duration policy instead waits until its queue head is wall-clock due, moves the policy cursor to
   that timestamp, and activates it.
2. Set the policy horizon to the earlier of:
   - `block.timestamp + scheduleDuration`; or
   - the next queued configuration timestamp; or
   - `uint32.max` seconds after `lastScheduledTime`, which bounds catch-up arithmetic after a very late call.
3. Accrue the configured Q32 minimum rate from `lastScheduledTime` through that horizon and floor the result to a whole
   smallest token unit. Fractions are intentionally not carried between calls.
4. Select a compatible Ve33-valid execution interval.
5. Accrue current Ve33 emissions and scan any already-scheduled rate changes in that interval.
6. Where projected emissions are below the configured minimum, schedule enough shortfall to reach the fitted rate.
7. Pay the actual amount Ve33 requires for those shortfall schedules from the scheduler's balance.
8. Activate the next configuration if the policy horizon ended at its timestamp.

The returned amount is the number of tokens paid by that call. It can be lower than the policy amount when another
Ve33 emission schedule contributes to the global minimum.

Ve33 rounds each funded subinterval up independently. Existing rate-change timestamps can therefore make the returned
amount exceed the single-window nominal amount by less than one smallest token unit per funded subinterval. The
scheduler deliberately does not store or reconcile this bounded dust. Likewise, flooring each keeper call can discard
less than one smallest unit. This keeps the policy state simple and is immaterial for STONX.

## Exact 333,333 STONX launch period

The launch policy is:

- zero emissions before the start;
- an exact policy start at `1785508200` (July 31, 2026 at 10:30 AM ET);
- 3,333.33 STONX per day for exactly 100 policy days;
- an exact policy end at `1794148200`;
- 333,333 STONX of total scheduler spending over those 100 days when no other Ve33 emissions overlap; and
- a lower ongoing minimum rate after the 100-day boundary.

The initial rate is rounded up in Q32:

```text
initialRate = ceil(3,333.33e18 * 2^32 / 1 day)
```

The configured launch rate has the useful property that the standard seven-day chunks and final two-day chunk are
already exact whole-wei amounts. Over exactly 100 days:

```text
floor(100 days * initialRate / 2^32) = 333,333e18
```

The launch tests call the scheduler every seven days, followed by the final two-day interval, and verify that the sum
paid through the 100-day boundary is exactly `333,333e18` without fractional carry state.

This exact total assumes no unrelated Ve33 schedule supplies part of the configured minimum. If another schedule does
overlap, paying less is correct: the scheduler is maintaining a minimum global rate, not blindly adding a second
stream.

## Expected keeper cadence

For the launch configuration, call `scheduleEmissions()` at least once per week.

A practical cadence is:

- make sure the scheduler has enough prefunded stake tokens;
- call once when emissions are ready to begin;
- call again roughly every seven days; and
- monitor transactions and call again after any failure.

Calling more frequently is safe. If the current policy horizon is already covered, the function returns zero.

A late call does not lose policy accounting. Its horizon is still based on `block.timestamp + scheduleDuration`, so it
can catch up unaccounted policy time and preschedule the next interval in one transaction. However, late calls delay
the physical distribution and can make the fitted stream more compressed.

If several queued configuration timestamps have passed, each call stops at the next timestamp. A call also accounts no
more than `uint32.max` policy seconds after a very long keeper outage. Call repeatedly until `lastScheduledTime` has
crossed the elapsed updates and the intended configuration is active. This bounds the work performed by one
transaction.

## Launch funding and ownership

`ConfigureSTONX` intentionally does not transfer STONX ownership to the scheduler. The scheduler does not need or use
minting authority. STONX ownership is transferred to governance after the scheduler is funded and configured.

During deployment it:

1. Transfers exactly `333,333e18` STONX to the scheduler for the initial 100-day program.
2. Sets the active minimum to zero with a one-week schedule duration.
3. Queues the 3,333.33-per-day configuration at the exact launch timestamp.
4. Queues the ongoing configuration exactly 100 days later.
5. Advances the zero-rate policy cursor to the launch timestamp, activating the initial configuration without paying
   or scheduling emissions.
6. Transfers scheduler ownership to governance.
7. Transfers the deployer's entire remaining STONX balance to governance.
8. Transfers STONX ownership to governance.

The scheduler is ready to pay for the full initial program from its own balance, so anyone can call
`scheduleEmissions()` when the start timestamp is reached.

The initial funding is exhausted after the first 100 days if no other schedule contributes to the minimum. Fund the
scheduler again before asking it to schedule the ongoing policy:

- transfer ERC-20 stake tokens directly to the scheduler; or
- send ETH directly to the scheduler when `stakeToken()` is `address(0)`; the scheduler inherits a payable
  `receive()` function from `BaseOwnableExecutor`.

An underfunded call reverts atomically. It cannot leave behind scheduler state changes or an unpaid Ve33 schedule.

## Multicall

The scheduler inherits Solady's standard `Multicallable` through `BaseOwnableExecutor`. This is not
`PayableMulticallable`: `multicall()` rejects nonzero `msg.value`.

Configuration calls can be batched, as `ConfigureSTONX` does. Native-token funding must be sent to the scheduler in a
separate plain ETH transfer, not attached to `multicall()`.

## Owner operations

### Immediate configuration

`setConfig(minEmissionsRate, scheduleDuration)` replaces the active policy without rewinding either scheduler cursor.

More precisely, the new policy begins at the later of the current block and `lastScheduledTime`. If a permissionless
caller has already prescheduled the old policy, governance can still call `setConfig()` to stop any further extension;
the policy and execution cursors are never rewound. Already-funded Ve33 streams remain committed because Ve33 has no
cancellation operation.

It reverts if:

- a queued update is already wall-clock due and must first be processed or cancelled;
- a nonzero rate is paired with zero duration; or
- the rate exceeds `MAX_MIN_EMISSIONS_RATE()`.

It preserves the linked-list head.

`setConfig(0, 0)` disables new scheduling. A zero-duration policy has no lookahead: if it has a queued successor, a
permissionless call activates that successor once its start timestamp is reached.

### Schedule a configuration

`scheduleConfig(startTime, minEmissionsRate, scheduleDuration, previousConfigTime)` inserts a future node.

Requirements include:

- `startTime` must be in the future;
- `startTime` must be later than `lastScheduledTime`;
- `scheduleDuration` must be nonzero;
- `minEmissionsRate` must not exceed `MAX_MIN_EMISSIONS_RATE()`;
- no node may already exist at `startTime`; and
- `previousConfigTime` must identify the correct insertion position.

Use scheduled configurations for planned changes at exact policy timestamps.

### Cancel a configuration

`cancelConfig(startTime, previousConfigTime)` removes a future node.

A node remains cancellable after its wall-clock start timestamp if policy accounting has not reached it. It cannot be
cancelled once `lastScheduledTime` has reached its timestamp. This gives governance a recovery path if execution of an
overdue policy is blocked by funding or Ve33 state.

## Monitoring

Useful reads are:

- `config()`: packed active `Ve33EmissionRateConfig` plus queue-head timestamp;
- `getConfigState()`: packed active configuration plus all queued configuration timestamps in ascending order;
- `config().nextConfigTime()`: queue-head timestamp read from the packed active state;
- `scheduledConfigs(timestamp)`: packed linked-list node at a timestamp;
- `lastScheduledTime()`: exact policy cursor;
- `emissionEnd()`: execution-time cursor; future values are Ve33-valid scheduling boundaries;
- `MAX_MIN_EMISSIONS_RATE()`: largest accepted policy minimum;
- the scheduler's stake-token balance: remaining funding;
- `stakeToken()`: ERC-20 address or the native-token sentinel; and
- `scheduleEmissions()` return value: actual amount paid for that call.

Useful events are:

- `ConfigSet`;
- `ConfigScheduled`;
- `ConfigActivated`; and
- `ConfigCancelled`.

## Operational edge cases

- If the configured amount is too small to fit into any currently available valid Ve33 interval while remaining at or
  above the minimum rate, the call reverts with `NoValidEmissionEnd`. Waiting allows more policy amount to accrue.
- A wall-clock-due but unaccounted queued node can still be cancelled if execution cannot reach it.
- Existing emissions can reduce the scheduler's payment below the nominal policy amount, including to zero.
- A zero minimum advances policy time without payment and is useful for delayed launches.
- A `(0, 0)` policy is fully disabled until a queued configuration becomes wall-clock due.
- Fractional Q32 amounts are not carried, and independent Ve33 subinterval round-ups are not reconciled. Both effects
  are bounded dust in the token's smallest unit.
- Configuration insertion and cancellation are owner-only, but emission maintenance is permissionless.
- The scheduler does not need token ownership or a mint interface, but it must be sufficiently prefunded.
- The owner can use `call()` to recover or reposition excess ERC-20 or native-token funding.
- The linked list deliberately uses caller-supplied hints; offchain tooling should read the queue before submitting an
  insertion or cancellation.
