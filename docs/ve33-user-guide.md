# Ve33 User Guide

This guide explains how the Ve33 pool system works for stakers, liquidity providers, swappers, reward funders, and integrators.

Ve33 pools are Ekubo Core pools with a custom extension. The Core pool fee is set to zero, and Ve33 accounts its own swap fee outside Core. Swap fees go to ve stakers. Liquidity providers do not earn swap fees; they earn the immutable Ve33 stake token as LP rewards.

## Contracts

- `Ve33`: the pool extension. It stores votes, pool fees, LP reward accounting, emissions, and canonical stake balances. It does not transfer ERC20 tokens directly.
- `VeToken`: an optional ERC721 wrapper for Ve33 stakes. Each NFT controls one Ve33 stake and can be transferred or approved like a normal NFT.
- `Ve33Positions`: the ERC721 manager for Ve33 LP positions. It owns Core positions, settles liquidity token payments, and claims LP rewards.
- `Ve33Periphery`: the token-settling helper for global emission schedules.
- `Ve33Lib`: read helpers for Ve33 storage exposed through `ExposedStorage`.

## Pool Rules

Ve33 pools must be initialized with `poolKey.config.fee() == 0`. Direct Core swaps revert. Swaps must go through a router that forwards `VE33_SWAP` to the extension.

The active swap fee is computed from Ve33 pool vote state. If nobody has active votes on a pool, the extension swap fee is zero. Voters choose explicit fees, capped at 50%.

## Stakers

Stakers lock the stake token for up to `4 years`. Voting power is linear:

```text
stake amount * (unlock time - now) / 4 years
```

Using `VeToken`, the common flow is:

1. Approve the stake token to `VeToken`.
2. Call `createStake(amount, end)` to mint a ve NFT.
3. Vote with `vote(veId, poolKey, swapFee)`.
4. Claim voter swap fees with `claimPoolFees(veId, poolKey)`.
5. Extend by calling `extendStake(veId, newEnd)`, split with `splitStake(veId, amount)`, merge stakes with `mergeStakes(fromVeId, toVeId)`, or add amount with `increaseStakeAmount(veId, amount)`.
6. After expiry, call `withdrawStake(veId)` to burn the NFT and withdraw the stake token to the current NFT owner.

Important details:

- The ve NFT owner, or an approved NFT operator, can manage the stake.
- Claimed pool fees and withdrawn stake tokens go to the current NFT owner.
- Increasing, extending, merging, or withdrawing a stake clears the affected stake votes.
- Splitting preserves the source stake vote with reduced weight; the newly split stake starts unvoted.
- Voting power is sampled when voting or when the stake is poked. Stored pool votes do not decay continuously.
- Anyone can call `Ve33.poke(owner, stakeId)` to refresh stale vote weights to current voting power or clear expired votes. Keepers can batch direct `poke` calls through generic multicall tooling.
- Claiming pool fees does not automatically poke. This avoids extra gas when a staker plans to extend or restake immediately after claiming.

## Voting And Fees

Each stake id votes for one pool with one selected swap fee. Ve33 converts the stake's current voting power into active pool weight. Users who want to allocate voting power across multiple pools split their stake into multiple stake ids, vote each stake id on one pool, and can later merge stake ids back together. A merge sets the destination stake end time to the greater end time of the two merged stakes.

For each pool:

```text
active swap fee = sum(active vote weight * selected fee) / total active vote weight
```

If active vote weight is zero, the extension swap fee is zero. Because the active fee comes from current stored votes, pool fees can change whenever votes are updated, stakes are changed, or stale votes are poked.

Voter fees are distributed only to active voters on the pool at the time fees are accounted.

## Liquidity Providers

LPs provide liquidity through `Ve33Positions`. Each ERC721 token can own one position per pool and tick range. The Core `PositionId` is derived from:

```text
owner = address(Ve33Positions)
salt = bytes24(uint192(tokenId))
tickLower
tickUpper
```

The ERC721 owner or approved operator can deposit, withdraw principal, and claim LP rewards. Separate NFTs can hold independent positions in the same pool and tick range.

LPs should remember:

- Ve33 LPs do not earn Core swap fees.
- LPs earn the stake token from global emissions directed by active votes.
- Rewards are range-aware. Out-of-range concentrated positions do not earn while out of range.
- Stableswap positions only earn while the pool price is inside the stableswap active-liquidity range.
- `claimRewards(tokenId, poolKey, tickLower, tickUpper, recipient)` claims accrued reward tokens.
- Before liquidity changes, Ve33 snapshots earned rewards. If a position fully exits, any unclaimed reward dust left in the snapshot is discarded.
- If emissions are realized while eligible liquidity is zero, those rewards are not assigned to LP positions.

## Swappers And Routers

Swappers should use a router configured for Ve33 pools. The router forwards swaps to Ve33 and settles the returned balance deltas.

Routers must set the intended `sqrtRatioLimit` before forwarding. Ve33 does not apply default sqrt-ratio limits internally.

For exact-input swaps, Ve33 removes the maximum voter fee up front, executes the Core swap with the net input, then charges the fee from actual executed input. If the swap only partially executes, the charged fee is capped to the amount removed up front.

For exact-output swaps, Ve33 lets Core compute the required input, grosses that input up by the active Ve33 fee, and accounts the extra input as voter fees.

## Reward Funders

Anyone can fund global LP emissions through the periphery:

- `scheduleEmissions(startTime, endTime, rewardRate)`: schedules a global Q32 emission rate.

Scheduling emissions does not choose pools by itself. As global emissions accrue, active vote weights determine the share earned by each pool. A pool realizes its share when it is touched by normal activity such as swaps, position updates, reward claims, vote updates, or pokes. There is no separate pool-emission trigger.

## Operational Notes

- Keepers can improve accounting freshness by poking old stakes through `Ve33.poke(owner, stakeId)`, batching direct `poke` calls through generic multicall tooling, or touching pools that have accrued rewards.
- Stakers are economically encouraged to claim, extend, and revote before their voting power becomes stale.
- Pool fees are not meant to be predictable across long time windows. Swappers should quote the fee for the swap they are about to execute.
- Integrators should use `Ve33Lib` against `Ve33` exposed storage for views such as stake amount, voting power, pool vote state, reward globals, and emission growth. Funded LP reward backing is a Core saved balance under the Ve33 LP reward saved-balance salt.
- Ve33 uses Core saved balances as its ledger. `Ve33` itself does not perform ERC20 transfers; wrappers and peripheries settle token movement inside Core locks.

## Deployment

Use `script/DeployVe33.s.sol` for deterministic deployment of the extension, ERC721 wrappers, periphery, and a router configured for Ve33 pools.

Required environment variables:

```text
STAKE_TOKEN=<stake/reward token>
```

Optional environment variables:

```text
CORE_ADDRESS=<deployed core, defaults to 0x00000000000014aA86C5d3c41765bb24e11bd701>
SALT=<create2 salt>
VE33_ADDRESS=<expected Ve33 address>
VE_TOKEN_ADDRESS=<expected VeToken address>
VE33_POSITIONS_ADDRESS=<expected Ve33Positions address>
VE33_POSITIONS_OWNER=<metadata owner for Ve33Positions, defaults to broadcaster>
VE33_PERIPHERY_ADDRESS=<expected Ve33Periphery address>
VE33_ROUTER_ADDRESS=<expected Ve33 router address>
MEV_CAPTURE_ADDRESS=<MEV capture extension address, defaults to mainnet deployment>
```

Run with Foundry's offline mode:

```sh
forge script --offline script/DeployVe33.s.sol --broadcast --rpc-url <rpc>
```
