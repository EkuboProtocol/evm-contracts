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
swap. Rent pays for time active rather than for exposure to any one trade, and
availability is best-effort; see Economics.

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
  competitor therefore obliges at least one paid second above its rate, which
  need not contain an executable block, and the displacing bid activates and
  ends any incumbent schedule, whose tail is credited. The displaced bidder is refunded in full and may bid again from the
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

Anyone can arbitrage a rented pool for the price of the fee, so while
arbitrageurs are active and the fee is low the price stays within the fee band
of the market. The holder chooses the fee and therefore how wide that band is,
with no cap: a prohibitive fee makes the pool exclusive. Swappers must bound
every swap by fee-inclusive minimum output or maximum input and an expiry, and
the pool price is not an oracle. See Economics.

## Rent

Rent is settled lazily before swaps, position updates, claims, bids, and by
`accrue(poolKey)`. It accrues from a bid's scheduled start even across quiet
periods.

- Rent belongs to liquidity **active over time**. Settling before a price move
  attributes the elapsed interval to the liquidity that was active during it.
  Before a swap that restores a moved price, that is the liquidity at the moved
  price; the restored liquidity earns from the swap's timestamp onward.
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
  `AuctionPositions` therefore collects before every deposit and withdrawal.
  `AUCTION_COLLECT_RENT` moves the position owner's rent to its locker;
  `getPositionRent` quotes the rent a collection in the current block would pay,
  settling the elapsed interval in memory.
- Integer rounding favors solvency; the scaled remainder of each global growth
  update is carried to the next settlement so settlement cadence cannot strand
  rent, while per-position checkpoint dust remains in the extension. There is no
  administrator sweep of any balance.

## AuctionPositions

`AuctionPositions(core, auction, metadataOwner)` is a position NFT manager for
this extension's pools, without protocol fees, that also collects rent:

```solidity
deposit(id, poolKey, tickLower, tickUpper, maxAmount0, maxAmount1, minLiquidity, rentRecipient)
withdraw(id, poolKey, tickLower, tickUpper, liquidity, recipient)
collectRent(id, poolKey, tickLower, tickUpper, recipient)
withdrawForfeitingRent(id, poolKey, tickLower, tickUpper, liquidity, recipient)
getPositionRentAndLiquidity(id, poolKey, tickLower, tickUpper)
```

The NFT owner and approved operators may deposit, withdraw and collect; the
overloads without a recipient pay the caller. The metadata owner receives no
right to other users' rent. The manager accepts only this extension's pools.

The extension discards a position's uncollected rent on any
nonzero liquidity change, so `deposit` (including a top-up) and `withdraw`
collect the position's rent in the same lock before changing its liquidity and
return it. A deposit into a position without liquidity skips the collection:
it has earned nothing. `withdrawForfeitingRent` is the only path that discards
rent. It exists so principal stays withdrawable independently of the rent
collection path and should not be offered as a default action.

`getPositionRentAndLiquidity` and the extension's `getPositionRent` settle the
elapsed interval in memory, so in any block they equal what collecting in that
block pays. Integrators should display that value, not a figure derived from
the last settlement.

Claimability travels with the NFT on transfer. Burning does not settle Core
positions or rent, and the original minter can recreate the same deterministic
NFT ID and thereby regain control of any value left under that ID. Burning a
funded NFT is not blocked on chain, as in the other Ekubo position managers:
the manager does not track which positions an ID holds, and doing so would add
a storage write to every position opening and closing. Exit with one
`multicall` that withdraws every position of the ID, which collects its rent,
and then burns; interfaces must warn before a burn of an ID with liquidity or
rent.

## Economics

In an ordinary pool the loss providers suffer to arbitrageurs when the market
moves is captured by the arbitrageurs and the block builders they compete
through; providers keep only the swap fee. Here the exclusive fee-free position
that lets one party capture that loss is auctioned, and the auction revenue is
paid to the providers whose liquidity is active while it is rented. With
competitive bidders, rent can approach the value of fee-free access plus the fee
revenue from other swappers, which is why this can pay more than a fixed
creator-chosen fee.

