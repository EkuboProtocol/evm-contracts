# Standard — a sovereign onchain central bank on Ekubo

An implementation of the [Standard whitepaper](https://www.standardreserve.xyz/whitepaper/) (v0.1)
built as an Ekubo Core extension rather than a Uniswap v4 hook.

Standard is a closed monetary economy with one currency (`$STANDARD`), one market (an ETH/`$STANDARD`
pool whose extension is the central bank), one policy signal (net ETH flow through that market), and
one authority (the `CentralBank` contract). Capital flowing in loosens policy, raises issuance, and
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
| §12 transferable charters (future one-way switch) | Always on | `$BANK` is transferable from genesis. Selling `$BANK` is already "an exit with zero sell pressure on `$STANDARD`" — the buyer replaces the seller one for one, balance included. |

Everything else — the issuance stream, the net flow signal, the multiplier, both Dutch auctions, the
resolution fee, the fee split, the two vaults, protocol-owned liquidity — is implemented as
specified.

### Ekubo Core extension, not a Uniswap v4 hook

`CentralBank` is a `BaseExtension` + `BaseForwardee`. Its `beforeSwap` reverts, so every trade must
arrive through `Core.forward`, exactly as `Ve33` does. That is what lets the bank take its trading
fee in ETH on both buys and sells and measure net flow on the same pass.

The extension deliberately does *not* fire its own hooks when it is the locker (Ekubo skips a call
point when `locker == extension`). Protocol-owned-liquidity buys therefore pay no fee and are not
counted as trader inflow, which is correct: POL compounding is not capital entering the economy.

### The hourly buyback tick is a TWAMM order

§11 rate-limits contraction-vault buybacks with an hourly `spend_tick = min(0.10 * V, 0.002 * R)` so
that "defense cannot be baited into one blockable shot". A TWAMM order already *is* that rate
limiter, executed continuously rather than hourly and with no keeper to bait. Both vaults are
`RevenueBuybacks` instances, so the spend rate is set by the order duration: a balance sold over a
`targetOrderDuration` of 10 days spends ~10%/day, matching the launch intent of §11 without the
hand-rolled tick.

### A minimal owner, with a one-way exit

The whitepaper claims the bank "answers to no board" while also describing a "policy-controlled"
charters-per-day count and an "admin-set reserve price". Both cannot be true at once. `CentralBank`
resolves it with a solady `Ownable` holding exactly four knobs — charters per day, the charter
auction reserve price, the team fee recipient, and the one-time genesis `$BANK` mint — and an
irreversible `renounceOwnership()`. The immutability claim is reachable rather than false at launch.

Everything else, including every monetary parameter below, is immutable from construction.

## Parameters

The whitepaper redacts every numeric parameter (§5, §7, §9 and the §14 launch table render as blank
boxes) and says final values "will be announced closer to launch". Every one of them is therefore a
constructor argument. The values below are the defaults in `script/DeployStandard.s.sol`; they are
consistent with the prose but are not authoritative.

Values stated in the whitepaper's own prose, and fixed in code:

| Parameter | Value | Source |
| --- | --- | --- |
| Hard cap | 1,000,000,000 `$STANDARD` | §3 |
| Genesis liquidity | 100,000,000 `$STANDARD`, full range, unwithdrawable | §3 |
| Issuance budget | 900,000,000 `$STANDARD` | §3 |
| Fee split | 70% active vault / 15% POL / 15% team | §11 |
| Resolution fee burn share | 50% burned, 50% to remaining holders | §9 |
| License payment | `$STANDARD`, 100% burned | §7 |
| License auction open | 2x previous close (2x floor if nothing sold) | §8 |
| Charter auction open | 3x previous close (3x floor if nothing sold) | §8 |
| Auction decay | exponential from open to floor over 24h | §7, eq 7.1 |
| Founding `$BANK` | 1,000 | §6 |

Configurable, with launch defaults:

| Parameter | Default | Note |
| --- | --- | --- |
| Base issuance | 1,000,000 `$STANDARD`/day at `m = 1` | §5 |
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
| Exit pressure denominator floor | 1,000,000 `$STANDARD` | §9, eq 9.1 |
| Vault order duration | 10 days | §11 |

`m` is stored as a `uint64` in `1e18` fixed point. `cutStep` is four times `raiseStep` by default,
which is what makes "the bank turns defensive faster than it turns generous" true in code: from the
4x ceiling to the 0.25x floor takes 15 epochs, while the reverse takes 60.

## Contracts

| Contract | Role |
| --- | --- |
| `StandardToken` | `$STANDARD`. ERC-20, 1B cumulative-mint cap. Only the bank mints. Anyone burns their own. |
| `BankToken` | `$BANK`. ERC-20 branch share. Settles both sides' accrued issuance on every transfer. |
| `CentralBank` | The extension. Issuance ledger, net flow, multiplier, fee routing, withdrawals, POL. |
| `StandardAuctions` | Both daily falling-price Dutch auctions (licenses in `$STANDARD`, charters in ETH). |
| `StandardVault` | A `RevenueBuybacks` whose proceeds are collected to a fixed recipient. Deployed twice. |

## Mechanics

### Issuance

`$STANDARD` is issued as a ledger entry, never as tokens, until a holder withdraws. `CentralBank`
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

- Fee routing uses `sign(F)` alone — the fast lever. `F > 0` sends the 70% share to the expansion
  vault; `F <= 0` sends it to the contraction vault. Zero counts as contraction, per §5.
- The multiplier uses `signal = F + F_previous`, the two most recently completed epochs — the slow
  lever. `signal > 0` raises `m` by `raiseStep` up to the ceiling; otherwise it cuts by `cutStep`
  down to the floor.

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
| Exact-in `$STANDARD` (a sell) | Fee taken from the ETH the pool pays out. |
| Exact-out `$STANDARD` (a buy) | Fee added to the ETH the pool requires. |

Net flow is measured on the trader-facing ETH delta, fee included, because that is the capital that
actually moved. Fee ETH accrues into a Core saved balance under the bank until it is routed.

### Withdrawing

`withdraw(bankAmount, recipient)` retires `bankAmount` of `$BANK` and liquidates exactly that
fraction of the caller's accrued ledger balance — §9's pro rata rule. Retiring all of it liquidates
everything and leaves the caller with no share of future issuance.

The resolution fee is congestion pricing on the exit door. With `W` the trailing 7 days of
system-wide withdrawals (a 7-bucket ring, one per day) and `D` the total ledger balance still at the
bank:

```
P   = W / max(D + W, denominatorFloor)
fee = feeFloor + (feeCeiling - feeFloor) * min(P / saturation, 1)^2
```

The rate locks at the moment of the call. Half the fee is minted and immediately burned, which is
what makes it a real burn under eq 3.2 rather than un-issuance; half is credited back to everyone
who stayed by advancing `growthPerShareX128` over the *post-burn* supply. If the last holder exits,
there is nobody to pay, and that half is burned too.

### Protocol-owned liquidity

`compound()` is permissionless. Inside one Core lock it draws the accumulated POL share out of the
bank's saved balance, swaps half of it to `$STANDARD` through the canonical pool (paying no fee and
registering no flow, because the bank is the locker), and adds both sides as full-range liquidity to
a position owned by the bank.

