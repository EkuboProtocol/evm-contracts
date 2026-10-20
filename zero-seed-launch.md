# Zero-seed launch extension (draft)

Draft for interface freeze. Local deterministic tests only. Nothing here is deployed, audited or approved for release.

`src/extensions/ZeroSeedLaunch.sol` (interface `src/interfaces/extensions/IZeroSeedLaunch.sol`) mints a fixed supply and installs all of it as one token-only concentrated position, from the ask price up to an upper bound, with no quote seed. Buyers fund the only quote reserve. The pool, the position and its liquidity never change after creation. Time only lowers the creator fee.

The extension is forward-only: creation, fee claims and swaps all reach it through `Core.forward`, and it has no external function that moves a token. `src/ZeroSeedLaunchPeriphery.sol` (interface `src/interfaces/IZeroSeedLaunchPeriphery.sol`) is the separate, permissionless, ownerless contract that creates launches for users, records who owns each one, and pays out creator fees. Swaps do not go through the periphery: any locker swaps by forwarding to the extension, which is what the deployed Base Yul router does for a forwarded hop.

This replaces the scheduled-release launch design (`ScheduledLaunch`, `LockedLaunchLiquidity`, `LaunchRouter`, staged release, `advance`, `migrate`, terminal pool and funding flows). Those files are deleted from this branch; they remain in its history at `40e5bb1`.

## Core target

The extension builds against this repository's `main` Core: Q0.64 pool fee in the pool config, raw tick spacing. Core runtime compiled from `main` (`98d1be1`) matches the runtime at Base `0x00000000000014aA86C5d3c41765bb24e11bd701` byte for byte (keccak `0xc5f90c9d…c71a`, read at Base block 52,449,112). `next` (Q0.16 fee, power-of-two spacing, pool salt, min-fee swap parameter) does not match the deployed Core and is not targeted.

The pool config fee is always 0. The creator fee is a Q0.64 fraction stored by the extension, so it does not depend on the Core fee encoding.

## Quote token

The constructor takes `(ICore core, address quote)` and fixes one quote per deployment as an immutable. There is no per-launch quote field: every pool of an instance pairs its launch token with the constructor quote, derived inside the extension. `quoteToken()` returns the bound address.

`address(0)` is native ETH, Core's own sentinel, and is the intended Base configuration. A native instance needs no ERC-20 code, `decimals()`, approvals or wrapper: the launch token is always token1 (no address is below zero), buyers pay ETH into Core, sells and fee claims are paid in ETH by Core's `withdraw`. An ERC-20 quote must be a plain token (no transfer fee, rebase, callback, pause, blocklist, upgrade or misreported balance); the constructor refuses an ERC-20 address without code (`UnsupportedQuoteToken`). There is no allowlist, admin, setter, rescue or upgrade.

The binding is a trust boundary, not a screen. The contract cannot tell whether an ERC-20 constructor input is a plain token: an instance deployed with a hostile quote is exactly as unsafe as an unrestricted extension for that quote (`test_constructorTrust_hostileInstanceStillDrainable`). The runtime bytecode hash with immutables zero-filled is not a deployment pin; the deployed runtime embeds `CORE` and the quote address. Local tests run the native quote and, for the other token order, the WETH9 runtime read from Base `0x4200000000000000000000000000000000000006` at block 52,449,112 (`test/fixtures/weth9-0x4200-base-52449112.hex`); the 18/6 vectors use a plain 6-decimal ERC-20 for math coverage only.

## Forward schema

Every payload is settled by the forwarding locker inside its own lock. The first word selects the action:

| Action | Payload | Returns | Lock after |
|---|---|---|---|
| swap | `abi.encode(PoolKey, SwapParameters)` (128 bytes; first word `token0 < 2**160`) | `abi.encode(PoolBalanceUpdate, PoolState)` | fee-inclusive deltas as debt |
| create | `abi.encode(ZERO_SEED_LAUNCH_CREATE, LaunchParameters)` | `abi.encode(Installation)` | zero |
| claim fees | `abi.encode(ZERO_SEED_LAUNCH_CLAIM_FEES, PoolKey)` | `abi.encode(uint128 amount0, uint128 amount1)` | credit of both amounts |

