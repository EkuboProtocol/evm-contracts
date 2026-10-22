# Zero-seed launch extension (draft)

Draft for interface freeze. Local deterministic tests only. Nothing here is deployed, audited or approved for release.

`src/extensions/ZeroSeedLaunch.sol` (interface `src/interfaces/extensions/IZeroSeedLaunch.sol`) mints the exact requested supply and installs its maximum liquidity as one token-only concentrated position, from the ask price up to an upper bound, with no quote seed. Rounding remainder is minted directly to address zero: `totalSupply` stays round, with no spendable leftover inventory. Buyers fund the only quote reserve. The pool, the position and its liquidity never change after creation. Time only lowers the creator fee.

The extension is forward-only: creation, fee claims and swaps all reach it through `Core.forward`, and it has no external function that moves a token. `src/ZeroSeedLaunchPeriphery.sol` (interface `src/interfaces/IZeroSeedLaunchPeriphery.sol`) is the separate, permissionless, ownerless contract that creates launches for users, records who owns each one, and pays out creator fees. Swaps do not go through the periphery: any locker swaps by forwarding to the extension. Tests use locally compiled Solidity lockers.

This replaces the scheduled-release launch design (`ScheduledLaunch`, `LockedLaunchLiquidity`, `LaunchRouter`, staged release, `advance`, `migrate`, terminal pool and funding flows). Those files are deleted from this branch; they remain in its history at `40e5bb1`.

## Core target

The extension builds against this repository's `main` Core: Q0.64 pool fee in the pool config, raw tick spacing. Core runtime compiled from `main` (`98d1be1`) matches the runtime at Base `0x00000000000014aA86C5d3c41765bb24e11bd701` byte for byte (keccak `0xc5f90c9d…c71a`, read at Base block 52,449,112). `next` (Q0.16 fee, power-of-two spacing, pool salt, min-fee swap parameter) does not match the deployed Core and is not targeted.

The pool config fee is always 0. The creator fee is a Q0.64 fraction stored by the extension, so it does not depend on the Core fee encoding.

## Quote token

The constructor takes `(ICore core)`. Each launch supplies `LaunchParameters.quoteToken`; the quote is part of its pool key and cannot change after creation. One extension supports multiple quotes. No separate quote storage or getter is needed.

`address(0)` is native ETH, Core's own sentinel, and is the intended Base configuration. A native launch needs no ERC-20 code, `decimals()`, approvals or wrapper: the launch token is always token1 (no address is below zero), buyers pay ETH into Core, sells and fee claims are paid in ETH by Core's `withdraw`. Preview and creation refuse a nonzero quote address without code (`UnsupportedQuoteToken`). There is no allowlist, admin, setter, rescue or upgrade.

Quote selection is a pair-local trust decision, not token screening. A lying ERC-20 can fake payment and drain its paired launch token; transfer taxes, rebases, blocked transfers and callbacks can also break that pair's economics. The extension never calls the quote during creation and keys its position, fee ledger and controller by pool ID. Tests execute a hostile drain alongside native and plain-quote launches on the same extension/periphery and verify their balances, principal, pool state and ledgers remain unchanged. Nested payment-snapshot theft reverts atomically. Selecting a hostile quote does not authorize access to unrelated pools. Local math tests use plain 18- and 6-decimal ERC-20s; the reference launch uses native ETH directly.

## Forward schema

Every payload is settled by the forwarding locker inside its own lock. The first word selects the action:

| Action | Payload | Returns | Lock after |
|---|---|---|---|
| swap | `abi.encode(PoolKey, SwapParameters)` (128 bytes; first word `token0 < 2**160`) | `abi.encode(PoolBalanceUpdate, PoolState)` | fee-inclusive deltas as debt |
| create | `abi.encode(ZERO_SEED_LAUNCH_CREATE, LaunchParameters)` | `abi.encode(Installation)` | zero |
| claim fees | `abi.encode(ZERO_SEED_LAUNCH_CLAIM_FEES, PoolKey)` | `abi.encode(uint128 amount0, uint128 amount1)` | credit of both amounts |