There is no code path anywhere in `CentralBank` that decreases that position's liquidity. POL only
grows.

### Vaults

Both vaults receive ETH and sell it through a TWAMM order.

- The **expansion vault** buys the reserve asset — a tokenized gold token, fixed at construction —
  and collects it to the `CentralBank`, which holds the reserves.
- The **contraction vault** buys `$STANDARD` and collects it to the `CentralBank`. Anyone may then
  call `burnReserves()` to burn every `$STANDARD` the bank holds. The vault can never sell.

One consequence of using TWAMM is worth stating plainly: a TWAMM order executes against a pool whose
extension is TWAMM, not against the canonical market, whose extension is the bank. Buybacks therefore
run through a separate ETH/`$STANDARD` TWAMM pool on the same pair and reach the canonical price
through arbitrage rather than directly. This is how Ekubo's own revenue buybacks work, and it is why
the buyback bid is structural rather than a mechanical push on the canonical pool. §11's claim that
the vault "buys $STANDARD on the open market and burns everything it buys" holds. Its claim that the
spend is bounded as a fraction of *canonical* pool depth does not translate, and is replaced by the
order duration.

## Genesis

1. Deploy `CentralBank` at an address whose leading byte encodes its call points, which also deploys
   `$STANDARD` and `$BANK`.
2. Deploy both vaults and `StandardAuctions`; the owner wires them in once each.
3. The owner calls `initialize{value: seedEth}(tick)`, which initializes the pool, mints the
   100,000,000 `$STANDARD` genesis supply, and locks it with the seed ETH into the full-range POL
   position. This is the only pre-mint.
4. The owner mints up to 1,000 `$BANK` for the founding distribution, pointing it at `Incentives`
   for a one-per-wallet merkle claim.
5. The owner renounces.
