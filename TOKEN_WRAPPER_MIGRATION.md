# Time-locked wrapper migration

`TokenWrapperFactory` is the immutable backing-accounting singleton for the ERC-20 wrappers it deploys. Tokens remain in Core, not in the factory or wrappers. A wrapper can be exchanged 1:1 for a wrapper of the same underlying with a **strictly later** unlock timestamp, including before either wrapper unlocks. This lets a router reach liquidity at a later maturity without first redeeming the underlying.

## Forwarded operations

Within a Core lock, forward to the **source wrapper**, not the factory:

- Wrap: `abi.encode(int256(amount))`.
- Unwrap: `abi.encode(-int256(amount))`; permitted at `block.timestamp >= UNLOCK_TIME`.
- Migrate: `abi.encode(-int256(amount), destinationWrapper)`.

Payloads must be exactly 32 or 64 bytes. Migration requires a positive amount, an already-deployed destination from the same factory, the same underlying, and a strictly later timestamp. Equal timestamps, reverse migration and cross-factory migration are rejected even after maturity. Zero wrap/unwrap remains a no-op; zero migration is rejected. Migration amounts are limited to `type(int128).max` by Core's signed debt interface. Each backing bucket supports up to `type(uint128).max`; overflow reverts atomically.

A migration debits `amount` source wrapper and credits `amount` destination wrapper in the active lock. The locker must settle these debts, using payments/withdrawals or netting against swaps. No underlying-token transfer, redemption or approval is needed for the migration. User-held source tokens still require the usual approval to the paying periphery. See `TokenWrapperPeriphery.migrate` in the tests for a minimal settlement example; it is test scaffolding, not a production router.

## Accounting and authentication

Each backing bucket in Core uses:

- Owner: the factory address.
- Token pair: `(underlying, address(type(uint160).max))`.
- Salt: `bytes32(uint256(uint160(wrapper)))`.

`totalSupply()` reads this bucket. Migration subtracts from the source bucket and adds the exact same integer amount to the destination bucket. Underlying debt cancels. The factory then forwards to the destination to credit its wrapper debt, while the source charges its own wrapper debt. Core enforces settlement at lock exit; an unpaid input, overdraw, overflow or failed payment rolls back the entire operation.

The factory registers only contracts it deploys. It authenticates the source using the original locker supplied by Core, then checks destination registration before reading its immutable metadata. It does not trust externally supplied wrapper metadata or use code hashes. Only factory-originated forwarding can credit a destination without adding backing; the immutable factory makes that call only after moving backing. Direct calls to either forwarded callback are restricted to Core.

All accounting interactions are with Core and factory-deployed wrappers. Neither migration nor its validation calls the underlying token. An untrusted token cannot nominate a wrapper of an unrelated asset as migration output. Ordinary underlying payments remain subject to Core's existing token semantics; rebasing, transfer-tax or dishonest token behavior is not made safe for users choosing that token.

## Compatibility

This changes the wrapper creation bytecode and backing owner/salt. It requires a new factory deployment; existing immutable factories and wrappers are not upgraded or registered retroactively. Existing locked wrappers cannot migrate through this implementation before their old unlock time. After maturity, a router can redeem an old wrapper and wrap its underlying through the new factory in one lock.

ERC-20 metadata, transfer and allowance behavior, the constructor argument list, factory deployment event and ordinary 32-byte wrap/unwrap payload remain unchanged. Wrappers must now be deployed through this factory rather than standalone. `FACTORY()` and `isWrapper(address)` expose membership. `Migrated(source, destination, amount)` records the backing conversion; wallet transfers continue to use the existing Core transfer event semantics.

Integrators must update CREATE2 predictions to the new bytecode, read the new backing owner/salt if bypassing `totalSupply()`, and distinguish factory generations. Routing support should add a directed, exact 1:1 edge only between registered wrappers of the same factory/underlying and increasing maturity. The UI must disclose the later unlock time before obtaining approval for a migration. This PR does not deploy contracts or enable these edges in production routing.

## Verification

Focused checks: `forge test --offline --match-contract 'TokenWrapper.*Test'`.

Coverage includes partial migration and exact maturity redemption, multiple holders/recipients, chain migration, invalid targets, direct callback and singleton authentication, unsettled-debt rollback, allowance failure, signed amount limits, destination backing overflow, native underlying, and a stateful independent cash-flow ledger across transfers, approvals, wrapping, unwrapping and migration. An adversarial underlying payment callback attempts cross-asset migration and then successfully executes a legitimate nested migration of separately held wrapper claims.

Representative isolated cold-call gas snapshots (Solidity 0.8.33, Osaka, repository optimizer settings):

| Operation | Previous | Singleton | Delta |
| --- | ---: | ---: | ---: |
| Deploy wrapper | 1,298,648 | 1,359,427 | +60,779 |
| Wrap | 120,556 | 127,945 | +7,389 |
| Unwrap | 59,366 | 65,814 | +6,448 |
| Migrate partial balance | n/a | 127,641 | new operation |

The extra registration, immutable factory pointer and nested forwarding increase ordinary wrap/unwrap costs in exchange for authenticated backing migration without code-hash validation. Migration gas includes source payment and destination withdrawal. These are test-path measurements, not a claim about every router composition.
