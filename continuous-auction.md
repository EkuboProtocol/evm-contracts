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
  never truncated early, so cancelling a pending bid is always harmless and the
  pool never closes from it. The incumbent's relinquished tenure is credited
  when the new bid activates; a replaced pending bid is credited immediately
  since its tenure never started.
- A killed pending promise still binds same-start replacements: displacing
  another bidder's pending bid records its rate, and every bid for that start —
  including cancel-and-rebid by the displacer — must beat it until the second
  passes. Topping the killed promise by one wei suffices.
- `end - start` must be at least one second and at most `2**32 - 1` seconds, and
  `end` must fit in 48 bits. Rate zero removes the caller's schedule from the
  next second on.
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

### Periphery

`AuctionPeriphery(core, auction)` settles bids for accounts that are not
lockers. `updateBid(key, salt, rate, end, executor, fee, recipient)` forwards
under `keccak256(abi.encode(msg.sender, salt))`, pays a positive delta from the
caller (ERC20 allowance, or ETH sent with the call for a native bid token) and
withdraws a negative one to `recipient`. `collectSwapFees(key, salt, recipient)`
withdraws the caller's fees. Batch `refundNativeToken()` in a multicall to
recover excess ETH. `bidderId(owner, salt)` gives the identity the extension
uses.

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

## Deployment and reproducibility

Use `script/DeployContinuousAuction.s.sol` with explicit `CORE_ADDRESS`,
`BID_TOKEN`, `OWNER_ADDRESS`, and a bytes32 `SALT`. It deploys the extension,
`AuctionPositions`, and `AuctionPeriphery`.
`BID_TOKEN=0x0000000000000000000000000000000000000000` selects native rent. The
script uses the repository's canonical CREATE2 deployer and mines the required
extension address prefix (`0x51`). Optional `AUCTION_ADDRESS`,
`AUCTION_POSITIONS_ADDRESS`, and `AUCTION_PERIPHERY_ADDRESS` variables assert the
predicted addresses. Repeated
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
