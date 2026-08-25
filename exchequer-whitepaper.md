# Exchequer

**A sovereign onchain central bank, built as an Ekubo Core extension.**

Version 1.0 — August 2026

---

## Abstract

Exchequer is a closed monetary economy with one currency, one market, one policy signal and one
authority. The currency, `$ISSUE`, is minted only when a banker withdraws earnings and is burned
by every other path through the system. The market is a single ETH/`$ISSUE` pool on Ekubo Core
whose extension is the bank itself, so every trade pays the bank a fee in ETH and reports to it
the direction of capital. The policy signal is net ETH flow through that market: inflows loosen
policy, raise issuance and route fees into hard reserves; outflows tighten it, redirect fees into
buybacks, and price the exits. The authority is the `Exchequer` contract, which holds a handful of
launch-time knobs behind a single owner and can give them up irreversibly.

Bankers hold `$BANK`, a fungible share in which one whole unit is one branch. Each branch earns a
pro rata slice of every epoch's issuance, streamed second by second into a ledger; a banker takes
profit by retiring branches, which liquidates exactly their fraction of the ledger and permanently
reduces the banker's share of all future issue. A resolution fee, priced by how much of the bank is
already leaving, is charged on the way out: half is burned, half is paid, over time, to the bankers
who stayed.

The design derives from the Standard whitepaper (v0.1). This paper describes the implementation
actually built: what it keeps, what it changes, the arithmetic it uses, and the attacks it was
built to refuse. Its central departures are that the bank **never swaps** — protocol-owned
liquidity and buybacks are both placed as standing bids in the bank's own market, which leaves
nothing to sandwich or bait — and that charters and branches collapse into one transferable share,
which the ledger travels with.

---

## 1. The entities

| Entity | What it is |
| --- | --- |
| `$ISSUE` | The currency. An ERC-20 with a 1,000,000,000 cumulative-mint cap. Minted at genesis and at withdrawals, by the bank alone. Burned by licenses, by buybacks, and by half of every resolution fee. |
| `$BANK` | The share. An ERC-20 in which one whole unit (`1e18`) is one branch. Every branch earns an equal slice of issuance. Transferable from genesis; a transfer carries the shares' earned balance with it. |
| The market | One Ekubo Core pool, ETH against `$ISSUE`, with no pool fee of its own. The bank is its extension: no other pool may adopt the bank, and no swap may bypass it. |
| The bank | `Exchequer`. Takes the trading fee, measures net flow, sets the issuance rate, keeps the ledger, prices exits, routes revenue, and places every protocol-owned bid. |
| The expansion vault | `ExchequerVault`, a bank-owned `RevenueBuybacks` that sells expansion-epoch ETH for a hard reserve asset through a TWAMM order and delivers it to the bank. |
| The auctions | `ExchequerAuctions`: two daily falling-price Dutch auctions. Expansion licenses, paid in `$ISSUE` and burned; charters, paid in ETH into the fee engine. Both open branches. |

The flows between them:

- **Traders ⇄ market.** Anyone may buy or sell `$ISSUE`. Every trade pays the bank a fee in ETH.
- **Market → bank.** The bank reads, on every trade, how much ETH entered or left the pool. This is
  its only policy input.
- **Bank → branches.** Each second, the bank issues `$ISSUE` to every branch pro rata, as a ledger
  entry.
- **Bankers → bank.** Bankers spend `$ISSUE` on expansion licenses to open more branches. Every
  token spent this way is burned.
- **Bankers → market.** To realize earnings, a banker retires branches; the released balance is
  minted to their wallet, less the resolution fee, and sells — if it sells — into the market.
- **New bankers → bank.** Charters are sold for ETH at a daily auction. That ETH joins the fee
  engine like every other ETH flow.

Every path through the economy either burns `$ISSUE` or brings the bank ETH that becomes reserves,
liquidity, or a standing bid for `$ISSUE`.

