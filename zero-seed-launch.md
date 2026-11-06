# Zero-seed launch contract specification

This document specifies the current source. All tests and vectors are local fixtures, not live-chain evidence. Deployed addresses are in `zero-seed-launch-deployment.md`.

## Contracts and accounting

`src/extensions/ZeroSeedLaunch.sol` installs one immutable, token-only concentrated position with no quote seed. Buyers provide the only quote reserve. Principal cannot be removed. All mutations reach the extension through `Core.forward`; direct initialization, swaps and position updates are refused by hooks. The extension never custodies or transfers tokens. The forwarding locker settles net debt before its Core lock exits.

`src/ZeroSeedLaunchPeriphery.sol` creates launches, records their owners and pays creator fees. It is permissionless and has no administrative owner, upgrade, allowlist or rescue. `claimFees` and `transferLaunch` require the recorded owner. The extension's controller is the authenticated forwarding locker, not a caller-supplied actor; for periphery launches the controller is the periphery. Ownership and controller are deliberately distinct.

The target Core uses Q0.64 pool fees and raw integer tick spacing, compiled with the pinned repository toolchain. Pool config fee is always zero; the extension separately books creator fees in Core saved balances under the pool ID.

## Final input and output

`LaunchParameters` is the fully static eleven-word tuple:

```text
(bytes32 name, bytes32 symbol, uint128 supply, address quoteToken,
 int32 askTick, int32 upperTick, uint64 tradingStart, uint64 decayRateX32,
 uint64 initialFee, uint64 finalFee, bytes32 salt)
```

- `name` and `symbol` are canonical Solady `LibString.packOne` words: the first byte is length **1..31**, the next length bytes are content, and every remaining byte is zero. Empty, invalid length or nonzero tail reverts `InvalidMetadata` in both preview and create. Never truncate. Length is in bytes, not characters. UTF-8 validation is a consumer policy: arbitrary bytes, including embedded zero bytes, round-trip unchanged. `LibString.packOne` assumes the input memory padding; producers must ensure a zero tail rather than accept dirty padding. Canonical words satisfy `packOne(unpackOne(word)) == word`.
- Decimals are always **18**, inherited from Solady ERC20; there is no decimals input.
- `1 <= supply <= 10**30` base units, otherwise `InvalidSupply`, including in preview. ABI type remains `uint128`.
- `quoteToken == address(0)` means native ETH. A nonzero quote must have code, otherwise `UnsupportedQuoteToken`. Quote selection is an explicit token trust decision, not screening.
- `MIN_TICK <= askTick < upperTick <= MAX_TICK`, otherwise `InvalidTicks`.
- `tradingStart >= block.timestamp` at creation and preview, otherwise `InvalidTradingStart`; trading requires `block.timestamp >= tradingStart`. No delay cap is imposed. Producers should bind an explicit future start and expiry; the reference producer policy is a 300-second minimum margin and one-day maximum delay, not a contract constraint or inclusion promise.
- Fees are exact `uint64` Q0.64 fractions. Every value is accepted if `finalFee <= initialFee`, else `InvalidFeeSchedule`. Exactly 100% (`2**64`) is not encodable and fails strict ABI decoding. Rates, supplies and fixed-point integers must cross JSON boundaries as decimal strings, never doubles.

`create(LaunchParameters parameters, string logoUrl)` takes the optional logo as a separate **second argument**; consumers pass `""` when absent. There is no Solidity default argument. `LaunchCreated` emits it as the **last field**, after `parameters`. It is never stored or interpreted, and is absent from preview, CREATE2 identity and pool ID. The contract imposes no URL validation or length cap; gas scales with calldata/log length. Consumers must treat it as untrusted display data, sanitize presentation and avoid unsafe URL fetching.

`Installation` returns `(address token, PoolKey poolKey, PositionId positionId, int32 initialTick, uint128 liquidity, uint128 installedSupply, uint32 tickSpacing, int32 askTick, int32 upperTick)`. The last three fields explicitly report the derived spacing and **installed, aligned economic bounds**, not the original request. The emitted parameters retain the requested bounds. Preview is installation math at its read state, not a dry run or inclusion guarantee.

