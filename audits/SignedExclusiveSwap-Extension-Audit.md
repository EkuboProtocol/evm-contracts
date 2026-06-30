# SignedExclusiveSwap Extension Audit

Date: 2026-06-30

Auditor: Codex

## Executive Summary

This review covered `src/extensions/SignedExclusiveSwap.sol` and the directly related signing, state-packing, fee, and test code. No Critical or High severity vulnerabilities were identified in the scoped review.

The extension implements a forward-only swap path for zero-fee pools, where a per-pool controller signs an EIP-712 payload authorizing a minimum pool balance update, a packed fee, an optional authorized locker, a deadline, and a nonce. Extra signed fees are saved under the extension's Core saved-balance account and donated to LP fee growth no more than once per block.

The original review identified low-severity integration and operations risks rather than direct protocol-loss bugs. The follow-up remediation addressed the actionable items in code and tests:

- `broadcastSignedSwaps` now rejects expired signatures, signatures outside the deadline window, and already-consumed non-sentinel nonces before emitting.
- Signature validation now recomputes the EIP-712 domain separator if `block.chainid` differs from the deployment chain ID.
- Controller updates now reject zero addresses and addresses whose high-bit EOA/ERC-1271 encoding conflicts with code existence.
- The signed payload does not bind swap parameters, recipient, payer, or caller. This appears compatible with the extension's design, but periphery contracts must enforce user-facing price, recipient, and payment constraints.
- The owner can set nonce bitmap words directly, including clearing consumed bits, so owner compromise can revive unexpired signatures.

## Scope

Primary file:

- `src/extensions/SignedExclusiveSwap.sol`

Supporting files reviewed:

- `src/interfaces/extensions/ISignedExclusiveSwap.sol`
- `src/libraries/SignedExclusiveSwapLib.sol`
- `src/types/signedSwapMeta.sol`
- `src/types/signedExclusiveSwapPoolState.sol`
- `src/types/controllerAddress.sol`
- `src/types/poolBalanceUpdate.sol`
- `src/types/swapParameters.sol`
- `src/math/fee.sol`
- `src/base/BaseForwardee.sol`
- `src/base/BaseExtension.sol`
- Relevant Core lock, forward, saved-balance, fee-accumulation, and swap paths in `src/Core.sol`, `src/base/FlashAccountant.sol`, and `src/libraries/ExtensionCallPointsLib.sol`
- `test/extensions/SignedExclusiveSwap.t.sol`

Out of scope:

- Economic quality of controller quotes.
- Off-chain quote distribution infrastructure.
- Production periphery contracts not present in the reviewed scope.
- Full Core audit beyond the paths needed to reason about this extension.

## Verification Performed

Focused test command:

```text
forge test --offline --match-contract SignedExclusiveSwapTest
```

Result:

```text
37 passed; 0 failed; 0 skipped
```

Full-suite command:

```text
forge test --offline
```

Result:

```text
853 passed; 0 failed; 0 skipped
```

The focused suite covers EIP-712 digest compatibility, chain-id changes, owner-only initialization and controller changes, invalid controller encodings, direct Core initialization rejection, direct nonce reuse rejection, the max-nonce replay sentinel, authorized locker rejection, deadline-window rejection, expired signatures, invalid signatures, min-balance-update reverts, broadcast validation, ERC-1271 controller use, exact-output meta-fee accounting, and deferred fee donation.

## Architecture Notes

### Pool Creation

`initializePool` is owner-only. It requires the pool key to point to this extension and requires the pool's native fee to be zero. The function then initializes the Core pool from the extension itself, which bypasses `beforeInitializePool` because Core skips the before-initialize hook when the initializer is the extension. The extension records the per-pool controller and current `uint32(block.timestamp)`.

Direct Core pool initialization for this extension is disabled because `beforeInitializePool` always reverts when Core calls it.

### Swap Path

Direct Core swaps are blocked by `beforeSwap`, which always reverts. The intended path is:

1. A locker/periphery obtains a Core lock.
2. The locker forwards calldata to `SignedExclusiveSwap`.
3. `handleForwardData` decodes `(PoolKey, SwapParameters, SignedSwapMeta, PoolBalanceUpdate, bytes signature)`.
4. The extension checks expiry, maximum deadline window, optional locker authorization, and controller signature.
5. The extension accumulates saved fees from prior blocks if needed.
6. The extension calls `CORE.swap` while the current locker is the extension, causing Core to skip the extension's own `beforeSwap` hook.
7. The raw Core balance update must be component-wise greater than or equal to the signed `minBalanceUpdate`.
8. The nonce is consumed unless it is `type(uint64).max`.
9. The signed meta fee is added to the returned balance update and saved in Core saved balances under salt `poolId`.

### Fee Donation

Signed fees are not immediately added to LP fee growth during the same swap. They are saved to the extension's Core saved-balance account. `accumulatePoolFees`, `beforeUpdatePosition`, `beforeCollectFees`, and the next forwarded swap donate the saved balance to LP fees if the pool's `lastUpdateTime` differs from the current `uint32(block.timestamp)`.

`_loadSavedFees` intentionally donates `savedBalance - 1` for each nonzero token balance. This leaves a one-unit dust balance in each token once fees have ever accrued, matching the existing test expectation.

## Intentional Non-Changes

The remediation deliberately did not add pool-initialization or extension-ownership guards to paths whose invalid-pool result is economically a no-op. In particular, `accumulatePoolFees` can be called for a pool without saved fees and will not donate fees or move saved balances. Adding `_requirePoolInitialized`-style checks to that path, or adding `onlyCore` to no-op/reverting hooks such as `beforeSwap`, would increase gas and complexity without protecting funds.

The swap path also does not pre-check nonce availability before fee accumulation or the Core swap. `_consumeNonce` remains the nonce authority, and its placement after the Core swap and `minBalanceUpdate` check preserves the existing behavior described in the source comment: failed or economically unacceptable swaps do not consume the nonce, and the successful path avoids a duplicate nonce bitmap read.

Duplicate broadcasts of the same still-executable signed payload remain allowed. `broadcastSignedSwaps` now filters expired, too-far, and already-consumed non-sentinel nonces, but it does not add event-level replay storage because the event is a quote-distribution aid rather than the swap execution guard.

## Findings

### L-01: Broadcast events could represent unusable signed swaps

Severity: Low
Status: Resolved

Original issue: `broadcastSignedSwaps` only validated that each payload was signed by the pool's current controller before emitting `SignedSwapBroadcasted`. It did not check:

- Whether `meta.deadline()` is expired.
- Whether the deadline is more than `_MAX_DEADLINE_FUTURE_WINDOW` from the current timestamp.
- Whether the nonce was already consumed.

The on-chain swap path already performed the expiry and deadline-window checks and consumed non-sentinel nonces only after a successful Core swap, so this was not a direct swap-safety issue. The risk was that indexers, UIs, market makers, or routers that treated `SignedSwapBroadcasted` as an executable-quote source could display stale or unusable quotes.

Remediation: `broadcastSignedSwaps` now applies the same timing checks used by swaps and rejects already-consumed non-sentinel nonces before emitting. The reusable max nonce remains intentionally broadcastable and executable until expiry. Duplicate broadcasts of a still-executable payload remain possible by design, so off-chain consumers should still deduplicate events.

Relevant code:

- Broadcast validation now calls `_validateMetaForUse` and `_validateNonceAvailable`: `src/extensions/SignedExclusiveSwap.sol:174-180`.
- Swap execution uses `_validateMetaForUse` before execution and relies on `_consumeNonce` after the Core swap, preserving the existing delayed nonce-consumption behavior: `src/extensions/SignedExclusiveSwap.sol:202-204` and `src/extensions/SignedExclusiveSwap.sol:237-240`.
- `_validateNonceAvailable` is used for broadcasts, while `_consumeNonce` remains the swap-path nonce authority: `src/extensions/SignedExclusiveSwap.sol:332-351`.

Recommendation:

Document that repeated broadcasts of the same still-executable quote are allowed and that off-chain consumers should deduplicate by `(poolId, meta, minBalanceUpdate, signature)` or by signed digest.

### L-02: Cached domain separator does not adapt to chain-id changes

Severity: Low
Status: Resolved