That outcome is conditional. The auction is **best-effort and permissionless**:
it guarantees who holds each paid second and that every obligation is funded,
not that the pool is available, that competition is meaningful, or that rent
compensates the providers who bore a given trade. The subsections below state
what the mechanism does in each case, and
[Assumptions and accepted residual risks](#assumptions-and-accepted-residual-risks)
lists what it relies on.

### Paid seconds are not executable blocks

A bid included in a block with timestamp `t` covers `[t + 1, end)`. It can swap
only in blocks whose timestamp lies in that interval, and rent accrues for every
second of it whether or not a block, or a swap, happens in that second. Further
blocks sharing timestamp `t` do not activate it.

On a chain whose next block after `t` arrives at `t + Δ`, the first block in
which a new bid can swap is at `t + Δ`, so `end` must be at least `t + Δ + 1`.
The cheapest usable bid therefore pays `Δ` seconds, `Δ - 1` of them before its
first swap. A one-second bid (`end = t + 2`) is usable in the next block only
when `Δ = 1`; with `Δ ≥ 2` it pays one second and never swaps. Missed or delayed
blocks lengthen `Δ` for that bid.

So a challenger that wants to take over and trade once pays at least `R × Δ`
rent at rate `R`, plus gas, priority fees, the capital cost of its escrow and
any inclusion margin, and it succeeds only if its bid and its swap are both
included in time and it is not outbid first. An opportunity worth `B` is worth
challenging for only when the expected `B`, weighted by that success
probability, exceeds these costs net of any refund if it is displaced. On long
block intervals, opportunities smaller than about `Δ` seconds of the prevailing
rent are not worth challenging for even with certain inclusion.

### Rent incidence

Rent follows **time active**, not inventory exposure within a block.

- Every swap settles rent before it moves the price, so the interval since the
  last settlement goes to the liquidity active at the pre-swap price. When a
  swap restores a moved price, the seconds that elapsed before it, including a
  challenger's own `Δ - 1` seconds before its first block, go to the liquidity at
  the moved price, not to the providers the swap brings back into range. Those
  earn from the restoring swap's timestamp onward.
- Liquidity that swaps traverse and leave within one timestamp earns nothing for
  those swaps: a price moved away and back in the same second accrues that
  second to wherever the price sits when the next settlement runs.
- A holder that also provides liquidity receives its share `α` of the rent it
  pays, so the rent it pays to others is `(1 - α) × R`, before gas and capital
  costs. Where its liquidity is the only active liquidity, `α` is close to one.
- Rent charged while no liquidity is active is discarded, and any nonzero
  liquidity change, including a top-up, discards the position's uncollected
  rent. Both are intentional, following Core swap fees and Ve33 rewards.
  `AuctionPositions` deposits and withdrawals collect first; only its
  `withdrawForfeitingRent` escape hatch discards (see [AuctionPositions](#auctionpositions)).

Full-range and stableswap pools allocate rent globally and pro rata, so no range
can be isolated from the rest there; common-control shares still apply.

### The outsider fee is uncapped

The holder chooses the fee that other swappers pay it, up to `1 - 2**-32`. At fee
`f`, outsiders can profitably arbitrage the pool only outside the band
`(1 - f) P ≤ p ≤ P / (1 - f)` around the market price `P`, before gas and depth.
That is `[0.99, 1.0101] P` at 1% and `[2**-32, 2**32] P` at the maximum. The fee
is therefore **exclusivity-capable**: a holder can make outside trading
ineffective and the pool price need not track the market.

A fee change applies from the next second, so a quote can be stale by the time a
swap lands. Traders and integrators must bound every swap by fee-inclusive
minimum output or maximum input and an expiry; a bounded swap reverts or routes
elsewhere instead of paying an arbitrary fee. At very high fees an exact-output
swap's grossed-up input can exceed Core's representable amounts and revert.
**The pool price is not an oracle.**

### Parking and restoration

A holder can move the price into a range where its own liquidity is the only
active liquidity, set a prohibitive fee, and receive most of its own rent back.
Doing so fills the positions it moved through at off-market prices and leaves a
restoration opportunity in the pool. The mechanism does not guarantee anyone
claims it:

- A challenger pays at least `Δ` seconds of rent at a rate above the holder's to
  restore once, and its `Δ - 1` pre-swap seconds go to the parked liquidity.
- A holder with ordering priority can restore and re-park within one timestamp,
  which recovers its own parking premium up to rounding.
- A challenger can add liquidity at the parked price before bidding and, by
  collecting before withdrawing, recapture its share of that pre-swap rent. That
  needs inventory held across blocks, exposed to the holder's trades, and
  competes with other entrants.
- Providers can withdraw while parked and keep the premium the move paid them,
  but withdrawal is delayed by observation and inclusion and does not undo
  earlier losses.

Neither sustained profitable parking nor its impossibility is established; the
outcome depends on ordering power, liquidity concentration, entry capacity and
capital. The regression tests pin each mechanical step above.

### Displacement

Displacing a competitor's pending bid obliges the displacer to hold that second
above the displaced rate (see
[Pending displacement is binding for one second](#pending-displacement-is-binding-for-one-second)).
The obligation is one second, not the displaced tenure. A **paid short
displacement** — a one-second bid one base unit above a longer pending or live
schedule — ends that schedule at its activation. The displaced bidder is
credited in full and may re-bid from the next second, but its schedule is not
restored, and on a chain with `Δ ≥ 2` the displacer may have no executable block
while the pool is closed at the next block. It costs the displacer
`(1 - α) × (r + 1)` for rate `r`, plus gas and capital; repeating it requires
winning ordering each time. It moves no one else's funds: it is paid disruption,
not theft.

### No reserve, increment, notice or minimum tenure

A lone bidder can rent the pool for almost nothing; providers set the floor by
withdrawing when rent does not cover what the holder's trading costs them, and a
thin pool is worth little to rent. There is no minimum increment, notice period
or minimum tenure, so a holder whose valuation falls can leave at the next
second instead of pricing a lockup into every bid, and a challenger never waits
longer than next-second activation. The same absence is what makes the paid
short displacement above possible and leaves tenure uncertain. These are
choices of flexibility over guaranteed tenure, not claims that brief control
is irrational.

### Assumptions and accepted residual risks

The mechanism relies on these assumptions; none is enforced on-chain.

- **Ordering.** Inclusion and ordering of bids and swaps are not guaranteed.
  Proposers, builders and sequencers can order, delay or exclude transactions,
  bid themselves, and accept side payments. Repeated displacement or
  same-timestamp restoration requires winning ordering.
- **Entry.** Liquidity provision and bidding are permissionless and free to
  enter and exit. Entrant liquidity and entrant bidders are the counter to
  parking and to a lone bidder; the mechanism does not supply them.
- **Capital.** Bids are escrowed in full for their tenure. Counter-parking
  liquidity must be financed across blocks. Flash liquidity cannot hold a
  position across timestamps or activate a bid.
- **Gas.** Every bid, swap, collection and position change costs gas and
  priority fees. High costs deter small challenges and favour incumbents; low
  costs make paid disruption cheaper.
- **Participation.** There is no keeper reward. Price restoration and
  competition happen only when some party profits from them, and providers
  must monitor and act for themselves.
- **Assets.** The bid token is a native token or a standard non-rebasing ERC20.
  Bidders and providers bear the exchange risk between it and the pool's
  tokens.

The following are **accepted, priced residual risks** of the best-effort,
permissionless design:

1. A paid second is not an executable block; bidders pay `Δ - 1` seconds
   before their first usable block, and a mis-sized bid can pay and never swap.
2. A paid short displacement can truncate a longer pending or live schedule
   without restoring it, at the price of one second above its rate.
3. Pool availability is not guaranteed. The pool does not swap in any second
   that no bid covers, and there is no fallback schedule.
4. Economically meaningful competitive tenure is not guaranteed.
5. The holder's outsider fee is uncapped and can make the pool exclusive.
6. Rent follows time active, not inventory exposure, so it can go to liquidity
   other than the liquidity a trade crossed, including the holder's own.
7. Rent is discarded when no liquidity is active and on any nonzero liquidity
   change before collection. `AuctionPositions` collects before every deposit
   and withdrawal; other lockers must do the same.

Launch claims must not state or imply guaranteed availability, a market-tracking
price, or full compensation of providers for arbitrage losses.

### Bidder scheduling

Bidders size `end` for the chain they are on. For a chain with block interval
`Δ` (use a conservative upper bound where it varies or slots can be missed),
latest acceptable bid inclusion timestamp `t`, `N` blocks of intended use and a
margin of `M` blocks for late bid or swap inclusion:

```
end = t + (N + M) × Δ + 1
```

- A bid included on time at `t` pays `(N + M) × Δ` seconds, `Δ - 1` of them
  before its first usable block.
- `end` is absolute. A bid included later has proportionally less tenure, and
  one included at or after `end - 1` reverts with `InvalidBid`, so `end` also
  acts as the bid's expiry.
- The bid cannot swap in its own inclusion block unless its bidder already holds
  the pool. Submit the swap for a later block.
- Without margin (`M = 0`), a swap that misses the first usable block finds the
  pool closed.

| Block interval `Δ` | Minimal usable `end` | Seconds paid | Paid before first swap | Seconds paid with `M = 1` |
|---|---|---|---|---|
| 1 s | `t + 2` | 1 | 0 | 2 |
| 2 s | `t + 3` | 2 | 1 | 4 |
| 6 s | `t + 7` | 6 | 5 | 12 |
| 12 s | `t + 13` | 12 | 11 | 24 |

Before displacing another bidder's pending bid, note that the replacement
cannot be withdrawn within that second. A displaced bidder should watch
`BidUpdated`, withdraw or reuse its credit, and re-bid; its old schedule does
not come back. Fee changes apply from the next second. The `test_chainAware_*`
and `test_economic_*` tests exercise these rules for 1, 2, 6 and 12-second
intervals.

### What the mechanism does not do

It does not guarantee retail flow, which reaches the pool only through lockers
that forward to the extension; it does not pay providers whose liquidity is
inactive, whatever the cause, so out-of-range providers should withdraw rather
than wait; and it does not compensate providers while the pool is unrented.

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
- **Competition.** A bid for `s` beats every other schedule covering `s`. Once a competitor's promise for `s` is displaced, second `s` is paid for above that promise. A paid second need not contain an executable block.
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

### Availability is best-effort

**Context.** The auction keeps one live and one next-second bid, requires a
strict outbid, activates bids the next second, credits displaced schedules
immediately and binds a same-second displacement for one second. It has no
reserve, increment, notice or minimum tenure. A paid second is therefore not an
executable block, and a paid short displacement can end a longer schedule.

**Decision.** Keep the mechanism and make no availability guarantee. Pool
availability and economically meaningful competitive tenure are not
guaranteed; the residual risks are accepted and priced as listed under
[Assumptions and accepted residual risks](#assumptions-and-accepted-residual-risks),
and bidders schedule for their chain as in [Bidder scheduling](#bidder-scheduling).

**Tradeoffs.** Guaranteeing usable tenure would need minimum competitive
durations, block-based epochs or a recoverable fallback schedule. Each adds
state and escrow, raises the cost of honest late challenges and of exit, and
cannot express wall-clock rent in blocks directly. A reserve rate or minimum
increment would raise the price of disruption without guaranteeing an
executable window.

### No fee cap

**Decision.** The holder chooses any fee up to `1 - 2**-32`. The fee is
exclusivity-capable, the pool price is not an oracle, and traders and
integrators must use fee-inclusive minimum-output or maximum-input bounds and an
expiry.

**Tradeoffs.** A cap would make outside arbitrage effective within a known band
but would limit what the holder can charge routed flow and would not by itself
fix rent incidence. Caps or opt-in fee classes remain possible later designs.

### Rent follows time active

**Decision.** Rent settles before every swap and position change and is
credited to the liquidity active over the elapsed interval. Before a restoring
swap, the elapsed rent goes to the liquidity active at the pre-swap price. Rent
with no active liquidity, and a position's uncollected rent on any nonzero
liquidity change, is discarded, as Core swap fees and Ve33 rewards are.

**Tradeoffs.** This is the same per-tick growth accounting Core and Ve33 use and
costs nothing beyond it. Paying for exposure within a block instead, such as by
giving traversed liquidity a share of swap-time value, would need a different
accounting and a fresh review of JIT, Sybil and gas costs. Banking uncollected
rent across liquidity changes would add a write per position change;
`AuctionPositions` instead collects in the same lock before every deposit and
withdrawal, which costs a forward only when the position already has liquidity.

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
displaced, second `s` is paid for by a bid whose rate exceeds that promise.
Displacing a competitor cannot preserve a lower-rate schedule or leave second
`s` unpaid. Funds are conserved throughout: the saved balance equals the
unsettled current second, outstanding credits and the live and pending
schedules.

**Tradeoffs.** The obligation is one paid second above the displaced rate, not
the displaced bidder's full tenure and not an executable block: on a chain with
blocks more than one second apart, the displacer may never be able to swap. A
bidder with a higher valuation can take the pool briefly and exit by truncation
the next second. The displaced bidder is refunded but not restored, and must
re-bid from the next second. The displacing bid still activates and ends the
incumbent's schedule, crediting its tail. Suppressing a challenger therefore
costs the incumbent one second above the challenger's rate and its lower-rate
tenure, rather than nothing, but it does not stop a paid short displacement
(see [Displacement](#displacement)). Obligating the displaced tenure, or
keeping the displaced schedule as a recoverable fallback, would need more
state and is outside the best-effort decision above. Honest bidders give up
only same-second cancellation after outbidding someone.

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