`ZERO_SEED_LAUNCH_CREATE = keccak256("IZeroSeedLaunch#CREATE") = 0x224a5a98239f599168b798c4205db155bfff4332b4931a7fb5bc60c2e2eeee30` and `ZERO_SEED_LAUNCH_CLAIM_FEES = keccak256("IZeroSeedLaunch#CLAIM_FEES") = 0xe52d8a05fd0f2d32b280675736d8117fee83069a0eac7ab9279aa52ff05a614c`. Both exceed `2**160`, so a swap payload, whose first word is an address, can never select an action. Any other first word at or above `2**160`, or a payload shorter than 32 bytes, reverts `UnknownForwardAction` before any branch; a first word below `2**160` is decoded strictly as a swap. The swap payload is unchanged from the previous revision, so the Yul router's forwarded hop needs no change.

### Identity

The extension never reads an actor from a payload. The **controller** of a launch is `Locker.addr()` of the locker that forwarded the creation, as Core authenticates it: `forward` is locker-only and passes the calling locker to the forwardee. The controller is the only locker whose claim forward succeeds (`ControllerOnly`), and it is part of the token's CREATE2 salt, so two controllers never share a token address or a pool. A malicious locker can create its own launches and claim its own fees, nothing else (`test_impersonation_controllerIsTheLocker`).

The **owner** is the periphery's notion. The periphery is the controller of every launch created through it; it stores `launchOwner[poolId] = msg.sender` at creation, gates `claimFees` and `transferLaunch` on it, and emits `LaunchOwnerChanged`. Fee rights follow the owner, including unclaimed fees at transfer time. Indexers attribute creators from the periphery's `LaunchOwnerChanged(poolId, 0, owner)`, and the controller from the extension's `LaunchCreated`.

### Address prediction

```
periphery salt   = keccak256(abi.encode(owner, userSalt))
extension salt   = keccak256(abi.encode(controller, salt))        // controller = periphery for periphery launches
token            = CREATE2(extension, extension salt, keccak256(MintableERC20.creationCode ++ abi.encode(extension, name, symbol, decimals)))
pool key         = (min(token, quote), max(token, quote), config(fee 0, tickSpacing, extension))
```

`ZeroSeedLaunchPeriphery.previewInstallation(owner, parameters)` applies both levels and returns the extension's preview.

## Creation

`ZeroSeedLaunchPeriphery.create(LaunchParameters)` namespaces the salt, takes one Core lock and forwards the create payload. Inside the forwarded call the extension:

1. validates the parameters, including the name and symbol lengths, and refuses a token address that already has code;
2. deploys `MintableERC20` with CREATE2 (salt above), so the token address and the token order do not depend on other transactions;
3. initializes the pool `(token0, token1, config(fee 0, tickSpacing, extension))` at the ask;
4. adds `parameters.liquidity` to position `(salt 0, tickLower, tickUpper)` and requires the token amount Core takes, rounded up, to equal `parameters.supply` exactly, with zero quote;
5. mints exactly `supply` to Core between `startPayments` and `completePayments`, which settles the lock's debt, and renounces the mint authority.

Token deployment, the mint that pays for the position and the renunciation all happen inside the forwarded call; the supply goes from the token contract straight into Core, the extension never holds a balance, and the forwarding locker's lock exits with zero debt. Any failure reverts everything. No token, pool or balance is left behind. The periphery records the owner after the lock returns.

Ticks in `LaunchParameters` are economic: log base 1.000001 of raw quote units per raw launch-token unit, so decimals and address order do not change their meaning. For a token0 launch the position is `[askTick, upperTick]` and the pool starts at `askTick`. For a token1 launch (always the case with native ETH) it is `[-upperTick, -askTick]` and the pool starts at `-askTick`. Both bounds must be aligned to `tickSpacing`.

Binding the plan: `previewInstallation` runs the same validation and token-address check as creation, then returns the token address, pool key, position, initial tick, the largest liquidity `parameters.supply` buys and the exact supply that liquidity takes (`installedSupply <= supply`). Pass the returned `liquidity` and `installedSupply` as `liquidity` and `supply`. The preview is not idempotent: `maxLiquidity` rounds down twice, so previewing `installedSupply` again usually returns `liquidity - 1`. Bind the pair from one preview; do not iterate. Preview and creation share the same pure geometry and supply helpers with the same inputs, so they agree exactly.

The preview is installation math at the state it reads, not a dry run. Creation can still fail after it, for example when the transaction is mined after `tradingStart`, or when the same owner creates the same salt and metadata first. Wallets still simulate the `create` call itself.

Refusals:

