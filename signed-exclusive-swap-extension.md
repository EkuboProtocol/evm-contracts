# Signed Exclusive Swap Extension

## What it does

`SignedExclusiveSwap` is a forward-only Ekubo pool extension that gives an aggregator/controller per-swap control over signed fees.

It enforces:
- direct swaps are blocked (`beforeSwap` always reverts),
- swaps must be executed through `Core.forward(...)` with a signed payload,
- nonces are one-time-use via a bitmap,
- signatures can optionally restrict which locker is allowed to use them,
- pool fee must be zero for pools using this extension,
- signed fees are collected by the extension first and donated to LPs at the beginning of the next block (MEVCapture-style timing).

## Payload

Forward calls decode:

- `poolKey`
- `params` (`SwapParameters`)
- `meta` (`SignedSwapMeta`, one 256-bit word)
- `signature` (`bytes`)

`SignedSwapMeta` packs:
- `authorizedLocker` (160 bits, `address(0)` means any locker),
- `deadline` (32 bits),
- `fee` (32 bits, Q32 fee rate),
- `nonce` (32 bits).

The signature is EIP-712 typed data over:
- `token0`, `token1`, `config`,
- `params`,
- `meta`,
- plus domain separator fields (`name`, `version`, `chainId`, `verifyingContract`).

## Swap flow

1. Caller holds a lock and forwards to extension.
2. Extension validates:
   - pool fee is zero,
   - deadline from `meta` has not expired (wrap-safe 32-bit comparison),
   - locker authorization from `meta` (`authorizedLocker == 0 || authorizedLocker == originalLocker`),
   - nonce not already used (then burns it),
   - signature against the pool controller stored in per-pool state.
3. Extension accumulates pending extension fees for the pool if this is the first touch in the block.
4. Extension executes `CORE.swap(...)`.
5. Extension applies `fee` to the swapper result:
   - exact-in: fee is charged on output amount,
   - exact-out: fee is charged on required input amount.
6. Charged fee is stored in Core saved balances under the extension owner.

## Fee donation timing (MEVCapture-like)

The extension does not immediately donate its signed fee to LPs.

Instead, on first touch in a new block (`swap`, `beforeUpdatePosition`, or `beforeCollectFees` path), it:
- reads extension saved balances for the pool,
- calls `CORE.accumulateAsFees(...)` to donate those amounts to LP accounting,
- debits extension saved balances back down,
- marks pool as updated for the block.

This prevents same-block liquidity changes from capturing fees that were earned in prior blocks.

## Replay protection

Replay protection is intentionally simple:
- `mapping(uint256 => Bitmap) nonceBitmap`
- `word = nonce >> 8`
- `bit = 1 << (nonce & 255)`

If the bit is set, the signature is invalid; otherwise it is toggled on during execution.

Nonce lifecycle/reuse strategy is handled off-chain by the controller.

## Controller management

- Contract is `Ownable`.
- `defaultController` and `defaultControllerIsEoa` are used for new pools in `afterInitializePool`.
- Owner can update:
  - default controller for future pools,
  - per-pool controller for already initialized pools.
- Pool state also stores an `isEoa` bit to choose an efficient signature verification path:
  - EOA path uses direct ECDSA recovery,
  - contract path uses ERC-1271 (`SignatureCheckerLib`).
