# Index-Tracking Assets Built From Fully Collateralized Options

Source thread: <https://ethresear.ch/t/building-index-tracking-assets-on-top-of-options-instead-of-debt/25036>

This note summarizes the design that seems strongest after the original proposal and the replies in the thread. The core conclusion is: use fully collateralized scalar payoff claims as the primitive, keep settlement one-time and slow wherever possible, and make the index-tracking product a rolling wrapper around short-dated claims rather than a debt system with liquidations.

## Objective

Create a synthetic asset whose value tracks an index `T` denominated in ETH, without a centralized issuer and without protocol-enforced liquidations. Examples of `T` include USD/ETH, CPI/ETH, commodity/ETH, rent-index/ETH, or a personalized basket of future expenses.

The system can only hold trustless collateral, assumed here to be ETH. Therefore all positive and negative exposure to `T` must net to zero inside the system. The design challenge is to avoid bad debt when `T` moves sharply.

## Core Primitive

The primitive is a fully collateralized scalar payoff vault:

- A vault is parameterized by index `T`, strike `S`, maturity `M`, and collateral asset, usually ETH.
- Depositing `1 ETH` mints two claims, `P` and `N`.
- Before maturity, `P + N` can always be recombined into `1 ETH`.
- At maturity, if the one-time oracle value of `T` is `x`:
  - `P = min(1, S / x)` ETH
  - `N = max(0, 1 - S / x)` ETH
- Therefore `P + N = 1` for every `x`.

The no-liquidation property comes from full collateralization plus the bounded payoff: the two sides always split existing collateral. The protocol never promises more collateral than it has, so there is no undercollateralized debt position to liquidate.

This is better described as an oracle-based scalar payoff than as a stablecoin or a perpetual. It is also close to a scalar prediction market, but the target use is financial payoff construction rather than binary prediction.

## Preferred Settlement Model

Use the weakest settlement mechanism that works for the index:

1. **Physical settlement for on-chain pairs**

   If both assets exist on chain, prefer physical exercise over an oracle. For a WETH/USDC-style vault:

   - Split `1 WETH` into `P` and `N`.
   - Before maturity, `P + N` recombine into `WETH`.
   - During exercise, `N + strike USDC -> WETH`.
   - After exercise, `P` redeems the vault's remaining balances.

   This turns settlement into asset movement rather than price lookup. The tradeoff is that someone must exercise in time, so keeper reliability and incentive design matter.

2. **One-time lazy oracle for off-chain or arbitrary indexes**

   If `T` is not physically settleable on chain, use a scalar oracle only at maturity. It should be lazy and dispute-friendly: the oracle answer is needed only when settlement occurs, not continuously.

   A robust design should use independent observers, ordered observations around `M`, quorum and coherence checks, and fallback to a heavier oracle only if observers disagree or the signal looks toxic. This preserves the main advantage over debt systems: the oracle is not deciding forced liquidations in real time.

3. **Avoid continuous funding or liquidation oracles**

   Continuous oracle updates are acceptable only for non-liquidating accounting, minting, or quoting. They should not be able to trigger forced wind-downs or liquidation cascades.

## Index-Tracking Wrapper

The user-facing index asset should be a wrapper over the option primitive, not the primitive itself.

The wrapper:

- Holds a diversified ladder of `P` claims for each target index component.
- Maintains the basket weights selected by the user or by a fixed rule.
- Rolls positions before maturity.
- Uses deterministic, fully automated rules; no governance votes and no discretionary AI.
- Exposes clear parameters: target indexes, weights, max tracking drift, strike rule, maturity ladder, roll window, and auction limits.

This wrapper is not an accounting stablecoin. It should be presented as a price-stability or future-expense hedging product. It will have tracking error, roll cost, and basis risk.

## Rolling Beats Reactive Rebalancing

The strongest feedback in the thread is that the design should not rely on frequent reactive rebalancing as price approaches the strike. Instead, it should use short-dated, conservative options and predictable rolling.

