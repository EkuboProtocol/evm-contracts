# Continuous swap-access auction

`ContinuousAuction` is an auction-managed pool extension. Liquidity providers in
its pools earn a single asset, the extension's immutable `bidToken`, instead of
swap fees in the pool's tokens. A continuous first-price auction sells the right
to be the pool's fee-free swapper. The winner pays rent per second to the
providers whose liquidity is active. Everyone else may still swap while the pool
is rented, paying the holder's fee to the holder.

Everything happens through `Core.forward` and is keyed by the forwarding locker,
as in Ve33. The extension never holds tokens: bid funding, credits, rent, and
swap fees are Core saved balances of the extension, and the locker that forwards
a call pays or withdraws the difference in the same lock.

`bidToken == address(0)` selects the native token; other addresses select
standard, non-rebasing ERC20s. Incoming ERC20 funding is checked against the
received balance, so transfer-tax deposits are rejected. One deployment serves
one bid token; deploy again for another.

## Pools

Any pool whose key names this extension with a zero Core fee can be initialized
directly through Core by anyone. Concentrated pools need a power-of-four tick
spacing; full-range and stableswap configurations are supported as well. The
extension has no terms, per pool or per deployment: its only parameters are Core
and the bid token. There is no reserve rate, no minimum bid increment, and no
notice period. Providers set the floor themselves by withdrawing when rent does
not cover what the holder's trading costs them, and an unrented pool does not
swap, so they are never exposed without being paid.

## Forward interface

The first word of forwarded data selects the operation; anything else is a
swap. `ContinuousAuctionLib` encodes each call.

```solidity
AUCTION_UPDATE_BID        (PoolKey key, bytes32 salt, uint96 rate, uint64 end, address executor, uint32 fee) -> int256 delta
AUCTION_COLLECT_RENT      (PoolKey key, PositionId positionId)                                                 -> uint256 amount
AUCTION_COLLECT_SWAP_FEES (PoolKey key, bytes32 salt)                                                          -> (uint128, uint128)
swap                      (PoolKey key, SwapParameters params)                                                 -> (PoolBalanceUpdate, PoolState)
```

A bid is identified by `keccak256(abi.encode(locker, salt))`, so one locker can
hold bids under several salts and a periphery can represent many users. Rent is
owed to the Core position owner, which is the forwarding locker.

### Updating a bid

`AUCTION_UPDATE_BID` is the only bid operation. It sets the caller's bid for
`[timestamp + 1, end)` at `rate` base units per second with the given executor
and fee, replacing whatever the caller had scheduled:

- A new bid must exceed every other live schedule covering its start: a
  same-second pending bid and/or the live incumbent. The scheduled bidder may
  replace its own bid, and an expiring incumbent need not be outbid.
- Displacement takes effect at activation, not at placement. The incumbent is
  never truncated early, so cancelling a pending bid never closes the pool
  early. The incumbent's relinquished tenure is credited
  when the new bid activates; a replaced pending bid is credited immediately
  since its tenure never started.
- A killed pending promise still binds same-start replacements: displacing
  another bidder's pending bid records its rate, and every bid for that start —
  including cancel-and-rebid by the displacer — must beat it until the second
  passes. Topping the killed promise by one wei suffices.
- **The floor binds the pending slot.** The displacing pending bid cannot be
  cancelled within that second (rate zero reverts with `BidTooLow`); its owner
  may only replace it above the killed promise. Otherwise a bidder could kill a
  competing pending bid with a second salt or identity and cancel for free,
  keeping a lower-rate incumbent or leaving the pool closed. Displacing a
  competitor therefore obliges at least one second of rent above its rate, and
  the displacing bid activates and ends any incumbent schedule, whose tail is
  credited. The displaced bidder is refunded in full and may bid again from the
  next second; its schedule is not restored. A pending bid that displaced
  nobody stays freely cancellable, and the obligation lapses when the second
  passes, after which the displacer may exit by truncation like any holder.
- `end - start` must be at least one second and at most `2**32 - 1` seconds, and
  `end` must fit in 48 bits. Rate zero removes the caller's schedule from the
  next second on, except a pending bid bound by the floor above.
