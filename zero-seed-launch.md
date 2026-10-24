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

Quote selection is a trust decision about that token, not token screening, and the trust is token-wide rather than pair-local. Core keeps one balance per token for every pool it holds, so a quote that lies about payments or transfers compromises everything that holds it: a lying ERC-20 can fake payment and drain its paired launch token, and the same fake credit withdraws the real quote that other pools' users deposited, including other launches on the same quote and ordinary pools without the extension. Whoever controls the quote's reported Core balance can withdraw all of its real balance through FlashAccountant alone, with no launch involved. An honest token paired with such a quote in an ordinary pool is exposed up to that pool's own reserve. The boundary is per token: a quote credit cannot pay for native ETH or for an unrelated ERC-20, so pools, positions and launches that do not hold the quote keep their balances, principal, state and ledgers. Transfer taxes, rebases, blocked transfers and callbacks likewise break the economics of every pool on that quote. The extension never calls the quote during creation and keys its position, fee ledger and controller by pool ID.

Tests execute a hostile drain alongside native and plain-quote launches on the same extension/periphery and verify their balances, principal, pool state and ledgers remain unchanged; two launches sharing a lying quote, where the attacker's launch claims and sells its way to the honest launch's real quote while native and honest-ERC-20 launches on the same contracts stay intact and tradable; the launch-free FlashAccountant baseline, including the refusal of the quote credit for ETH and honest-ERC-20 withdrawals; and an honest asset in a plain pool paired with the lying quote, bounded by that pool's own reserve. Nested payment-snapshot theft reverts atomically. Selecting a hostile quote does not authorize access to pools that do not hold it. Local math tests use plain 18- and 6-decimal ERC-20s; the reference launch uses native ETH directly.

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
4. computes the installed liquidity from `parameters.supply` (see [Installation math](#installation-math)) and adds it to position `(salt 0, tickLower, tickUpper)`; the rounded-up token debit is `installedSupply <= supply`, with zero quote;
5. mints `installedSupply` to Core between `startPayments` and `completePayments`, settling the lock's debt; mints any `supply - installedSupply` directly to address zero; then renounces the mint authority. This is a sink allocation, not an ERC-20 `_burn`: totalSupply remains exactly the requested value.

Token deployment, the mint that pays for the position and the renunciation all happen inside the forwarded call; the supply goes from the token contract straight into Core, the extension never holds a balance, and the forwarding locker's lock exits with zero debt. Any failure reverts everything. No token, pool or balance is left behind. The periphery records the owner after the lock returns.

Ticks in `LaunchParameters` are economic: log base 1.000001 of raw quote units per raw launch-token unit, so decimals and address order do not change their meaning. For a token0 launch the position is `[askTick, upperTick]` and the pool starts at `askTick`. For a token1 launch (always the case with native ETH) it is `[-upperTick, -askTick]` and the pool starts at `-askTick`. Both bounds must be aligned to `tickSpacing`.

`previewInstallation` returns token address, pool key, position, initial tick, computed liquidity and `installedSupply`. Submit the original requested `supply` unchanged: creation calls the same preview calculation. Liquidity is no longer an input. For the 1-billion-token 18/18 examples, the sink receives 790 base units (token0) or 578 base units (token1). The 18/6 examples sink 697,343,214 or 717,714,600 base units, still less than one billionth of a token. Supported supplies are `1..int128.max`, further constrained by nonzero liquidity and the per-tick cap. The contract rejects unsupported geometry rather than silently capping liquidity and sinking a large excess.

The preview is installation math at the state it reads, not a dry run. Creation can still fail after it, for example when the transaction is mined after `tradingStart`, or when the same owner creates the same salt and metadata first. Wallets still simulate the `create` call itself.

### Installation math

The installed liquidity is the largest integer whose Core debit, rounded up, is at most `supply`; the sink is the part of `supply` below one more liquidity unit. With `lower` and `upper` the position's sqrt ratios as 64.128 fixed-point values (`SqrtRatio.toFixed()` of `tickToSqrtRatio`) and `Q = 2**128`:

| Order | Core debit for `L` (`src/math/delta.sol`, rounded up) | Installed liquidity |
|---|---|---|
| token0 (ERC-20 quote above the token address) | `ceil(ceil(L * Q * (upper - lower) / upper) / lower) = ceil(L * Q * (upper - lower) / (upper * lower))` | `floor(supply * lower * upper / (Q * (upper - lower)))` |
| token1 (native ETH, or a quote below the token address) | `ceil(L * (upper - lower) / Q)` | `floor(supply * Q / (upper - lower))` |

Each formula is the exact inverse of its debit: `debit(L) <= supply < debit(L + 1)` for every supported tick pair and supply. The token1 order is the shared `maxLiquidityForToken1` helper, unchanged. The token0 order is computed in the extension, not the shared `maxLiquidityForToken0` helper: that helper floors `lower * upper / Q` before multiplying by the supply, and at low prices (`lower * upper` far below `Q`) the dropped fraction is worth whole liquidity units, so it installed less than the supply pays for and sank the difference. At ask `-88080384`, upper `-85983232`, spacing 524,288 and supply 1e30 the helper installed 106,052,588,672 liquidity and sank 7.84% of the supply; the exact maximum 115,073,586,432 is affordable and sinks 8,589,236,567,713,153,558 raw units (8.6e-12). With supply 17,380,183,081,064,167,375 at the same ticks the helper installed one unit and sank half; two units cost exactly the supply. Over the full width at spacing 1 with supply 170,141,183,460,469,231,694,794,709,727,778,658,247 the helper was one unit short and sank 18,446,296,994,052,723,740. The fixture geometries (asks `-13815500` and `-41446500`) are unchanged. Consumers that reproduce the preview locally must use the formulas above with exact integers; the shared helper's operation order no longer applies to the token0 order.

On chain the token0 formula uses the compact representation: a `SqrtRatio` is `mantissa * 2**shift` with `2**62 <= mantissa < 2**94` and shift 2, 34, 66 or 98 from its top two bits. Since `lower < upper`, `shiftLower <= shiftUpper` and `upper - lower` is a multiple of `2**shiftLower`, so

```
liquidity = floor(supply * mantissaLower * mantissaUpper / (((upper - lower) >> shiftLower) << (128 - shiftUpper)))
```

with one 512-bit multiply-divide (`FixedPointMathLib.fullMulDiv`). The denominator is `(upper - lower) * 2**(128 - shiftLower - shiftUpper)` exactly, nonzero because `tickToSqrtRatio` is strictly increasing, and below `2**220`; the numerator is below `2**315`; the quotient is below `2**213` for every supported pair, since adjacent ticks at the top of the range maximize `upper * lower / (upper - lower)` below `2**213`, so the division cannot fail. Results at or above `2**128` saturate to `2**128 - 1` and then fail the per-tick cap, exactly as before. A bounded decrement or increment loop around the helper was rejected: the helper's shortfall is `supply * frac / (upper - lower)` units for a dropped fraction `frac < 1`, unbounded in the supply. Measured against the previous revision (same toolchain, `test_gas_creationGeometries`): a token0 preview or creation costs 31 to 347 more gas (the larger figure where `supply * mantissaLower * mantissaUpper` needs the 512-bit path), and 25,057 to 25,373 less where the exact maximum leaves no sink, since the zero-address mint is skipped; token1 previews and creations are unchanged (one geometry differs by 4 gas from code layout). Warm `previewInstallation` costs 19,734 to 23,696 gas and creation 1,274,599 to 1,368,449 gas across the fixtures and boundary geometries in both orders. Current sizes and hashes and the per-geometry gas table are in `test/vectors/zero-seed-launch-installation.json` under `pins`.

Changes at the boundary relative to the helper, both exact rather than silently adjusted: a geometry and supply whose helper result was 0 but whose exact maximum is at least 1 now creates instead of reverting `ZeroLiquidity`; one whose helper result was within the per-tick cap but whose exact maximum exceeds it now reverts `LiquidityAboveTickCap` instead of installing less than the supply pays for.

The sink preserves supply conservation regardless: `totalSupply` is the requested supply and `installedSupply + balanceOf(address(0))` equals it.

The sink mint emits `Transfer(address(0), address(0), remainder)`. Event-only trackers that subtract every transfer to zero as a burn may report `installedSupply` instead of the requested `totalSupply()`. Integrations should use the requested amount in `LaunchCreated` or read `totalSupply()`, and report the inaccessible sink separately. The zero-address allocation is intentional and is not a reduction of ERC-20 total supply.

Refusals:

| Condition | Error |
|---|---|
| `name` or `symbol` longer than 31 bytes (bytes, not characters; `MintableERC20` packs length and bytes into one word) | `MetadataTooLong` |
| the token address for this controller, salt and metadata already has code (same owner and salt again) | `LaunchTokenExists(token)` |
| `supply == 0` or `supply > int128.max`; `tickSpacing` 0 or above 698,605; `askTick < MIN_TICK`; `upperTick > MAX_TICK`; `askTick >= upperTick` | `InvalidParameters` |
| misaligned bounds | Core `BoundsTickSpacing` |
| `finalFee > initialFee` | `InvalidFeeSchedule` (any `decayRateX32`, zero included, is accepted) |
| `initialFee`, `finalFee` or `decayRateX32` of exactly `2**64` | not a `uint64`: the call fails ABI decoding with empty revert data before any logic, through `create`, `previewInstallation` and a raw forwarded create payload alike; nothing is truncated or wrapped |
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

`feeAt(t)` is `initialFee` until `tradingStart`; afterwards the excess over `finalFee` shrinks along the pool's own tick math at a per-launch rate. With `elapsed = t - tradingStart` in whole seconds and `decayRateX32` the launch's rate in ticks per second as unsigned Q32.32:

```
m        = floor(decayRateX32 * elapsed / 2**32)                 # whole ticks accumulated
R(m)     = tickToSqrtRatio(-m).toFixed()                         # ~ 1.000001**(-m/2) in 64.128, compact (rounded down)
feeAt    = finalFee + floor((initialFee - finalFee) * R(m) / 2**128)
```

guarded by, in this order: `decayRateX32 == 0` returns `initialFee` (a flat fee); `elapsed > MAX_DECAY_PRODUCT / decayRateX32` returns `finalFee` (saturation), where `MAX_DECAY_PRODUCT = (88722835 + 1) * 2**32 - 1 = 381061679028371455`. The check is an integer division before any multiplication, so `decayRateX32 * elapsed` is never formed outside its range: within range the product is below `2**59`, `m <= 88722835 = MAX_TICK_MAGNITUDE` fits the helper's `int32`, the Q128 product is below `2**192`, and the floored quotient is at most the excess, so the sum is a `uint64` in `[finalFee, initialFee]`. Any larger `elapsed`, up to `type(uint256).max`, returns `finalFee` without reverting. The operation order is normative for every other implementation (`src/math/feeDecay.sol`, oracle in `test/vectors/zero-seed-launch-reference.py`).

The helper is the standalone `tickToSqrtRatio`, so one tick of decay removes `1 - 1.000001**-0.5 = 5.0e-7` of the excess, and the excess halves every `2 * ln 2 / ln 1.000001 = 1,386,295.054` ticks. Pool tick spacing plays no role. `R(m)` is the compact sqrt ratio (94-bit mantissa, rounded down) converted to 64.128; it is exactly `2**128` at `m = 0`, so a launch whose rate has not yet accumulated one whole tick still charges `initialFee`.

**`finalFee` is a floor, not a scheduled endpoint.** The fee approaches it and lands on it either by rounding (once `floor(excess * R / 2**128)` is zero) or by saturation (once `m` would exceed the helper's range). Neither is a promise about a date: at the default rate the 50% to 0.3% schedule is 25.15% after one day, 12.73% after two, 0.69% after seven, still `0.3% + 8538397665 / 2**64` after 30 days, and exactly 0.3% from the 64th day; at the minimum tick a full-span excess (`2**64 - 1` to 0) still leaves one raw unit, which is why the guard returns `finalFee` rather than clamping to the minimum tick. Four distinct effects, none of them a deadline: rate quantization (Q32.32), tick stepping (the fee only moves when `m` increments, e.g. every 4 s at 1/4 tick/s), output rounding (the final floor), and numerical saturation.

### Decay rate

`decayRateX32` is a `uint64`, unsigned Q32.32 ticks per second: `2**32` is one tick per second, `1` is `2**-32` ticks per second (the first tick after 136 years) and `2**64 - 1` is about 4.29e9 ticks per second (saturated within the first second). Every value is accepted; nothing is validated beyond the type. Zero is a flat fee at `initialFee`; equal `initialFee` and `finalFee` are flat at that value; both fall out of the formula.

Half-life of the excess in seconds: `H = 1386295.0542669557 * 2**32 / decayRateX32`. Rate for a half-life `H`: `floor(1386295.0542669557... * 2**32 / H)`, computed with exact arithmetic (big integers or a high-precision decimal, not binary floating point; a double round-trip of the rate loses the low bits). Consumers should display the half-life and keep the raw rate as a decimal string.

| Half-life | `decayRateX32` | ticks/s | Last second through the helper (`MAX_DECAY_PRODUCT / rate`) |
|---|---|---|---|
| 1 day (default) | `68913100933` | 16.04508164641447365283966064453125 | 5,529,597 (64.0 days) |
| 600 s | `9923486534471` | 2310.37 | 38,399 |
| 8.0225 days (example "2 ticks/s") | `8589934592` | 2 | 44,361,417 |
| 64.18 days | `1073741824` | 0.25 | 354,891,343 |
| 1.89e8 years | `1` | 2**-32 | 381,061,679,028,371,455 |
| 0.32 ns | `18446744073709551615` | 4.29e9 | 0 |

The default `68913100933 = floor(2 * ln 2 / ln 1.000001 * 2**32 / 86400)` has a continuous half-life of 86,400.0000010436 s; at second 86,400 it has accumulated exactly 1,386,295 ticks and the 50% to 0.3% fee is `4639356258918185573 / 2**64 = 25.1500006743%`. The rate is a creation parameter, not a contract constant.

Against the real-number `F + (I - F) * 1.000001**(-(rate / 2**32) * t / 2)` the integer result is within one tick of the excess (below 5.0e-7 of `I - F`; measured 4.99e-7 at second 244 of the default schedule) because `m` is floored; the helper itself is within a few units of `2**-128` of the exact sqrt ratio and the final floor loses less than one raw unit.

The previous revision's fixed 600 s half-life table, its `feeDuration` and its exact endpoint are gone: `decayQ128`, `DECAY_ZERO_FROM` and `gen-fee-decay-table.py` are removed, and the fee reuses the tick helper instead of a second exponentiation. Measured as a warm call minus an identical identity call, the fee costs 585 gas at the start (no helper walk), 760 gas one second in, 1,254 after an hour, 1,384 after a day, 1,600 after 30 days and 1,572 at the last second before saturation, then 124 gas once saturated (`test_gas_isolatedMath`). Warm forwarded buys on the fixture cost 34,294 (t0) and 35,190 (t1 native) gas at the start, 35,505 / 36,401 after an hour, 35,634 / 36,530 after a day and 34,382 / 35,278 once saturated (`test_gas_swapsAcrossWindow`). The extension runtime shrinks from 20,402 to 19,694 bytes (init code 20,892 to 20,184); the periphery runtime is 5,534 bytes (init code 5,754).

The fee is charged on the calculated side of the actual fill:

| Swap | Fee asset | Amount |
|---|---|---|
| exact-input buy | launch token (output) | `ceil(output * fee / 2**64)` deducted from output |
| exact-input sell | quote (output) | same |
| exact-output buy | quote (input) | `ceil(input * 2**64 / (2**64 - fee)) - input` added to input |
| exact-output sell | launch token (input) | same |

### Rate range

`initialFee` and `finalFee` accept every `uint64`, `0..18446744073709551615` inclusive (`MAX_CREATOR_FEE = type(uint64).max`); the only schedule rule is `finalFee <= initialFee`. There is no ceiling below the type: the former 99% limit and its `FeeTooHigh` error are gone. The maximum, `2**64 - 1`, is `1 - 2**-64` of the calculated amount, just under 100%; exactly 100% (`2**64`) is not a `uint64` and cannot be submitted (see the refusals above). Consumers must carry rates as exact integers (decimal strings at API boundaries) and must not describe the maximum as 100%.

At the maximum rate the arithmetic above gives, per swap:

- exact input: `net = floor(gross / 2**64)` and `fee = gross - net`. A fill grossing less than `2**64` raw units of the calculated asset nets zero and is entirely fee; a whole quote unit on the fixture nets 54,160 raw launch-token units (18/18) or 54,158 (18/6). A positive fill with zero net output is still a swap: the buyer pays and receives nothing unless its router enforces a minimum output.
- exact output: `paid = calc * 2**64`, so the fee-inclusive input is representable only while `calc <= 2**63 - 1` (`int128` delta). `calc` in `[2**63, 2**64 - 1]` passes the `uint128` gross-up helper and fails the signed conversion (`SafeCastLib.Overflow`, `0x35278d12`); `calc >= 2**64` fails the helper (`AmountBeforeFeeOverflow`, `0x0d88f526`). Either reverts the whole forwarded swap: pool state, fee ledger, position and Core balances are unchanged and the lock is released. On the fixture the last executable exact-output request is `9147280263567190862134907` raw launch-token units (t0; `9147280263567190861982364` native t1) with `calc = 2**63 - 1` and `paid = 2**127 - 2**64`; the helper limit is first hit at `18145179163502972233172124` (t0; `18145179163502972233028471` native t1).

These bounds are amount-dependent at every rate; routers keep their own maximum-input, minimum-output and full-fill checks. The consumer-side default is 50% to 0.3% with a one-day half-life (`decayRateX32 = 68913100933`); the ceiling is a caller-selectable bound, not a suggested value.

The fee is saved in Core under the extension with salt = pool id, separate from the position. A claim forward moves the whole two-asset ledger onto the controller's lock as a credit; the extension transfers nothing. `ZeroSeedLaunchPeriphery.claimFees(poolKey, recipient)` (owner only) forwards the claim and withdraws both amounts from Core to `recipient` in the same lock, native ETH by Core's plain call. It never touches the position.

The recipient must not be zero, Core, the extension, the periphery or either pool token; each would strand the fees, and the claim reverts `InvalidRecipient` with the ledger and principal unchanged. The claim is all or nothing over both assets: a reverting native recipient or a refused ERC-20 transfer rolls everything back and the owner can retry to another recipient. Because the ledger is moved before Core pays, an owner contract that re-enters `claimFees` while receiving its ETH claims zero. Fee rights move with `transferLaunch`. The owner can buy and later claim its own fee back, so the fee does not protect buyers from the owner.

Local reference parameters (not live selections): 5% (`922337203685477580`) to 0.3% (`55340232221128654`) at the default one-day half-life, and a 600 s half-life (`9923486534471`) for comparison; the fee-curve study executes 50%, 75%, 90%, 99% and the maximum `2**64 - 1`, every one created through the periphery.

## Events

| Contract | Event | Topic |
|---|---|---|
| extension | `LaunchCreated(PoolId indexed, address indexed token, address indexed controller, PoolKey, PositionId, uint128 liquidity, LaunchParameters)` | `0x8f81ce1beb182cad759aa1c797ef027d374f535fd0c08696441c32797c7a5888` |
| extension | `LaunchSwapped(PoolId indexed, address indexed locker, int128 delta0, int128 delta1, uint64 feeRate, uint128 feeAmount, bool feeIsToken1)` | `0x3e58795f52a8e88efdec2da89ea3798175f8764145ccd7bf5e40633a7d571f6d` |
| extension | `CreatorFeesClaimed(PoolId indexed, address indexed controller, uint128 amount0, uint128 amount1)` | `0xf0ffdfa84530baef2e9f8bbb160545a59bfef8da319fa27aa69e4f3c8f05a41d` |
| periphery | `LaunchOwnerChanged(PoolId indexed, address indexed previousOwner, address indexed newOwner)` | `0x478004cf03e8c3b648608ce0259ce479c813aa671a383230ee7763fe5da22391` |
| periphery | `LaunchFeesClaimed(PoolId indexed, address indexed owner, address indexed recipient, uint128 amount0, uint128 amount1)` | `0x908c6b2c19765fe47aef218b4f71ea1a10a9e156d9d5c3500c3a298e01428805` |

`LaunchParameters` is `(string name, string symbol, uint8 decimals, uint128 supply, address quoteToken, int32 askTick, int32 upperTick, uint32 tickSpacing, uint64 tradingStart, uint64 decayRateX32, uint64 initialFee, uint64 finalFee, bytes32 salt)`; the emitted `salt` is the namespaced extension salt. `Launch` (returned by `getLaunch`) is `(address controller, uint64 tradingStart, uint64 decayRateX32, uint64 initialFee, uint64 finalFee, int32 tickLower, int32 tickUpper)`, two storage slots (slot 1 packs the rate, both fees and both ticks exactly). `LaunchSwapped` deltas are fee-inclusive, from the pool's side, as settled by the locker; `locker` is the forwarding locker (a router), not the trader. Principal moves are Core's own swap events. The fee ledger is the running sum of `LaunchSwapped.feeAmount` minus claims.

Selectors: extension `previewInstallation(address,LaunchParameters) 0xb665ec4d`, `feeAt(bytes32,uint256) 0xe81084ec`, `getLaunch(bytes32) 0x7d1d589c`, `creatorFees((address,address,bytes32)) 0xb4ce9a2e`; periphery `create(LaunchParameters) 0xf91810d2`, `previewInstallation(address,LaunchParameters) 0xb665ec4d`, `claimFees((address,address,bytes32),address) 0x6906b4c0`, `transferLaunch(bytes32,address) 0x8b1cb36f`, `launchOwner(bytes32) 0x60ac0b66`, `LAUNCH() 0x096e3c3e`. The full list, with the previous values of everything that changed, is in `test/vectors/zero-seed-launch.json` under `abi`. Relative to the `feeDuration` revision: the creation/preview tuple, `create` and `previewInstallation` selectors, the `LaunchCreated` topic and the `getLaunch` return tuple change (the 10th parameter field and the 3rd record field are now `uint64 decayRateX32`); `feeAt`, `getLaunch` and `creatorFees` selectors, `LaunchSwapped`, `CreatorFeesClaimed`, both periphery events, the forward tags, the swap payload, pool IDs, token addresses for the same metadata and salt, and the `InvalidFeeSchedule` selector are unchanged. Client-side guards that refused `feeDuration == 0` must not refuse a zero rate. Launches created by a previously deployed extension keep that extension's math and ABI; a consumer must dispatch on the extension address. Consumers must distinguish requested total supply from installed inventory and must not rewrite supply to the preview's installed amount.

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

`test/extensions/ZeroSeedLaunch.t.sol` runs both token orders, native ETH (t1, 18/18) and a plain test ERC-20 (t0, 18/18), plus a plain 6-decimal quote (18/6): creation through the periphery, round supply/sink conservation and maximum-liquidity fuzzing, refusals (including the zero, slowest and fastest decay rates created normally), bypasses, claims, trading sequences with ledger checks, a fuzzed sequence invariant, the fee schedule at the default and the 600 s half-life through saturation, time-only immutability, and `test/LaunchTestRouter.sol` in both orders with native value, refunds and ETH payout, inclusive deadline, minimum output and partial-fill checks, gas, and canonical vectors. Router quotes in tests are snapshot/revert executions of the same test contract, not a deployed-router integration. No bytecode fixtures or fixture filesystem permissions are needed. `test/vectors/zero-seed-launch.json` holds the same vectors with an independent integer and real-number reference check.

`test/extensions/ZeroSeedLaunchInstallation.t.sol`: the installation math against Core's own debit in both orders: the low-ask and full-width vectors created through the periphery with Core's plain-pool debit at the installed liquidity and one unit above it, the pinned oracle rows (fixtures, adjacent ticks at both ends of the range, every compact-ratio region crossing, the maximum spacing, supplies of 1 and `int128.max`, both refusals), a full-domain fuzz over spacing, aligned range, supply and order asserting `debit(L) <= supply < debit(L + 1)` or a debit-confirmed refusal, refusal atomicity, and creation gas by geometry. `test/vectors/zero-seed-launch-installation.py` is the independent integer oracle (an exact port of the tick table, Core's rounded debits, a direct big-integer inverse and a binary search on the debit inequality) that generates and checks `test/vectors/zero-seed-launch-installation.json` and sweeps pseudo-random full-domain cases, including supplies at liquidity-quantization boundaries.

`test/extensions/ZeroSeedLaunchAdversarial.t.sol`: per-launch native acceptance and codeless ERC-20 refusal, forged quote/pool refusal, shared-extension hostile-quote isolation, two launches on one lying quote with the launch-free FlashAccountant baseline and the plain-pool reserve bound, nested settlement-snapshot theft failing closed, recipient sinks, atomic claim rollback for a refused ERC-20 transfer and a reverting native recipient, re-entrant native and hostile-quote claims, launch transfer, metadata and collision refusals, start boundaries, fee signs and conservation from events, bypasses, minter renounce and Permit2, amount extremes, forward dispatch, controller identity against a malicious locker, and absence of direct extension entrypoints.

`test/extensions/ZeroSeedLaunchFeeCurve.t.sol`: the guard constant against the helper's actual `InvalidTick` boundary and the one-unit residual at the minimum tick, saturation boundaries for six rates (the fee at `S`, at `S + 1`, at `uint64.max` and `uint256.max` elapsed), tick stepping at 1/4 and 0.1 ticks/s, one-unit and equal-fee flats, the default one-day schedule and the 2 ticks/s example values, fuzzed bounds and monotonicity in time and in rate over the whole uint64 rate and uint256 elapsed domain (also run at 200,000 cases), a fuzzed check against the written-out formula, Python-pinned digests over five sampled schedules, ordinary periphery creation at `2**64 - 1` in both orders with native ETH and plain ERC-20 quotes at 18 and 6 decimals (decaying to 0.3% at the default rate, to zero at the fastest rate, and flat at the maximum at the slowest) with the emitted parameters, stored record and live schedule checked, the exact-100% ABI refusal in either fee word through the periphery and a raw forward, executed swaps at 50/75/90/99% and at the maximum in both orders, both exact-output representation limits executed at the maximum in the ERC-20 and the native order with rollback checked, the test router at the maximum rate in both orders including native value refunds, claims at the maximum against the emitted fee sum, and isolated-math, swap, bytecode and runtime-hash measurements.

Every test is a local fixture. None is live evidence.

Run the independent integer/Decimal fee, liquidity, dust and start/expiry vector checks with `python3 test/vectors/zero-seed-launch-reference.py` (it ports the tick table, the saturation guard and the floors, pins the default rate from `2 ln 2 / ln 1.000001` at 150 digits and measures the error against the real-number curve) and the installation oracle with `python3 test/vectors/zero-seed-launch-installation.py [--sweep N]` (no network or Solidity execution).