| Condition | Error |
|---|---|
| `name` or `symbol` longer than 31 bytes (bytes, not characters; `MintableERC20` packs length and bytes into one word) | `MetadataTooLong` |
| the token address for this controller, salt and metadata already has code (same owner and salt again) | `LaunchTokenExists(token)` |
| `supply == 0` or `supply > int128.max`; `tickSpacing` 0 or above 698,605; `askTick < MIN_TICK`; `upperTick > MAX_TICK`; `askTick >= upperTick` | `InvalidParameters` |
| misaligned bounds | Core `BoundsTickSpacing` |
| `initialFee > floor(2**64 * 99 / 100)` (99%; exactly 100% is not a `uint64`) | `FeeTooHigh` |
| `finalFee > initialFee` or `feeDuration == 0` | `InvalidFeeSchedule` |
| `tradingStart < block.timestamp` | `InvalidTradingStart` |
| liquidity 0 | `ZeroLiquidity` |
| liquidity above the per-tick cap of the spacing | `LiquidityAboveTickCap(liquidity, cap)` |
| `supply` is not the exact amount for `liquidity` | `SupplyNotExactlyInstallable(requested, installable)` |

Creation and `previewInstallation` apply every row above except the last two, which need a `liquidity` and apply to creation only; the preview derives liquidity itself and refuses zero or over-cap liquidity with the same errors.

### Start time

The contract enforces only `tradingStart >= block.timestamp` at creation and `block.timestamp >= tradingStart` for each swap. A start equal to the creation block's timestamp trades in that block. There is no start-delay cap: a start of `type(uint64).max` installs the whole supply with an astronomically distant trading date, effectively locking it indefinitely. A plan built with a start at or near its build time is refused if it is mined after the start (`InvalidTradingStart`), atomically, with nothing left behind. The contract does not move a past start forward.

Producer rule (local reference proposal, not a live parameter): bind an explicit future `tradingStart` and an execution expiry with `buildTime + 300 <= tradingStart <= buildTime + 86,400` and `buildTime < expiry <= tradingStart`. This bounds the requested wait to one day from build time, but is not an inclusion guarantee. Boundary vectors are in `test/vectors/zero-seed-launch.json` under `start`.

## Trading

Only `Core.forward(extension, abi.encode(PoolKey, SwapParameters))` trades, returning `abi.encode(PoolBalanceUpdate, PoolState)` that the forwarding locker settles. This is the payload the deployed Base Yul router (`0x03c8…`) sends for a forwarded hop, with native ETH as `address(0)` attached as `value` and the unspent part refunded; the tests run that runtime in both orders. Direct Core swaps (`SwapsThroughForwardOnly`), other positions (`PositionsThroughCreateOnly`) and other initializations (`InitializeThroughCreateOnly`) are refused by hooks. Before `tradingStart` a forward reverts `TradingNotStarted`. There is no end time and no cutoff.

Every swap's price limit is clamped to the position bounds, so the price stays in `[tickLower, tickUpper]`:

- Before any buy there is no bid. A sell fills zero, pays nothing and moves nothing.
- Buys fill up to the upper bound. An exact-output buy for more than the remaining inventory fills partially; an exact-input buy spends only what fills. Routers refuse the partial fill unless the route allows it.
- Sells can return only real quote paid in earlier and stop at the ask.
- After the upper bound, further buys fill zero.

## Creator fee

`feeAt(t)` is `initialFee` until `tradingStart`, then a 600 second half-life exponential rescaled to its endpoints, then `finalFee` from `tradingStart + feeDuration` on. With `D = feeDuration`, `E = decay(D)` and `0 < elapsed < D`:

```
decay(t) = 2**(-t/600) in Q128
feeAt    = finalFee + floor((initialFee - finalFee) * (decay(elapsed) - E) / (2**128 - E))
```

`decay` (`decayQ128` in `src/math/feeDecay.sol`) is built like `tickToSqrtRatio`: one constant `round(2**128 * 2**(-2**i/600))` per exponent bit, multiplied in and floored to Q128 for every set bit of the integer seconds, starting from `2**128`. The 17 nonzero constants cover bits 0 to 16; the result is zero for every `t >= 2**17` (`DECAY_ZERO_FROM`, an explicit cutoff, because higher bits have no constant and would otherwise alias), and the chain itself reaches zero at 76,800 s. The constants are generated by `test/vectors/gen-fee-decay-table.py`, adapted from the tick-math generator in starknet-contracts (`scripts/codegen/gen-tick-math.ts`, commit `48d8653`), which also checks exhaustively that `decay` never increases over `[0, 2**17]` and is within 4 units of `2**-128` of the real value. The operation order is normative for every other implementation. The fee is `initialFee` at `elapsed == 0`, exactly `finalFee` at `elapsed == D`, inside `[finalFee, initialFee]` and non-increasing in time.