## Spacing and signed alignment

Economic ticks mean log base 1.000001 of raw quote units per raw launch-token unit, independent of address order. Derive from the original unsnapped ticks, exactly:

```text
width        = upperTick - askTick
tickSpacing  = (width + 255) // 256
alignedAsk   = ceil(askTick / tickSpacing) * tickSpacing
alignedUpper = floor(upperTick / tickSpacing) * tickSpacing
```

`ceil` and `floor` are mathematical signed operations, **not truncation toward zero**. Ask rounds upward, top downward: the position stays inside the requested range and never starts below the requested ask. Each bound moves less than one spacing; actual price movement factors are `1.000001**tickDifference`. For widths at most 256 spacing is 1 and neither bound moves. Otherwise twice the spacing is less than the width, so bounds remain strictly ordered. There is no clamp: the full-domain maximum spacing is **693148**, below Core's 698605 maximum.

| Requested ask → upper | Spacing | Installed ask → upper |
|---|---:|---|
| -13815500 → -9210300 (default ~100×) | 17990 | -13798330 → -9210880 |
| -41446500 → -36841300 (18/6 quote) | 17990 | -41430970 → -36843520 |
| -88722835 → 88722835 (entire domain) | 693148 | -88029796 → 88029796 |
| -88722835 → -88722834 | 1 | unchanged |
| 60000000 → 70000000 | 39063 | 60000768 → 69961833 |
| -70000000 → -60000000 | 39063 | -69961833 → -60000768 |
| -5000001 → 4999999 | 39063 | -4961001 → 4961001 |

For token0 launches pool bounds are `[alignedAsk, alignedUpper]`, starting at the lower bound; for token1 launches they are `[-alignedUpper, -alignedAsk]`, starting at the upper bound. Native ETH always makes the launch token token1. Compact sqrt-ratio rounding differs slightly by address order; installation uses Core's exact integer debit for that order.

### Traversal proof and executable budget

Core's `src/math/tickBitmap.sol` maps a tick to `floor(tick/spacing) + 89421695`, with 256 spacing steps per word. The installed range spans at most 256 steps; hence the only two initialized ticks occupy at most two **adjacent** words in either order. Merely having two initialized ticks would not bound traversal without this spacing constraint.

The extension clamps every swap limit to the installed bounds and overrides the caller's skip-ahead with **1**. A search can therefore read the current word plus one adjacent word and find the relevant bound in a single `findNextInitializedTick`/`findPrevInitializedTick` invocation, rather than charging the swap loop once per empty word. Boundary-start swaps may first cross the starting initialized tick; this does not imply only one search invocation per entire transaction. All searches stay bounded by the same adjacent-word geometry.

`test/extensions/ZeroSeedLaunchFreeze.t.sol::test_widestRange_coldRouter_bothOrders_under2M` creates the widest range at the supply cap through the periphery and executes buys to the economic upper bound plus reverse sells via a real local Core and forwarding `LaunchTestRouter`. It records touched persistent slots, restores the state and explicitly cools each slot/account before execution. Each call is limited to 1.9M execution gas, with a conservative additional 100k transaction-overhead allowance: **2M total test budget**. This is a local realistic budget, not a claim about live chain block limits. Fuzz tests separately prove geometry over the full signed tick domain. Extreme quote amounts or maximum creator fees may require multiple fills or revert on signed-amount limits; bounded traversal is not a guarantee that every economic range and supply is installable or fully fillable with one `int128` amount.

## Installation and fixed supply

Let `lower` and `upper` be Core's compact sqrt ratios converted to 64.128 integers, and `Q = 2**128`. Install the largest integer liquidity whose rounded-up debit fits the requested supply:

| Launch order | Debit for liquidity L | Maximum affordable liquidity |
|---|---|---|
| token0 | `ceil(L * Q * (upper-lower) / (upper*lower))` | `floor(supply * lower * upper / (Q*(upper-lower)))` |
| token1 | `ceil(L * (upper-lower) / Q)` | `floor(supply * Q / (upper-lower))` |

