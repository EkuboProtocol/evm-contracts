# Ve33 User Guide

This guide explains how the Ve33 pool system works for stakers, liquidity providers, swappers, reward funders, and integrators.

Ve33 pools are Ekubo Core pools with a custom extension. The Core pool fee is set to zero, and Ve33 accounts its own swap fee outside Core. Swap fees go to ve stakers. Liquidity providers do not earn swap fees; they earn the immutable Ve33 stake token as LP rewards.

## Contracts

- `Ve33`: the pool extension. It stores votes, pool fees, LP reward accounting, emissions, and canonical stake balances. It does not transfer ERC20 tokens directly.
- `VeToken`: an optional ERC721 wrapper for Ve33 stakes. Each NFT controls one Ve33 stake and can be transferred or approved like a normal NFT.
- `Ve33Periphery`: the token-settling helper for swaps, LP position updates, LP reward claims, reward donations, reward schedules, and emissions.
- `Ve33Lib`: read helpers for Ve33 storage exposed through `ExposedStorage`.

## Pool Rules

Ve33 pools must be initialized with `poolKey.config.fee() == 0`. Direct Core swaps revert. Swaps must go through a router or periphery that forwards `VE33_SWAP` to the extension.

The active swap fee is stored in Ve33 pool state. If nobody has active votes on a pool, the pool uses its default fee. Concentrated pool defaults are derived from `2 * tickSpacing`; stableswap defaults are derived from amplification. Voters can choose explicit fees, capped at 50%.

## Stakers

Stakers lock the stake token for up to `4 years`. Voting power is linear:

```text
stake amount * (unlock time - now) / 4 years
```

Using `VeToken`, the common flow is:

1. Approve the stake token to `VeToken`.
2. Call `createStake(amount, end)` to mint a ve NFT.
3. Vote with `vote(veId, poolKeys, weights, swapFees)` or `voteWithDefaultFees(veId, poolKeys, weights)`.
4. Claim voter swap fees with `claimPoolFees(veId, poolKey)`.
5. Extend by calling `extendStake(veId, newEnd)`, or add amount with `increaseStakeAmount(veId, amount)`.
6. After expiry, call `withdrawStake(veId)` to burn the NFT and withdraw the stake token to the current NFT owner.

Important details:

- The ve NFT owner, or an approved NFT operator, can manage the stake.
- Claimed pool fees and withdrawn stake tokens go to the current NFT owner.
- Increasing, extending, or withdrawing a stake clears that stake's votes.
- Voting power is sampled when voting or when the stake is poked. Stored pool votes do not decay continuously.
- Anyone can call `VeToken.poke(veId)` or `Ve33.poke(stakeKey)` to refresh stale vote weights to current voting power or clear expired votes.
- Claiming pool fees does not automatically poke. This avoids extra gas when a staker plans to extend or restake immediately after claiming.

## Voting And Fees

Each vote assigns relative weights across pools and a selected swap fee per pool. Ve33 converts the relative weights into the stake's current voting power and stores active pool weights.

For each pool:

```text
active swap fee = sum(active vote weight * selected fee) / total active vote weight
```

If active vote weight is zero, the pool uses its default fee. Because the active fee comes from current stored votes, pool fees can change whenever votes are updated, stakes are changed, or stale votes are poked.

Voter fees are distributed only to active voters on the pool at the time fees are accounted. If a pool is using its default fee with no active vote weight, the swap fee is still saved under the pool but is not assigned to any voter.

## Liquidity Providers

LPs provide liquidity through `Ve33Periphery.updatePosition`. The production periphery derives a Core `PositionId` from:

```text
owner = msg.sender
salt = user-selected bytes24 salt
tickLower
tickUpper
```

This means two LPs can use the same salt and tick range without sharing a Core position. Withdrawals and LP reward claims are scoped to the caller's namespaced position.

LPs should remember:

- Ve33 LPs do not earn Core swap fees.
- LPs earn the stake token from donations, scheduled pool rewards, and triggered emissions.
- Rewards are range-aware. Out-of-range concentrated positions do not earn while out of range.
- Stableswap positions only earn while the pool price is inside the stableswap active-liquidity range.
- `claimRewards(poolKey, salt, tickLower, tickUpper, recipient)` claims the caller's accrued reward tokens.
- Before liquidity changes, Ve33 snapshots earned rewards. If a position fully exits, any unclaimed reward dust left in the snapshot is discarded.
- If rewards are donated or accrue while eligible liquidity is zero, those rewards are not assigned to LP positions.

## Swappers And Routers

Swappers should use a router or periphery that forwards swaps to Ve33. `Ve33Periphery.swap(poolKey, params, recipient)` is the reference flow.

Routers must set the intended `sqrtRatioLimit` before forwarding. Ve33 does not apply default sqrt-ratio limits internally.

For exact-input swaps, Ve33 removes the maximum voter fee up front, executes the Core swap with the net input, then charges the fee from actual executed input. If the swap only partially executes, the charged fee is capped to the amount removed up front.

For exact-output swaps, Ve33 lets Core compute the required input, grosses that input up by the active Ve33 fee, and accounts the extra input as voter fees.

## Reward Funders

Anyone can add LP rewards through the periphery:

- `donateRewards(poolKey, amount)`: immediately credits current eligible liquidity.
- `addRewards(poolKey, startTime, endTime, rewardRate)`: schedules a fixed Q32 reward rate for a pool.
- `fundEmissions(amount)`: funds global emissions for one week.
- `triggerPoolEmissions(poolKey)`: assigns a pool's share of funded emissions based on time-weighted votes and schedules that pool's LP rewards.

Funding emissions does not choose pools by itself. Vote weights and elapsed vote time determine distribution, and each pool must be triggered independently. Anyone can trigger a voted pool.

## Operational Notes

- Keepers can improve accounting freshness by poking old stakes through `VeToken.poke(veId)` and triggering emissions for voted pools.
- Stakers are economically encouraged to claim, extend, and revote before their voting power becomes stale.
- Pool fees are not meant to be predictable across long time windows. Swappers should quote the fee for the swap they are about to execute.
- Integrators should use `Ve33Lib` against `Ve33` exposed storage for views such as stake amount, voting power, pool vote state, reward globals, and emission reserves.
- Ve33 uses Core saved balances as its ledger. `Ve33` itself does not perform ERC20 transfers; wrappers and peripheries settle token movement inside Core locks.

## Deployment

Use `script/DeployVe33.s.sol` for deterministic deployment of the extension, ERC721 wrapper, and periphery.

Required environment variables:

```text
CORE_ADDRESS=<deployed core>
STAKE_TOKEN=<stake/reward token>
```

Optional environment variables:

```text
SALT=<create2 salt>
VE33_ADDRESS=<expected Ve33 address>
VE_TOKEN_ADDRESS=<expected VeToken address>
VE33_PERIPHERY_ADDRESS=<expected Ve33Periphery address>
```

Run with Foundry's offline mode:

```sh
forge script --offline script/DeployVe33.s.sol --broadcast --rpc-url <rpc>
```