Original issue: the constructor computed `_DOMAIN_SEPARATOR` once and stored it as an immutable. The domain includes `block.chainid` and this contract's address. If a chain changed its chain ID after deployment, the extension would have continued validating signatures against the chain ID that existed during deployment.

Remediation: the extension now caches the deployment chain ID and recomputes the domain separator when `block.chainid` differs from the cached value.

Relevant code:

- `_DOMAIN_SEPARATOR` and `_CACHED_CHAIN_ID` are assigned in the constructor: `src/extensions/SignedExclusiveSwap.sol:52-63`.
- `computeDomainSeparatorHash` includes `block.chainid`: `src/libraries/SignedExclusiveSwapLib.sol:41-52`.
- `_validateSignature` hashes with `_domainSeparator()`, which recomputes on chain-id changes: `src/extensions/SignedExclusiveSwap.sol:294-313`.

Recommendation:

No further action required for this issue.

### L-03: Controller address encoding can brick signature validation if misconfigured

Severity: Low
Status: Resolved

Original issue: `ControllerAddress.isEoa` classifies controllers by the top bit of the 160-bit address. Addresses with high bit `0` are validated with `ECDSA.recover`; addresses with high bit `1` are validated through ERC-1271. This is a non-standard encoding and was independent of whether code existed at the address.

Consequences:

- A smart-contract controller whose address has high bit `0` will be treated as an EOA and ERC-1271 signatures will not validate.
- An EOA controller whose address has high bit `1` will be treated as a contract and ECDSA signatures will not validate.
- If accepted, a mistaken owner update could make a pool unable to accept signatures until the owner corrects it.

Remediation: `initializePool` and `setPoolController` now reject zero controllers, low-bit controllers with code, and high-bit controllers without code.

Relevant code:

- High-bit controller classification: `src/types/controllerAddress.sol:11-24`.
- Controller is packed directly into per-pool state: `src/types/signedExclusiveSwapPoolState.sol:25-31`.
- Owner-set controller paths call `_validateController`: `src/extensions/SignedExclusiveSwap.sol:70-79` and `src/extensions/SignedExclusiveSwap.sol:163-168`.
- `_validateController` enforces code-existence consistency with the high-bit encoding: `src/extensions/SignedExclusiveSwap.sol:315-323`.
- Tests cover valid low-bit EOA and high-bit contract-controller addresses, plus invalid controller encodings: `test/extensions/SignedExclusiveSwap.t.sol:548-600` and `test/extensions/SignedExclusiveSwap.t.sol:1002-1030`.

Recommendation:

Document the encoding prominently in deployment and controller-rotation runbooks. For future controller deployments, ensure any intended ERC-1271 controller address satisfies the high-bit encoding before deployment.

### I-01: Signed payload intentionally does not bind swap parameters, payer, recipient, or caller

Severity: Informational

The signed EIP-712 struct is:

```text
SignedSwap(bytes32 poolId,uint256 meta,bytes32 minBalanceUpdate)
```

It does not include `SwapParameters`, payer, recipient, caller, or the full locker address. The extension authorizes any forwarded swap for the pool as long as the raw Core `PoolBalanceUpdate` is component-wise greater than or equal to `minBalanceUpdate`, the optional locker-low-128 authorization passes, and the nonce is available.

This appears aligned with a design where the controller signs pool-side acceptability rather than a full user quote. It does mean user-facing safety must be provided by the locker/periphery:

- exact-input users need output protections in the periphery or swap parameters;
- exact-output users need max-input protection in the periphery or swap parameters;
- the periphery must bind `msg.sender` to the payer and must avoid letting arbitrary callers spend approved funds;
- the periphery must enforce the intended recipient;
- off-chain quote systems must treat a nonzero nonce as globally consumable once any valid swap uses it.

Relevant code:

- Signed type hash omits swap parameters and parties: `src/libraries/SignedExclusiveSwapLib.sol:18-23`.
- Forwarded calldata includes unsigned `PoolKey` and `SwapParameters`: `src/extensions/SignedExclusiveSwap.sol:192-208`.
- The signed threshold checks only raw Core `balanceUpdate`: `src/extensions/SignedExclusiveSwap.sol:229-235`.
- Meta authorization stores and compares only the lower 128 bits of the original locker address, with zero meaning unrestricted: `src/types/signedSwapMeta.sol:6-27`.

