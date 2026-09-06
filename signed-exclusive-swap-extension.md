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
- the signed fee is handed to `Core.swap(...)` as that swap's minimum fee, so it is charged on the input token and accrues to the LPs within the swap itself.

Call points are `beforeInitializePool` (to block direct initialization) and `beforeSwap` (to block direct swaps). The extension holds no funds and keeps no per-pool state other than the controller.

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
   (The nonce is not pre-checked on the forward path; reuse is rejected when the nonce is consumed in step 4.)
3. Extension executes `CORE.swap(...)`, passing `fee` (a Q32 rate, widened to Core's Q64) as that swap's minimum fee. Core charges the greater of the pool's configured fee and that minimum; the pool's fee is required to be zero here, so the signed fee is exactly what is charged. It comes off the input token in both directions, moves the price less, and is credited to the LPs that were in range for each step of the swap.
4. Extension checks `actualBalanceUpdate >= minBalanceUpdate` component-wise (`delta0` and `delta1`). Because the fee is now inside the Core swap, the bound applies to what the swapper actually pays and receives.
5. Extension consumes the nonce. This happens only after the bounds check passes, so a swap that violates its bounds costs less gas and does not burn the nonce.

## Why `minBalanceUpdate` is useful

`minBalanceUpdate` is a signed lower bound on the `PoolBalanceUpdate` that Core returns for the swap, inclusive of the signed fee, and it is part of the signed payload.

It provides four protections at once:
- Direction enforcement: by requiring the expected leg to be positive/negative as appropriate, it prevents a fill that moves value in the wrong direction.
- Slippage tolerance: the signer can allow a range (for example, accept at least `X` output) instead of requiring an exact result.
- Maximum magnitude control: bounds on input/output deltas cap how large a trade can effectively execute under that signature.
- Best-price cap: because bounds are on both components, the signer can also cap how favorable a fill may be (for example, avoid overfilling beyond inventory/risk limits), not only protect against worse prices.

## Fee timing and JIT liquidity

The signed fee is credited to LPs inside the swap, on the same path as an ordinary pool fee.

An earlier version of this extension instead collected the fee into its own Core saved balances, salted by pool ID, and donated it at the pool's first touch at a later block timestamp. That deferral existed to stop liquidity from being added purely to capture a fee it had not been at risk for. It is gone: these pools now carry exactly the just-in-time exposure that every other Ekubo pool carries, and signed fees can be much larger than a typical pool fee, so the payoff to a JIT LP is correspondingly larger.

What the current scheme buys in exchange is better attribution. A deferred donation credits whoever holds liquidity at donation time, regardless of who was in range when the fee was earned; Core credits the LPs who were actually in range for each step of the swap that paid it.

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
- Owner initializes pools by setting a `ControllerAddress controller` via `initializePool(poolKey, tick, controller)`; the controller is the extension's entire per-pool state, stored at the slot keyed by pool ID; the EOA/contract flag is encoded in the controller address (high bit at position 159).
- Direct `Core.initializePool(...)` for this extension is blocked by `beforeInitializePool`.
- Owner can update per-pool controller for already initialized pools via `setPoolController(...)`.
- Controller signatures support both EOAs and ERC-1271 contract wallets; which path is used is determined by bit 159 of the controller address itself, not a separate flag. Addresses below `2^159` are verified via ECDSA, addresses at or above it via ERC-1271. Initialization and controller updates enforce that the address's code presence matches the encoded type.

## Broadcasting quotes

`broadcastSignedSwaps(SignedSwapBroadcast[])` is a permissionless entrypoint that validates a batch of signed payloads (deadline window, nonce still available, signature against the pool's current controller) and emits one `SignedSwapBroadcasted` event per valid payload. It executes nothing and consumes no nonces; it exists so a controller can publish live quotes on-chain for takers to discover. The whole call reverts if any payload fails validation.