The base is fixed; there is no per-launch decay factor. The previous revision raised a per-launch Q0.64 factor by square-and-multiply, computing two variable-base powers per fee. At the factor it was given for the canonical window, `floor(2**64 * 2**(-1/600))`, the table reproduces the 50% to 0.3% over 3,600 s curve within 120 units of `2**-64` (about 6.5e-18 absolute) at every second, with identical endpoints. Windows other than 3,600 s now follow the same 600 s half-life rescaled to their endpoints instead of a factor chosen per launch; for windows beyond about 10.7 hours the scaled term floors to zero before `D`, so the fee sits at `finalFee` early. Measured as a warm call minus an identical identity call, the table costs 921 to 1,372 gas per fee across the window against 1,905 to 3,276 for the previous implementation (`test_gas_isolatedMath_tableVersusLegacy`).

The fee is charged on the calculated side of the actual fill:

| Swap | Fee asset | Amount |
|---|---|---|
| exact-input buy | launch token (output) | `ceil(output * fee / 2**64)` deducted from output |
| exact-input sell | quote (output) | same |
| exact-output buy | quote (input) | `ceil(input * 2**64 / (2**64 - fee)) - input` added to input |
| exact-output sell | launch token (input) | same |

The fee is saved in Core under the extension with salt = pool id, separate from the position. A claim forward moves the whole two-asset ledger onto the controller's lock as a credit; the extension transfers nothing. `ZeroSeedLaunchPeriphery.claimFees(poolKey, recipient)` (owner only) forwards the claim and withdraws both amounts from Core to `recipient` in the same lock, native ETH by Core's plain call. It never touches the position.

The recipient must not be zero, Core, the extension, the periphery or either pool token; each would strand the fees, and the claim reverts `InvalidRecipient` with the ledger and principal unchanged. The claim is all or nothing over both assets: a reverting native recipient or a refused ERC-20 transfer rolls everything back and the owner can retry to another recipient. Because the ledger is moved before Core pays, an owner contract that re-enters `claimFees` while receiving its ETH claims zero. Fee rights move with `transferLaunch`. The owner can buy and later claim its own fee back, so the fee does not protect buyers from the owner.

Local reference parameters (not live selections): 5% (`922337203685477580`) to 0.3% (`55340232221128654`) over 3,600 s, and 600 s for comparison; the fee-curve study executes 50%, 75%, 90%, 99% and the injected maximum.

## Events

| Contract | Event | Topic |
|---|---|---|
| extension | `LaunchCreated(PoolId indexed, address indexed token, address indexed controller, PoolKey, PositionId, uint128 liquidity, LaunchParameters)` | `0x085ada2e6f98dc43ec420caff7f39c25cbc16c81595684b19c4fca014dae5f2d` |
| extension | `LaunchSwapped(PoolId indexed, address indexed locker, int128 delta0, int128 delta1, uint64 feeRate, uint128 feeAmount, bool feeIsToken1)` | `0x3e58795f52a8e88efdec2da89ea3798175f8764145ccd7bf5e40633a7d571f6d` |
| extension | `CreatorFeesClaimed(PoolId indexed, address indexed controller, uint128 amount0, uint128 amount1)` | `0xf0ffdfa84530baef2e9f8bbb160545a59bfef8da319fa27aa69e4f3c8f05a41d` |
| periphery | `LaunchOwnerChanged(PoolId indexed, address indexed previousOwner, address indexed newOwner)` | `0x478004cf03e8c3b648608ce0259ce479c813aa671a383230ee7763fe5da22391` |
| periphery | `LaunchFeesClaimed(PoolId indexed, address indexed owner, address indexed recipient, uint128 amount0, uint128 amount1)` | `0x908c6b2c19765fe47aef218b4f71ea1a10a9e156d9d5c3500c3a298e01428805` |

`LaunchParameters` is `(string name, string symbol, uint8 decimals, uint128 supply, uint128 liquidity, int32 askTick, int32 upperTick, uint32 tickSpacing, uint64 tradingStart, uint32 feeDuration, uint64 initialFee, uint64 finalFee, bytes32 salt)`; the emitted `salt` is the namespaced extension salt. `LaunchSwapped` deltas are fee-inclusive, from the pool's side, as settled by the locker; `locker` is the forwarding locker (a router), not the trader. Principal moves are Core's own swap events. The fee ledger is the running sum of `LaunchSwapped.feeAmount` minus claims.