- The incumbent keeps the current second. Another bidder's displaced tenure is
  credited when the new bid activates. The caller's own replaced tenure and any
  outstanding credit are netted against the new funding, and the returned `delta` is what
  the locker owes (positive) or may withdraw (negative) in the same lock. A call
  with rate zero and nothing scheduled simply withdraws the credit.
- `fee` is the fee the bid charges non-holder swaps once it activates, a 0.32
  fixed-point fraction: the upper 32 bits of Core's fee format. There is no cap.
  To change it, replace the bid; the change applies from the next second.
- `executor` is the authorized **Core locker contract**. It must authenticate
  its callers. Naming a permissionless router grants that router's users
  fee-free access.

Extend, shorten, raise, lower, re-target the executor, change the fee, and exit
are therefore all the same operation, and several can be batched in one lock.
The schedule is one live bid plus at most one pending bid placed this second.
Every operation is constant time.

### Settlement

Bidders are lockers: they call `Core.forward(address(extension))` and settle
the returned delta in the same lock, paying a positive delta and withdrawing a
negative one. No bidder periphery is deployed. `test/AuctionPeriphery.sol` is a
test-only settling locker used by the test suite and gas snapshots.

## Swaps

The authorized locker calls `Core.forward(address(extension))` with trailing
`abi.encode(poolKey, swapParameters)`. Direct Core swaps revert.

- The holder's executor swaps with no fee.
- While the pool is rented, any other locker may forward a swap and pays the
  holder's fee to the holder: on the output for exact-input swaps, on the input
  for exact-output swaps. The returned `(PoolBalanceUpdate, PoolState)` already
  reflects the fee. Fees are saved in Core under a salt of the pool and bidder
  and moved to the bidder's locker by `AUCTION_COLLECT_SWAP_FEES`.
- Without a live bid the pool does not swap. Providers may still deposit and
  withdraw at any time.

Because anyone can arbitrage a rented pool for the price of the fee, the price
stays within the fee band of the market whenever arbitrageurs are active. The
holder chooses the fee and therefore how tight that band is. A holder that sets
a prohibitive fee makes the pool exclusive in practice; what that costs it is
described under Economics.

## Rent

Rent is settled lazily before swaps, position updates, claims, bids, and by
`accrue(poolKey)`. It accrues from a bid's scheduled start even across quiet
periods.

- Rent belongs to liquidity **active over time**. Settling before a price move
  attributes the elapsed interval to the liquidity that was active during it.
- Concentrated pools use Q128 growth, per-tick outside growth, and per-position
  snapshots, following Ve33's external reward accounting. Full-range and
  stableswap pools use global growth, so every position earns pro rata
  regardless of price.
- Rent charged while no liquidity is active is discarded: it is logged but never
  refunded nor paid to later depositors. A holder can avoid that outcome by
  providing liquidity at the market price itself.
- Position changes advance the position's snapshot when liquidity actually changes.
  Like Core swap fees and Ve33 rewards, rent is computed from the snapshot and
  never banked, so uncollected rent is discarded on any nonzero liquidity change.
  Collect first — `withdrawAndCollectRent` collects and withdraws atomically.
  `AUCTION_COLLECT_RENT` moves the position owner's rent to its locker;
  `getPositionRent` quotes already-accrued rent.
- Integer rounding favors solvency; the scaled remainder of each global growth
  update is carried to the next settlement so settlement cadence cannot strand
  rent, while per-position checkpoint dust remains in the extension. There is no
  administrator sweep of any balance.

## AuctionPositions

`AuctionPositions(core, auction, metadataOwner)` is a position NFT manager for
this extension's pools, without protocol fees, that also collects rent:

```solidity
collectRent(id, poolKey, tickLower, tickUpper, recipient)
withdrawAndCollectRent(id, poolKey, tickLower, tickUpper, liquidity, recipient)
getPositionRentAndLiquidity(id, poolKey, tickLower, tickUpper)
```

The NFT owner and approved operators may collect; the overloads without a
recipient pay the caller. The metadata owner receives no right to other users' rent.
Uncollected rent is discarded on any liquidity change, so collect before depositing
more or withdrawing — `withdrawAndCollectRent` does both atomically. Claimability
travels with the NFT on transfer. Collect all
balances before burning the NFT. The original minter can
recreate the same deterministic NFT ID and thereby regain control of any value
left under that ID after an authorized burn.