The token0 expression is the exact inverse of Core's nested ceiling. Its implementation factors compact mantissas and shifts and uses one full-precision multiply-divide; the token1 path reuses the shared helper. `debit(L) <= supply < debit(L+1)` is checked against Core's debit and an independent Python integer/binary-search oracle.

Zero liquidity reverts `ZeroLiquidity`. Liquidity above `floor((2**128-1)/(1 + 2*floor(88722835/spacing)))` reverts `LiquidityAboveTickCap(liquidity, cap)`, including results saturating at `uint128.max`. Neither is silently capped. Supply cap acceptance alone does not guarantee installable liquidity. The exact per-order supply envelope for fixed bounds is:

```text
minimumSupply = debit(1)
maximumSupply = min(10**30, debit(tickCap + 1) - 1)
```

If minimum exceeds maximum, that geometry supports no supply. All arithmetic here is unbounded-integer reference arithmetic; do not narrow `tickCap+1` or the reference debit. Machine boundary examples cover narrow, extreme-price, zero-crossing and full-width geometry in `test/vectors/zero-seed-launch-installation.json`.

`LaunchToken` is a separate Solady ERC20; unrelated `MintableERC20` users are untouched. Constructor `(bytes32 name, bytes32 symbol)` records the deploying extension as immutable minter. Its one mint call sends installed supply directly to Core and the remainder to zero while totalSupply is zero; after a positive supply exists minting is permanently closed (`MintClosed`). It has no Ownable or renounce path. The extension validates metadata and positive supply before deploying it. There is no external callback during the mint.

Core payment accounting brackets this single mint. The supply is exactly requested; `Core launch-token balance + outside balances == totalSupply`, including the zero-address sink. The sink is not a burn: its `Transfer(0,0,remainder)` does not reduce totalSupply. Trackers must not subtract it as a burn. Extension and periphery hold no balances.

## Identity, forwarding and events

```text
periphery salt = keccak256(abi.encode(owner, userSalt))
token salt     = keccak256(abi.encode(controller, salt))
token address  = CREATE2(extension, token salt,
                 keccak256(LaunchToken.creationCode ++ abi.encode(name, symbol)))
pool key       = (min(token,quote), max(token,quote), config(fee=0,derivedSpacing,extension))
```

Creation through the periphery emits the once-owner-namespaced salt in `LaunchCreated.parameters.salt`. The second namespace is applied only in CREATE2. Metadata and compiler bytecode affect token address; supply, range, start, fees and logo do not. Pool identity additionally depends on quote and derived spacing.

| Forward action | Payload | Returns / accounting |
|---|---|---|
| create | `abi.encode(CREATE_TAG, LaunchParameters, string logoUrl)` | `abi.encode(Installation)`; no residual lock debt |
| swap | `abi.encode(PoolKey, SwapParameters)` (128 bytes) | `abi.encode(PoolBalanceUpdate, PoolState)`; fee-inclusive deltas |
| claim | `abi.encode(CLAIM_TAG, PoolKey)` | `abi.encode(uint128 amount0,uint128 amount1)` credited to controller lock |

Tags are `keccak256("IZeroSeedLaunch#CREATE")` and `keccak256("IZeroSeedLaunch#CLAIM_FEES")`, both above `2**160`; a swap's address-valued first word cannot alias them. Unknown high tags or payloads shorter than 32 bytes revert `UnknownForwardAction`; known malformed actions fail ABI decoding.

`LaunchCreated(PoolId indexed poolId,address indexed token,address indexed controller,PoolKey poolKey,PositionId positionId,uint128 liquidity,LaunchParameters parameters,string logoUrl)` is the creation event. Other accounting events are `LaunchSwapped`, `CreatorFeesClaimed`, `LaunchOwnerChanged` and `LaunchFeesClaimed`. Compiled ABI, selectors, errors and topics are generated in `test/vectors/zero-seed-launch.json`; full empty/nonempty-logo event topic/data fixtures are in `zero-seed-launch-events.json`. Solidity checks every event field against actual local execution. Event fixtures are untrusted external input for consumers, not instructions.

