# Zero-seed launch extension (draft)

Draft for interface freeze. Local deterministic tests only. Nothing here is deployed, audited or approved for release.

`src/extensions/ZeroSeedLaunch.sol` (interface `src/interfaces/extensions/IZeroSeedLaunch.sol`) mints a fixed supply and installs all of it as one token-only concentrated position, from the ask price up to an upper bound, with no quote seed. Buyers fund the only quote reserve. The pool, the position and its liquidity never change after creation. Time only lowers the creator fee.

This replaces the scheduled-release launch design (`ScheduledLaunch`, `LockedLaunchLiquidity`, `LaunchRouter`, staged release, `advance`, `migrate`, terminal pool and funding flows). Those files are deleted from this branch; they remain in its history at `40e5bb1`.

## Core target

The extension builds against this repository's `main` Core: Q0.64 pool fee in the pool config, raw tick spacing. Core runtime compiled from `main` (`98d1be1`) matches the runtime at Base `0x00000000000014aA86C5d3c41765bb24e11bd701` byte for byte (keccak `0xc5f90c9d…c71a`, read at Base block 52,449,112). `next` (Q0.16 fee, power-of-two spacing, pool salt, min-fee swap parameter) does not match the deployed Core and is not targeted.

The pool config fee is always 0. The creator fee is a Q0.64 fraction stored by the extension, so it does not depend on the Core fee encoding. A `next` port would change the pool config construction (`createConcentratedPoolConfig(uint16, uint8 exp, address, uint64 salt)`, power-of-two spacing), the `SwapParameters` layout and the Q0.16 `fee.sol` helpers; the extension would then need its own Q0.64 fee helpers.

## Quote token

The constructor takes `(ICore core, address quote)` and fixes one quote token per deployment as an immutable. `create` and `previewInstallation` refuse every other `parameters.quoteToken` with `UnsupportedQuoteToken`; `quoteToken()` returns the bound address. The constructor refuses the native token (`address(0)`) and an address without code. There is no allowlist, admin, setter, rescue or upgrade.

The reference configuration is plain WETH. Local tests etch the WETH9 runtime read from Base `0x4200000000000000000000000000000000000006` at block 52,449,112 (`test/fixtures/weth9-0x4200-base-52449112.hex`, 2,041 bytes, keccak `0x8a3a1f6a9f9dce633117adee5b458245835a8645a8c8726a26382a4622508b1c`, solc 0.5.17 metadata) with the name, symbol and decimals slots read at the same block. `test/fixtures/weth9.md` binds the pinned source and compiler input: executable bytes reproduce exactly, but the CBOR build metadata does not. The 18/6 vectors use a plain 6-decimal ERC-20 as the constructor quote for math coverage only.

The binding is a trust boundary, not a screen. The contract cannot tell whether the constructor input is a plain token: an instance deployed with a hostile quote (lying balance, outbound tax, rebase, block, callbacks) is exactly as unsafe as an unrestricted extension for that quote (`test_constructorTrust_hostileInstanceStillDrainable`). The deployed instance's runtime, constructor quote, network and deployer are release evidence that does not exist yet. The runtime bytecode hash with immutables zero-filled is not a deployment pin; the deployed runtime embeds `CORE` and the quote address.

## Creation

`create(LaunchParameters)` is called directly. `msg.sender` becomes the creator for good. Inside one Core lock it:

1. validates the parameters, including the quote and the name and symbol lengths, and refuses a token address that already has code;
2. deploys `MintableERC20` with CREATE2, salt `keccak256(abi.encode(creator, parameters.salt))`, so the token address and the token order do not depend on other transactions;
3. initializes the pool `(token0, token1, config(fee 0, tickSpacing, extension))` at the ask;
4. adds `parameters.liquidity` to position `(salt 0, tickLower, tickUpper)` and requires the token amount Core takes, rounded up, to equal `parameters.supply` exactly, with zero quote;
5. mints exactly `supply` to Core between `startPayments` and `completePayments`, which settles the lock, and renounces the mint authority.