Use `mintAndDeposit`, `deposit`, and `withdraw` for principal. The manager
accepts only this extension's pools.

## Economics

In an ordinary pool the loss providers suffer to arbitrageurs when the market
moves is captured by the arbitrageurs and the block builders they compete
through; providers keep only the swap fee. Here the exclusive fee-free position
that lets one party capture that loss is auctioned, and the auction revenue is
paid to the providers whose liquidity bears it. Paying rent pro rata to active
liquidity over time matches how that loss is borne. With competitive bidders,
rent approaches the value of fee-free access plus the fee revenue from other
swappers, which is why this can pay more than a fixed creator-chosen fee.

The design choices below each close a way for that revenue to leak:

- **Fee-paying outsider swaps** let the holder monetize routed flow and keep
  the price within the fee band of the market. The holder sets the fee because
  it earns it and wants it low enough to attract that flow.
- **Parking is a bounty, not a strategy.** A holder could set a prohibitive fee,
  deposit dust away from every other position, and move the price there so all
  rent returns to itself. Doing so fills every position it moved through at
  above-market prices, so the pool then holds a mispricing worth roughly the
  traversed range width times the capital in it. Any bidder can claim it by
  outbidding the holder, waiting one second, and moving the
  price back with its first swap; its cost is one second of rent, which goes to
  the providers the parker was starving, and the parker is left holding
  inventory bought above market. To make that challenge unprofitable the parker
  would have to make one second of rent exceed the bounty, which no rational
  bidder does. Providers can also withdraw while parked and keep the premium.
  And while parked the holder earns nothing else: no outsider swaps at a
  prohibitive fee, so there is no fee revenue, and no arbitrage flow reaches the
  pool, so the rent only buys exposure to providers who have no reason to stay.
- **No reserve rate.** A lone bidder can rent the pool for almost nothing, but
  providers are not obliged to stay: rent below what the holder's trading costs
  them is a signal to withdraw, and a thin pool is worth little to rent. A
  creator-chosen reserve could only add a way for the pool to sit unrented.
- **No increment, no notice.** Both would only deter behaviour that is
  irrational anyway: a bidder that flips control pays full rent for every
  second it holds and gains nothing, and rational competitors jump to their
  valuation rather than creep. Their absence keeps takeovers and challenges as
  cheap as the one-second activation allows, which is what makes parking
  indefensible, and lets a holder whose valuation falls leave at once instead
  of pricing a lockup into every bid.

What the mechanism does not do: it does not guarantee retail flow, which
reaches the pool only through lockers that forward to the extension; it does not
pay providers whose liquidity is inactive, whatever the cause, so out-of-range
providers should withdraw rather than wait; and it does not compensate providers
while the pool is unrented. Bidders bear the exchange
risk between the bid token and the pool's tokens.

## Architecture

### State

Per pool, in the extension:

| State | Meaning |
|---|---|
| `bids[2]`, `currentIndex` | The current bid is `bids[currentIndex]`. It covers `[start, end)`, and `start <= lastSettled` once it is current. |
| `hasNext` | `bids[currentIndex ^ 1]` is a next bid placed during second `lastSettled`, starting at `lastSettled + 1`. Otherwise that slot is stale and never read. |
| `lastSettled`, `accrualRemainder`, `growth` | The settlement clock, the Q128 rent growth per unit of active liquidity, and the carried division remainder. These pack with `currentIndex` and `hasNext` into one slot, except `growth`. |
| `pendingFloor` | The rate and start of the latest displaced next bid. It binds only while `start == block.timestamp + 1`. |
| `growthOutside[tick]` | Rent growth on the far side of each initialized boundary of a concentrated pool. |

Per bidder (`keccak256(locker, salt)`): `refundable`, credit netted into its next bid update.
Per position: `positionRentSnapshot`.

In Core:
- One saved balance of this extension holds every bid-token unit.
- Per-pool, per-bidder saved balances hold outsider swap fees.
- The Core position liquidity is the only record of provider principal.

### Transitions

