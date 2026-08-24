# Exchequer — a sovereign onchain central bank on Ekubo

An implementation of the [Standard whitepaper](https://www.standardreserve.xyz/whitepaper/) (v0.1)
built as an Ekubo Core extension rather than a Uniswap v4 hook.

Exchequer is a closed monetary economy with one currency (`$ISSUE`), one market (an ETH/`$ISSUE`
pool whose extension is the central bank), one policy signal (net ETH flow through that market), and
one authority (the `Exchequer` contract). Capital flowing in loosens policy, raises issuance, and
stacks hard reserves. Capital flowing out tightens policy, flips fee routing into buybacks, and
prices the exits.

## What is different from the whitepaper, and why

### One fungible `$BANK` instead of soulbound charters and branches

The whitepaper separates a soulbound charter NFT (the license to operate a bank) from branches (the
yield-accrual vehicles inside it, 1 to 10 per charter). This implementation collapses both into a
single fungible ERC-20, `$BANK`. One whole `$BANK` (`1e18`) is one branch.

This is a deliberate simplification, and it removes several whitepaper mechanisms as a direct
consequence:

| Whitepaper mechanism | Status here | Why |
| --- | --- | --- |
| Charter NFT, burned when the last branch retires | Removed | A `$BANK` balance reaching zero is the same event, with no NFT to burn. |
| Max 10 branches per charter | Removed | There is no charter to scope the cap to. The daily license supply cap is the real constraint on expansion. |
| Max 3 licenses per charter per day | Removed | A per-address cap over a freely transferable token is evaded with a second address, so enforcing it would be security theatre. §8's daily supply cap does the actual rationing. |
| §10 dormancy: report, bounty, revocation, shutdown | Removed | Dormancy exists because an idle charter siphons a fixed pro-rata share away from working bankers. With per-share accrual an idle holder earns exactly their share and dilutes no one differently from an active holder, so there is nothing to reclaim. |
| §12 transferable charters (future one-way switch) | Always on | `$BANK` is transferable from genesis. Selling `$BANK` is already "an exit with zero sell pressure on `$ISSUE`" — the buyer replaces the seller one for one, balance included. |

Everything else — the issuance stream, the net flow signal, the multiplier, both Dutch auctions, the
resolution fee, the fee split, the two vaults, protocol-owned liquidity — is implemented as
specified.

### Ekubo Core extension, not a Uniswap v4 hook

`Exchequer` is a `BaseExtension` + `BaseForwardee`. Its `beforeSwap` reverts, so every trade must
arrive through `Core.forward`, exactly as `Ve33` does. That is what lets the bank take its trading
fee in ETH on both buys and sells and measure net flow on the same pass.

The extension deliberately does *not* fire its own hooks when it is the locker (Ekubo skips a call
point when `locker == extension`). The bank itself never swaps — protocol-owned liquidity and
buybacks are both placed as standing bids — so the only thing this exempts is its own position
management, which pays no fee and registers no flow. That is correct: placing a bid is not capital
entering the economy.

One integration consequence: the stock `Router` only forwards to the addresses in its `MEV_CAPTURE`
and `VE33` slots and calls `Core.swap` directly for every other extension, which this pool rejects.
The bank's forward payload is identical to `Ve33`'s, so a `Router` deployed with the bank in its
`ve33` slot drives the pool unmodified; a production deployment wants either that dedicated router
or a router that knows the bank's address.

### Buybacks are standing bids, not market orders

§11 has the contraction vault "buy $ISSUE on the open market" in hourly rate-limited steps,
`spend_tick = min(0.10 * V, 0.002 * R)`, so that "defense cannot be baited into one blockable shot".
Any market buy the protocol makes on a schedule is a target for whoever can see it coming. Here the
bank *is* the market, so it does not need to buy on it: contraction ETH is placed as a single-sided
bid bucket just below the price, sellers who push `$ISSUE` down into it are bought out at the bid,
and a permissionless `defend()` withdraws whatever the bucket acquired, burns it, and re-bids the
rest from the current price. Defense executes exactly when there is sell pressure to absorb and
never at a price the bank did not set, so there is nothing to bait. The expansion vault, which
buys gold, keeps a TWAMM order — there is no canonical market for the reserve asset — and that
order's duration is its rate limit.

### A minimal owner, with a one-way exit

The whitepaper claims the bank "answers to no board" while also describing a "policy-controlled"
charters-per-day count and an "admin-set reserve price". Both cannot be true at once. `Exchequer`
resolves it with a solady `Ownable` holding exactly five knobs — charters per day, the charter
auction reserve price, the team fee recipient, the expansion vault's TWAMM order configuration,
and the one-time genesis `$BANK` mint — and an irreversible `renounceOwnership()`. The immutability
claim is reachable rather than false at launch.

Everything else, including every monetary parameter below, is immutable from construction.

## Parameters

The whitepaper redacts every numeric parameter (§5, §7, §9 and the §14 launch table render as blank
boxes) and says final values "will be announced closer to launch". Every one of them is therefore a
constructor argument. The values below are the defaults in `script/DeployExchequer.s.sol`; they are
consistent with the prose but are not authoritative.

Values stated in the whitepaper's own prose, and fixed in code:

| Parameter | Value | Source |
| --- | --- | --- |
| Hard cap | 1,000,000,000 `$ISSUE` | §3 |
| Genesis liquidity | 100,000,000 `$ISSUE`, full range, unwithdrawable | §3 |
| Issuance budget | 900,000,000 `$ISSUE` | §3 |
| Fee split | 70% active vault / 15% POL / 15% team | §11 |
| Resolution fee burn share | 50% burned, 50% to remaining holders | §9 |
| License payment | `$ISSUE`, 100% burned | §7 |
| License auction open | 2x previous close (2x floor if nothing sold) | §8 |
| Charter auction open | 3x previous close (3x floor if nothing sold) | §8 |
| Auction decay | exponential from open to floor over 24h | §7, eq 7.1 |
| Founding `$BANK` | 1,000 | §6 |

Configurable, with launch defaults:

| Parameter | Default | Note |
| --- | --- | --- |
| Base issuance | 1,000,000 `$ISSUE`/day at `m = 1` | §5 |
| Multiplier range | 0.25x to 4x | §5 |
| Multiplier at launch | 1x | §5 |
| Epoch length | 1 day | §4 |
| Rate cut per epoch | 0.25x | §5: cuts are immediate |
| Rate raise per epoch | 0.0625x | §5: raises must be earned (4x slower) |
| Trading fee | 0.30% | §11, always taken in ETH |
| License supply | 100/day | §7 |
| License floor | 2 days of one branch's yield | §8 |
| Charter supply | 0/day (owner-enabled) | §8 |
| Charter reserve price | 0.01 ETH | §8, owner-set |
| Resolution fee floor | 1% | §9 |
| Resolution fee ceiling | 30% | §9 |
| Exit pressure saturation | 25% of the bank in 7 days | §9 |
| Exit pressure denominator floor | 1,000,000 `$ISSUE` | §9, eq 9.1 |
| Minimum net flow | 1 ETH | an epoch counts as expansion only at or above this net inflow (§4: "denominated in real capital") |
| Reference window | 1 hour | a price must prevail this long to fully replace the bank's reference |
| Bid grid | 10 tick spacings (~1%) | bid buckets start on the first grid line above the market |
| Redistribution stream | 7 days | the stayers' half of each exit fee streams over the exit window |
| Vault order duration | 10 days | §11, expansion vault only |

`m` is stored as a `uint64` in `1e18` fixed point. `cutStep` is four times `raiseStep` by default,
which is what makes "the bank turns defensive faster than it turns generous" true in code: from the
4x ceiling to the 0.25x floor takes 15 epochs, while the reverse takes 60.

## Contracts

| Contract | Role |
| --- | --- |
| `IssueToken` | `$ISSUE`. ERC-20, 1B cumulative-mint cap. Only the bank mints. Anyone burns their own. |
| `BankToken` | `$BANK`. ERC-20 branch share. Settles both sides' accrued issuance on every transfer. |
| `Exchequer` | The extension. Issuance ledger, net flow, multiplier, fee routing, withdrawals, POL. |
| `ExchequerAuctions` | Both daily falling-price Dutch auctions (licenses in `$ISSUE`, charters in ETH). |
| `ExchequerVault` | The expansion vault: a `RevenueBuybacks` owned by the bank, so its gold can only land there. |

## Mechanics

### Issuance

`$ISSUE` is issued as a ledger entry, never as tokens, until a holder withdraws. `Exchequer`
keeps a `growthPerShareX128` accumulator in the style of `Ve33`'s `emissionGrowthGlobalX128`: each
`accrue()` advances `issuanceGrowthPerShareX128` by `(amount << 128) / bankSupply` and each holder's
claim is `balance * (growth - snapshot) >> 128` plus anything already settled.

`accrue()` is called by every swap, every `$BANK` transfer, mint or burn, and every withdrawal. It
is also public, so anyone can advance it. Nothing needs a keeper.

Issuance while `bankSupply == 0` is not issued at all — it is not owed to anyone, and crediting it
to the first holder would be a windfall.

### Epoch rollover

Rollover is evaluated lazily on the first touch after a boundary, so there is no keeper and no epoch
can be skipped. `accrue()` accrues in segments up to each boundary, rolls, and continues.

At each rollover, with `F` the net flow of the epoch that just ended:

- Fee routing uses the closed epoch alone — the fast lever. `F >= minNetFlow` sends the 70% share
  to the expansion vault; anything less funds buyback bids instead. Zero counts as contraction, per
  §5, and so does anything below the dead band: a pure sign test would let a one-wei buy make an
  epoch expansionary, and §4 says the signal is "denominated in real capital".
- The multiplier uses `signal = F + F_previous`, the two most recently completed epochs — the slow
  lever. `signal >= minNetFlow` raises `m` by `raiseStep` up to the ceiling; otherwise it cuts by
  `cutStep` down to the floor.

A long gap with no interaction means every intervening epoch had zero flow. The first two are rolled
individually, because their signal can still carry real flow from before the gap; the remainder are
closed-formed as an arithmetic series of cuts down to the floor, so catching up after months of
silence costs O(1) gas rather than O(epochs).

### Net flow and the trading fee

The fee is always taken in ETH, on both buys and sells, and is always taken so that the trader's
*specified* amount stays exact. All four swap shapes are handled:

| Swap | Fee handling |
| --- | --- |
| Exact-in ETH (a buy) | Fee deducted off the top; the pool swaps `amount - fee`. |
| Exact-out ETH (a sell) | Requested output grossed up; the pool swaps for `amountBeforeFee`. |
| Exact-in `$ISSUE` (a sell) | Fee taken from the ETH the pool pays out. |
| Exact-out `$ISSUE` (a buy) | Fee added to the ETH the pool requires. |

Net flow is measured on the trader-facing ETH delta, fee included, because that is the capital that
actually moved. Fee ETH accrues into a Core saved balance under the bank until it is routed.

### Withdrawing

`withdraw(bankAmount, recipient)` retires `bankAmount` of `$BANK` and liquidates exactly that
fraction of the caller's accrued ledger balance — §9's pro rata rule. Retiring all of it liquidates
everything and leaves the caller with no share of future issuance.

The rule only holds if the ledger cannot be separated from the shares, so it is not: a transfer
carries the shares' pro rata portion of the sender's settled balance with them (§12: "the seat
moves whole, branches and balance included"). Otherwise a holder could park all but one wei of
their shares elsewhere, retire that wei against the whole ledger, and take the shares back.

The resolution fee is congestion pricing on the exit door. With `W` the trailing 7 days of
system-wide withdrawals (a 7-bucket ring, one per day) and `D` the total ledger balance still at the
bank:

```
P   = W / max(D + W, denominatorFloor)
fee = feeFloor + (feeCeiling - feeFloor) * min(P / saturation, 1)^2
```

The rate locks at the moment of the call. Half the fee is minted and immediately burned, which is
what makes it a real burn under eq 3.2 rather than un-issuance. The other half is paid to everyone
who stayed — but *streamed* over `redistributionStreamLength` (the exit window) rather than
credited at once. `$BANK` is transferable, so an instant credit would be capturable by anyone who
bought shares in the block before a large exit and sold them in the block after; streaming makes
"stayed" a statement about time. If the last holder exits, there is nobody to pay, and that half
— along with anything still in flight from earlier exits — is burned too.

### Protocol-owned liquidity

`compound()` is permissionless. It draws the accumulated POL share out of the bank's saved balance
and places it as **single-sided ETH liquidity** in the range from the first grid tick above the
market up to the top of the pool. ETH is `token0`, and `token0` liquidity sits above the current
tick, where the pool sells it for `$ISSUE` as the price rises through it — which in this pool means
as `$ISSUE` cheapens. A bucket is therefore a standing bid for `$ISSUE` at every price below the
market: exactly the "floor of exit liquidity that no one can pull" the whitepaper describes, placed
directly rather than by swapping first.

No swap happens, so there is nothing to sandwich and no premium is ever paid. The bank buys
`$ISSUE` only when sellers come down to its bids, at prices it set. Buckets accumulate on a grid
(`10 × tickSpacing`, about 1%) and there is no code path in `Exchequer` that decreases the
liquidity of any position under the POL salt — the genesis range or any bucket. POL only grows.

The whitepaper's "half swapped, paired, added forever" would have put two-sided depth at the
current price immediately; this puts one-sided depth just below it and lets the market convert it.
That is the deliberate trade: two-sided depth at spot is what a sandwich needs, and the whitepaper's
own reason for POL — exit liquidity — is served better by bids.

#### The bank is its own oracle

There is still one thing a front-runner could try: pump `$ISSUE` in the same block, so the bank's
"just below the market" bucket lands above the real price, then sell into it. The bank defends
against this with something it already has — **every trade in this economy passes through it** —
so it keeps its own price reference. After every swap it folds the pool tick into a time-weighted
value:

```
reference += (lastObservedTick - reference) * min(elapsed, WINDOW) / WINDOW
```

A price pulls the reference toward itself in proportion to how long it prevailed; a price that
lasts a full `polReferenceWindow` replaces it outright; a price that exists only inside one block
has prevailed for zero seconds and moves nothing. Bid buckets start on the first grid line above
`max(spot, reference)`, so a same-block pump cannot pull a bid up to meet it — the bucket lands
above the *reference*, the pumper finds only the genesis range to sell into, and their round trip
paid two fees and price impact for nothing. A same-block dump only places the bids lower, which
costs the dumper and gives the bank a cheaper bid.

The residual exposure is the standard one for any time-weighted reference: hold the price up for
the whole window, exposed to arbitrage the entire time, so that the reference itself rises before
the next `compound()`. The prize is bounded by one tranche's ETH times the premium the bids then
carry above the true price; the cost is fees and impact on the volume needed to move a pool this
deep for an hour, and it grows with the POL position.

Alternatives considered and not taken: a reference-bounded market buy (leaks up to the bound to
arbitrageurs on every tranche, and the bank's own buy feeds back into its reference); routing the
POL share through a TWAMM order (works, but executes in a separate TWAMM pool and reaches the
canonical price by arbitrage); and a reverse Dutch auction where the bank's bid rises and sellers
step in (market-set, but a third auction's worth of surface for the same result as a standing bid).

### Buybacks

`defend()` is permissionless and does two things in one call. If a buyback bucket is standing and
the price has fallen into it, the bucket is withdrawn, every `$ISSUE` it bought is burned, and the
recovered ETH is re-bid from the current price. Then any newly routed contraction ETH is added to
that bid. There is only ever one active buyback bucket, so nothing needs enumerating.

The bucket sits on the same grid, above the same `max(spot, reference)` floor, for the same
reason. Buybacks therefore execute only into sell pressure, only at a price the bank set, and only
in the canonical market — no TWAMM sidecar pool, no arbitrage leg between that pool and this one,
and no schedule to front-run. Burned `$ISSUE` lowers the eq 3.2 ceiling permanently.

### The expansion vault

The expansion vault receives ETH from expansion epochs and sells it through a TWAMM order for the
reserve asset — a tokenized gold token, fixed at construction — which it collects to the
`Exchequer`. The bank holds the reserves.

"Can never sell" is structural rather than promised. `RevenueBuybacks.collect` is permissionless
and delivers to the vault's *owner*, and its owner also holds an arbitrary `call`. The vault is
therefore owned by `Exchequer` itself: whatever anyone collects lands at the bank, and the
arbitrary call is reachable by nobody, because the bank exposes no way to make it. The only thing
the bank's owner can do to the vault is `configureExpansionVault` — order duration and fee tier —
and once the owner renounces, even that is frozen.

A TWAMM order executes against a pool whose extension is TWAMM, so the vault trades an ETH/gold
TWAMM pool, and its execution quality is that pool's depth. That is an accepted dependency for the
gold leg, where there is no canonical market to defend in; it is exactly why the `$ISSUE` leg does
not use one.

## Threat model

Every vector considered, with what was done about it. "Accepted" means the mechanism is per the
whitepaper and the exposure is understood, not that it was overlooked.

| Vector | Mitigation | Residual |
| --- | --- | --- |
| Sandwich `compound()` — pump, let the bank buy, sell into it | The bank never swaps. Bids sit above `max(spot, reference)`; a same-block pump cannot move the reference | Hold the price up for the full window while exposed to arbitrage; prize bounded by one tranche × the premium |
| Bait `defend()` into buying high | Same bids, same floor; a bucket the price has not reached is left alone (`NothingToDefend`) | None found |
| Front-run the buyback TWAMM in a thin sidecar pool | No `$ISSUE` TWAMM exists; buybacks are bids in the canonical market | The gold leg still executes in a TWAMM pool: accepted |
| JIT-capture the stayers' half of an exit fee | Streamed over the exit window; a share held for one block collects nothing | A holder must stay the window; that is the intent |
| Divert vault proceeds via `collect()` to the owner, or the owner's `call` | The bank owns the vault; the bank has no passthrough for `call` | None |
| Brick `flush()` with a reverting team recipient | Team share is a separate pull | A bricked recipient forfeits only its own share |
| Buy the policy signal with dust | Dead band: an epoch is expansion only at or above `minNetFlow` net inflow, for both levers | Moving the signal costs at least `minNetFlow` of real capital per epoch, held, and unwinding it is a cut: accepted per §4 |
| Extract the ledger while keeping the shares (park shares, retire one wei against the whole balance) | The settled ledger travels with the shares on transfer, so a share is worth what it earned wherever it goes | None |
| Open the canonical pool ahead of genesis and brick `initialize()` | `beforeInitializePool` refuses everyone; Core never calls it for the bank's own genesis | None |
| Flip an epoch's regime with a last-second trade | Fee routing keys on the closed epoch's sign alone, as §4 specifies ("fast lever") | Accepted: the flipper pays a fee to redirect 70% of one epoch's revenue between two protocol-owned uses |
| Run first on the exit door | Fee locks at commitment and rises with trailing volume; half goes to stayers | Accepted: the whitepaper's own design; early exits pay less than late ones by construction |
| Grief the license open by timing the first sale | The day's open is pinned by its first sale to 2× yesterday's close or 2× floor | Floor moves with supply and rate inside the day; marginal |
| Drain a shared saved-balance pot (cf. Ekubo limit-orders incident) | The fee pot is keyed under the bank's own address with salt 0; nothing else writes it, and only the bank's lock can draw it | None |
| Stale views quoting yesterday's rate to the first caller of a quiet day | Every view projects through the same `_walk`/stream release `accrue()` uses | None |
| Rounding | Per-share credits round down, so a few wei of unclaimable dust remain on the ledger total | Harmless |

## Genesis

1. Deploy `Exchequer` at an address whose leading byte encodes its call points, which also deploys
   `$ISSUE` and `$BANK`.
2. Deploy the expansion vault and `ExchequerAuctions`; the owner wires them in once each.
3. The owner calls `initialize{value: seedEth}(tick)`, which initializes the pool, mints the
   100,000,000 `$ISSUE` genesis supply, and locks it with the seed ETH into the full-range POL
   position. This is the only pre-mint.
4. The owner calls `configureExpansionVault` once an ETH/gold TWAMM pool exists at the chosen fee.
5. The owner mints up to 1,000 `$BANK` for the founding distribution, pointing it at `Incentives`
   for a one-per-wallet merkle claim.
6. The owner renounces.
