# Zero-seed launch extension (draft)

Draft for interface freeze. Local deterministic tests only. Nothing here is deployed, audited or approved for release.

`src/extensions/ZeroSeedLaunch.sol` (interface `src/interfaces/extensions/IZeroSeedLaunch.sol`) mints a fixed supply and installs all of it as one token-only concentrated position, from the ask price up to an upper bound, with no quote seed. Buyers fund the only quote reserve. The pool, the position and its liquidity never change after creation. Time only lowers the creator fee.

This replaces the scheduled-release launch design (`ScheduledLaunch`, `LockedLaunchLiquidity`, `LaunchRouter`, staged release, `advance`, `migrate`, terminal pool and funding flows). Those files are deleted from this branch; they remain in its history at `40e5bb1`.

## Core target

The extension builds against this repository's `main` Core: Q0.64 pool fee in the pool config, raw tick spacing. Core runtime compiled from `main` (`98d1be1`) matches the runtime at Base `0x00000000000014aA86C5d3c41765bb24e11bd701` byte for byte (keccak `0xc5f90c9d…c71a`, read at Base block 52,449,112). `next` (Q0.16 fee, power-of-two spacing, pool salt, min-fee swap parameter) does not match the deployed Core and is not targeted.

The pool config fee is always 0. The creator fee is a Q0.64 fraction stored by the extension, so it does not depend on the Core fee encoding. A `next` port would change the pool config construction (`createConcentratedPoolConfig(uint16, uint8 exp, address, uint64 salt)`, power-of-two spacing), the `SwapParameters` layout and the Q0.16 `fee.sol` helpers; the extension would then need its own Q0.64 fee helpers.

## Creation

`create(LaunchParameters)` is called directly. `msg.sender` becomes the creator for good. Inside one Core lock it:

1. validates the parameters;
2. deploys `MintableERC20` with CREATE2, salt `keccak256(abi.encode(creator, parameters.salt))`, so the token address and the token order do not depend on other transactions;
3. initializes the pool `(token0, token1, config(fee 0, tickSpacing, extension))` at the ask;
4. adds `parameters.liquidity` to position `(salt 0, tickLower, tickUpper)` and requires the token amount Core takes, rounded up, to equal `parameters.supply` exactly, with zero quote;
5. mints exactly `supply` to Core between `startPayments` and `completePayments`, which settles the lock, and renounces the mint authority.

Any failure reverts everything. No token, pool or balance is left behind.

Ticks in `LaunchParameters` are economic: log base 1.000001 of raw quote units per raw launch-token unit, so decimals and address order do not change their meaning. For a token0 launch the position is `[askTick, upperTick]` and the pool starts at `askTick`. For a token1 launch it is `[-upperTick, -askTick]` and the pool starts at `-askTick`. Both bounds must be aligned to `tickSpacing`.

Binding the plan: `previewInstallation(creator, parameters)` returns the token address, pool key, position, initial tick, the largest liquidity `parameters.supply` buys and the exact supply that liquidity takes (`installedSupply <= supply`). Pass the returned `liquidity` and `installedSupply` as `liquidity` and `supply`. The preview is not idempotent: `maxLiquidity` rounds down twice, so previewing `installedSupply` again usually returns `liquidity - 1`. Bind the pair from one preview; do not iterate.

Refusals:

| Condition | Error |
|---|---|
| quote is the native token (`address(0)`) or has no code | `UnsupportedQuoteToken` |
| `supply == 0` or `supply > int128.max`; `tickSpacing` 0 or above 698,605; `askTick < MIN_TICK`; `upperTick > MAX_TICK`; `askTick >= upperTick` | `InvalidParameters` |
| misaligned bounds | Core `BoundsTickSpacing` |
| `initialFee > floor(2**64 / 10)` (10%) | `FeeTooHigh` |
| `finalFee > initialFee` or `feeDuration == 0` | `InvalidFeeSchedule` |
| `tradingStart < block.timestamp` | `InvalidTradingStart` |
| liquidity 0 | `ZeroLiquidity` |
| liquidity above the per-tick cap of the spacing | `LiquidityAboveTickCap(liquidity, cap)` |
| `supply` is not the exact amount for `liquidity` | `SupplyNotExactlyInstallable(requested, installable)` |
| same creator and salt again | CREATE2 collision revert |

## Trading

