// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {PoolKey} from "../../types/poolKey.sol";
import {PoolId} from "../../types/poolId.sol";
import {PositionId} from "../../types/positionId.sol";

/// @dev Forward action tags. Derived as uint256(keccak256("IZeroSeedLaunch#CREATE")) and
/// uint256(keccak256("IZeroSeedLaunch#CLAIM_FEES")). Both exceed 2**160, so the first word of a swap payload, which
/// is `PoolKey.token0` and therefore below 2**160, can never select an action.
uint256 constant ZERO_SEED_LAUNCH_CREATE = 0x224a5a98239f599168b798c4205db155bfff4332b4931a7fb5bc60c2e2eeee30;
uint256 constant ZERO_SEED_LAUNCH_CLAIM_FEES = 0xe52d8a05fd0f2d32b280675736d8117fee83069a0eac7ab9279aa52ff05a614c;

/// @title Zero-seed launch extension interface
/// @notice Fixed-supply launches with one immutable token-only position and an inaccessible rounding remainder.
/// Every action reaches the extension through `Core.forward`; it has no external mutating entrypoint.
/// @dev Ticks in `LaunchParameters` are economic: log base 1.000001 of raw quote units per raw launch token unit,
/// independent of address order. The pool tick is the same for a token0 launch and negated for a token1 launch.
/// Creator fees are Q0.64 fractions (2**64 = 100%) held by this extension, separate from the pool config fee,
/// which is always zero. Every `uint64` is a valid rate, `0..2**64 - 1` inclusive; exactly 100% is not encodable.
/// The fee is `initialFee` until `tradingStart`; afterwards the excess over `finalFee` shrinks by the tick-math
/// factor `tickToSqrtRatio(-m)`, about `1.000001**(-m / 2)`, where `m` is the whole number of ticks the launch's
/// `decayRateX32` (Q32.32 ticks per second) has accumulated since the start (see `src/math/feeDecay.sol`).
/// `finalFee` is the long-run floor, not a scheduled endpoint: the fee approaches it and settles there only by
/// rounding or by saturation once `m` exceeds the supported tick magnitude. Requires `finalFee <= initialFee`
/// (`InvalidFeeSchedule` otherwise); every `uint64` rate is accepted, zero included (a flat fee).
///
/// Forward payloads, all settled by the forwarding locker within its lock:
/// - swap: `abi.encode(PoolKey, SwapParameters)` (128 bytes), returns `abi.encode(PoolBalanceUpdate, PoolState)`;
///   the fee-inclusive deltas are debt on the lock.
/// - create: `abi.encode(ZERO_SEED_LAUNCH_CREATE, LaunchParameters)`, returns `abi.encode(Installation)`; the
///   forwarding locker becomes the launch controller and the lock exits with zero debt.
/// - claim fees: `abi.encode(ZERO_SEED_LAUNCH_CLAIM_FEES, PoolKey)`, controller only, returns
///   `abi.encode(uint128 amount0, uint128 amount1)` credited to the lock for the locker to withdraw.
/// Any other first word at or above 2**160 reverts `UnknownForwardAction`.
interface IZeroSeedLaunch {
    struct LaunchParameters {
        /// @dev At most 31 bytes, as is `symbol`.
        string name;
        string symbol;
        uint8 decimals;
        /// @dev Exact minted supply. The installed liquidity is the largest amount whose Core debit, rounded up,
        /// fits this supply; the remainder below one more liquidity unit is minted to address(0), preserving the
        /// round totalSupply.
        uint128 supply;
        /// @dev Native ETH is address(0). An ERC-20 quote is untrusted and its trust is token-wide, not pair-local:
        /// Core keeps one balance per token, so a quote that misreports balances or transfers compromises every
        /// pool, position and fee ledger that holds that quote, including other launches and ordinary pools on the
        /// same quote, and an honest token paired with it can lose those pools' own reserves. Unrelated tokens and
        /// native ETH keep their own per-token accounting, so pools without the quote are not reachable through it.
        address quoteToken;
        int32 askTick;
        int32 upperTick;
        uint32 tickSpacing;
        uint64 tradingStart;
        /// @dev Fee decay speed in ticks per second as unsigned Q32.32 (`2**32` = one tick per second). The excess
        /// fee over `finalFee` halves every `2 * ln(2) / ln(1.000001)` = 1,386,295.05 ticks, so the half-life in
        /// seconds is `1386295.05 * 2**32 / decayRateX32`; 68913100933 is a one-day half-life. Any `uint64` value:
        /// zero keeps the fee flat at `initialFee`, the maximum saturates to `finalFee` within the first second.
        uint64 decayRateX32;
        /// @dev Q0.64 rates; any `uint64` value, with `finalFee <= initialFee`.
        uint64 initialFee;
        uint64 finalFee;
        /// @dev Namespaced by the controller: the token salt is `keccak256(abi.encode(controller, salt))`.
        bytes32 salt;
    }

