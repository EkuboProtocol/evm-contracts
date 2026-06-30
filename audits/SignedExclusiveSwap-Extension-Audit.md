# SignedExclusiveSwap Extension Audit

Date: 2026-06-30

Auditor: Codex

## Executive Summary

This review covered `src/extensions/SignedExclusiveSwap.sol` and the directly related signing, state-packing, fee, and test code. No Critical or High severity vulnerabilities were identified in the scoped review.

The extension implements a forward-only swap path for zero-fee pools, where a per-pool controller signs an EIP-712 payload authorizing a minimum pool balance update, a packed fee, an optional authorized locker, a deadline, and a nonce. Extra signed fees are saved under the extension's Core saved-balance account and donated to LP fee growth no more than once per block.

The most important risks are integration and operations risks rather than direct protocol-loss bugs:

- `broadcastSignedSwaps` emits events for signatures that may be expired, already consumed, intentionally replayable, or outside the extension's deadline window.
- The signed payload does not bind swap parameters, recipient, payer, or caller. This appears compatible with the extension's design, but periphery contracts must enforce user-facing price, recipient, and payment constraints.
- Controller addresses use a non-standard high-bit encoding to choose EOA versus ERC-1271 verification. Misconfiguration can make a pool unable to accept signatures until the owner updates the controller.
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
27 passed; 0 failed; 0 skipped
```

The suite covers EIP-712 digest compatibility, owner-only initialization and controller changes, direct Core initialization rejection, direct nonce reuse rejection, the max-nonce replay sentinel, authorized locker rejection, deadline-window rejection, expired signatures, invalid signatures, min-balance-update reverts, event broadcasting, ERC-1271 controller use, and deferred fee donation.

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

## Findings

### L-01: Broadcast events can represent unusable or replayed signed swaps

Severity: Low

`broadcastSignedSwaps` only validates that each payload is signed by the pool's current controller before emitting `SignedSwapBroadcasted`. It does not check:

- Whether `meta.deadline()` is expired.
- Whether the deadline is more than `_MAX_DEADLINE_FUTURE_WINDOW` from the current timestamp.
- Whether the nonce was already consumed.
- Whether the nonce is the reusable max sentinel.
- Whether the same payload has already been broadcast.

The on-chain swap path performs the expiry and deadline-window checks and consumes non-sentinel nonces only after a successful Core swap. Therefore this is not a direct swap-safety issue. The risk is that indexers, UIs, market makers, or routers that treat `SignedSwapBroadcasted` as an executable-quote source can display stale or unusable quotes, or can be spammed with repeated broadcasts of the same valid signature.

Relevant code:

- `broadcastSignedSwaps` validates only `_validateSignature` before emitting: `src/extensions/SignedExclusiveSwap.sol:169-183`.
- Swap execution separately checks expiry and deadline window: `src/extensions/SignedExclusiveSwap.sol:195-198`.
- Nonce consumption happens only during successful swap execution: `src/extensions/SignedExclusiveSwap.sol:231-233`.
- Max nonce is intentionally never consumed: `src/extensions/SignedExclusiveSwap.sol:304-306`.

Recommendation:

Either rename/document the event as "signature-valid only", or make `broadcastSignedSwaps` enforce the same non-state-changing validity checks used by swaps: not expired and not too far in the future. If the event is intended to represent currently executable quotes, also consider rejecting already-consumed nonces and adding an event-level replay guard. If replayed broadcasts are desired, document that off-chain consumers must deduplicate by `(poolId, meta, minBalanceUpdate, signature)` and must independently simulate or validate current executability.

### L-02: Cached domain separator does not adapt to chain-id changes

Severity: Low

The constructor computes `_DOMAIN_SEPARATOR` once and stores it as an immutable. The domain includes `block.chainid` and this contract's address. If a chain changes its chain ID after deployment, the extension will continue validating signatures against the chain ID that existed during deployment.

This is uncommon, but it differs from the defensive EIP-712 pattern that recomputes or invalidates the domain separator when `block.chainid` changes. The practical impact is that signatures made for the old chain ID may remain valid on the same deployed contract after a chain-id migration.

Relevant code:

- `_DOMAIN_SEPARATOR` is assigned in the constructor: `src/extensions/SignedExclusiveSwap.sol:52-61`.
- `computeDomainSeparatorHash` includes `block.chainid`: `src/libraries/SignedExclusiveSwapLib.sol:41-52`.
- `_validateSignature` always hashes with the cached separator: `src/extensions/SignedExclusiveSwap.sol:288-300`.

Recommendation:

If chain-id migration replay resistance is required, store the deployment chain ID and recompute the domain separator when `block.chainid` differs. If the immutable separator is intentional for gas reasons, document that signatures remain bound to the deployment chain ID rather than the current chain ID.

### L-03: Controller address encoding can brick signature validation if misconfigured

Severity: Low

`ControllerAddress.isEoa` classifies controllers by the top bit of the 160-bit address. Addresses with high bit `0` are validated with `ECDSA.recover`; addresses with high bit `1` are validated through ERC-1271. This is a non-standard encoding and is independent of whether code exists at the address.

Consequences:

- A smart-contract controller whose address has high bit `0` will be treated as an EOA and ERC-1271 signatures will not validate.
- An EOA controller whose address has high bit `1` will be treated as a contract and ECDSA signatures will not validate.
- `initializePool` and `setPoolController` do not validate the controller against code existence or zero address, so a mistaken owner update can make a pool unable to accept signatures until the owner corrects it.

This is mainly an operational risk because controller changes are owner-only and recoverable by the owner.

Relevant code:

- High-bit controller classification: `src/types/controllerAddress.sol:11-24`.
- Controller is packed directly into per-pool state: `src/types/signedExclusiveSwapPoolState.sol:25-31`.
- Owner-set controller paths do not validate address class: `src/extensions/SignedExclusiveSwap.sol:68-80` and `src/extensions/SignedExclusiveSwap.sol:159-167`.
- Tests intentionally search for low-bit EOA and high-bit contract-controller addresses: `test/extensions/SignedExclusiveSwap.t.sol:545-619`.

Recommendation:

Document the encoding prominently in deployment and controller-rotation runbooks. Consider adding helper constructors or validation helpers such as `requireEoaController` and `requireContractController` for operational scripts. If gas budget allows, reject `address(0)` and optionally reject obviously mismatched controller classes.

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
- Forwarded calldata includes unsigned `PoolKey` and `SwapParameters`: `src/extensions/SignedExclusiveSwap.sol:185-193`.
- The signed threshold checks only raw Core `balanceUpdate`: `src/extensions/SignedExclusiveSwap.sol:223-229`.
- Meta authorization stores and compares only the lower 128 bits of the original locker address, with zero meaning unrestricted: `src/types/signedSwapMeta.sol:6-27`.

Recommendation:

Keep this design only if the controller is meant to sign pool-side minimum economics, not exact user quotes. Document this clearly for integrators. For official periphery, add explicit tests proving that caller, payer, recipient, exact-input minimum output, and exact-output maximum input are enforced outside the extension.

### I-02: Owner-managed nonce bitmap can revive signatures

Severity: Informational

`setNonceBitmap` lets the owner overwrite any nonce word. This can be used to invalidate outstanding signatures by setting bits, but it can also clear consumed bits and make unexpired signatures usable again.

This is not a vulnerability under the current trust model because the owner already controls pool initialization and controller rotation. It is still important for operations and incident response because the owner can alter replay state independently of the controller.

Relevant code:

- Owner-controlled bitmap overwrite: `src/extensions/SignedExclusiveSwap.sol:154-157`.
- Nonce consumption toggles one bit and rejects if the bit was already set: `src/extensions/SignedExclusiveSwap.sol:304-315`.
- Test confirms owner can set a full word: `test/extensions/SignedExclusiveSwap.t.sol:896-903`.

Recommendation:

Use append-only or monotonic nonce-management procedures off-chain. If direct replay revival is not needed, consider replacing arbitrary overwrite with narrower owner functions such as `invalidateNonceWord` or `invalidateNonceRange`, or emit a dedicated event that off-chain consumers treat as a quote-state reset.

### I-03: Max nonce is a reusable quote sentinel

Severity: Informational

`type(uint64).max` is never consumed. Any signature using that nonce remains reusable until it expires, the controller changes, or the signed economics stop passing. This is tested behavior and can be useful for standing quotes, but it should not be used where single execution is expected.

Relevant code:

- Max nonce bypass: `src/extensions/SignedExclusiveSwap.sol:304-306`.
- Replay test: `test/extensions/SignedExclusiveSwap.t.sol:425-468`.

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

The current focused suite is strong for the main happy path and common reverts. Recommended additions:

- Exact-output swaps with nonzero `meta.fee()` for both token directions.
- `broadcastSignedSwaps` with expired signatures, too-far deadlines, already-consumed nonces, max nonce, and duplicate payloads, documenting whether each behavior is intended.
- Controller misconfiguration cases: zero address, contract address with high bit `0`, and EOA address with high bit `1`.
- Official periphery tests, if such periphery exists, proving caller/payer/recipient binding and exact-output max-input protection.
- Fuzz tests over `meta.fee()` near `0`, small values, and near `type(uint32).max` to document rounding and revert behavior in `amountBeforeFee`.
- Tests showing `accumulatePoolFees` leaves one unit of saved-balance dust and eventually donates later accumulated fees as expected.

## Overall Assessment

The extension's core accounting model is coherent: swaps are forced through `forward`, pool-side signed economics are checked before nonce consumption, extra fees accrue to saved balances, and those balances are donated to LP fee growth before later LP-sensitive actions. The code relies on several deliberate but non-obvious conventions: high-bit controller encoding, lower-128-bit locker authorization, globally scoped nonce words, a reusable max-nonce sentinel, and event broadcasts that validate signatures but not current executability.

Those conventions should be explicitly documented for controller infrastructure, periphery authors, indexers, and UIs. With those integration constraints respected, the reviewed implementation did not reveal a direct Critical or High severity vulnerability.