Any failure reverts everything. No token, pool or balance is left behind.

Ticks in `LaunchParameters` are economic: log base 1.000001 of raw quote units per raw launch-token unit, so decimals and address order do not change their meaning. For a token0 launch the position is `[askTick, upperTick]` and the pool starts at `askTick`. For a token1 launch it is `[-upperTick, -askTick]` and the pool starts at `-askTick`. Both bounds must be aligned to `tickSpacing`.

Binding the plan: `previewInstallation(creator, parameters)` runs the same validation and token-address check as `create`, then returns the token address, pool key, position, initial tick, the largest liquidity `parameters.supply` buys and the exact supply that liquidity takes (`installedSupply <= supply`). Pass the returned `liquidity` and `installedSupply` as `liquidity` and `supply`. The preview is not idempotent: `maxLiquidity` rounds down twice, so previewing `installedSupply` again usually returns `liquidity - 1`. Bind the pair from one preview; do not iterate.

The preview is installation math at the state it reads, not a dry run. `create` can still fail after it, for example when the transaction is mined after `tradingStart`, or when the same creator creates the same salt and metadata first. Wallets still simulate the `create` call itself.

Refusals:

| Condition | Error |
|---|---|
| quote is not the constructor quote | `UnsupportedQuoteToken` |
| `name` or `symbol` longer than 31 bytes (bytes, not characters; `MintableERC20` packs length and bytes into one word) | `MetadataTooLong` |
| the token address for this creator, salt and metadata already has code (same creator and salt again) | `LaunchTokenExists(token)` |
| `supply == 0` or `supply > int128.max`; `tickSpacing` 0 or above 698,605; `askTick < MIN_TICK`; `upperTick > MAX_TICK`; `askTick >= upperTick` | `InvalidParameters` |
| misaligned bounds | Core `BoundsTickSpacing` |
| `initialFee > floor(2**64 * 99 / 100)` (99%; exactly 100% is not a `uint64`) | `FeeTooHigh` |
| `finalFee > initialFee`, `feeDuration == 0` or `decayFactor == 0` | `InvalidFeeSchedule` |
| `tradingStart < block.timestamp` | `InvalidTradingStart` |
| liquidity 0 | `ZeroLiquidity` |
| liquidity above the per-tick cap of the spacing | `LiquidityAboveTickCap(liquidity, cap)` |
| `supply` is not the exact amount for `liquidity` | `SupplyNotExactlyInstallable(requested, installable)` |

`create` and `previewInstallation` apply every row above except the last two, which need a `liquidity` and apply to `create` only; the preview derives liquidity itself and refuses zero or over-cap liquidity with the same errors.

### Start time

The contract enforces only `tradingStart >= block.timestamp` at creation and `block.timestamp >= tradingStart` for each swap. A start equal to the creation block's timestamp trades in that block. There is no start-delay cap: a start of `type(uint64).max` installs the whole supply with an astronomically distant trading date, effectively locking it indefinitely. A plan built with a start at or near its build time is refused if it is mined after the start (`InvalidTradingStart`), atomically, with nothing left behind. The contract does not move a past start forward.

Producer rule (local reference proposal for the CTO freeze, not a live parameter): bind an explicit future `tradingStart` and an execution expiry with `buildTime + 300 <= tradingStart <= buildTime + 86,400` and `buildTime < expiry <= tradingStart`. This bounds the requested wait to one day from build time, but is not an inclusion guarantee: a transaction submitted before expiry can still be mined after start and revert atomically. Producers and decoders refuse start-now (`tradingStart <= buildTime`), a start below the margin, a start above the cap, and an expiry after the start; they never rewrite a signed start. Boundary vectors are in `test/vectors/zero-seed-launch.json` under `start`.

## Trading

