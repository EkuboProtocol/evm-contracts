# Stable Pair Fungible Position Extension Spec

## Summary

Create one ERC20-compatible fungible position token per Ekubo pool key and configuration. The contract is both:

- an Ekubo pool extension for the configured pool; and
- the ERC20 vault/share token representing pro rata ownership of the extension-managed liquidity and idle inventory.

The target use case is a stable pair such as USDC/USDT, managed as concentrated liquidity around the pool price. The design assumes a concentrated pool because the requested `tickSpacing` and `N * tickSpacing` position bounds are not compatible with Ekubo native stableswap pools, where position bounds are fixed by the pool config.

## Immutable Configuration

Each deployed token/extension has immutable parameters:

- `ICore CORE`
- `PoolKey POOL_KEY`
- `PoolId POOL_ID`
- `address token0`
- `address token1`
- `uint32 tickSpacing`
- `uint32 N`
- `int32 initialTick`
- `uint64 maxContributionToLiquidityBps`
- optional `address initializer` or `factory`
- ERC20 metadata

Constraints:

- `POOL_KEY.token0 == token0`
- `POOL_KEY.token1 == token1`
- `POOL_KEY.config.extension() == address(this)`
- `POOL_KEY.config.isConcentrated()`
- `POOL_KEY.config.concentratedTickSpacing() == tickSpacing`
- `N > 0`
- `N * tickSpacing` and `2 * N * tickSpacing` must fit safely in `int32`
- `initialTick % int32(tickSpacing) == 0`
- `maxContributionToLiquidityBps > 0`

## Call Points

The extension should register these call points:

- `beforeInitializePool`: prevent undesired pool creation.
- `beforeUpdatePosition`: prevent positions being created or modified outside this extension.
- `beforeSwap`: block direct Core swaps and force swaps through the extension entrypoints.
- `afterSwap`: enforce the per-block price movement limit.

`beforeCollectFees` is optional. It is only needed if a later implementation decides to expose direct fee collection on extension-owned positions. The first version should keep fee collection internal and not expose position ownership externally.

## Pool Initialization Guard

Only the configured pool may be initialized through this extension.

`beforeInitializePool(caller, poolKey, tick)` must revert unless:

- `caller == address(this)`;
- `poolKey.toPoolId() == POOL_ID`;
- `poolKey` exactly matches `POOL_KEY`;
- `poolKey.config.extension() == address(this)`;
- `poolKey.config.isConcentrated()`;
- `poolKey.config.concentratedTickSpacing() == tickSpacing`;
- `tick == initialTick`.

The contract should expose an `initializePool()` entrypoint that calls `CORE.initializePool(POOL_KEY, initialTick)`. `initialTick` must be immutable or factory-controlled before deployment. This is required because the first LP has no existing liquid range from which the contract can infer a manipulation-resistant price.

## Position Ownership Model

The extension must only ever own one Core liquidity position for the pool.

The managed `POSITION_ID` is fixed at deployment or pool initialization. It is the only position id the extension is allowed to touch for the configured pool. The extension may increase or decrease liquidity on this one position, but it must never create a second position, migrate liquidity to different bounds, or temporarily hold liquidity in another position during rebalance.

`beforeUpdatePosition(locker, poolKey, positionId, liquidityDelta)` must revert unless:

- `poolKey.toPoolId() == POOL_ID`;
- `locker.addr() == address(this)`;
- the extension is currently executing an internal position update; and
- `positionId == POSITION_ID`.

This prevents users from creating positions directly through Core for the extension pool. It also prevents the extension address from being used through arbitrary forwarded calldata to mutate unexpected positions.

## Managed Position Bounds

The managed position bounds are chosen once and never change.

Recommended bound calculation at initialization:

- `centerTick = nearest usable tick to initial pool tick`, aligned to `tickSpacing`;
- `lower = centerTick - int32(N * tickSpacing)`;
- `upper = centerTick + int32(N * tickSpacing)`;
- clamp to Ekubo min/max ticks if needed, preserving tick spacing alignment.

`POSITION_ID` is derived from these bounds and a fixed salt. Because the contract only ever owns this one position, `N` defines the half-width of the managed range rather than a range that is recentered every block.

## Rebalancing

