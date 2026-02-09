# Auctions Whitepaper

## Purpose

An Ekubo auction is designed to do two things in one flow:

1. Sell launch inventory over a fixed time window using TWAMM.
2. Route post-sale value into both creator proceeds and optional liquidity incentives.

The mechanism is permissionless to complete, predictable once configured, and built around onchain accounting.

## Core Objects

Each auction is keyed by:

- `token0`/`token1` pair,
- an `AuctionConfig` (sale direction, timing, creator fee, boost settings, graduation pool settings),
- and an auction NFT `tokenId`.

`tokenId` is also used as the TWAMM order salt and the saved-balance accounting key.

## Lifecycle

1. **Mint auction NFT**
   The creator (or a later approved operator) mints and controls an ERC-721 auction NFT.

2. **Fund auction before start**
   `sellByAuction(tokenId, auctionKey, amount)` can be called by the NFT owner/approved operator while
   `block.timestamp <= startTime` (the contract reverts once `block.timestamp > startTime`).

   The call:
   - validates graduation pool tick spacing and max supported min boost duration,
   - computes sale rate from `amount / auctionDuration`,
   - initializes the launch TWAMM pool if needed,
   - increases the TWAMM order sale rate for `salt = bytes32(tokenId)`,
   - pulls sell tokens from the caller.

   Multiple pre-start calls can add more inventory to the same auction order.

3. **Auction runs in TWAMM**
   Price discovery and execution are handled by TWAMM/Core virtual orders. Participants interact with the launch pool directly through TWAMM-compatible flows.

4. **Permissionless completion after end time**
   Anyone can call `completeAuction` once `block.timestamp >= endTime`.

   Completion:
   - collects purchased proceeds from the TWAMM order,
   - reverts if proceeds are zero,
   - computes creator share from `creatorFee`,
   - treats the remainder as boost-eligible,
   - optionally adds incentives to the graduation pool until an aligned `boostEndTime`.

   Important accounting detail:
   the final creator amount is set to `auctionProceeds - actualBoostedAmount`.
   So creator proceeds may be larger than the configured creator-fee share if boost amount is capped or otherwise less than boost-eligible amount.

5. **Creator proceeds withdrawal**
   Owner/approved operator calls `collectCreatorProceeds` (partial or all, to self or recipient).
   Proceeds are held as Core saved balances under `(token0, token1, salt=bytes32(tokenId))` until withdrawn.

## Access Control and Permissions

- `sellByAuction` and all `collectCreatorProceeds` overloads require owner/approved access to the auction NFT.
- `completeAuction` is permissionless.

## Timing and Configuration Constraints

- Auction cannot be newly funded once `block.timestamp > startTime`.
- Completion is blocked before `endTime`.
- `auctionDuration` must produce a non-zero sale rate for the funded amount.
- Graduation pool tick spacing must be in `(0, MAX_TICK_SPACING]`.
- `minBoostDuration` must be `<= 180 days`.

## Proceeds and Incentives Semantics

- Creator proceeds are stored in the buy-token side of saved balances.
- Boost incentives are funded from the same collected proceeds.
- If no boost can be applied, all proceeds become creator proceeds.
- If only part of boost-eligible proceeds is applied (for example because of rate caps), unused amount is redirected to creator proceeds.

## Design Goals

- Deterministic launch schedule once auction starts.
- Permissionless completion after end time.
- Onchain, auditable split between creator proceeds and liquidity incentives.
- Flexible creator withdrawal without custody handoffs.