---

## 2. The currency

| | |
| --- | --- |
| Hard cap | 1,000,000,000 `$ISSUE`, 18 decimals, enforced as a *cumulative* mint cap: burned supply does not free headroom |
| Genesis | 100,000,000 `$ISSUE`, locked with seed ETH into a full-range position the bank owns and can never withdraw |
| Issuance budget | 900,000,000 `$ISSUE`, the cap less genesis. When cumulative base issuance reaches it, base issuance stops forever |

`$ISSUE` is minted on demand. Issuance credits a banker's ledger; tokens exist only when a banker
withdraws. Supply therefore obeys one identity at every block:

```
totalSupply = totalMinted − totalBurned
totalMinted ≤ 1,000,000,000
```

and because burns are permanent, the largest supply that can ever exist only falls:

```
maxSupply = 1,000,000,000 − totalBurned
```

Genesis is one shot. The bank refuses to run it unless the chosen tick and the seed ETH absorb
the entire genesis supply (to within one part in a million of rounding dust): a genesis that
silently burned most of the supply would be unrecoverable. Any seed ETH the position could not
absorb is held for protocol-owned liquidity rather than returned.

---

## 3. The market and the fee

There is exactly one place ETH enters or leaves this economy: the canonical pool. Two hooks make
that true. `beforeInitializePool` refuses every caller — Core does not invoke it for the bank's
own genesis, so any call that arrives is someone else opening a second pool, or the canonical
pool ahead of genesis. `beforeSwap` refuses every caller too, which forces every trade to arrive
through `Core.forward`, where the bank executes the swap itself.

Executing the swap is what lets the bank take its fee in ETH on both sides while keeping the
trader's specified amount exact:

| Swap | Fee handling |
| --- | --- |
| Exact-in ETH (a buy) | Fee taken off the top; the pool receives `amount − fee`. |
| Exact-out ETH (a sell) | The request is grossed up; the pool releases `amountBeforeFee(amount)`. |
| Exact-in `$ISSUE` (a sell) | Fee taken from the ETH the pool pays out. |
| Exact-out `$ISSUE` (a buy) | Fee added to the ETH the pool requires. |

A swap stopped by its price limit pays a fee only on what actually traded. Fee ETH accrues in a
Core saved balance keyed to the bank until it is routed.

Net flow is measured on the **pool-facing** ETH delta, before the fee. Booking the fee as inflow
would let a round trip register its own two fees as capital entering — the cheapest possible way
to buy an expansion epoch. Measured this way, a round trip leaves behind only its price impact.

The bank's own position management — placing a bid, withdrawing a filled buyback bucket — runs
inside its own lock, where Core skips the hooks. It pays no fee and registers no flow, which is
correct: a bid is not capital entering the economy.

---

## 4. The net flow signal

The bank keeps, for the epoch in progress, gross ETH into the pool from buys and gross ETH out of
it from sells. Net flow for epoch `n` is the difference, and the two policy levers read it at
different speeds:

```
F_n      = ethIn_n − ethOut_n
signal_n = F_n + F_{n−1}
```

- **Fee routing** keys on `F_n` alone — the fast lever, so defense reacts within one epoch.
- **Issuance** keys on `signal_n`, the two most recently completed epochs — the slow lever, so one
  manipulated day cannot swing the rate.

An epoch counts as expansion only if its flow is at least `minNetFlow`, a launch parameter. A
pure sign test would make a one-wei buy expansionary; the dead band makes moving the signal cost
real capital, held in the pool, for at least an epoch. Zero flow, and anything below the band, is
a contraction.

---

## 5. Monetary policy

Issuance runs at a base rate of `baseIssuancePerDay` scaled by a multiplier `m`:

```
I_n = baseIssuancePerDay × d × m_n        (d = epoch length in days)
```

split pro rata across branches and streamed second by second. A branch earns from the moment it
opens. The multiplier follows one rule at each epoch boundary:

```
m_{n+1} = min(m_n + raiseStep, m_max)   if signal_n ≥ minNetFlow
        = max(m_n − cutStep,   m_min)   otherwise
```

The asymmetry is deliberate. At the launch values — a range of 0.25× to 4×, a raise of 0.0625 and
a cut of 0.25 — the bank climbs from floor to ceiling in sixty expansion epochs and falls from
ceiling to floor in fifteen contraction epochs. It turns defensive faster than it turns generous.

Rollover is lazy. There is no keeper: the first interaction after a boundary settles it, and the
first interaction after a long silence settles every boundary crossed. The first two silent epochs
still carry pre-gap flow in their signal and are rolled individually; every later silent epoch has
a zero signal and is cut, so the remainder is settled in closed form as an arithmetic series of
cuts. Catching up after months of silence costs the same gas as catching up after a day.

Each epoch is one of two regimes:

| | Expansion (`F ≥ minNetFlow`) | Contraction (otherwise) |
| --- | --- | --- |
| Issuance | raised, if the trailing signal agrees | cut immediately |
| Fee routing | 70% to the expansion vault: hard reserves | 70% to buyback bids |
| Licenses | cost more, since the floor scales with the rate | cost less |
| Exits | cheap | floor-priced by the crowd, up to the ceiling |

---

## 6. Branches and the ledger

A branch is one whole `$BANK`. The whitepaper this design derives from wraps branches in a
soulbound charter NFT; Exchequer does not. A `$BANK` balance is a bank, every whole unit of it is a
branch, and the share is transferable from genesis. Several of the source design's mechanisms
disappear as a direct consequence, and one appears:

| Source mechanism | Here | Why |
| --- | --- | --- |
| Charter NFT, burned when its last branch retires | Removed | A balance reaching zero is the same event. |
| At most 10 branches per charter, 3 licenses per charter per day | Removed | A per-address cap over a transferable share is evaded with a second address. The daily supply cap does the real rationing. |
| Dormancy: reporting, bounty, revocation | Removed | Dormancy reclaims a fixed share from an idle charter. With per-share accrual an idle holder earns exactly their share and dilutes nobody differently from an active one. |
| Transferable charters as a later, one-way switch | Always on | Selling `$BANK` is already an exit with zero sell pressure on `$ISSUE`: the buyer replaces the seller one for one. |
| — | **The ledger travels with the shares** | See below. |

### 6.1 Accrual

The bank keeps a global accumulator, `issuanceGrowthPerShareX128`, the cumulative `$ISSUE` ever
credited per whole share, and for each holder a settled ledger balance and a snapshot of the
accumulator at their last settlement. A holder's claim is

```
claim = ledger + balance × (growth − snapshot) / 2^128
```

Every swap, every `$BANK` mint, burn or transfer, and every withdrawal first advances the
accumulator to the current block and settles the parties involved. Nothing is issued while no
shares exist: it is owed to nobody, and crediting it to the first holder would be a windfall.

### 6.2 The ledger travels with the shares

A transfer of `amount` from a balance of `balance` moves `ledger × amount / balance` of the
sender's settled ledger to the recipient. This is what the source design's "the seat moves whole,
branches and balance included" means when the seat is fungible, and it is not optional. Without
it a holder could park all but one wei of their shares elsewhere, retire that wei against the
whole ledger, and take the shares back — value extracted, vehicle kept. With it the ledger per
share is invariant under transfer, so retiring a share liquidates exactly one share's worth and
no more, however the shares are shuffled.

### 6.3 Withdrawing

`withdraw(bankAmount)` retires `bankAmount` of `$BANK` and liquidates exactly that fraction of the
caller's ledger:

```
released = ledger × bankAmount / balance
```

Retiring one branch of ten liquidates one tenth of the balance. Retiring all of them liquidates
everything and leaves the caller with no share of future issue. The released amount is minted to
the caller's wallet, less the resolution fee.

