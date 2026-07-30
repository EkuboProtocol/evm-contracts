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
3. Pay only the tokens required to bring projected global Ve33 emissions up to the configured minimum.

`minEmissionsRate` is a floor, not an additive emissions stream. If another Ve33 schedule already supplies some or all
of the minimum, this scheduler pays only the shortfall. If projected emissions are already above the minimum, it pays
nothing.

The scheduler never calls a token mint interface. Its Ve33 stake token may be an ERC-20 or the native token:

- ERC-20 payments are transferred directly from the scheduler to the flash accountant.
- When `stakeToken()` is `address(0)`, native-token payments are sent as ETH from the scheduler to the flash
  accountant.

Every scheduling transaction reverts atomically if the scheduler does not have enough of the stake token.

## Configuration values

An emission-rate configuration contains:

- `minEmissionsRate`: the minimum global Ve33 emissions rate, expressed as Q32 token units per second.
- `scheduleDuration`: how far beyond the current block a keeper call may preschedule policy.

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
- `emissionEnd` is a timestamp accepted by Ve33. It records the valid execution-time boundary through which projected
  emissions have been covered.

These values are intentionally different. A governance update may begin at an arbitrary timestamp, but Ve33 still
requires schedule endpoints to be valid according to its existing time rules.

The scheduler does not relax or bypass those rules. Instead, it:

1. Calculates the exact whole-token policy amount accrued between policy timestamps.
2. Chooses a Ve33-valid execution interval no longer than the corresponding minimum-rate interval.
3. Fits the policy amount into that interval.

Because the chosen interval is no longer than the ideal interval, its fitted minimum rate is at least the configured
`minEmissionsRate`. This can make the physical stream slightly faster and shorter than the ideal policy interval.
Policy accounting and configuration activation still happen at the exact arbitrary timestamps.

## What `scheduleEmissions()` does

`scheduleEmissions()` is permissionless. A successful call performs the following work atomically:

1. Activate a queued configuration if the policy cursor is exactly at its start timestamp.
2. Set the policy horizon to the earlier of:
   - `block.timestamp + scheduleDuration`; or
   - the next queued configuration timestamp.
3. Accrue the configured Q32 minimum rate from `lastScheduledTime` through that horizon.
4. Carry the fractional low 32 bits in `rateRemainder`, so splitting the same policy interval across several keeper
   calls does not change its whole-token amount.
5. Select a compatible Ve33-valid execution interval.
6. Accrue current Ve33 emissions and scan any already-scheduled rate changes in that interval.
7. Where projected emissions are below the configured minimum, schedule enough shortfall to reach the fitted rate.
8. Pay the actual amount Ve33 requires for those shortfall schedules from the scheduler's balance.
9. Activate the next configuration if the policy horizon ended at its timestamp.

The returned amount is the number of tokens paid by that call. It can be lower than the policy amount when another
Ve33 emission schedule contributes to the global minimum.

## Exact 333,333 STONX launch period

The launch policy is:

- zero emissions before the start;
- an exact policy start one week after configuration;
- 3,333.33 STONX per day for exactly 100 policy days;
- 333,333 STONX of total scheduler spending over those 100 days when no other Ve33 emissions overlap; and
- a lower ongoing minimum rate after the 100-day boundary.

The initial rate is rounded up in Q32:

```text
initialRate = ceil(3,333.33e18 * 2^32 / 1 day)
```

The scheduler carries Q32 fractions across keeper calls. Over exactly 100 days:

```text
floor(100 days * initialRate / 2^32) = 333,333e18
```

The launch tests call the scheduler weekly and verify that the sum paid through the 100-day boundary is exactly
`333,333e18`.

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

If several queued configuration timestamps have passed, each call stops at the next timestamp. Call repeatedly until
`lastScheduledTime` has crossed the elapsed updates and the intended configuration is active. This bounds the work
performed by one transaction.

## Launch funding and ownership

`ConfigureSTONX` intentionally does not transfer STONX ownership to the scheduler. The scheduler does not need or use
minting authority.

During deployment it:

1. Transfers exactly `333,333e18` STONX to the scheduler for the initial 100-day program.
2. Sets the active minimum to zero with a one-week schedule duration.
3. Queues the 3,333.33-per-day configuration at the exact launch timestamp.
4. Queues the ongoing configuration exactly 100 days later.
5. Advances the zero-rate policy cursor to the launch timestamp, activating the initial configuration without paying
   or scheduling emissions.
6. Transfers scheduler ownership to governance.

STONX ownership remains with the deployer. The scheduler is ready to pay for the full initial program from its own
balance, so anyone can call `scheduleEmissions()` when the start timestamp is reached.

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

`setConfig(minEmissionsRate, scheduleDuration)` updates the active policy immediately.

It is intended for a policy that has not already been accounted into the future. It reverts if:

- a queued update is already due; or
- policy time or Ve33 execution time has already been scheduled beyond the current block.

It preserves the linked-list head.

### Schedule a configuration

`scheduleConfig(startTime, minEmissionsRate, scheduleDuration, previousConfigTime)` inserts a future node.

Requirements include:

- `startTime` must be in the future;
- `startTime` must be later than `lastScheduledTime`;
- `scheduleDuration` must be nonzero;
- no node may already exist at `startTime`; and
- `previousConfigTime` must identify the correct insertion position.

Use scheduled configurations for planned changes at exact policy timestamps.

### Cancel a configuration

`cancelConfig(startTime, previousConfigTime)` removes a future node.

A node cannot be cancelled once its start timestamp has been reached or once policy accounting has reached it.

## Monitoring

Useful reads are:

- `config()`: packed active `Ve33EmissionRateConfig` plus queue-head timestamp;
- `getConfigState()`: packed active configuration plus all queued configuration timestamps in ascending order;
- `config().nextConfigTime()`: queue-head timestamp read from the packed active state;
- `scheduledConfigs(timestamp)`: packed linked-list node at a timestamp;
- `lastScheduledTime()`: exact policy cursor;
- `emissionEnd()`: latest Ve33-valid execution boundary;
- `rateRemainder()`: carried Q32 fractional policy amount;
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
- Existing emissions can reduce the scheduler's payment below the nominal policy amount, including to zero.
- A zero minimum advances policy time without payment and is useful for delayed launches.
- Configuration insertion and cancellation are owner-only, but emission maintenance is permissionless.
- The scheduler does not need token ownership or a mint interface, but it must be sufficiently prefunded.
- The owner can use `call()` to recover or reposition excess ERC-20 or native-token funding.
- The linked list deliberately uses caller-supplied hints; offchain tooling should read the queue before submitting an
  insertion or cancellation.