`ZERO_SEED_LAUNCH_CREATE = keccak256("IZeroSeedLaunch#CREATE") = 0x224a5a98239f599168b798c4205db155bfff4332b4931a7fb5bc60c2e2eeee30` and `ZERO_SEED_LAUNCH_CLAIM_FEES = keccak256("IZeroSeedLaunch#CLAIM_FEES") = 0xe52d8a05fd0f2d32b280675736d8117fee83069a0eac7ab9279aa52ff05a614c`. Both exceed `2**160`, so a swap payload, whose first word is an address, can never select an action. Any other first word at or above `2**160`, or a payload shorter than 32 bytes, reverts `UnknownForwardAction` before any branch; a first word below `2**160` is decoded strictly as a swap. The swap payload is unchanged from the previous revision.

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
4. computes `maxLiquidity` from `parameters.supply` and adds it to position `(salt 0, tickLower, tickUpper)`; the rounded-up token debit is `installedSupply <= supply`, with zero quote;
5. mints `installedSupply` to Core between `startPayments` and `completePayments`, settling the lock's debt; mints any `supply - installedSupply` directly to address zero; then renounces the mint authority. This is a sink allocation, not an ERC-20 `_burn`: totalSupply remains exactly the requested value.

Token deployment, the mint that pays for the position and the renunciation all happen inside the forwarded call; the supply goes from the token contract straight into Core, the extension never holds a balance, and the forwarding locker's lock exits with zero debt. Any failure reverts everything. No token, pool or balance is left behind. The periphery records the owner after the lock returns.

Ticks in `LaunchParameters` are economic: log base 1.000001 of raw quote units per raw launch-token unit, so decimals and address order do not change their meaning. For a token0 launch the position is `[askTick, upperTick]` and the pool starts at `askTick`. For a token1 launch (always the case with native ETH) it is `[-upperTick, -askTick]` and the pool starts at `-askTick`. Both bounds must be aligned to `tickSpacing`.

`previewInstallation` returns token address, pool key, position, initial tick, computed liquidity and `installedSupply`. Submit the original requested `supply` unchanged: creation calls the same preview calculation. Liquidity is no longer an input. For the 1-billion-token 18/18 examples, the sink receives 790 base units (token0) or 578 base units (token1). The 18/6 examples sink 697,343,214 or 717,714,600 base units, still less than one billionth of a token. Supported supplies are `1..int128.max`, further constrained by nonzero liquidity and the per-tick cap. The contract rejects unsupported geometry rather than silently capping liquidity and sinking a large excess.

The preview is installation math at the state it reads, not a dry run. Creation can still fail after it, for example when the transaction is mined after `tradingStart`, or when the same owner creates the same salt and metadata first. Wallets still simulate the `create` call itself.

`maxLiquidity` is the existing conservative Core math helper, not a promise of a globally exact mathematical maximum: its token0 double-floor can leave one additional liquidity unit affordable in some geometries. No iterative dust correction is performed. The sink preserves supply conservation regardless; consumers must reproduce the helper's operation order rather than optimize the result independently.

The sink mint emits `Transfer(address(0), address(0), remainder)`. Event-only trackers that subtract every transfer to zero as a burn may report `installedSupply` instead of the requested `totalSupply()`. Integrations should use the requested amount in `LaunchCreated` or read `totalSupply()`, and report the inaccessible sink separately. The zero-address allocation is intentional and is not a reduction of ERC-20 total supply.

Refusals:

| Condition | Error |
|---|---|
| `name` or `symbol` longer than 31 bytes (bytes, not characters; `MintableERC20` packs length and bytes into one word) | `MetadataTooLong` |
| the token address for this controller, salt and metadata already has code (same owner and salt again) | `LaunchTokenExists(token)` |
| `supply == 0` or `supply > int128.max`; `tickSpacing` 0 or above 698,605; `askTick < MIN_TICK`; `upperTick > MAX_TICK`; `askTick >= upperTick` | `InvalidParameters` |
| misaligned bounds | Core `BoundsTickSpacing` |
| `finalFee > initialFee` or `feeDuration == 0` | `InvalidFeeSchedule` |
| `initialFee` or `finalFee` of exactly `2**64` (100%) | not a `uint64`: the call fails ABI decoding with empty revert data before any logic, through `create`, `previewInstallation` and a raw forwarded create payload alike; nothing is truncated or wrapped |
| `tradingStart < block.timestamp` | `InvalidTradingStart` |
| liquidity 0 | `ZeroLiquidity` |
| liquidity above the per-tick cap of the spacing | `LiquidityAboveTickCap(liquidity, cap)` |
| non-native quote without code | `UnsupportedQuoteToken` |

Creation and `previewInstallation` apply the same validation and liquidity calculation.

### Start time

The contract enforces only `tradingStart >= block.timestamp` at creation and `block.timestamp >= tradingStart` for each swap. A start equal to the creation block's timestamp trades in that block. There is no start-delay cap: a start of `type(uint64).max` installs the whole supply with an astronomically distant trading date, effectively locking it indefinitely. A plan built with a start at or near its build time is refused if it is mined after the start (`InvalidTradingStart`), atomically, with nothing left behind. The contract does not move a past start forward.

Producer rule (local reference proposal, not a live parameter): bind an explicit future `tradingStart` and an execution expiry with `buildTime + 300 <= tradingStart <= buildTime + 86,400` and `buildTime < expiry <= tradingStart`. This bounds the requested wait to one day from build time, but is not an inclusion guarantee. Boundary vectors are in `test/vectors/zero-seed-launch.json` under `start`.

## Trading

Only `Core.forward(extension, abi.encode(PoolKey, SwapParameters))` trades, returning `abi.encode(PoolBalanceUpdate, PoolState)` that the forwarding locker settles. The test router accepts native ETH as `value`, pays only the actual input and refunds the remainder. Direct Core swaps (`SwapsThroughForwardOnly`), other positions (`PositionsThroughCreateOnly`) and other initializations (`InitializeThroughCreateOnly`) are refused by hooks. Before `tradingStart` a forward reverts `TradingNotStarted`. There is no end time and no cutoff.

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

### Rate range

`initialFee` and `finalFee` accept every `uint64`, `0..18446744073709551615` inclusive (`MAX_CREATOR_FEE = type(uint64).max`); the only schedule rules are `finalFee <= initialFee` and `feeDuration > 0`. There is no ceiling below the type: the former 99% limit and its `FeeTooHigh` error are gone. The maximum, `2**64 - 1`, is `1 - 2**-64` of the calculated amount, just under 100%; exactly 100% (`2**64`) is not a `uint64` and cannot be submitted (see the refusals above). Consumers must carry rates as exact integers (decimal strings at API boundaries) and must not describe the maximum as 100%.

At the maximum rate the arithmetic above gives, per swap:

- exact input: `net = floor(gross / 2**64)` and `fee = gross - net`. A fill grossing less than `2**64` raw units of the calculated asset nets zero and is entirely fee; a whole quote unit on the fixture nets 54,160 raw launch-token units (18/18) or 54,158 (18/6). A positive fill with zero net output is still a swap: the buyer pays and receives nothing unless its router enforces a minimum output.
- exact output: `paid = calc * 2**64`, so the fee-inclusive input is representable only while `calc <= 2**63 - 1` (`int128` delta). `calc` in `[2**63, 2**64 - 1]` passes the `uint128` gross-up helper and fails the signed conversion (`SafeCastLib.Overflow`, `0x35278d12`); `calc >= 2**64` fails the helper (`AmountBeforeFeeOverflow`, `0x0d88f526`). Either reverts the whole forwarded swap: pool state, fee ledger, position and Core balances are unchanged and the lock is released. On the fixture the last executable exact-output request is `9147280263567190862134907` raw launch-token units (t0; `9147280263567190861982364` native t1) with `calc = 2**63 - 1` and `paid = 2**127 - 2**64`; the helper limit is first hit at `18145179163502972233172124` (t0; `18145179163502972233028471` native t1).

