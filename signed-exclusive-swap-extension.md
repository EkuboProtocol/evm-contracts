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
- signed fees are split between the owner and LPs; the LP share is donated on the next block touch.

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
   - deadline from `meta` has not expired, and is no further than 30 days in the future,
   - locker authorization from `meta`,
   - signature against the pool controller stored in per-pool state.
   (The nonce is not pre-checked on the forward path; reuse is rejected when the nonce is consumed in step 6.)
3. Extension accumulates pending extension fees for the pool if this is the pool's first touch at the current block timestamp.
4. Extension executes `CORE.swap(...)`.
5. Extension checks `actualBalanceUpdate >= minBalanceUpdate` component-wise (`delta0` and `delta1`) on the raw result returned by Core, before any fee is applied.
6. Extension consumes the nonce. This happens only after the bounds check passes, so a swap that violates its bounds costs less gas and does not burn the nonce.
7. Extension applies `fee` to the swapper result:
   - exact-in: fee is charged on output amount,
   - exact-out: fee is charged on required input amount; the total input including the fee must fit `int128`, otherwise the swap reverts.
8. For a nonzero collected fee, the owner share is calculated with `computeFee` and saved separately in Core under salt zero. The remainder is saved under the pool ID and later donated to that pool's LPs.

## Why `minBalanceUpdate` is useful

`minBalanceUpdate` is a signed lower bound on the `PoolBalanceUpdate` that Core returns for the swap, checked before the signed fee is applied, and it is part of the signed payload.

It provides four protections at once:
- Direction enforcement: by requiring the expected leg to be positive/negative as appropriate, it prevents a fill that moves value in the wrong direction.
- Slippage tolerance: the signer can allow a range (for example, accept at least `X` output) instead of requiring an exact result.
- Maximum magnitude control: bounds on input/output deltas cap how large a trade can effectively execute under that signature.
- Best-price cap: because bounds are on both components, the signer can also cap how favorable a fill may be (for example, avoid overfilling beyond inventory/risk limits), not only protect against worse prices.

## Fee donation timing

The extension does not immediately donate the LP share of its signed fee to LPs.

On a pool's first touch at a new block *timestamp* (`swap`, `beforeUpdatePosition`, `beforeCollectFees`, or public `accumulatePoolFees`), it:
- donates previously collected LP fees into pool LP accounting,
- records the pool as updated for the current block timestamp.

Position updates and fee collection at the same timestamp do not flush pending LP fees. Donations go to liquidity active at donation time, so liquidity added before donation can receive earlier fees, withdrawing liquidity can miss pending fees, and a donation with no active liquidity is burned. The gate uses the timestamp rather than the block number; on chains with multiple blocks per second, those blocks can share a pending fee bucket.

This attribution tradeoff is intentional. The controller authorizes swaps and their fees, and has an arbitrage incentive to leave the pool at the correct price at the end of the block. Flushing on position changes would not prevent controller-authorized swaps from moving the active range before donation, so it does not provide a useful attribution guarantee for this design. The end-of-block price is an economic expectation, not an enforced invariant. Perfect attribution to the liquidity used throughout a swap requires per-step fee accounting in Core. See the [acknowledged V12 finding](https://v12.sh/runs/7702/274639).

## Replay protection

Each signed quote includes a nonce, and the extension enforces one-time use.
If a nonce has already been consumed, the swap is rejected.

The nonce `type(uint64).max` is a reserved, reusable sentinel: it is never consumed, so a signature carrying it can be replayed without limit until its deadline passes. Issue it only when unlimited reuse within the deadline is intended.

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
- Owner initializes pools by setting a `ControllerAddress controller` via `initializePool(poolKey, tick, controller, ownerFee)`; the EOA/contract flag is encoded in the controller address (high bit at position 159).
- Direct `Core.initializePool(...)` for this extension is blocked by `beforeInitializePool`.
- Owner can update per-pool controller for already initialized pools via `setPoolController(...)`.
- Controller signatures support both EOAs and ERC-1271 contract wallets; which path is used is determined by bit 159 of the controller address itself, not a separate flag. Addresses below `2^159` are verified via ECDSA, addresses at or above it via ERC-1271. Initialization and controller updates enforce that the address's code presence matches the encoded type.

## Broadcasting quotes

`broadcastSignedSwaps(SignedSwapBroadcast[])` is a permissionless entrypoint that validates a batch of signed payloads (deadline window, nonce still available, signature against the pool's current controller) and emits one `SignedSwapBroadcasted` event per valid payload. It executes nothing and consumes no nonces; it exists so a controller can publish live quotes on-chain for takers to discover. The whole call reverts if any payload fails validation.

## Owner fee share

The owner can call `setOwnerFee(PoolKey,uint64)` to set a Q0.64 share of subsequently collected swap fees for an initialized pool (the same representation as regular pool fees). The initial share is supplied to `initializePool(poolKey, tick, controller, ownerFee)`. `PoolStateUpdated` records changes. Read the share through ExposedStorage at the pool ID slot and decode it with `SignedExclusiveSwapPoolState.ownerFee()`. For example, `1 << 63` takes half of the collected fee, not half of the swap amount.

The fee occupies bits [63..0] of `SignedExclusiveSwapPoolState`, alongside the 160-bit controller and 32-bit last-update timestamp. Swaps read the fee from the already loaded state, requiring no additional storage read.

During each swap, a nonzero collected fee is split using `computeFee(collectedFee, ownerFee)`, rounding the owner's share up. Only a nonzero computed owner share is saved immediately through `CORE.updateSavedBalances` under salt zero, aggregated by ordered token pair. The remaining fee goes to the pool's pending LP balance. The swapper's total fee is unchanged, and rate changes do not affect fees already saved for LPs.

The owner can collect these balances with `withdrawOwnerFees(token0, token1, amount0, amount1, recipient)`. Pending LP balances remain separate under the pool ID salt.