Selectors: extension `quoteToken() 0x217a4b70`, `previewInstallation(address,LaunchParameters) 0x42b9fe08`, `feeAt(bytes32,uint256) 0xe81084ec`, `getLaunch(bytes32) 0x7d1d589c`, `creatorFees((address,address,bytes32)) 0xb4ce9a2e`; periphery `create(LaunchParameters) 0x687ba810`, `previewInstallation(address,LaunchParameters) 0x42b9fe08`, `claimFees((address,address,bytes32),address) 0x6906b4c0`, `transferLaunch(bytes32,address) 0x8b1cb36f`, `launchOwner(bytes32) 0x60ac0b66`, `LAUNCH() 0x096e3c3e`. The full list is in `test/vectors/zero-seed-launch.json` under `abi`.

## Launch token

`MintableERC20` is solady's ERC-20, which gives Permit2 (`0x000000000022D473030F116dDEE9F6B43aC78BA3`) an infinite allowance from every holder. Permit2 signatures over a launch token can move it without a separate approval.

## Accounting

With Core holding only this launch's tokens:

- launch token: Core balance + all outside balances = `supply`; Core balance >= position amount (rounded down) + token fee ledger.
- quote (ETH or ERC-20): Core balance = quote paid in − quote paid out (claims included) >= position amount + quote fee ledger.
- the extension and the periphery hold no balance of either asset at any point; neither accepts ETH.
- Core rounds every swap in the pool's favour. Two separate metrics, both in raw units:
  - **Core unbooked dust**: Core balance minus the position amount (rounded down) minus the fee ledger, per token, accumulated over every swap. Nobody owns it: it is not creator principal, not creator fees, and no claim reaches it. The fuzzed sequences assert it stays below 1e15 raw units (1e-12 of supply).
  - **Upper-bound residue**: launch tokens left in the position before the exhausting buy that the buy does not deliver when it stops at the upper bound. It becomes part of the Core unbooked dust (the tests assert dust after = dust before + residue).
- The position's token amount never exceeds `supply`; its quote amount is never negative.

## Tests and vectors

`test/extensions/ZeroSeedLaunch.t.sol` runs both token orders, native ETH (t1, 18/18) and the WETH9 fixture (t0, 18/18), plus a plain 6-decimal quote (18/6): creation through the periphery, refusals, bypasses, claims, trading sequences with ledger checks, a fuzzed sequence invariant, the fee schedule at both durations, time-only immutability, the deployed Base Yul router runtime (`test/fixtures/yul-router-0x03c8-base-52449112.hex`) in both orders with native value, refunds and ETH payout, inclusive deadline, minimum output and partial-fill checks, gas, and frozen canonical vectors. `test/vectors/zero-seed-launch.json` holds the same vectors with an independent integer and real-number reference check.

`test/extensions/ZeroSeedLaunchAdversarial.t.sol`: constructor acceptance of native and refusal of codeless ERC-20s, integration refusal of other quotes, the constructor-trust negative control, the nested settlement-snapshot theft failing closed, recipient sinks, atomic claim rollback for a refused ERC-20 transfer and a reverting native recipient, re-entrant native and hostile-quote claims, launch transfer, metadata and collision refusals, start boundaries, fee signs and conservation from events, bypasses, minter renounce and Permit2, amount extremes, forward dispatch (action tags, unknown and malformed payloads), controller identity against a malicious locker, and the absence of direct extension entrypoints.

`test/extensions/ZeroSeedLaunchFeeCurve.t.sol`: the generated table against the generator's constants, cutoffs and aliasing, fuzzed monotonicity and bounds over the whole duration domain, Python-pinned digests over every second of both windows at five rates, the per-second deviation from the previous implementation, executed swaps at 50/75/90/99% and at the highest encodable rate (injected into storage, since creation refuses it) in both orders, both exact-output representation limits executed at that rate, the Yul router at the maximum rate, and isolated-math, swap and bytecode measurements.

Every test is a local fixture. None is live evidence.

Run the independent integer/Decimal fee, liquidity, dust and start/expiry vector checks with `python3 test/vectors/zero-seed-launch-reference.py` and regenerate or re-check the table with `python3 test/vectors/gen-fee-decay-table.py` (no network or Solidity execution).