`_accrue` runs first in every operation that reads or changes auction state. It settles `[lastSettled, now)`:

| Before settlement | Effect |
|---|---|
| `now == lastSettled` | Nothing. |
| No next bid | Rent of the current bid over the interval accrues to active liquidity. |
| Next bid | Rent of the current bid up to the handover, plus the next bid from the handover. The current bid's tail after the handover is credited to its owner, and the next bid becomes current by flipping `currentIndex`. |
| Rent with zero active liquidity | Discarded and logged as `RentUnallocated`. |

A bid update by bidder `b` with start `s = now + 1`, after settlement:

| Case | Condition | Effect |
|---|---|---|
| New or raised bid | `rate > 0`; beats another bidder's next bid, the current bid when it covers `s` and is not `b`'s, and the floor for `s` | Writes the next slot. `b`'s own next bid is credited in full. `b`'s own current bid is truncated to `s` with its tail credited. Another bidder's next bid is credited in full and becomes the floor for `s`. |
| Cancel next bid | `rate == 0`, `b` owns the next bid, no floor for `s` | The next bid is credited in full, and the pool keeps the current bid. |
| Cancel a bound next bid | `rate == 0`, `b` owns the next bid, floor for `s` | Reverts `BidTooLow`. |
| Exit | `rate == 0`, `b` owns the current bid | The current bid is truncated to `s` and its tail credited. Another bidder's next bid is untouched. |
| Withdraw credit | `rate == 0`, nothing of `b`'s scheduled | Only `refundable[b]` is withdrawn. |

Every update nets `refundable[b]` and moves `cost - credit` through the saved balance in the same lock. Swaps revert unless the current bid covers `now`. The executor swaps fee-free; anyone else pays the holder's fee. Position changes on concentrated pools flip boundary ticks and re-snapshot. Swaps flip `growthOutside` for every initialized tick crossed.

### Invariants

- **Escrow.** The funds saved balance equals the sum of:
  - accrued, uncollected rent;
  - the unsettled rent of the current bid, which is its schedule from `lastSettled` to `end`;
  - the next bid's full schedule;
  - all `refundable` credit.

  The balance can only exceed this sum, by division dust and by discarded unallocated rent. The per-second reference and escrow fuzzers check this.
- **Access.** At most one bid holds the pool in any second. A next bid holds it only from its start, and a displaced current bid holds it until then.
- **Competition.** A bid for `s` beats every other schedule covering `s`. Once a competitor's promise for `s` is displaced, the pool is held during `s` above that promise.
- **Rent attribution.** Each interval's rent goes pro rata to the liquidity active at the tick it was spent at. The crossing reference fuzzer checks this.
- **Isolation.** All pools share one funds saved balance, but every obligation against it is tracked per pool, except bidder credit, which is fungible bid token by design. Swap fees are saved per pool and bidder, in the pool's own token pair.

### Why each piece of state exists

- **Two bid slots.** Access and handover need them. One slot plus a start time cannot tell a next bid from an extension of the current one without truncating the incumbent at placement. That would make cancelling harmful and let a pending bid veto the holder's exit.
- **`hasNext` separate from the stale slot.** Clearing the slot costs three zeroing writes per activation and three dirty writes per placement. A flag in the already-written settlement slot costs about 100 gas.
- **`pendingFloor`.** It is the only memory of a displaced promise, which the P1 binding needs. Keying it by start makes it expire without clearing.
- **`refundable`.** A displaced bidder is not the caller, so its funds cannot move in the same lock. Credit cannot be pushed to it without an external call.
- **Rejected removals.**
  - `accrualRemainder`: removing it would strand rent at fine settlement cadence.
  - `lastSettled` as a timestamp rather than a flag: rent is proportional to elapsed time.
  - Per-tick `growthOutside`: range-aware attribution needs it.

## Design decisions

### Pending displacement is binding for one second

**Context.** Displacing a competitor's same-second pending bid deletes and
fully refunds it. The floor already forced every later nonzero bid for that
start above the killed rate, but rate zero was exempt, so the displacer could
cancel. With a second salt, an incumbent at rate `R` could erase a `2R`
challenge by bidding `2R + 1` for one second and cancelling in the same
second, paying only gas. It kept its tenure at `R`. With no incumbent, anyone
could leave the pool closed the same way.