---

## 7. The resolution fee

The exit door is congestion priced. Let `W` be system-wide withdrawals over the trailing seven
days (a ring of seven daily buckets), `D` everything still held at the bank as a ledger entry,
and `x` the exit being priced. Exit pressure and the fee it commands are

```
P   = (W + x) / max(D + W, denominatorFloor)
fee = floor + (ceiling − floor) × min(P / saturation, 1)²
```

At the launch values the fee runs from 1% to 30%, quadratic in pressure, and saturates once a
quarter of the bank tries to leave inside a week.

Two properties matter. **The exit's own size is in its price.** An exit large enough to be a run
on its own is priced as one, so lumping a position out in a single call is never cheaper than
splitting it. **The rate locks at commitment.** The fee an exit pays is the fee computed at the
moment of the call; later exits see the pressure it added.

Half of every fee is minted and immediately burned — a real burn under the supply identity, not
un-issuance. The other half is paid to every banker who stays, **streamed** over the exit window
rather than credited at once. `$BANK` is transferable, so an instant credit would be capturable by
anyone who bought shares in the block before a large exit and sold them in the block after;
streaming makes "stayed" a statement about time. Each new deposit joins the stream with an
amount-weighted end time, so a dust exit cannot stretch a stream already in flight and no stream
is ever brought forward. If the last holder exits, there is nobody to pay, and that half — along
with anything still in flight — is burned too.

Withdrawals are never paused or queued at any fee level. The cost of leaving is the only control.

---

## 8. The auctions

Both sales run on one mechanism: a daily falling-price Dutch auction. The price opens high, decays
exponentially toward a floor over 24 hours, and purchases execute instantly at the current price,
first come first served. There are no bids, no escrow, no refunds and nothing to snipe.

```
P(t) = P_start × (P_floor / P_start)^(t / 24h)
```

A day's open is pinned by its first sale, so later sales in the same day decay from the same
open. If yesterday sold anything, today opens at a multiple of yesterday's last — and therefore
lowest — sale; if it sold nothing, at that multiple of the floor. Unsold supply does not roll
over.

| | Expansion licenses | Charters |
| --- | --- | --- |
| Paid in | `$ISSUE`, 100% burned | ETH, into the fee engine |
| Supply | 100 per day | 0 at launch; policy may offer up to 100 per day |
| Open | 2× yesterday's close | 3× yesterday's close |
| Floor | two days of one branch's yield, never below one `$ISSUE` | an owner-set reserve, which must be nonzero while any supply is offered |
| Mints | one branch per license | one branch per charter, in the same transaction |

Charters open higher than licenses because scarce seats should reprice into demand faster than a
daily commodity. The license floor scales with the issuance rate, so expansion is cheapest in a
contraction and dearest in a boom — and it falls to its minimum once the issuance budget is spent,
so no license is ever priced off yield that no longer exists.

Charter policy — supply per day and the reserve — belongs to whoever owns the bank. The auctions
have no owner of their own, so renouncing the bank freezes them as well.

---

## 9. The fee engine

All protocol ETH — trading fees and charter proceeds alike — is routed at each epoch boundary:

| Share | Destination |
| --- | --- |
| 70% | the active vault for the closed epoch: the expansion vault in expansion, buyback bids in contraction |
| 15% | protocol-owned liquidity |
| 15% | the team |

Delivery is permissionless. `flush()` sends the expansion share to the vault and attempts the
team's; a team recipient that refuses ETH is simply left pending, and can never hold up the vault.
`compound()` places the POL share. `defend()` places the contraction share.

### 9.1 The expansion vault

The expansion vault sells its ETH through a TWAMM order for a hard reserve asset — a tokenized gold
token, fixed at construction — and delivers what it buys to the bank. The bank holds the reserves.
The order's duration is the spend rate; at launch a balance is sold over ten days.