`Launch` storage is two mapping-value slots: slot 0 has address controller (offset 0) and uint64 tradingStart (offset 20); slot 1 has uint64 decayRateX32 (0), initialFee (8), finalFee (16), int32 lower (24), upper (28). Slot 0 leaves four bytes unused. Removing decay would not remove slot 1. No metadata or logo storage is added to the extension or periphery. Token metadata and deployer are immutable bytecode; ERC20 balances, total supply, allowances and nonces remain Solady storage. Compiler-produced layouts accompany the unsigned packet.

## Fee semantics and claims

Before/at tradingStart charge initialFee. After it, `elapsed = timestamp-start`:

```text
if decayRateX32 == 0: initialFee
elif elapsed > 381061679028371455 // decayRateX32: finalFee
else:
    m = (decayRateX32 * elapsed) >> 32
    fee = finalFee + (((initialFee-finalFee) * tickToSqrtRatio(-m).toFixed()) >> 128)
```

`decayRateX32` is unsigned Q32.32 ticks/second, not linked to spacing. Every uint64 rate is valid. The saturation division precedes multiplication and helper evaluation; `m <= 88722835` within the helper range. The excess approximately halves every 1386295.05426696 ticks. Default one-day half-life rate is **68913100933**; consumer default fees are 50% → 0.3%. The fee after one day is 25.1500006743%. The final fee is a long-run **floor**, not a scheduled endpoint. It is reached by rounding or saturation, not a promised deadline. Quantized ticks, rate precision, output flooring and saturation are distinct effects. The independent Decimal oracle measures error below one tick of the excess (5e-7).

Exact-input fees are `ceil(actual output * fee / 2**64)` deducted from output; exact-output fees gross up actual input as `ceil(input * 2**64 / (2**64-fee)) - input`. At `uint64.max`, small outputs can net zero; gross-up can exceed uint128 or signed int128 limits and revert atomically. Routers enforce minimum output, maximum input, full/partial fill and deadlines. Swaps stop at installed bounds; there is no bid before buyers pay in, and further buys after exhaustion fill zero.

Claims move the complete saved fee ledger to the authenticated controller's lock before Core withdrawals. Periphery recipients cannot be zero, Core, extension, periphery or either pool token (`InvalidRecipient`). Reverting recipients/transfers roll back the entire claim. Reentrant claims see the emptied ledger and cannot claim twice; no blanket reentrancy guard is introduced. Ownership transfer moves all fee rights, including accumulated fees. Creators may buy and recapture their own fees; the fee is not buyer protection against the creator.

An ERC20 quote is untrusted and its risk is token-wide, not pair-local: lying balances can compromise every ledger holding that quote, and paired honest assets up to those pools' own reserves. Native ETH and unrelated ERC20 accounting are isolated. Existing hostile-token, nested-payment and shared-quote regressions remain required. Core unbooked rounding dust is not creator principal or fees and cannot be claimed.

## Verification and deployment

Run `forge fmt --check`, `forge build --offline`, `forge test --offline`, targeted fuzz/accounting suites and `forge snapshot --offline` before committing. Oracle commands: `python3 test/vectors/zero-seed-launch-installation.py --sweep 20000` and `python3 test/vectors/zero-seed-launch-reference.py`. Refresh execution/ABI fixtures from a successful focused log using `zero-seed-launch-freeze.py`.

Deployment inputs are derived with `script/launch-stdjson.py` and `script/launch-packet.py`. Standard-JSON recompilation must reproduce Forge creation code, runtime template and metadata exactly; compiler ASTs label immutable references before runtime hashes are resolved. Any source change produces new bytecode, a new callpoint salt search and a new deployment; existing deployments never change. The Robinhood Chain deployment of this source and its verification steps are recorded in `zero-seed-launch-deployment.md`.