Rebalancing only changes how much of the contract's current inventory is active in the managed position. It does not move the position bounds and does not perform an internal swap for the vault.

At each rebalance, the extension should:

1. Collect fees owed to `POSITION_ID`.
2. Remove current liquidity from `POSITION_ID` if needed to make all vault-owned assets available for ratio calculation.
3. Snapshot the current pool tick and sqrt ratio.
4. Process eligible pending contributions at that block-start price.
5. Add as much liquidity as possible to `POSITION_ID` using vault-owned token0 and token1 at the current pool price.
6. Leave any token0 or token1 that cannot be deposited at the required position ratio as idle vault inventory.

This moves the active asset ratio toward the current pool price by maximizing liquidity at that price. Unused assets are not swapped; they remain idle until a later rebalance can use them.

## Block Sync

The extension has a single internal sync routine used by all state-changing interactions with the contract.

`_syncBlock()`:

1. If `block.number == lastProcessedBlock`, do nothing.
2. Rebalance the single managed position using the steps above.
3. Store `lastProcessedBlock = block.number`, `lastBlockStartTick`, and `lastBlockStartSqrtRatio`.

Every external state-changing entrypoint must call `_syncBlock()` before doing its own action. This includes contributing, withdrawing, claiming refunds, extension-mediated swaps, and ERC20 state changes. The first state-changing interaction in a block processes all eligible pending contributions and rebalances before that interaction continues.

If nobody touches the extension in the immediately following block, pending contributions cannot be processed on-chain in that block. They remain eligible and are processed by the first later state-changing interaction, unless an expiry mechanism is added.

## Delayed Contribution Flow

Users do not receive shares in the same block in which they contribute capital. They may contribute token0, token1, or both in any ratio in one block, then their LP shares are minted no earlier than the start of the next block at the pre-swap block-start price.

Suggested contribution entrypoint:

```solidity
function contribute(
    uint128 amount0,
    uint128 amount1,
    address recipient,
    uint256 minShares,
    uint64 deadlineBlock
) external payable returns (uint256 contributionId);
```

Behavior:

- Pull `amount0` and/or `amount1` from the caller.
- Store the contribution as a pending liability, not vault-owned assets.
- Set `eligibleBlock = block.number + 1`.
- Store the current pool tick as `commitTick`.
- Store `minShares` for automatic processing.
- No ERC20 shares are minted in the contribution block.
- If `deadlineBlock` is nonzero and the contribution has not been processed by that block, it can be cancelled/refunded.

Optional manual process entrypoint:

```solidity
function processPending(uint256 contributionId) external returns (uint256 shares);
```

`processPending` exists only as a convenience wrapper that calls `_syncBlock()` and returns the resulting shares for one contribution. It is not required for deposits to mint. Any state-changing interaction in an eligible block triggers `_syncBlock()` and processes all eligible pending contributions before continuing.

For each eligible contribution:

1. Compute vault NAV before accepting the contribution, valued in token0 terms at `lastBlockStartSqrtRatio`.
2. Compute the contribution value in token0 terms at the same price.
3. Mint shares to the contribution recipient:
   - if `totalSupply == 0`, `shares = contributionValue0`;
   - otherwise, `shares = contributionValue0 * totalSupply / totalAssets0Before`.
4. Move the contributed tokens from pending liabilities into vault-owned inventory.
5. Revert if the stored minimum shares for that contribution is not met.

Eligible non-expired contributions mint at the block-start price. They do not carry a per-contribution price interval.

Eligible pending contributions must be processed deterministically and atomically during `_syncBlock()`. A later interaction must not be able to process only a subset of currently eligible contributions and then continue to swap, withdraw, or transfer.

## Delayed Mint Security Model

Pending contributions do not pause the pool. Swaps and withdrawals may continue while contributions are waiting to mint.

Without an oracle, the protection for contributors is that shares are minted by the first state-changing interaction of the next block, before that interaction can do anything else. If an attacker moves the pool price after a contribution and wants the contribution to mint at that manipulated price, they must keep the pool at that price through the end of the block. At the start of the next block, pending contributions are minted and liquidity is added before the attacker can unwind through the extension. With meaningful active liquidity, holding that price across the block is costly and exposes the attacker to loss when the next-block liquidity is added.