Recommendation:

Keep this design only if the controller is meant to sign pool-side minimum economics, not exact user quotes. Document this clearly for integrators. For official periphery, add explicit tests proving that caller, payer, recipient, exact-input minimum output, and exact-output maximum input are enforced outside the extension.

### I-02: Owner-managed nonce bitmap can revive signatures

Severity: Informational

`setNonceBitmap` lets the owner overwrite any nonce word. This can be used to invalidate outstanding signatures by setting bits, but it can also clear consumed bits and make unexpired signatures usable again.

This is not a vulnerability under the current trust model because the owner already controls pool initialization and controller rotation. It is still important for operations and incident response because the owner can alter replay state independently of the controller.

Relevant code:

- Owner-controlled bitmap overwrite: `src/extensions/SignedExclusiveSwap.sol:157-160`.
- Nonce consumption toggles one bit and rejects if the bit was already set: `src/extensions/SignedExclusiveSwap.sol:340-351`.
- Test confirms owner can set a full word: `test/extensions/SignedExclusiveSwap.t.sol:1033-1040`.

Recommendation:

Use append-only or monotonic nonce-management procedures off-chain. If direct replay revival is not needed, consider replacing arbitrary overwrite with narrower owner functions such as `invalidateNonceWord` or `invalidateNonceRange`, or emit a dedicated event that off-chain consumers treat as a quote-state reset.

### I-03: Max nonce is a reusable quote sentinel

Severity: Informational

`type(uint64).max` is never consumed. Any signature using that nonce remains reusable until it expires, the controller changes, or the signed economics stop passing. This is tested behavior and can be useful for standing quotes, but it should not be used where single execution is expected.

Relevant code:

- Max nonce bypass: `src/extensions/SignedExclusiveSwap.sol:340-342`.
- Replay test: `test/extensions/SignedExclusiveSwap.t.sol:428-470`.

Recommendation:

Reserve max nonce for explicit standing quotes. Off-chain systems should visually and operationally distinguish reusable signatures from one-time signatures.

## Confirmed Invariants

The following invariants held under code review and the focused test suite:

- Direct Core initialization is disabled for pools whose extension is `SignedExclusiveSwap`.
- Owner initialization requires the pool key extension to be this contract and Core fee to be zero.
- Direct Core swaps revert because `beforeSwap` always reverts when Core attempts to call it from a non-extension locker.
- Forwarded swaps skip the extension's own `beforeSwap` hook because Core sees the current locker as the extension during `forward`.
- Controller signatures bind `poolId`, `meta`, and `minBalanceUpdate` through the cached EIP-712 domain.
- Non-sentinel nonces are consumed only after the Core swap and `minBalanceUpdate` checks succeed.
- Saved fees are donated at most once per `uint32(block.timestamp)` value per pool.
- LP updates and fee collection trigger pending fee donation before the position operation proceeds.
- Extra signed fees are accounted through Core saved balances, not direct ERC-20 custody in the extension.
- ERC-1271 controllers work when their address has the expected high-bit contract encoding.

## Additional Test Coverage Recommendations

The focused suite was expanded during remediation. Remaining useful additions:

- Official periphery tests, if such periphery exists, proving caller/payer/recipient binding and exact-output max-input protection.
- Fuzz tests over `meta.fee()` near `0`, small values, and near `type(uint32).max` to document rounding and revert behavior in `amountBeforeFee`.
- Tests showing `accumulatePoolFees` leaves one unit of saved-balance dust and eventually donates later accumulated fees as expected.

## Overall Assessment

The extension's core accounting model is coherent: swaps are forced through `forward`, pool-side signed economics are checked before nonce consumption, extra fees accrue to saved balances, and those balances are donated to LP fee growth before later LP-sensitive actions. The code relies on several deliberate but non-obvious conventions: high-bit controller encoding, lower-128-bit locker authorization, globally scoped nonce words, a reusable max-nonce sentinel, and event broadcasts that validate signatures but not current executability.

Those conventions should be explicitly documented for controller infrastructure, periphery authors, indexers, and UIs. With those integration constraints respected, the reviewed implementation did not reveal a direct Critical or High severity vulnerability.
