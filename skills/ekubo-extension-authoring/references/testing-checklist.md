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
- Test boundary conditions (zero amounts, first-touch-in-block, repeated calls).

## Forwarded Calls

- Test successful forwarded execution path.
- Test malformed/unauthorized payload reverts.
- Test return values and side effects from `handleForwardData`.

## Commands

Run:

- `forge fmt`
- `forge build --offline`
- `forge test --offline`

Use targeted tests first, then full suite.