The vault is owned by the bank. In Ekubo's `RevenueBuybacks`, collection is permissionless and
pays the owner, and the owner holds an arbitrary call; with the bank as owner, everything the
vault buys can only land at the bank, and the arbitrary call is reachable by nobody. The bank's
own owner can configure the order duration and fee tier, and nothing else. Genesis refuses a vault
the bank does not own or that buys anything but the reserve asset.

There is no canonical market for the reserve asset, so this is the one place the economy trades
through a TWAMM pool, and its execution quality is that pool's depth. That dependency is accepted
for the gold leg; it is exactly why the `$ISSUE` leg does not use one.

### 9.2 The bank never swaps

Every place the source design has the protocol buy `$ISSUE` on the open market — half the POL
share, and every buyback — is a target for whoever can see it coming. A permissionless market buy
at spot invites the obvious sandwich; a scheduled one invites front-running; a rate-limited one
can be baited. Exchequer removes the target: the bank *is* the market, so it does not buy on it.

ETH is placed as **single-sided liquidity** in the canonical pool. ETH is `token0`, and `token0`
liquidity sits above the current tick, where the pool sells it for `$ISSUE` as the price rises
through it — which in this pool means as `$ISSUE` cheapens. A range from just above the market to
the top of the pool is therefore a standing bid for `$ISSUE` at every price below the market: the
"floor of exit liquidity" the source design wanted, placed directly. No swap happens. The bank pays
no premium. It buys only when sellers come down to its bids, at prices it set.

**Protocol-owned liquidity** goes in under one salt, in buckets on a grid ten tick spacings wide
(about 1%), each with no withdrawal path. POL only grows. When sellers push the price through a
bucket it converts to `$ISSUE`, and from then on it is two-sided liquidity the protocol owns.

**Buybacks** go in under a second salt as one active bucket. `defend()` does two things in one
call: if a bucket is standing and the price has fallen into it, the bucket is withdrawn, every
`$ISSUE` it bought is burned, and the recovered ETH is re-bid from the current price; then any
newly routed contraction ETH is added. Defense executes only into sell pressure, only at the
bank's own price, only in the canonical market, and only when there is something to do — a bucket
the price has not reached is left alone. There is no schedule to front-run and no market order to
bait.

### 9.3 The bank is its own oracle

One thing a front-runner could still try: pump `$ISSUE` in the same block, so that "just above the
market" lands above the real price, then sell into the bank's bid. The bank defends with something
it already has — every trade passes through it — so it keeps its own price reference. After each
swap it folds the pool tick into a time-weighted value:

```
reference ← reference + (lastObservedTick − reference) × min(elapsed, window) / window
```

A price pulls the reference toward itself in proportion to how long it prevailed; one that lasts a
full window (one hour at launch) replaces it outright; one that exists only inside a block has
prevailed for zero seconds and moves nothing. Bid buckets start on the first grid line above
`max(spot, reference)`. A same-block pump cannot pull a bid up to meet it: the bucket lands above
the reference, the pumper finds only the genesis range to sell into, and the round trip paid two
fees and price impact for nothing. A same-block dump only places the bids lower, at the dumper's
expense.

The residual exposure is the standard one for any time-weighted reference: hold the price up for
the whole window, exposed to arbitrage the entire time, so that the reference itself rises before
the next placement. The prize is bounded by one tranche's ETH times the premium the bids then
carry; the cost is fees and impact on the volume needed to move a pool this deep for an hour, and
it grows with the position.

---

## 10. Authority

The source design claims the bank "answers to no board" while also describing an admin-set
reserve price and a policy-controlled charter count. Exchequer resolves that with one owner and
one irreversible exit. The owner holds exactly these knobs:

| Knob | Scope |
| --- | --- |
| `initialize(tick, vault, auctions)` | genesis and wiring, once |
| `setCharterPolicy(perDay, reserve)` on the auctions | capped per day, reserve nonzero while open |
| `setTeamRecipient` | where the 15% goes |
| `configureExpansionVault` | the vault's order duration and fee tier |
| `mintFoundingBank` | the free founding distribution, up to 1,000 `$BANK`, normally pointed at a merkle claim |

and `renounceOwnership()`. Every monetary parameter is immutable from construction. The auctions
read the bank's owner rather than keeping their own, so there is one authority, and when it
renounces, nothing in the economy answers to anyone.

---

## 11. Architecture

Exchequer is built as the rest of Ekubo's extensions are built.

**No getters.** `Exchequer` and `ExchequerAuctions` expose no view functions. Both inherit
`ExposedStorage`, and `ExchequerStorageLayout` and `ExchequerAuctionsStorageLayout` define every
slot — related words packed, per-holder state under a hashed offset, the trailing withdrawal ring
in seven consecutive slots. Hot-path parameters are immutables, mirrored once into storage so a
reader with only `sload` can recover them.

**One implementation of the arithmetic.** `ExchequerMath` is pure and holds every formula in this
paper once: the epoch walk and its closed-form decay, base issuance against the budget, the
stream release and its weighted end, the fee curve, the reference fold, bid placement on the
grid, the Dutch price and the auction open. The bank settles with it; `ExchequerLib` and
`ExchequerAuctionsLib` project with it from exposed storage. A read can therefore never disagree
with a settlement, and the first caller of a quiet day is never quoted yesterday's rate.

**External views for those who need them.** `ExchequerDataFetcher` wraps the libraries for
off-chain readers and tests.

