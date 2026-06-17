# Extension Testing Checklist

## Deployment and Registration

- Deploy at callpoint-derived address when matching existing tests:
  - `address(uint160(<callpoints>.toUint8()) << 152)`.
- Assert `core.isExtensionRegistered(address(extension))`.
- Assert enabled hooks execute and disabled hooks are unreachable.

## Initialization and Pool Validation

- Test valid pool initialization path.
- Test wrong pool type/config reverts.
- Test `poolKey.config.extension() != address(this)` reverts where required.

## Hook Safety

- For `onlyCore` hooks, test direct external call reverts.
- For forward-only designs, test direct swap/hook path reverts.
- Test state is unchanged on rejected calls.

## Accounting and State Transitions

- Test per-block or per-call accumulation logic.
- Test saved balance updates and fee donation behavior.
- Test saved-balance bucket separation for each token obligation the extension tracks.
- Test boundary conditions (zero amounts, first-touch-in-block, repeated calls).
- For range-based rewards, test that out-of-range positions do not earn after swaps cross their tick range.
- Test initialized tick reward-outside updates in both price directions, including stableswap active-range boundaries if
  the extension supports stableswap pools.
- Test that funded-but-unassigned tokens remain in the correct Core saved-balance bucket, and that assigning or claiming
  rewards moves only accounting state in the extension.
- If reward or emission policy is external, test funding/configuration separately from allocation. The extension should
  consume its own accumulated accounting state, not query policy during pool actions.

## Forwarded Calls

- Test successful forwarded execution path.
- Test malformed/unauthorized payload reverts.
- Test return values and side effects from `handleForwardData`.
- Verify the extension itself does not custody tokens or transfer ERC20s. Token settlement should happen in the
  locker/periphery around `forward`.
- For forward-only swaps, include tests that direct Core swaps revert and that partial exact-input swaps charge extension
  fees from actual executed input, capped by the fee removed up front.
- For custom swap entrypoints, test the periphery/router path, malformed forwarded payloads, pool ownership validation,
  saved-balance deltas, and returned balance deltas.

## Commands

Run:

- `forge fmt`
- `forge build --offline`
- `forge test --offline`

Use targeted tests first, then full suite.