Recommended baseline:

- Use short maturities, roughly `3-10 days`, rather than one-year options.
- Roll with about `1 day` remaining.
- Choose strikes far enough from spot that shortfall risk is negligible under the desired risk model, for example around `50-60%` of current ETH/USD for a USD-stability product.
- Use longer maturities only when the premium improvement clearly justifies the additional tail and tracking risk.
- Model expected value at entry directly; do not overfit to Black-Scholes Greeks or require a volatility oracle.

This changes the operational problem from "rebalance during stress" to "roll on a known schedule." Shorter maturities make the system converge toward collateralized lending: if the position cannot be rolled at an acceptable premium, the user exits instead of being liquidated.

## Market Structure For Rolls

Do not use ordinary AMM swaps as the primary roll mechanism. The roll is not urgent, and forcing it through instant liquidity can easily dominate the economics.

A better roll market:

- Batch auction, gradual Dutch auction, RFQ, or intent-based order flow.
- Roll windows measured in hours, not blocks.
- P holders offer the yield they require; N holders/speculators/lenders match when the price is acceptable.
- Allow partial fills and fallback exit.
- Route large wrappers through time-sliced auctions to minimize market impact.

Because both sides usually prefer to roll before expiry, spreads can plausibly be much tighter than spot AMM slippage. Liquidity remains the main practical risk: on-chain options have historically struggled because fragmented strikes and expiries split liquidity.

## Payoff Design Extensions

The simple `P/N` payoff is the minimal sound design, but the wrapper should allow richer payoff templates where they reduce liquidity fragmentation or improve tracking:

- Piecewise functions of the form `f(x) = a / x + b + c x` can represent tranches and spreads.
- Generalized power payoffs `sum(a_k x^k)` can approximate leverage or custom convexity.
- Risk stratification can reconcile different desired strikes between stability seekers and speculators.
- If an asset already exists on chain, covered options can replicate payoffs with no oracle in the happy path.

These extensions should preserve the invariant that all claims are nonnegative and fully collateralized.

## Leverage And The Short Side

Leverage is possible only because the payoff redistributes a fixed collateral pool. It is bounded by the payoff shape, strike choice, premium, and available counterparties. The protocol should not sell unlimited convexity.

The `N` side is the natural home for speculators seeking upside or leverage. The `P` side is the natural home for users seeking stability relative to `T`. Market demand between those two groups determines where liquidity, strikes, and premiums settle.

If the design becomes perpetual and liquidity-backed rather than expiring, the right failure mode is saturation: convexity degrades when LP depth is insufficient. It should not pretend to maintain constant leverage forever. That variant gives up some oracle purity in exchange for no expiry and continuous mint/burn.

## Known Limitations

- It cannot create perfect long exposure to an external asset whose value can exceed the collateral pool. At best it redistributes ETH collateral according to a bounded payoff.
- It is not a perfect stablecoin. It has tracking error, basis, roll cost, and tail behavior.
- Long-dated deep options can have severe time-value/theta economics. This is why short maturities and predictable rolls are preferred.
- Liquidity fragmentation across strikes, expiries, and indexes is the largest practical obstacle.
- Physical settlement removes price lookup but introduces exercise reliability requirements.
- Oracle settlement is slower and safer than liquidation oracles, but still a trust dependency for arbitrary off-chain indexes.

## Optimal Design Summary

The best version is a two-layer system:

1. A base layer of fully collateralized, expiring, scalar payoff vaults with `P + N = collateral`, physical settlement when possible, and one-time lazy scalar oracles otherwise.
2. A wrapper layer that builds index-tracking assets by holding conservative short-dated `P` claims, rolling them through scheduled auctions, and exposing tracking error as an explicit product parameter.

The design should optimize for soundness over perfect peg behavior. It should avoid liquidation, avoid real-time canonical oracles, avoid governance discretion, and avoid instant AMM rolls. The practical success condition is deep, cheap roll liquidity; without that, the math can be correct while the product remains hard to use.
