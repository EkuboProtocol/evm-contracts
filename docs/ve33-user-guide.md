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

The active swap fee is computed from Ve33 pool vote state. If nobody has active votes on a pool, the extension swap fee is zero. Voters choose explicit `uint64` 0.64 fixed-point fees.

## Stakers

Stakers lock the stake token for up to `4 years`. Voting power is linear:

```text
stake amount * (unlock time - now) / 4 years
```

Using `VeToken`, the common flow is:

1. Approve the stake token to `VeToken`.
2. Call `stake(amount, end)` to mint a ve NFT.
3. Vote with `vote(veId, poolKey, swapFee)`.
4. Claim voter swap fees with `claimPoolFees(veId, poolKey, recipient)` or `claimPoolFeesToSelf(veId, poolKey)`.
5. Extend by calling `extendStake(veId, newEnd)`, split with `splitStake(veId, amount)`, merge stakes with `mergeStakes(fromVeId, toVeId)`, or add amount with `increaseStakeAmount(veId, amount)`.
6. After expiry, call `withdrawStake(veId)` to burn the NFT and withdraw the stake token to the current NFT owner.

Important details:

- The ve NFT owner, or an approved NFT operator, can manage the stake.
- `VeToken` returns token IDs as `uint256`, but generated IDs are constrained to the `uint192` range. Deterministic overloads such as `stake(amount, end, salt)` and `splitStake(veId, amount, salt)` accept a `bytes32` salt and derive the token ID with `saltToId(msg.sender, salt)`. The resulting token ID is also the Ve33 stake salt.
- The NFT SVG shows a 6-emoji fingerprint for large token IDs instead of printing long decimal numbers.
- Claimed pool fees can be sent to an authorized caller-selected recipient, and withdrawn stake tokens go to the current NFT owner.
- Increasing, extending, merging, or withdrawing a stake updates or clears the affected stake votes.
- Splitting preserves the source stake vote with reduced weight; the newly split stake starts unvoted.
- Voting power is sampled when voting or when the stake owner changes the stake in a way that refreshes the stored vote. Stored pool votes do not decay continuously.
- Claim pool fees before changing, clearing, or replacing a stake's vote, or before a stake operation that clears a vote whose pending fees you want to keep. Nonzero vote-weight resizing preserves fees already accrued under the previous weight.

## Voting And Fees

Each stake id votes for one pool with one selected swap fee. Ve33 converts the stake's current voting power into active pool weight. Users who want to allocate voting power across multiple pools split their stake into multiple stake ids, vote each stake id on one pool, and can later merge stake ids back together. A merge moves the source stake into the destination stake id selected by the caller; the destination stake id must end after the source stake id and keeps its existing end time.

For each pool:

```text
active swap fee = sum(active vote weight * selected fee) / total active vote weight
```

If active vote weight is zero, the extension swap fee is zero. Because the active fee comes from current stored votes, pool fees can change whenever votes are updated or stakes are changed.

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
- Stableswap positions use global pool reward growth and can earn while the pool price is outside the stableswap active-liquidity range.
- `claimRewards(tokenId, poolKey, tickLower, tickUpper, recipient)` claims accrued reward tokens.
- Before liquidity changes, Ve33 snapshots earned rewards. If a position fully exits, any unclaimed reward dust left in the snapshot is discarded.
- If emissions are realized before a pool is initialized or while pool liquidity is zero, those rewards are economically burned rather than assigned to LP positions.

## Swappers And Routers

Swappers should use a router configured for Ve33 pools. The router forwards swaps to Ve33 and settles the returned balance deltas.

Routers must set the intended `sqrtRatioLimit` before forwarding. Ve33 does not apply default sqrt-ratio limits internally.

Ve33 accounts voter fees in the unspecified token. For exact-input swaps, the fee is taken from the output token. For exact-output swaps, the fee is taken from the input token.

## Reward Funders

Anyone can fund global LP emissions through the periphery:

- `scheduleEmissions(startTime, endTime, rewardRate)`: schedules a global Q32 emission rate.

Scheduling emissions does not choose pools by itself. As global emissions accrue, active vote weights determine the share earned by each pool. A pool realizes its share when it is touched by normal activity such as swaps, position updates, reward claims, vote updates, or stake changes. There is no separate pool-emission trigger.

## Operational Notes

- Stakers are economically encouraged to claim, extend, and revote before their voting power becomes stale.
- There is no external permissionless stale-vote poke path. The stake owner wrapper is responsible for claiming fees before it replaces a vote or changes a stake in a way that discards the old fee snapshot.
- Pool fees are not meant to be predictable across long time windows. Swappers should quote the fee for the swap they are about to execute.
- Integrators should use `Ve33Lib` against `Ve33` exposed storage for views such as stake amount, voting power, pool vote state, reward globals, and emission growth. Voter fees share the aggregate Ve33 pool-fee saved-balance salt per token pair, while staked balances and funded LP reward backing share the aggregate Ve33 stake-token saved-balance salt.
- Ve33 uses Core saved balances as its ledger. `Ve33` itself does not perform ERC20 transfers; wrappers and peripheries settle token movement inside Core locks.

