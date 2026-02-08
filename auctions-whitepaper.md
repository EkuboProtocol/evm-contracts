# Auctions Whitepaper

## Overview

The `Auctions` contract is a launch mechanism built on Ekubo's TWAMM model.

At a high level, an auction is not a custom order book or bespoke pricing engine. It is a TWAMM sell order with strict rules around control, lifecycle, and settlement:

- The sale is represented by an NFT (`tokenId`).
- The sale is executed as a TWAMM order over a fixed time window.
- The sale cannot be canceled once created.
- Anyone can participate on the buy side at any time by placing a DCA buy order on the same TWAMM pool.
- Buyers can stop their own TWAMM buy order with zero pool fee (launch pool fee is `0`) or collect proceeds at any time, per normal TWAMM behavior.
- After the auction ends, anyone can trigger graduation, which splits proceeds between creator proceeds and a boost incentive stream for a configured pool.

## Core Design

## 1. Auction = Uncancelable TWAMM Sell Schedule

Each auction is encoded by:

- `AuctionKey` (token pair + packed config)
- `tokenId` (auction NFT, also used as TWAMM salt)

When `sellByAuction` is called, the contract computes a sale rate from:

- sell amount
- remaining time until configured end

Then it increases TWAMM sale rate for `(owner = Auctions, salt = tokenId, orderKey = auctionKey.toOrderKey())`.

There is intentionally no "cancel auction" path in `Auctions`.
This is a fairness choice: once the schedule is published onchain, seller discretion is removed.

## 2. Permissionless Buy-Side Participation

The launch pool is a normal TWAMM full-range pool (fee `0`, TWAMM extension).
Participants join by placing their own TWAMM buy orders directly against that pool.

Because this is standard TWAMM behavior:

- buyers can join late,
- buyers can increase/decrease/stop their own orders,
- buyers can collect their own proceeds whenever they want.

Using fee `0` on the launch pool makes stop/exit operations effectively zero-fee at the pool level.

## 3. NFT-Gated Seller Controls

The auction NFT owner (or approved operator) controls creator-side operations using `authorizedForNft(tokenId)`:

- `sellByAuction`
- `collectCreatorProceeds` (all overloads)

This cleanly separates control from addresses and enables transfer/approval semantics via ERC721.

## 4. Permissionless Graduation

After end time, `completeAuction` is permissionless.
Any caller can finalize:

1. Collect proceeds from the auction TWAMM order.
2. Split proceeds into:
   - `creatorAmount = computeFee(proceeds, creatorFee)`
   - `boostAmount = proceeds - creatorAmount`
3. Save creator proceeds in Core saved balances keyed by `(token0, token1, salt=tokenId)`.
4. Convert boost amount into a boost stream on the configured graduation pool.

This avoids dependence on a privileged "finalizer" and guarantees liveness if anyone is willing to execute.

## 5. Creator Proceeds via Saved Balances

Creator proceeds are not immediately pushed to the creator during `completeAuction`.
They are first credited to Core saved balances, then pulled by an authorized NFT controller:

- collect specific amount to specific recipient,
- collect all to specific recipient,
- collect specific amount to caller,
- collect all to caller.

This design:

- supports partial withdrawals,
- supports delegated collection,
- keeps graduation simple and permissionless,
- avoids forced transfer to an address that may not be the desired recipient.

## 6. Post-Sale Boost

A portion of proceeds can be routed into a BoostedFees schedule for a configured graduation pool:

- pool parameters come from auction config (`graduationPoolFee`, `graduationPoolTickSpacing`),
- duration comes from `boostDuration`,
- time alignment uses Ekubo valid-time constraints (`nextValidTime`),
- incentives are added as a TWAMM-like rate stream.

Economically, this can seed post-launch liquidity behavior and align incentives after primary sale completion.

## Lifecycle Summary

1. Mint auction NFT.
2. Authorized owner/approved account calls `sellByAuction`.
3. Market participants place TWAMM buy DCA orders as desired.
4. Auction runs until end time.
5. Anyone calls `completeAuction` after end:
   - proceeds are split,
   - creator share saved,
   - boost share streamed to graduation pool.
6. Authorized NFT owner/approved account collects creator proceeds in chosen amounts/recipients.

## Important Design Decisions

- **Uncancelable auction schedule**: improves fairness and predictability.
- **Permissionless participation**: no allowlist or coordinator needed for buyers.
- **Permissionless graduation**: no finalization trust bottleneck.
- **NFT-based authorization**: transferable control surface and clean approval model.
- **Saved-balance accounting for creator proceeds**: flexible and robust withdrawal flow.
- **Boost as native onchain incentives**: ties launch outcome to post-launch liquidity incentives.
- **No-op/revert discipline**:
  - creation reverts if computed sale rate delta is zero,
  - graduation reverts if no proceeds exist,
  - zero-amount collection is a no-op without event emission.

## Practical Implications

- Launches are transparent and mechanically constrained once started.
- Buyers interact with familiar TWAMM primitives instead of custom auction logic.
- Finalization and settlement are resilient to inactive creators.
- Post-sale liquidity incentives are automatically derived from actual sale proceeds.

## Conclusion

`Auctions` is intentionally minimal: it composes existing Ekubo primitives (TWAMM, Core saved balances, BoostedFees) into a launch flow with hard guarantees around fairness, liveness, and predictable control.

Rather than inventing a new market mechanism, it packages a strict policy layer around TWAMM to make onchain launches simple to reason about and hard to manipulate.