Rules:

1. `contribute(...)` must call `_syncBlock()` before recording the contribution.
2. Extension-mediated swaps remain allowed while contributions are pending.
3. Withdrawals remain allowed while contributions are pending, but cannot reduce active liquidity below the pending-contribution liquidity floor described below.
4. Burns that only withdraw idle assets remain allowed.
5. At the first `_syncBlock()` in an eligible block, the contract must process all eligible contributions before the triggering action continues.
6. Direct Core swaps and direct position updates remain disabled through hooks.

This makes price movement during the waiting period possible, but forces it to persist until the next block's first state-changing interaction to affect mint pricing.

To reduce stale-liability griefing, the implementation should require a minimum contribution value or an expiry on pending contributions.

## Contribution Size Limit

Contributions after bootstrap are limited relative to current active liquidity. This keeps delayed mints small compared with the liquidity that makes end-of-block price manipulation expensive.

After `contribute(...)` calls `_syncBlock()`, it computes:

- `contributionValue0`: the new contribution valued in token0 terms at the current pool price;
- `activeLiquidityValue0`: the current token0-equivalent value of assets backing `POSITION_ID`; and
- `pendingValue0ForBlock`: the aggregate token0-equivalent value of already accepted contributions with the same `eligibleBlock`.

If `totalSupply != 0` and `activeLiquidityValue0 != 0`, the contribution must satisfy:

```text
pendingValue0ForBlock + contributionValue0
    <= activeLiquidityValue0 * maxContributionToLiquidityBps / 10_000
```

If `activeLiquidityValue0 == 0`, swaps are disabled, so there is no pool-trade path to manipulate the delayed mint price. Contributions may still be accepted, but swaps remain disabled until a rebalance can create nonzero active liquidity.

The first bootstrap contribution is exempt because there is no active liquidity yet; bootstrap is protected by fixed initialization, disabled swaps before first liquidity, and the first mint happening before any later action can execute.

While contributions are pending, the contract maintains a liquidity floor:

```text
requiredActiveLiquidityValue0
    = max over pending eligibleBlock groups of pendingValue0ForBlock * 10_000 / maxContributionToLiquidityBps
```

Withdrawals may remove liquidity only if the remaining active liquidity value is at least `requiredActiveLiquidityValue0`, unless active liquidity is already zero and swaps are disabled. This prevents an LP from accepting capped pending contributions, removing the liquidity that justified the cap, and then manipulating the pool price with a thinner range.

## Bootstrap Rules

The first LP has no existing liquid range, so bootstrap needs stricter rules:

1. Pool initialization must use the immutable `initialTick`.
2. No swap may execute while `totalSupply == 0` or `activeLiquidity == 0`.
3. First contributions follow the same delayed flow: contribute in block N, mint in block N+1 or later.
4. The first mint must execute at `initialTick`; because swaps are disabled while `activeLiquidity == 0`, the pool price cannot move before first liquidity is added.
5. The first rebalance must add as much liquidity as possible to `POSITION_ID` before any later action is allowed.

Because swaps are disabled before first liquidity and initialization is fixed, there is no pool-trade path to manipulate the first LP's mint price.

## Extension-Mediated Pool Swaps

Direct Core swaps should be rejected in `beforeSwap`. Normal immediate pool swaps, if supported, must go through an extension entrypoint that:

1. calls `_syncBlock()`;
2. reverts if `activeLiquidity == 0`;
3. forwards into the extension under the Core lock;
4. calls `CORE.swap(POOL_KEY, params)`; and
5. relies on `afterSwap` to enforce the movement limit.

This guarantees a swap cannot be the first action in a block without first processing all eligible non-expired contributions and adding as much liquidity as possible to the single managed position. Non-eligible contributions from the current block remain pending while swaps continue.

## Price Movement Limit

For every extension-mediated Core swap, the final pool tick must remain within:

```text
lastBlockStartTick +/- int32(2 * N * tickSpacing)
```

`afterSwap(..., stateAfter)` should revert if:

```text
abs(stateAfter.tick() - lastBlockStartTick) > 2 * N * tickSpacing
```

It should also revert if `stateAfter.tick()` is outside the managed position bounds:

```text
POSITION_ID.tickLower() <= stateAfter.tick() < POSITION_ID.tickUpper()
```

This limits price movement to twice the managed position half-width from the block-start reference price, and ensures the final price remains inside the extension-owned liquid range.

Because direct Core swaps are rejected, every price-moving swap should pass through this check. Delayed next-block minting and contribution size limits handle price movement before delayed mints; the per-swap movement limit handles swaps that execute through the extension.

## Deposit Flow

Same-block deposits are not supported. The deposit flow is the delayed contribution flow:

- `contribute(...)` transfers assets in at any token0/token1 ratio and creates a pending contribution.
- any state-changing interaction can cause eligible pending contributions to mint in a later block.
- The mint price is the block-start price observed by `_syncBlock()` before the triggering interaction continues.
- The newly accepted capital becomes vault-owned inventory in full.
- The extension adds as much liquidity as possible after processing it.
- Any accepted token0 or token1 that cannot be added to the Core position remains idle inventory owned pro rata by LP token holders.

Pending contributions must not be included in vault NAV until they are processed and shares are minted.

`totalAssets0Before` for minting must include:

- idle vault token0;
- idle vault token1 valued at the block-start price;
- principal in `POSITION_ID`;
- uncollected fees owed to `POSITION_ID`; and
- assets removed from `POSITION_ID` during `_syncBlock()`.

It must exclude:

- pending contributions that have not yet minted shares; and
- expired or refundable contributions owed back to users.

## Withdraw Flow

Suggested entrypoint:

```solidity
function withdraw(
    uint256 shares,
    uint128 minAmount0,
    uint128 minAmount1,
    address receiver
) external returns (uint128 amount0, uint128 amount1);
```

Behavior:

1. Call `_syncBlock()`.
2. Compute whether the withdrawal would require removing active liquidity.
3. If active liquidity must be removed, require the remaining active liquidity value to satisfy the pending-contribution liquidity floor.
4. Burn `shares`.
5. Compute the user's pro rata share of total vault assets, including active position principal, idle assets, and uncollected fees.
6. Remove pro rata liquidity from `POSITION_ID` if idle balances are insufficient.
7. Transfer token0 and token1 pro rata to `receiver`.
8. Revert if outputs are below `minAmount0` or `minAmount1`.

Withdrawals receive actual token0/token1 inventory, not token0-value-only settlement. This includes the user's pro rata share of assets currently in the Core position and assets that were accepted by the vault but left idle because they could not be added as liquidity at the current position ratio.

## Accounting

The contract tracks these categories separately:

- `activeLiquidity`: liquidity in `POSITION_ID`.
- `POSITION_ID`: the only Core position id the extension may own.
- `idle0` / `idle1`: vault-owned tokens not currently in Core liquidity, including accepted contribution assets that could not be added to `POSITION_ID`.
- pending contribution token0/token1 amounts.
- aggregate pending contribution value per eligible block.
- required active liquidity value implied by pending contribution caps.
- refundable expired or cancelled contributions.

Vault share price is based only on vault-owned assets. Pending contribution liabilities are never counted as assets for minting or withdrawal pricing until shares are minted.

## ERC20 Behavior

The position token is a standard non-rebasing ERC20.

- Transfers move pro rata ownership of vault assets.
- Processed contributions mint shares.
- Withdrawals burn shares.
- No per-account position data is needed beyond ERC20 balances.

The implementation can use Solady `ERC20` unless repo conventions suggest another base.

## Events

Recommended events:

- `PoolInitialized(int32 tick)`
- `ContributionSubmitted(uint256 indexed contributionId, address indexed caller, address indexed receiver, uint128 amount0, uint128 amount1, uint64 eligibleBlock)`
- `ContributionMinted(uint256 indexed contributionId, address indexed receiver, uint256 shares, uint128 amount0, uint128 amount1, int32 mintTick)`
- `ContributionRefundable(uint256 indexed contributionId)`
- `ContributionRefunded(uint256 indexed contributionId, address indexed receiver, uint128 amount0, uint128 amount1)`
- `Withdrawn(address indexed caller, address indexed receiver, uint256 shares, uint128 amount0, uint128 amount1)`
- `Rebalanced(int32 blockStartTick, PositionId positionId, uint128 liquidity, uint128 idle0, uint128 idle1)`