These bounds are amount-dependent at every rate; routers keep their own maximum-input, minimum-output and full-fill checks. The 50% to 0.3% over 3,600 s schedule remains the consumer-side default; the ceiling is a caller-selectable bound, not a suggested value.

The fee is saved in Core under the extension with salt = pool id, separate from the position. A claim forward moves the whole two-asset ledger onto the controller's lock as a credit; the extension transfers nothing. `ZeroSeedLaunchPeriphery.claimFees(poolKey, recipient)` (owner only) forwards the claim and withdraws both amounts from Core to `recipient` in the same lock, native ETH by Core's plain call. It never touches the position.

The recipient must not be zero, Core, the extension, the periphery or either pool token; each would strand the fees, and the claim reverts `InvalidRecipient` with the ledger and principal unchanged. The claim is all or nothing over both assets: a reverting native recipient or a refused ERC-20 transfer rolls everything back and the owner can retry to another recipient. Because the ledger is moved before Core pays, an owner contract that re-enters `claimFees` while receiving its ETH claims zero. Fee rights move with `transferLaunch`. The owner can buy and later claim its own fee back, so the fee does not protect buyers from the owner.

Local reference parameters (not live selections): 5% (`922337203685477580`) to 0.3% (`55340232221128654`) over 3,600 s, and 600 s for comparison; the fee-curve study executes 50%, 75%, 90%, 99% and the maximum `2**64 - 1`, every one created through the periphery.

## Events

| Contract | Event | Topic |
|---|---|---|
| extension | `LaunchCreated(PoolId indexed, address indexed token, address indexed controller, PoolKey, PositionId, uint128 liquidity, LaunchParameters)` | `0x3a4e811187f4a8c0b72396e9d7ca13aeed62eb97a599a24af1ed99066041098f` |
| extension | `LaunchSwapped(PoolId indexed, address indexed locker, int128 delta0, int128 delta1, uint64 feeRate, uint128 feeAmount, bool feeIsToken1)` | `0x3e58795f52a8e88efdec2da89ea3798175f8764145ccd7bf5e40633a7d571f6d` |
| extension | `CreatorFeesClaimed(PoolId indexed, address indexed controller, uint128 amount0, uint128 amount1)` | `0xf0ffdfa84530baef2e9f8bbb160545a59bfef8da319fa27aa69e4f3c8f05a41d` |
| periphery | `LaunchOwnerChanged(PoolId indexed, address indexed previousOwner, address indexed newOwner)` | `0x478004cf03e8c3b648608ce0259ce479c813aa671a383230ee7763fe5da22391` |
| periphery | `LaunchFeesClaimed(PoolId indexed, address indexed owner, address indexed recipient, uint128 amount0, uint128 amount1)` | `0x908c6b2c19765fe47aef218b4f71ea1a10a9e156d9d5c3500c3a298e01428805` |

`LaunchParameters` is `(string name, string symbol, uint8 decimals, uint128 supply, address quoteToken, int32 askTick, int32 upperTick, uint32 tickSpacing, uint64 tradingStart, uint32 feeDuration, uint64 initialFee, uint64 finalFee, bytes32 salt)`; the emitted `salt` is the namespaced extension salt. `LaunchSwapped` deltas are fee-inclusive, from the pool's side, as settled by the locker; `locker` is the forwarding locker (a router), not the trader. Principal moves are Core's own swap events. The fee ledger is the running sum of `LaunchSwapped.feeAmount` minus claims.