**Decision.** Rate-zero removal of the pending bid by its owner is subject to
the same floor as a nonzero replacement. After a displacement at start `s`,
whoever holds the pending slot for `s` cannot vacate it until `s` passes. It
may only replace it at a rate above the killed promise, for any tenure of at
least one second. Removing a live incumbent's own schedule is unchanged when
the incumbent does not hold the pending slot. An incumbent that displaced a
challenger by replacing its own bid holds the pending slot and is bound too.

**Preserved invariant.** Once a bidder's pending promise for `s` has been
displaced, the pool is held during `s` by a bid whose rate exceeds that
promise. Displacing a competitor cannot preserve a lower-rate schedule or
leave the pool unrented for that second. Funds are conserved throughout: the
saved balance equals the unsettled current second, outstanding credits and the
live and pending schedules.

**Tradeoffs.** The obligation is one second of rent above the displaced rate,
not the displaced bidder's full tenure. A bidder with a higher valuation can
still take the pool briefly and exit by truncation the next second. The
displaced bidder is refunded but not restored, and must re-bid from the next
second. The displacing bid still activates and ends the incumbent's schedule,
crediting its tail. Suppressing a challenger therefore costs the incumbent one
second above the challenger's rate and its lower-rate tenure, rather than
nothing.
Obligating the displaced tenure, or keeping the displaced schedule as a
recoverable fallback, would need more state and an economic change the board
has not accepted. Honest bidders give up only same-second cancellation after
outbidding someone.

### Gas-motivated structure

The two-slot bids and the batched LP reads do not alter behavior. The reference fuzzers cover them, and `snapshots/ContinuousAuctionTest.json` records their gas.

- **Two-slot bids with an index flip.** Activation flips `currentIndex`. A placement overwrites the stale slot. This replaces copying three slots and deleting three.
  - Recurring saving: about 69k per bid lifecycle (steady-state placement plus activation) before refunds, and at least 54.8k after the 14.4k the old deletion could refund.
  - Rejected: bid structs smaller than three slots. The rate, executor, fee and times do not fit in two words alongside a 32-byte bidder id.
- **Crossing follows Ve33.** After a swap, `_cross` walks Core's `prevInitializedTick` or `nextInitializedTick` from the old tick to the new one, passing the swap's `skipAhead` as the search hint, and flips `growthOutside` at each initialized tick it passes. It is the same walk `Ve33` uses. It costs one Core call per crossed tick or searched bitmap word.
  - Rejected: reading Core's bitmap words directly, in batches, and scanning their bits locally. It saved about 2k per crossed tick and more on long swaps across empty words, but it needed raw calldata assembly and a dependency on Core's bitmap layout.
- **Batched LP reads.** Position updates read the pool state and both boundary ticks in one Core call. Collection reads the pool state and the position together and computes the in-range growth once.

## Deployment and reproducibility

Use `script/DeployContinuousAuction.s.sol` with explicit `CORE_ADDRESS`,
`BID_TOKEN`, `OWNER_ADDRESS`, and a bytes32 `SALT`. It deploys the extension
and `AuctionPositions`.
`BID_TOKEN=0x0000000000000000000000000000000000000000` selects native rent. The
script uses the repository's canonical CREATE2 deployer and mines the required
extension address prefix (`0x51`). Optional `AUCTION_ADDRESS` and
`AUCTION_POSITIONS_ADDRESS` variables assert the predicted addresses. Repeated
execution reuses the same deployments. The metadata owner can subsequently call
the manager's inherited `setMetadata`.

```bash
forge test --offline --match-contract 'ContinuousAuction(Test|DeploymentTest)'
forge script --offline script/DeployContinuousAuction.s.sol:DeployContinuousAuction \
  --rpc-url "$RPC_URL" --account "$DEPLOYER_ACCOUNT"
```

The script command simulates deployment; add `--broadcast` for an approved
launch. The Core and bid-token bytecode must exist on the target chain (except
native address zero), and the chain must support transient storage. Initialize pools
directly through Core, configure a caller-authenticated executor before bidding,
and note that the general Router does not route through this extension.