## Known Burn And Discard Cases

- Clearing or replacing a vote discards unclaimed voter fees for the previous vote.
- Withdrawing an expired stake clears its vote. Claim voter fees first if the stake has pending fees.
- Moving an entire stake clears the source stake's vote. Claim source-stake voter fees first if they should be preserved.
- Fully withdrawing LP liquidity without first claiming rewards clears the position reward snapshot and discards unclaimed LP rewards; use `withdrawAndClaimRewards` to bundle both actions.
- Voting for an uninitialized pool can direct future emissions to that pool, but emissions realized before the pool has liquidity are not claimable by later LPs.
- Emissions accrued while total active vote weight is zero, plus normal fixed-point rounding dust, can remain unassigned in Core saved balances and are not retroactively distributed.

## Deployment

Use `script/DeployVe33.s.sol` for deterministic deployment of the extension, ERC721 wrappers, and periphery. Use
`script/DeployRouter.s.sol` separately on chains where a Ve33-aware router should be deployed.

To deploy a new `MintableERC20` stake token first, configure:

```text
TOKEN_NAME=<ERC20 name>
TOKEN_SYMBOL=<ERC20 symbol>
TOKEN_DECIMALS=<optional ERC20 decimals, defaults to 18>
TOKEN_ADDRESS=<optional expected deterministic address>
SALT=<optional create2 salt>
```

The mintable token is owned by the broadcasting wallet returned by `vm.getWallets()[0]`.

```sh
forge script --offline script/DeployMintableToken.s.sol --broadcast --rpc-url <rpc>
```

Pass the resulting token address to the Ve33 deployment. `DeployVe33` reads the stake token's name, symbol, and decimals
from the token contract unless the optional name or symbol overrides are provided.

Required environment variables:

```text
STAKE_TOKEN=<stake/reward token>
```

Optional environment variables:

```text
CORE_ADDRESS=<deployed core, defaults to 0x00000000000014aA86C5d3c41765bb24e11bd701>
SALT=<create2 salt>
OWNER_ADDRESS=<Ve33Positions owner, defaults to broadcaster>
VE33_ADDRESS=<expected Ve33 address>
VE_TOKEN_ADDRESS=<expected VeToken address>
VE33_POSITIONS_ADDRESS=<expected Ve33Positions address>
VE33_PERIPHERY_ADDRESS=<expected Ve33Periphery address>
VE33_DATA_FETCHER_ADDRESS=<expected Ve33DataFetcher address>
STAKE_TOKEN_NAME=<optional stake-token name override>
STAKE_TOKEN_SYMBOL=<optional stake-token symbol override>
VE_TOKEN_NAME=<optional VeToken collection name>
VE_TOKEN_SYMBOL=<optional VeToken collection symbol>
VE33_POSITIONS_NAME=<optional positions collection name>
VE33_POSITIONS_SYMBOL=<optional positions collection symbol>
VE33_POSITIONS_BASE_URL=<optional positions metadata base URL>
```

Run with Foundry's offline mode:

```sh
forge script --offline script/DeployVe33.s.sol --broadcast --rpc-url <rpc>
```

For the STONX proposal flow, deploy STONX with `DeployMintableToken`, deploy its Ve33 system with `DeployVe33`, then run
`ConfigureSTONX`. The configuration script derives STONX from `Ve33.stakeToken()` and requires the broadcasting wallet
to still own STONX. It seeds the STONX/USDG pool, creates and votes the initial stake, schedules initial emissions,
deploys and configures the emission scheduler, and transfers the configured ownership.

Required environment variables:

```text
VE33_ADDRESS=<Ve33 extension previously deployed with STONX>
VE_TOKEN_ADDRESS=<VeToken deployed with Ve33>
VE33_POSITIONS_ADDRESS=<Ve33Positions deployed with Ve33>
VE33_PERIPHERY_ADDRESS=<Ve33Periphery deployed with Ve33>
USDG_ADDRESS=<USDG token used for initial liquidity>
```

```sh
forge script --offline script/ConfigureSTONX.s.sol --broadcast --rpc-url <rpc>
```

Router deployment accepts these optional environment variables:

```text
CORE_ADDRESS=<deployed core, defaults to 0x00000000000014aA86C5d3c41765bb24e11bd701>
SALT=<create2 salt>
MEV_CAPTURE_ADDRESS=<MEV capture extension address, defaults to mainnet deployment>
VE33_ADDRESS=<Ve33 extension address, defaults to address(0)>
ROUTER_ADDRESS=<expected router address>
```

```sh
forge script --offline script/DeployRouter.s.sol --broadcast --rpc-url <rpc>
```