## Errors

Recommended errors:

- `InvalidPoolKey()`
- `InvalidPoolConfig()`
- `InvalidN()`
- `InvalidTickSpacing()`
- `InitializerOnly()`
- `PoolAlreadyInitialized()`
- `DirectSwapDisabled()`
- `DirectPositionUpdateDisabled()`
- `UnauthorizedPositionUpdate()`
- `InvalidPositionBounds()`
- `PriceMoveLimitExceeded()`
- `ZeroContribution()`
- `ZeroShares()`
- `SlippageLimitExceeded()`
- `ContributionNotEligible()`
- `ContributionExpired()`
- `ContributionAlreadySettled()`
- `NoActiveLiquidity()`
- `ContributionTooLarge()`
- `PendingContributionLiquidityFloor()`

## Test Plan

Initialization:

- registers the expected call points;
- rejects initialization of any pool key other than `POOL_KEY`;
- rejects direct Core initialization by an external caller;
- rejects mismatched pool type, extension address, or tick spacing;
- accepts initialization through the extension entrypoint.
- rejects bootstrap initialization at any tick other than immutable `initialTick`.

Position control:

- direct `CORE.updatePosition` reverts;
- extension internal rebalance can update only `POSITION_ID`;
- unexpected `positionId` reverts even when reached through forwarding.

Contributions and withdrawals:

- contribution in block N does not mint shares;
- `processPending` in block N does not mint the new contribution;
- any state-changing interaction in block N+1 mints all eligible contributions at the pre-action block-start price;
- stored `minShares` is enforced when an eligible contribution is automatically processed;
- first contribution mints at `initialTick` because swaps are disabled before first liquidity;
- token0-only, token1-only, and mixed contributions mint equivalent shares at the same price;
- arbitrary-ratio contributions mint based on token0-equivalent value and leave unusable inventory idle;
- pending contributions are excluded from NAV;
- expired or cancelled contributions become refundable and are not included in NAV;
- post-bootstrap contributions are capped by aggregate pending value for their eligible block relative to active liquidity;
- multiple small contributions cannot bypass the cap because the cap uses aggregate pending value;
- contributions remain allowed when active liquidity is zero, but swaps stay disabled until active liquidity exists;
- withdrawals return pro rata active and idle assets;
- withdrawals include pro rata accepted assets that are idle outside the Core position;
- withdrawals that would reduce active liquidity below the pending-contribution liquidity floor revert;
- withdrawals that only use idle assets remain allowed while pending contributions exist;
- fees accrue to share holders and are included in withdrawal/NAV.

Pending contribution price protection:

- extension-mediated swaps remain allowed while a non-eligible contribution is pending;
- withdrawals remain allowed while a non-eligible contribution is pending if the liquidity floor is preserved;
- eligible non-expired pending contributions are minted before the first state-changing interaction in the block continues;
- swaps in the contribution block can move the price, but affecting the delayed mint requires the price to remain moved until the next block's first state-changing interaction;
- a dust contribution cannot permanently create stale liabilities because it expires or can be refunded.

Rebalancing:

- first state-changing interaction in a new block processes pending contributions and rebalances before continuing;
- the contract never creates or migrates to a second position;
- rebalancing adds as much liquidity as possible to `POSITION_ID`;
- unused capital remains idle.

Swap limits:

- direct Core swaps revert;
- swaps revert before first liquidity exists;
- extension-mediated swaps within `2 * N * tickSpacing` succeed;
- extension-mediated swaps that end outside the allowed range revert;
- the first state-changing interaction in a new block syncs before continuing.

## Open Questions

1. Should `initialTick` be fixed directly in the token/extension constructor, or provided by a factory that deploys the token at a deterministic address?
2. Should automatic pending contribution processing be capped per sync for gas, or should the contribution queue be bounded so all eligible deposits can always be processed atomically?
3. What minimum contribution value or fee is acceptable to mitigate one-block griefing from dust contributions?
4. Should `maxContributionToLiquidityBps` be immutable per token/extension, or should it be encoded in a factory-level policy?
5. Should immediate extension-mediated pool swaps be exposed, or should the pool only support keeper-triggered syncs plus external routing elsewhere?