**The minimum set of transitions.** The bank's external surface is `accrue`, `settleTransfer`,
`withdraw`, `compound`, `defend`, `flush`, `openBranches` (the auctions' one entry point), the
owner's knobs, ownership, the two hooks, and `sload`/`tload`.

**The tokens are bound.** The bank and its tokens each need the other's address, so the tokens are
deployed first, unbound, and bound to the bank once by the deployer; genesis refuses to run until
both tokens answer to the bank and no other. This also keeps the tokens' creation code out of the
bank, whose runtime is 19,405 bytes against the 24,576-byte EIP-170 limit.

**Router integration.** The bank's forward payload is identical to `Ve33`'s, so a stock `Router`
deployed with the bank in its ve33 slot drives the pool unmodified.

---

## 12. Threat model

Every vector considered, what was done, and what is accepted. "Accepted" means the mechanism is
faithful to the source design and the exposure is understood.

| Vector | Mitigation | Residual |
| --- | --- | --- |
| Sandwich a protocol buy | The bank never swaps; bids sit above `max(spot, reference)`, which a same-block pump cannot move | Hold the price up for a full window under arbitrage; prize bounded by one tranche × the premium |
| Bait buybacks | Same bids; an unfilled bucket is left alone | None found |
| Arbitrage a thin buyback TWAMM pool | No `$ISSUE` TWAMM exists; buybacks are bids in the canonical market | The gold leg still executes through a TWAMM pool: accepted |
| Extract the ledger while keeping the shares | The ledger travels with the shares | None |
| JIT-capture the stayers' half of an exit fee | Streamed over the exit window | A holder must stay the window; that is the intent |
| Stretch the stream with dust exits | Amount-weighted end; no stream is brought forward | A large exit legitimately re-times the pool it joins |
| Lump a position out at the floor | The exit's own size is in its price | None |
| Buy the policy signal with dust, or with a round trip's own fees | Dead band on net flow; flow is the pool-facing delta | Moving the signal costs `minNetFlow` of capital, held: accepted |
| Flip an epoch's regime with a last-second trade | Routing keys on the closed epoch alone, as designed | Accepted: the flipper pays a fee to redirect one epoch's revenue between two protocol-owned uses |
| Run first on the exit door | Fee locks at commitment and rises with trailing volume | Accepted: the source design's own choice |
| Mint `$BANK` for nothing via a zero-reserve charter auction, or a second owner surviving the bank's renounce | Policy belongs to the bank's owner; open auctions need a real reserve; supply is capped | The owner may sell up to the cap at a real reserve: that is the design |
| Divert vault proceeds | The bank owns the vault; it exposes no passthrough for the vault's arbitrary call | None |
| Brick delivery with a reverting team recipient | The team's share is delivered on a best-effort basis and left pending on refusal | A refusing recipient forfeits only its own share until it can receive |
| Open the canonical pool ahead of genesis, or a second pool | `beforeInitializePool` refuses everyone | None |
| Burn the genesis supply with a seed the tick cannot pair | Genesis refuses unless the whole supply is absorbed | The owner seeds enough ETH, and may retry |
| Wire a foreign vault, the wrong asset, or another bank's auctions | Genesis verifies ownership, `BUY_TOKEN`, and the auctions' bank and currency | None |
| Drain a shared saved-balance pot | The fee pot is keyed under the bank's own address; only the bank's lock draws it | None |
| Stale views | Every read projects through the same arithmetic the bank settles with | None |

---

## 13. Launch parameters

The source design redacts every numeric parameter and defers them to launch. Here every one is a
constructor argument. The values below are the documented defaults, consistent with the design's
prose but not authoritative.

| Parameter | Default |
| --- | --- |
| Base issuance | 1,000,000 `$ISSUE` per day at `m = 1` |
| Multiplier range, launch, steps | 0.25× – 4×; 1×; raise 0.0625, cut 0.25 |
| Epoch length | 1 day |
| Minimum net flow | 1 ETH |
| Trading fee | 0.30%, always in ETH |
| Tick spacing | 1,000; bid grid 10,000 ticks (~1%) |
| Resolution fee | 1% floor, 30% ceiling, saturating at 25% of the bank in 7 days; denominator floor 1,000,000 `$ISSUE` |
| Redistribution stream | 7 days |
| Reference window | 1 hour |
| Licenses | 100 per day; floor two days of one branch's yield, never below 1 `$ISSUE` |
| Charters | 0 per day at launch; at most 100 per day |
| Founding `$BANK` | up to 1,000 |
| Fee split | 70% active vault, 15% POL, 15% team |
| Vault order duration | set post-genesis, once an ETH/reserve-asset TWAMM pool exists |

---

## 14. Genesis

1. Deploy `$ISSUE` and `$BANK`, unbound. Deploy the bank at an address whose leading byte encodes
   its call points, with the launch parameters and the eventual owner. Bind both tokens to it.
2. Deploy the expansion vault, owned by the bank, and the auctions, for the bank and its currency.
3. The owner calls `initialize{value: seed}(tick, vault, auctions)`: the wiring is verified, the
   pool is opened, the genesis supply is minted and locked. This is the only pre-mint and the only
   wiring.
4. The owner configures the expansion vault once a reserve-asset TWAMM pool exists, and mints the
   founding distribution.
5. The owner renounces.

---

## 15. Open questions

Things the source design leaves unspecified, that this implementation does not decide for it.

- **Reserves have no outlet.** The gold lands at the bank and nothing can move it out — the bank
  has no arbitrary call, and its owner can renounce. That is the faithful reading and the safe one,
  but a balance sheet nobody can draw on is decorative. If reserves are meant to back a redemption
  floor, a crisis backstop, or a dividend, that is a mechanism to be designed, not a parameter to
  be set.
- **The dead band is a fixed parameter.** One ETH suits a pool a hundred ETH deep and is wrong for
  one a thousand times deeper. A dead band scaled to depth or to gross volume would track the
  economy; it would also be one more thing a trader can move.

---

## 16. Disclaimer

Exchequer is experimental onchain software. It is not a bank, holds no customer funds, offers no
accounts, and is not a regulated financial institution of any kind. Nothing in this document is
investment advice. Participate at your own risk.
