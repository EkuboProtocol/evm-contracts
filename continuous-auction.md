# Continuous swap-access auction

`ContinuousAuction` is an auction-managed pool extension. Liquidity providers in
its pools earn a single asset, the extension's immutable `bidToken`, instead of
swap fees in the pool's tokens. A continuous first-price auction sells the right
to be the pool's fee-free swapper. The winner pays rent per second to the
providers whose liquidity is active. Everyone else may still swap while the pool
is rented, paying the pool's fee to the holder.

`bidToken == address(0)` selects the native token; other addresses select
standard, non-rebasing ERC20s. Incoming ERC20 funding is checked against the
received balance, so transfer-tax deposits are rejected. One deployment serves
one bid token; deploy again for another.

## Pools and terms

Pools must be created through the extension. Direct `Core.initializePool` calls
revert.

```solidity
createPool(PoolKey key, int32 tick, uint32 fee, uint96 minRate, uint32 noticePeriod, uint16 minIncrementBps)
```

- The key must name this extension and a zero Core fee. Concentrated pools need
  a power-of-four tick spacing; full-range and stableswap configurations are
  supported as well.
- `fee` is the initial fee charged to non-holder swaps, a 0.32 fixed-point
  fraction: the upper 32 bits of Core's fee format. The fee is pool state that
  each holder may change with `setFee`, without a cap.
- `minRate` is the reserve rent in bid-token base units per second. No bid
  below it is accepted.
- `noticePeriod` is the minimum funded tenure of a bid and the minimum remaining
  tenure after a holder shortens its bid. It is the holder's exit notice, the
  bond a short-lived bid must post, and the cost of challenging a holder that
  has moved the price away from the market (see Economics).
- `minIncrementBps` is the minimum rate increase, in basis points, that another
  bidder must offer over the scheduled bid.

Terms are immutable per pool. A key identifies one pool, so one set of terms.

## Bids

```solidity
bid(PoolKey key, uint96 rate, uint64 end, address executor)
extend(PoolKey key, uint64 end)
shorten(PoolKey key, uint64 end)
setFee(PoolKey key, uint32 fee)
withdrawRefund(address recipient)
```

- A bid covers `[timestamp + 1, end)` at `rate` base units per second and must
  be fully funded: `rate * (end - start)`. Native bids may overpay; the excess
  is credited to the bidder's refund balance, which tolerates inclusion delay.
  ERC20 bids pull the exact amount.
- `end - start` must be at least `noticePeriod` and at most `2**32 - 1` seconds.
- The bid must exceed the rate scheduled at its start by `minIncrementBps`. The
  scheduled bidder may raise its own rate by any amount. An expiring incumbent
  need not be outbid.
- The incumbent keeps the current second. The displaced part of its funding is
  credited as a refund; nothing is rescheduled later. A bid placed in the same
  second as another pending bid replaces it and refunds it entirely.
- `extend` adds funded tenure at the same rate. `shorten` relinquishes tenure
  and credits the refund, but the bid must keep at least `noticePeriod` seconds
  from now. That is the only voluntary exit; there is no rate reduction. Neither
  is available to a bidder whose bid has already been displaced.
- `setFee` sets the non-holder swap fee and is available to the scheduled
  bidder, pending or live. The fee persists in pool state across holders until
  changed, so a new holder should set it after bidding.
- `executor` is the authorized **Core locker contract**. It must authenticate
  its callers. Naming a permissionless router grants that router's users
  fee-free access.

The schedule is one live bid plus at most one pending bid placed this second.
Every operation is constant time.

## Swaps

The authorized locker calls `Core.forward(address(extension))` with trailing
`abi.encode(poolKey, swapParameters)`. Direct Core swaps revert.

- The holder's executor swaps with no fee.
- While the pool is rented, any other locker may forward a swap and pays the
  current fee to the holder: on the output for exact-input swaps, on the input
  for exact-output swaps. The returned `(PoolBalanceUpdate, PoolState)` already
  reflects the fee. Fees are saved in Core under the pool's salt and withdrawn by
  the bidder with `withdrawSwapFees(poolKey, recipient)`.
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
- Rent charged while no liquidity is active is recorded in
  `unallocatedRent(poolId)` and is neither refunded nor paid to later
  depositors. A holder can avoid that outcome by providing liquidity at the
  market price itself.
- Position changes checkpoint earned rent into an owed balance. Removing all
  liquidity does not discard it. `collectRent(poolKey, positionId, recipient)`
  pays the Core position owner; `getPositionRent` quotes already-accrued rent.
- Integer rounding favors solvency; dust remains in the extension. There is no
  administrator sweep of any balance.

## AuctionPositions

`AuctionPositions(core, auction, metadataOwner)` extends the standard `Positions`
manager with zero protocol fees and rent collection:

```solidity
collectRent(id, poolKey, tickLower, tickUpper, recipient)
```

The NFT owner and approved operators may collect; the four-argument overload
pays the caller. The metadata owner receives no right to other users' rent.
Pending rent travels with the NFT on transfer and remains claimable after full
withdrawal. Collect all balances before burning the NFT. The original minter can
recreate the same deterministic NFT ID and thereby regain control of any value
left under that ID after an authorized burn.

Use the inherited `mintAndDeposit`, `deposit`, and `withdraw` APIs for
principal. The manager can also manage ordinary pools, but its rent collector
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
  outbidding the holder by the increment, waiting one second, and moving the
  price back with its first swap; its cost is one notice period of rent, which
  goes to the providers the parker was starving, and the parker is left holding
  inventory bought above market. To make that challenge unprofitable the parker
  must keep `rate * noticePeriod * (1 + increment)` above the bounty, which it
  can only do by locking capital of about the bounty's size in a rolling bid.
  Providers can also withdraw while parked and keep the premium. And while
  parked the holder earns nothing else: no outsider swaps at a prohibitive fee,
  so there is no fee revenue, and no arbitrage flow reaches the pool, so the
  locked capital and the rent only buy exposure to providers who have no reason
  to stay. The notice period prices the defence: longer notice makes challenges
  dearer and control changes rarer, shorter notice makes parking indefensible.
- **A reserve rate** keeps a lone bidder from taking fee-free access for
  nothing. Below the reserve the pool is simply unrented, and unrented pools do
  not swap, so providers bear no arbitrage loss they are not paid for.
- **A minimum increment and a notice period** make control changes costly. A
  bid must beat the incumbent by the increment, and every bid posts at least a
  notice period of rent. Flipping control every block therefore ratchets the
  rate and burns the bond; refunds cover only displaced tenure.
- **Notice-period exit** replaces a hard commitment. A holder whose valuation
  falls shortens its bid and pays until the notice elapses, rather than pricing
  an unbounded lockup into every bid.

What the mechanism does not do: it does not guarantee retail flow, which
reaches the pool only through lockers that forward to the extension; it does not
pay providers whose liquidity is inactive, whatever the cause, so out-of-range
providers should withdraw rather than wait; and it does not compensate providers
while the pool is unrented. Bidders bear the exchange
risk between the bid token and the pool's tokens.

## Deployment and reproducibility

Use `script/DeployContinuousAuction.s.sol` with explicit `CORE_ADDRESS`,
`BID_TOKEN`, `OWNER_ADDRESS`, and a bytes32 `SALT`.
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
native address zero), and the chain must support transient storage. Create pools
with `createPool`, configure a caller-authenticated executor before bidding, and
note that the general Router does not route through this extension.
