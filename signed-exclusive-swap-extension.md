# Signed Exclusive Swap Extension

## What it does

`SignedExclusiveSwap` is a forward-only Ekubo pool extension that gives an aggregator/controller per-swap control over signed fees.

It enforces:
- direct swaps are blocked,
- swaps must be executed through `Core.forward(...)` with a signed payload,
- signatures are one-time-use via nonce replay protection,
- signatures can optionally restrict which locker is allowed to use them,
- pool fee must be zero for pools using this extension,
- pools must be initialized through the extension's owner-only `initializePool(...)`,
- signed fees are collected by the extension first and donated to LPs on the next block touch.

## Payload

Forward calls decode:

- `poolKey`
- `params` (`SwapParameters`)
- `meta` (`SignedSwapMeta`, one 256-bit word)
- `minBalanceUpdate` (`PoolBalanceUpdate`, one 256-bit word)
- `signature` (`bytes`)

`SignedSwapMeta` packs:
- `authorizedLockerLow128` (lower 128 bits of locker address, `0` means any locker),
- `deadline` (32 bits),
- `fee` (32 bits, Q32 fee rate),
- `nonce` (64 bits).

The signature is EIP-712 over this exact type:

`SignedSwap(bytes32 poolId,uint256 meta,bytes32 minBalanceUpdate)`

with:
- `poolId = keccak256(abi.encode(poolKey.token0, poolKey.token1, poolKey.config))`
- `meta = SignedSwapMeta.unwrap(meta)`
- `minBalanceUpdate = PoolBalanceUpdate.unwrap(minBalanceUpdate)`

Domain separator:

`EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)`

where:
- `name = "Ekubo SignedExclusiveSwap"`
- `version = "1"`
- `chainId = block.chainid`
- `verifyingContract = address(extension)`

## Swap flow

1. Caller holds a lock and forwards to extension.
2. Extension validates:
   - deadline from `meta` has not expired,
   - locker authorization from `meta`,
   - nonce has not already been used,
   - signature against the pool controller stored in per-pool state.
3. Extension accumulates pending extension fees for the pool if this is the first touch in the block.
4. Extension executes `CORE.swap(...)`.
5. Extension applies `fee` to the swapper result:
   - exact-in: fee is charged on output amount,
   - exact-out: fee is charged on required input amount.
6. Extension checks `actualBalanceUpdate >= minBalanceUpdate` component-wise (`delta0` and `delta1`).
7. Charged fee is stored in Core saved balances under the extension owner.

## Why `minBalanceUpdate` is useful

`minBalanceUpdate` is a signed lower bound on the final `PoolBalanceUpdate` returned by the extension, and it is part of the signed payload.

It provides four protections at once:
- Direction enforcement: by requiring the expected leg to be positive/negative as appropriate, it prevents a fill that moves value in the wrong direction.
- Slippage tolerance: the signer can allow a range (for example, accept at least `X` output) instead of requiring an exact result.
- Maximum magnitude control: bounds on input/output deltas cap how large a trade can effectively execute under that signature.
- Best-price cap: because bounds are on both components, the signer can also cap how favorable a fill may be (for example, avoid overfilling beyond inventory/risk limits), not only protect against worse prices.

## Fee donation timing

The extension does not immediately donate its signed fee to LPs.

Instead, on first touch in a new block (`swap`, `beforeUpdatePosition`, or `beforeCollectFees` path), it:
- donates previously collected extension fees into pool LP accounting,
- records the pool as updated for the current block.

This prevents same-block liquidity changes from capturing fees that were earned in prior blocks.

## Replay protection

Each signed quote includes a nonce, and the extension enforces one-time use.
If a nonce has already been consumed, the swap is rejected.

Nonce lifecycle/reuse strategy is handled off-chain by the controller/signer:
- track nonces that were used on-chain,
- track nonces that were issued but later expired unfilled,
- only recycle nonces when it is safe (for example after expiry and state reconciliation).

The owner can explicitly reset nonce state for reuse via admin nonce-bitmap management, which enables controlled nonce recycling when operationally needed.

## Quote selection risk and mitigations

A practical drawback of off-chain signed quotes is selective execution risk: a counterparty can request many quote variants, wait for price movement, and execute only the most profitable signature while letting others expire.

Common mitigations:
- use short deadlines so stale quotes lose value quickly,
- bind quotes to an authorized locker/session and tighter eligibility checks,
- gate quote/API access so only qualified users receive exclusive-liquidity quotes (for example wallet-authenticated users that satisfy balance or other policy requirements),
- apply stricter quote issuance policies (rate limits, narrower bounds, per-user controls) for higher-risk flows.

These controls reduce the value of quote farming and make selective execution materially harder.

## Controller management

- Contract is `Ownable`.
- Owner initializes pools by setting a `ControllerAddress controller` via `initializePool(poolKey, tick, controller)`; the EOA/contract flag is encoded in the controller address (high bit at position 159).
- Direct `Core.initializePool(...)` for this extension is blocked by `beforeInitializePool`.
- Owner can update per-pool controller for already initialized pools.
- Controller signatures support both EOAs and ERC-1271 contract wallets.