Selectors: extension `previewInstallation(address,LaunchParameters) 0x917c1163`, `feeAt(bytes32,uint256) 0xe81084ec`, `getLaunch(bytes32) 0x7d1d589c`, `creatorFees((address,address,bytes32)) 0xb4ce9a2e`; periphery `create(LaunchParameters) 0x662af306`, `previewInstallation(address,LaunchParameters) 0x917c1163`, `claimFees((address,address,bytes32),address) 0x6906b4c0`, `transferLaunch(bytes32,address) 0x8b1cb36f`, `launchOwner(bytes32) 0x60ac0b66`, `LAUNCH() 0x096e3c3e`. The full list is in `test/vectors/zero-seed-launch.json` under `abi`. Integrators must update the creation/preview tuple, selectors, constructor and LaunchCreated topic; the old quote getter is removed, and so is the `FeeTooHigh()` error (`0xcd4e6167`): decoders that still carry it never see it, and client-side rate guards must accept the whole `uint64` range. Pool IDs, forwarded swaps, fee claims and Launch storage layout are unchanged. Consumers must distinguish requested total supply from installed inventory and must not rewrite supply to the preview's installed amount.

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

`test/extensions/ZeroSeedLaunch.t.sol` runs both token orders, native ETH (t1, 18/18) and a plain test ERC-20 (t0, 18/18), plus a plain 6-decimal quote (18/6): creation through the periphery, round supply/sink conservation and maximum-liquidity fuzzing, refusals, bypasses, claims, trading sequences with ledger checks, a fuzzed sequence invariant, the fee schedule at both durations, time-only immutability, and `test/LaunchTestRouter.sol` in both orders with native value, refunds and ETH payout, inclusive deadline, minimum output and partial-fill checks, gas, and canonical vectors. Router quotes in tests are snapshot/revert executions of the same test contract, not a deployed-router integration. No bytecode fixtures or fixture filesystem permissions are needed. `test/vectors/zero-seed-launch.json` holds the same vectors with an independent integer and real-number reference check.

`test/extensions/ZeroSeedLaunchAdversarial.t.sol`: per-launch native acceptance and codeless ERC-20 refusal, forged quote/pool refusal, shared-extension hostile-quote isolation, nested settlement-snapshot theft failing closed, recipient sinks, atomic claim rollback for a refused ERC-20 transfer and a reverting native recipient, re-entrant native and hostile-quote claims, launch transfer, metadata and collision refusals, start boundaries, fee signs and conservation from events, bypasses, minter renounce and Permit2, amount extremes, forward dispatch, controller identity against a malicious locker, and absence of direct extension entrypoints.

`test/extensions/ZeroSeedLaunchFeeCurve.t.sol`: the generated table against the generator's constants, cutoffs and aliasing, fuzzed monotonicity and bounds over the whole uint64 rate and uint32 duration domain, the maximum-rate schedule at both duration extremes, Python-pinned digests over every second of both windows at five rates, the per-second deviation from the previous implementation, ordinary periphery creation at `2**64 - 1` in both orders with native ETH and plain ERC-20 quotes at 18 and 6 decimals (decaying to 0.3%, to zero, and flat at the maximum, over 1 s, 3,600 s and `2**32 - 1` s) with the emitted parameters, stored record and live schedule checked, the exact-100% ABI refusal in either fee word through the periphery and a raw forward, executed swaps at 50/75/90/99% and at the maximum in both orders, both exact-output representation limits executed at the maximum in the ERC-20 and the native order with rollback checked, the test router at the maximum rate in both orders including native value refunds, claims at the maximum against the emitted fee sum, and isolated-math, swap, bytecode and runtime-hash measurements.

Every test is a local fixture. None is live evidence.

Run the independent integer/Decimal fee, liquidity, dust and start/expiry vector checks with `python3 test/vectors/zero-seed-launch-reference.py` and regenerate or re-check the table with `python3 test/vectors/gen-fee-decay-table.py` (no network or Solidity execution).
