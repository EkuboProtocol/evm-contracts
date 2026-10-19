// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {PoolKey} from "../../types/poolKey.sol";
import {PoolId} from "../../types/poolId.sol";
import {PositionId} from "../../types/positionId.sol";

/// @title Zero-seed launch extension interface
/// @notice Fixed-supply launches whose whole supply is one immutable token-only position at the lower price bound.
/// @dev Ticks in `LaunchParameters` are economic: log base 1.000001 of raw quote units per raw launch token unit,
/// independent of address order. The pool tick is the same for a token0 launch and negated for a token1 launch.
/// Creator fees are Q0.64 fractions (2**64 = 100%) held by this extension, separate from the pool config fee,
/// which is always zero. The fee is `initialFee` at `tradingStart` and decays exponentially, rescaled to reach
/// `finalFee` exactly `feeDuration` seconds later (see `src/math/feeDecay.sol`).
interface IZeroSeedLaunch {
    struct LaunchParameters {
        /// @dev Must equal `quoteToken()`, the one quote token this deployment accepts.
        address quoteToken;
        /// @dev At most 31 bytes, as is `symbol`.
        string name;
        string symbol;
        uint8 decimals;
        /// @dev Minted supply. `create` requires it to equal the token amount Core takes for `liquidity`.
        uint128 supply;
        /// @dev Liquidity of the single position. Ignored by `previewInstallation`, which derives it from `supply`.
        uint128 liquidity;
        int32 askTick;
        int32 upperTick;
        uint32 tickSpacing;
        uint64 tradingStart;
        uint32 feeDuration;
        uint64 initialFee;
        uint64 finalFee;
        /// @dev Per-second Q0.64 multiplier of the unscaled decay, in (0, 2**64). Not a half-life.
        uint64 decayFactor;
        bytes32 salt;
    }

    struct Launch {
        address creator;
        uint64 tradingStart;
        uint32 feeDuration;
        uint64 initialFee;
        uint64 finalFee;
        int32 tickLower;
        int32 tickUpper;
        uint64 decayFactor;
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
    error FeeTooHigh();
    error InvalidFeeSchedule();
    error InvalidTradingStart();
    error ZeroLiquidity();
    error LiquidityAboveTickCap(uint128 liquidity, uint128 cap);
    error SupplyNotExactlyInstallable(uint128 requested, uint128 installable);
    error UnknownLaunch();
    error TradingNotStarted();
    error CreatorOnly();
    error InvalidRecipient();
    error InitializeThroughCreateOnly();
    error SwapsThroughForwardOnly();
    error PositionsThroughCreateOnly();

    /// @notice Emitted once per launch. `liquidity` and `supply` are the installed principal, which never changes.
    event LaunchCreated(
        PoolId indexed poolId,
        address indexed token,
        address indexed creator,
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

    event CreatorFeesClaimed(
        PoolId indexed poolId, address indexed creator, address indexed recipient, uint128 amount0, uint128 amount1
    );

    /// @notice Creates the launch token, pool and locked position atomically; msg.sender becomes the creator.
    function create(LaunchParameters calldata parameters) external returns (Installation memory installation);

    /// @notice For `creator`, the largest liquidity `supply` buys and the exact supply that liquidity takes. Passing
    /// the returned `liquidity` and `installedSupply` as `liquidity` and `supply` makes `create` install exactly.
    /// Applies the same parameter, metadata and token-address checks as `create`, so it refuses an unsupported quote,
    /// an oversized name or symbol and a creator/salt/metadata whose token already exists. It is installation math
    /// at the current state, not a dry run: `create` can still fail later, for example once `tradingStart` passes.
    function previewInstallation(address creator, LaunchParameters calldata parameters)
        external
        view
        returns (Installation memory installation);

    /// @notice The only quote token this deployment accepts, fixed at construction.
    function quoteToken() external view returns (address);

    /// @notice Sends the whole creator fee ledger of a launch to `recipient`, both assets in one transfer pair or
    /// nothing. Creator only. `recipient` must not be zero, Core, this extension or either pool token.
    function claimFees(PoolKey calldata poolKey, address recipient) external returns (uint128 amount0, uint128 amount1);

    function feeAt(PoolId poolId, uint256 timestamp) external view returns (uint64);

    function getLaunch(PoolId poolId) external view returns (Launch memory);

    function creatorFees(PoolKey calldata poolKey) external view returns (uint128 amount0, uint128 amount1);
}