Only `Core.forward(extension, abi.encode(PoolKey, SwapParameters))` trades, returning `abi.encode(PoolBalanceUpdate, PoolState)` that the forwarding locker settles. This is the payload the deployed Base Yul router (`0x03c8…`) sends for a forwarded hop. Direct Core swaps (`SwapsThroughForwardOnly`), other positions (`PositionsThroughCreateOnly`) and other initializations (`InitializeThroughCreateOnly`) are refused by hooks. Before `tradingStart` a forward reverts `TradingNotStarted`. There is no end time and no cutoff.

Every swap's price limit is clamped to the position bounds, so the price stays in `[tickLower, tickUpper]`:

- Before any buy there is no bid. A sell fills zero, pays nothing and moves nothing.
- Buys fill up to the upper bound. An exact-output buy for more than the remaining inventory fills partially; an exact-input buy spends only what fills. Routers refuse the partial fill unless the route allows it (the Yul router's full-fill flag, or `BaseRouter.PartialSwapsDisallowed`).
- Sells can return only real quote paid in earlier and stop at the ask.
- After the upper bound, further buys fill zero.

## Creator fee

`feeAt(t)` is `initialFee` until `tradingStart`, then an exponential rescaled to its endpoints, then `finalFee` from `tradingStart + feeDuration` on. With `Q = 2**64`, `b = decayFactor` (a per-second Q0.64 multiplier in `(0, Q)`, not a half-life), `E = powQ64(b, feeDuration)` and `0 < elapsed < feeDuration`:

```
feeAt = finalFee + floor((initialFee - finalFee) * (powQ64(b, elapsed) - E) / (Q - E))
```

`powQ64` (`src/math/feeDecay.sol`) is square-and-multiply with a floor after every Q64 multiply; its operation order is the reference for every other implementation. The value is `initialFee` at `elapsed == 0`, exactly `finalFee` at `elapsed == feeDuration`, inside `[finalFee, initialFee]` and non-increasing in time for every valid factor. For a nearly flat factor the integer result can sit a few units above the linear chord between the endpoints; the two study factors (about six underlying half-lives over 600 s and 3,600 s) stay under it at every second. The fee is charged on the calculated side of the actual fill:

| Swap | Fee asset | Amount |
|---|---|---|
| exact-input buy | launch token (output) | `ceil(output * fee / 2**64)` deducted from output |
| exact-input sell | quote (output) | same |
| exact-output buy | quote (input) | `ceil(input * 2**64 / (2**64 - fee)) - input` added to input |
| exact-output sell | launch token (input) | same |

The fee is saved in Core under the extension with salt = pool id, separate from the position. `claimFees(poolKey, recipient)` (creator only) withdraws the whole two-asset ledger. It never touches the position.

The recipient must not be zero, Core, the extension, or either pool token (the launch token and the quote); each would strand the fees, and the claim reverts `InvalidRecipient` with the ledger and principal unchanged. The claim is all or nothing over both assets: if either transfer fails, both ledgers stay as they were and the creator can retry to another recipient. There is no one-sided claim. Neither plain WETH nor the launch token calls the recipient, so the tests show the rollback by injecting a failed quote transfer. Fee rights cannot be transferred. The creator can buy and later claim its own fee back, so the fee does not protect buyers from the creator.

Local reference parameters (not live selections): 5% (`922337203685477580`) to 0.3% (`55340232221128654`) over 3,600 s, and 600 s for comparison.

## Events

| Event | Topic |
|---|---|
| `LaunchCreated(PoolId indexed, address indexed token, address indexed creator, PoolKey, PositionId, uint128 liquidity, LaunchParameters)` | `0x9658a825b186d32fc3d164a53e6387b7f6d5e317e624faeac98a5d5ad84c3301` |
| `LaunchSwapped(PoolId indexed, address indexed locker, int128 delta0, int128 delta1, uint64 feeRate, uint128 feeAmount, bool feeIsToken1)` | `0x3e58795f52a8e88efdec2da89ea3798175f8764145ccd7bf5e40633a7d571f6d` |
| `CreatorFeesClaimed(PoolId indexed, address indexed creator, address indexed recipient, uint128 amount0, uint128 amount1)` | `0xda45e5fa280329970441a582e78cff0b8e25a17a5d56e3809ef3e6a0dcc078f5` |

`LaunchSwapped` deltas are fee-inclusive, from the pool's side, as settled by the locker. Principal moves are Core's own swap events. The fee ledger is the running sum of `LaunchSwapped.feeAmount` minus claims.

## Launch token

`MintableERC20` is solady's ERC-20, which gives Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) an infinite allowance from every holder. Permit2 signatures over a launch token can move it without a separate approval.

## Accounting

With Core holding only this launch's tokens:

- launch token: Core balance + all outside balances = `supply`; Core balance >= position amount (rounded down) + token fee ledger.
- quote: Core balance = quote paid in − quote paid out (claims included) >= position amount + quote fee ledger.
- Core rounds every swap in the pool's favour. Two separate metrics, both in raw units:
  - **Core unbooked dust**: Core balance minus the position amount (rounded down) minus the fee ledger, per token, accumulated over every swap. Nobody owns it: it is not creator principal, not creator fees, and no claim reaches it. In the fixed scenarios after exhaustion it is 191 / 94,478,106 / 428,919 / 91 raw launch-token units and 90 / 100 / 86 / 90 raw quote units (t0 18/18, t0 18/6, t1 18/18, t1 18/6). At 18/6 one raw quote unit is about 1e12 raw token units at the ask, so per-swap token rounding is larger. The fuzzed sequences assert it stays below 1e15 raw units (1e-12 of supply).
  - **Upper-bound residue**: launch tokens left in the position before the exhausting buy that the buy does not deliver when it stops at the upper bound: 89 / 89 / 94 / 90 raw launch-token units in the same scenarios. It becomes part of the Core unbooked dust (the tests assert dust after = dust before + residue). It is not a quote amount and not a per-launch constant.
- The position's token amount never exceeds `supply`; its quote amount is never negative.

## Tests and vectors

`test/extensions/ZeroSeedLaunch.t.sol` runs both token orders on the WETH9 fixture (18/18) and a plain 6-decimal quote (18/6) at 18/18 and 18/6 decimals: creation, refusals, bypasses, claims, trading sequences with ledger checks, a fuzzed sequence invariant, the fee schedule at both durations, time-only immutability, the deployed Base Yul router runtime (`test/fixtures/yul-router-0x03c8-base-52449112.hex`) with inclusive deadline, minimum output and partial-fill checks, gas, and frozen canonical vectors. `test/vectors/zero-seed-launch.json` holds the same vectors with an independent integer and real-number reference check.

`test/extensions/ZeroSeedLaunchAdversarial.t.sol` ports the adversarial review tests: unsupported quotes (hostile controller, another plain ERC-20, WETH code at another address, native) refused by create and preview in both orders, integration refusal, the constructor-trust negative control, the nested settlement-snapshot theft failing closed next to a WETH launch, recipient sinks, atomic claim rollback by fault injection, re-entrant claim, metadata and collision refusals, start boundaries, fee signs and conservation from events, bypasses, minter renounce and Permit2, and amount extremes.

`test/extensions/ZeroSeedLaunchFeeCurve.t.sol` is the fee-curve study: schedule properties with Python-pinned digests over every second of both study schedules at six rates, the documented integer-chord counterexamples, fuzzed boundedness and monotonicity over the whole factor and duration domains, executed swaps at 50/75/90/99% and at the highest encodable rate (injected into storage, since `create` refuses it), both exact-output representation limits executed at that rate, the Yul router at the maximum rate, immediate round trips and creator-versus-outsider access against a linear comparator at identical states, and full-swap plus isolated-math gas for both curves.

Every test is a local fixture. None is live evidence.

Run the independent integer/Decimal fee, liquidity, dust and start/expiry vector checks with
`python3 test/vectors/zero-seed-launch-reference.py` (no network or Solidity execution).
