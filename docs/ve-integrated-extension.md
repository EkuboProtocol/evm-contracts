# ve(3,3) Integrated Pool Extension

`Ve33Rewards` combines the ve gauge, voter-directed swap fees, and single-token LP rewards into one pool extension. Pools using it must be concentrated-liquidity pools with a zero Core pool-config fee. The extension stores the active swap fee in its own pool vote state.

## Swap Path

Swaps must go through `Core.forward` to the extension using `VE33_SWAP`. Direct Core swaps hit `beforeSwap` and revert.

For exact-input swaps, the extension computes the voter fee from the specified input amount, calls Core with the remaining input, then adds the fee back to the returned balance delta. For exact-output swaps, the extension calls Core with the zero-fee exact-output parameters and grosses up the input by the active voter fee.

The fee is saved with `Core.updateSavedBalances` under the extension and pool id. It is not accumulated as Core LP fees, so LPs do not earn swap fees.

## Voting And Fees

ve lockers vote on pools and provide either explicit fees or tick spacings. Tick spacing votes use `defaultFeeForTickSpacing`, which prices a `2 * tickSpacing` move and caps the result at 50%.

Each pool stores:

- total active vote weight
- time-weighted vote seconds for emissions
- accumulated voter fee growth for token0 and token1
- weighted fee sum
- current swap fee
- default swap fee derived from the pool tick spacing

When votes change, the pool fee is recomputed as `feeWeightSum / weight`. If no votes remain, it falls back to the default fee.

## Fee Claims

Per-swap fees are distributed to ve voters through fee-growth accounting. `claimPoolFees` locks the extension, subtracts the claimed amount from the saved balance, and withdraws token0/token1 to the ve NFT owner.

## LP Rewards

LPs only earn the immutable reward token, which is `stakeToken` for this extension. Reward accounting mirrors `SingleTokenRewards`:

- `rewardsGlobalPerLiquidity`
- per-initialized-tick `tickRewardsOutsidePerLiquidity`
- per-position `positionRewardsSnapshotPerLiquidity`

Because forwarded swaps skip extension hooks, the forwarded swap handler explicitly accumulates rewards before the Core swap and updates crossed tick reward snapshots after it.

Reward funding and donations use saved balances through `forward`. No transfer is performed by the extension in the forwarded reward accounting path; the caller’s lock is responsible for settling the saved balance delta.