Only `Core.forward(extension, abi.encode(PoolKey, SwapParameters))` trades, returning `abi.encode(PoolBalanceUpdate, PoolState)` that the forwarding locker settles. This is the payload the deployed Base Yul router (`0x03c8…`) sends for a forwarded hop. Direct Core swaps (`SwapsThroughForwardOnly`), other positions (`PositionsThroughCreateOnly`) and other initializations (`InitializeThroughCreateOnly`) are refused by hooks. Before `tradingStart` a forward reverts `TradingNotStarted`. There is no end time and no cutoff.

Every swap's price limit is clamped to the position bounds, so the price stays in `[tickLower, tickUpper]`:

- Before any buy there is no bid. A sell fills zero, pays nothing and moves nothing.
- Buys fill up to the upper bound. An exact-output buy for more than the remaining inventory fills partially; an exact-input buy spends only what fills. Routers refuse the partial fill unless the route allows it (the Yul router's full-fill flag, or `BaseRouter.PartialSwapsDisallowed`).
- Sells can return only real quote paid in earlier and stop at the ask.
- After the upper bound, further buys fill zero.

## Creator fee

`feeAt(t)` is `initialFee` until `tradingStart`, then `initialFee - floor((initialFee - finalFee) * elapsed / feeDuration)`, then `finalFee` from `tradingStart + feeDuration` on. It is charged on the calculated side of the actual fill:

| Swap | Fee asset | Amount |
|---|---|---|
| exact-input buy | launch token (output) | `ceil(output * fee / 2**64)` deducted from output |
| exact-input sell | quote (output) | same |
| exact-output buy | quote (input) | `ceil(input * 2**64 / (2**64 - fee)) - input` added to input |
| exact-output sell | launch token (input) | same |

The fee is saved in Core under the extension with salt = pool id, separate from the position. `claimFees(poolKey, recipient)` (creator only, recipient not zero) withdraws the whole two-asset ledger. It never touches the position. Fee rights cannot be transferred. The creator can buy and later claim its own fee back, so the fee does not protect buyers from the creator.

Local reference parameters (not live selections): 5% (`922337203685477580`) to 0.3% (`55340232221128654`) over 3,600 s, and 600 s for comparison.

## Events

| Event | Topic |
|---|---|
| `LaunchCreated(PoolId indexed, address indexed token, address indexed creator, PoolKey, PositionId, uint128 liquidity, LaunchParameters)` | `0xfe2a763a22e674e13e94ee2f603a671afd54b304fd050776ee150e36370e5dc4` |
| `LaunchSwapped(PoolId indexed, address indexed locker, int128 delta0, int128 delta1, uint64 feeRate, uint128 feeAmount, bool feeIsToken1)` | `0x3e58795f52a8e88efdec2da89ea3798175f8764145ccd7bf5e40633a7d571f6d` |
| `CreatorFeesClaimed(PoolId indexed, address indexed creator, address indexed recipient, uint128 amount0, uint128 amount1)` | `0xda45e5fa280329970441a582e78cff0b8e25a17a5d56e3809ef3e6a0dcc078f5` |

`LaunchSwapped` deltas are fee-inclusive, from the pool's side, as settled by the locker. Principal moves are Core's own swap events. The fee ledger is the running sum of `LaunchSwapped.feeAmount` minus claims.

## Accounting

With Core holding only this launch's tokens:

- launch token: Core balance + all outside balances = `supply`; Core balance >= position amount (rounded down) + token fee ledger.
- quote: Core balance = quote paid in − quote paid out (claims included) >= position amount + quote fee ledger.
- Core rounds every swap in the pool's favour. The difference (dust) is non-negative. In the fixed scenarios it peaks at 94,478,106 raw token units and 100 raw quote units; the fuzzed sequences assert it stays below 1e15 raw units (1e-12 of supply).
- The position's token amount never exceeds `supply`; its quote amount is never negative.

## Tests and vectors

`test/extensions/ZeroSeedLaunch.t.sol` runs both token orders at 18/18 and 18/6 decimals: creation, refusals, bypasses, claims, trading sequences with ledger checks, a fuzzed sequence invariant, the fee schedule at both durations, time-only immutability, the deployed Base Yul router runtime (`test/fixtures/yul-router-0x03c8-base-52449112.hex`) with inclusive deadline, minimum output and partial-fill checks, gas, and frozen canonical vectors. `test/vectors/zero-seed-launch.json` holds the same vectors with an independent integer and real-number reference check.

Every test is a local fixture. None is live evidence.