    struct Launch {
        /// @dev The locker that forwarded the creation; the only locker that may claim the fee ledger.
        address controller;
        uint64 tradingStart;
        uint64 decayRateX32;
        uint64 initialFee;
        uint64 finalFee;
        int32 tickLower;
        int32 tickUpper;
    }

    struct Installation {
        address token;
        PoolKey poolKey;
        PositionId positionId;
        int32 initialTick;
        uint128 liquidity;
        uint128 installedSupply;
    }

    error InvalidParameters();
    error UnsupportedQuoteToken();
    error MetadataTooLong();
    error LaunchTokenExists(address token);
    error InvalidFeeSchedule();
    error InvalidTradingStart();
    error ZeroLiquidity();
    error LiquidityAboveTickCap(uint128 liquidity, uint128 cap);
    error UnknownLaunch();
    error TradingNotStarted();
    error ControllerOnly();
    error UnknownForwardAction();
    error InitializeThroughCreateOnly();
    error SwapsThroughForwardOnly();
    error PositionsThroughCreateOnly();

    /// @notice Emitted once per launch. `liquidity` is installed principal; `parameters.supply` includes the
    /// inaccessible rounding remainder at address(0).
    /// `controller` is the locker that forwarded the creation, for example the periphery that records the owner.
    event LaunchCreated(
        PoolId indexed poolId,
        address indexed token,
        address indexed controller,
        PoolKey poolKey,
        PositionId positionId,
        uint128 liquidity,
        LaunchParameters parameters
    );

    /// @notice Emitted for every forwarded swap after the creator fee is applied.
    /// @param delta0 Fee-inclusive pool-perspective delta settled by the forwarding locker.
    /// @param delta1 Fee-inclusive pool-perspective delta settled by the forwarding locker.
    /// @param feeAmount Creator fee in the calculated token, added to the creator ledger.
    event LaunchSwapped(
        PoolId indexed poolId,
        address indexed locker,
        int128 delta0,
        int128 delta1,
        uint64 feeRate,
        uint128 feeAmount,
        bool feeIsToken1
    );

    /// @notice Emitted when the controller moves the whole fee ledger of a launch onto its lock.
    event CreatorFeesClaimed(PoolId indexed poolId, address indexed controller, uint128 amount0, uint128 amount1);

    /// @notice For `controller`, the largest liquidity `supply` buys and the exact supply that liquidity takes.
    /// Creation uses the same calculation and sends `supply - installedSupply` to address(0).
    /// Applies the same parameter, metadata and token-address checks as creation, so it refuses an oversized
    /// name or symbol and a controller/salt/metadata whose token already exists. It is installation math at the
    /// current state, not a dry run: creation can still fail later, for example once `tradingStart` passes.
    function previewInstallation(address controller, LaunchParameters calldata parameters)
        external
        view
        returns (Installation memory installation);

    function feeAt(PoolId poolId, uint256 timestamp) external view returns (uint64);

    function getLaunch(PoolId poolId) external view returns (Launch memory);

    function creatorFees(PoolKey calldata poolKey) external view returns (uint128 amount0, uint128 amount1);
}
