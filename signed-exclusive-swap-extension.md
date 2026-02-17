# Signed Exclusive Swap Extension

## What it does

`SignedExclusiveSwap` is a forward-only Ekubo pool extension that gives an aggregator/controller per-swap control over extra fees via signature.

It enforces:
- direct swaps are blocked (`beforeSwap` always reverts),
- swaps must be executed through `Core.forward(...)` with a signed payload,
- nonces are one-time-use via a bitmap,
- signatures can optionally restrict which locker is allowed to use them,
- extra fees are collected by the extension first and donated to LPs at the beginning of the next block (MEVCapture-style timing).

## Payload

Forward calls decode:

- `poolKey`
- `params` (`SwapParameters`)
- `authorizedLocker` (`address`, optional: `address(0)` means any locker)
- `deadline` (`uint64`)
- `extraFee` (`uint64`, Q64 fee rate)
- `nonce` (`uint256`)
- `signature` (`bytes`)

The signature is EIP-712 typed data over:
- `token0`, `token1`, `config`,
- `params`,
- `authorizedLocker`,
- `deadline`,
- `extraFee`,
- `nonce`,
- plus domain separator fields (`name`, `version`, `chainId`, `verifyingContract`).

## Swap flow

1. Caller holds a lock and forwards to extension.
2. Extension validates:
   - `block.timestamp <= deadline`,
   - locker authorization (`authorizedLocker == 0 || authorizedLocker == originalLocker`),
   - nonce not already used (then burns it),
   - signature from immutable `CONTROLLER`.
3. Extension accumulates pending extension fees for the pool if this is the first touch in the block.
4. Extension executes `CORE.swap(...)`.
5. Extension applies `extraFee` to the swapper result:
   - exact-in: fee is charged on output amount,
   - exact-out: fee is charged on required input amount.
6. Charged fee is stored in Core saved balances under the extension owner.

## Fee donation timing (MEVCapture-like)

The extension does not immediately donate its extra fee to LPs.

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
