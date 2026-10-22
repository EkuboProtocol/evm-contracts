// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore, CallPoints} from "../interfaces/ICore.sol";
import {IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {
    IZeroSeedLaunch,
    ZERO_SEED_LAUNCH_CREATE,
    ZERO_SEED_LAUNCH_CLAIM_FEES
} from "../interfaces/extensions/IZeroSeedLaunch.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {MintableERC20} from "../MintableERC20.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolState} from "../types/poolState.sol";
import {createConcentratedPoolConfig} from "../types/poolConfig.sol";
import {PositionId, createPositionId} from "../types/positionId.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";
import {Locker} from "../types/locker.sol";
import {SqrtRatio, BIT_MASK} from "../types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {maxLiquidity, liquidityDeltaToAmountDelta} from "../math/liquidity.sol";
import {computeFee, amountBeforeFee} from "../math/fee.sol";
import {decayedFee} from "../math/feeDecay.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @dev Highest creator fee rate: every `uint64` is a valid Q0.64 rate, so the ceiling is the type's own maximum,
/// 2**64 - 1 (just under 100%). Exactly 100% (2**64) is not a `uint64`: calldata carrying it fails ABI decoding
/// before any logic runs, and no narrowing can wrap it to zero.
uint64 constant MAX_CREATOR_FEE = type(uint64).max;

/// @dev Longest token name or symbol in bytes: `MintableERC20` packs each with its length into one word.
uint256 constant MAX_METADATA_LENGTH = 31;

function zeroSeedLaunchCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: false,
        beforeSwap: true,
        afterSwap: false,
        beforeUpdatePosition: true,
        afterUpdatePosition: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

/// @title Zero-seed launch
/// @notice Mints the requested fixed supply and installs its maximum liquidity as one token-only position, with
/// the rounding remainder sent directly to address(0), from the ask price up, with
/// no quote seed. Buyers fund the only quote reserve. The position, its principal and the pool never change
/// except through swaps; time only lowers the creator fee, from `initialFee` at `tradingStart` along the 600 second
/// half-life exponential rescaled to reach `finalFee` after `feeDuration`, where it stays.
/// @dev Forward only: creation, fee claims and swaps all arrive through `Core.forward`, so this contract is never a
/// locker, never holds a balance and never transfers a token. The forwarding locker settles what each action leaves
/// on its lock: nothing for creation (the new supply is minted straight into Core as the position's payment), the
/// fee-inclusive deltas for a swap, and a credit for a claim. The locker that forwards a creation is the launch's
/// controller: the only locker that may claim its fee ledger, and the namespace of its token address. A periphery
/// that forwards for users records who owns each launch itself.
/// No admin, upgrade, withdrawal, migration or staging path. The pool fee is zero; the creator fee is taken on the
/// calculated side of each swap and saved in Core under this extension, salt = pool id. Any `uint64` rate is
/// accepted: at 2**64 - 1 an exact-input swap nets floor(gross / 2**64) and an exact-output swap pays
/// calculated * 2**64, so exact output is bounded by the signed delta (calculated <= 2**63 - 1) and the uint128
/// gross-up helper (calculated < 2**64); either limit reverts the whole swap. Each launch chooses
/// its quote: native ETH (`address(0)`, always token0) or a plain
/// ERC-20 (no transfer fee, rebase, callback, pause, blocklist, upgrade or misreported balance); nothing here can
/// detect a token that only behaves later. That trust is token-wide: Core holds one balance per token, so a quote
/// that lies about payments exposes every pool, position and fee ledger holding it, on this extension or not, and
/// the honest side of any pool paired with it, up to those pools' own reserves. Pools without that quote keep their
/// own per-token accounting and are not reachable through it.
contract ZeroSeedLaunch is IZeroSeedLaunch, BaseExtension, BaseForwardee {
    using CoreLib for ICore;

    mapping(PoolId => Launch) private _launches;

    constructor(ICore core) BaseExtension(core) BaseForwardee(core) {}

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return zeroSeedLaunchCallPoints();
    }

    /// @dev Core skips this hook when this extension initializes its own pool.
    function beforeInitializePool(address, PoolKey calldata, int32) external pure override {
        revert InitializeThroughCreateOnly();
    }

    /// @dev Core skips this hook while this extension is the locker, i.e. inside a forward to it.
    function beforeSwap(Locker, PoolKey memory, SwapParameters) external pure override {
        revert SwapsThroughForwardOnly();
    }

    /// @dev Core skips this hook for this extension's own position; no other position may exist in a launch pool.
    function beforeUpdatePosition(Locker, PoolKey memory, PositionId, int128) external pure override {
        revert PositionsThroughCreateOnly();
    }

    /// @inheritdoc IZeroSeedLaunch
    function previewInstallation(address controller, LaunchParameters memory parameters)
        public
        view
        returns (Installation memory)
    {
        _validate(parameters);
        (address token, PoolKey memory poolKey, PositionId positionId, int32 initialTick) =
            _geometry(controller, parameters);
        bool tokenIs0 = poolKey.token0 == token;
        (, SqrtRatio lower, SqrtRatio upper) = _sqrtRatios(positionId, initialTick);
        uint128 liquidity = _maxLiquidity(tokenIs0, lower, upper, parameters.supply);
        uint128 installedSupply = _installedSupply(
            tokenIs0, positionId, initialTick, liquidity, poolKey.config.concentratedMaxLiquidityPerTick()
        );
        return Installation(token, poolKey, positionId, initialTick, liquidity, installedSupply);
    }

    /// @inheritdoc IZeroSeedLaunch
    function feeAt(PoolId poolId, uint256 timestamp) external view returns (uint64) {
        Launch memory launch = _launches[poolId];
        if (launch.controller == address(0)) revert UnknownLaunch();
        return _feeAt(launch.initialFee, launch.finalFee, launch.feeDuration, launch.tradingStart, timestamp);
    }

    /// @inheritdoc IZeroSeedLaunch
    function getLaunch(PoolId poolId) external view returns (Launch memory) {
        return _launches[poolId];
    }

    /// @inheritdoc IZeroSeedLaunch
    function creatorFees(PoolKey calldata poolKey) external view returns (uint128, uint128) {
        return CORE.savedBalances(address(this), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
    }

    /// @dev Dispatch on the first word. Action tags exceed 2**160; a swap payload starts with `token0 < 2**160`, so
    /// no payload selects more than one branch and an unknown tag never reaches the swap decoder.
    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory) {
        if (data.length < 32) revert UnknownForwardAction();
        uint256 tag;
        assembly ("memory-safe") {
            tag := mload(add(data, 0x20))
        }
        if (tag == ZERO_SEED_LAUNCH_CREATE) {
            (, LaunchParameters memory parameters) = abi.decode(data, (uint256, LaunchParameters));
            return abi.encode(_create(original.addr(), parameters));
        }
        if (tag == ZERO_SEED_LAUNCH_CLAIM_FEES) {
            (, PoolKey memory claimed) = abi.decode(data, (uint256, PoolKey));
            (uint128 amount0, uint128 amount1) = _claimFees(original.addr(), claimed);
            return abi.encode(amount0, amount1);
        }
        if (tag >> 160 != 0) revert UnknownForwardAction();
        (PoolKey memory poolKey, SwapParameters params) = abi.decode(data, (PoolKey, SwapParameters));
        return _swap(original.addr(), poolKey, params);
    }

    /// @dev Installed inventory is minted to Core and credited to this lock; the remainder goes directly to zero.
    /// The lock settles with nothing owed and no spendable inventory outside the position.
    function _create(address controller, LaunchParameters memory parameters)
        private
        returns (Installation memory installation)
    {
        installation = previewInstallation(controller, parameters);
        address predicted = installation.token;
        PoolKey memory poolKey = installation.poolKey;
        PositionId positionId = installation.positionId;
        int32 initialTick = installation.initialTick;
        bool tokenIs0 = poolKey.token0 == predicted;

        MintableERC20 token = new MintableERC20{salt: _tokenSalt(controller, parameters.salt)}(
            address(this), parameters.name, parameters.symbol, parameters.decimals
        );
        assert(address(token) == predicted);

        PoolId poolId = poolKey.toPoolId();
        _launches[poolId] = Launch({
            controller: controller,
            tradingStart: parameters.tradingStart,
            feeDuration: parameters.feeDuration,
            initialFee: parameters.initialFee,
            finalFee: parameters.finalFee,
            tickLower: positionId.tickLower(),
            tickUpper: positionId.tickUpper()
        });
        CORE.initializePool(poolKey, initialTick);
        PoolBalanceUpdate update = CORE.updatePosition(poolKey, positionId, int128(installation.liquidity));
        // Equal to the preview by construction; checked again because the principal claim depends on it.
        assert(
            (tokenIs0 ? update.delta0() : update.delta1()) == int128(installation.installedSupply)
                && (tokenIs0 ? update.delta1() : update.delta0()) == 0
        );

        // Token deployment, the mint that pays the position and the renunciation of the mint authority all happen
        // here, inside the forwarded call: the supply goes from the token contract straight into Core.
        bytes memory tokenArg = abi.encode(token);
        (bool started,) = address(CORE).call(bytes.concat(IFlashAccountant.startPayments.selector, tokenArg));
        token.mint(address(CORE), installation.installedSupply);
        (bool completed,) = address(CORE).call(bytes.concat(IFlashAccountant.completePayments.selector, tokenArg));
        assert(started && completed);
        // Keep totalSupply exactly as requested without leaving spendable inventory outside the position.
        // Mint directly to the sink: no custody, transfer or additional Core accounting is needed.
        uint128 remainder = parameters.supply - installation.installedSupply;
        if (remainder != 0) token.mint(address(0), remainder);
        token.renounceOwnership();

        emit LaunchCreated(poolId, address(token), controller, poolKey, positionId, installation.liquidity, parameters);
    }

    /// @dev Only the controller that forwarded the creation may move the ledger; it is credited to the current lock
    /// for the controller to withdraw.
    function _claimFees(address controller, PoolKey memory poolKey) private returns (uint128 amount0, uint128 amount1) {
        PoolId poolId = poolKey.toPoolId();
        address stored = _launches[poolId].controller;
        if (stored == address(0)) revert UnknownLaunch();
        if (stored != controller) revert ControllerOnly();
        (amount0, amount1) = CORE.savedBalances(address(this), poolKey.token0, poolKey.token1, PoolId.unwrap(poolId));
        if (amount0 != 0 || amount1 != 0) {
            CORE.updateSavedBalances(
                poolKey.token0,
                poolKey.token1,
                PoolId.unwrap(poolId),
                -int256(uint256(amount0)),
                -int256(uint256(amount1))
            );
        }
        emit CreatorFeesClaimed(poolId, controller, amount0, amount1);
    }

    /// @dev The forwarding locker settles the fee-inclusive update.
    function _swap(address locker, PoolKey memory poolKey, SwapParameters params) private returns (bytes memory) {
        PoolId poolId = poolKey.toPoolId();
        Launch memory launch = _launches[poolId];
        if (launch.controller == address(0)) revert UnknownLaunch();
        if (block.timestamp < launch.tradingStart) revert TradingNotStarted();

        (PoolBalanceUpdate update, PoolState state) =
            CORE.swap(0, poolKey, _withinPosition(launch.tickLower, launch.tickUpper, params));

        // Fee on the calculated side of the actual fill: output for exact input, input for exact output.
        bool feeIsToken1 = !params.isToken1();
        int128 calculated = feeIsToken1 ? update.delta1() : update.delta0();
        uint128 amount = uint128(FixedPointMathLib.abs(calculated));
        uint64 rate =
            _feeAt(launch.initialFee, launch.finalFee, launch.feeDuration, launch.tradingStart, block.timestamp);
        uint128 feeAmount = params.isExactOut() ? amountBeforeFee(amount, rate) - amount : computeFee(amount, rate);
        if (feeAmount != 0) {
            CORE.updateSavedBalances(
                poolKey.token0,
                poolKey.token1,
                PoolId.unwrap(poolId),
                feeIsToken1 ? int256(0) : int256(uint256(feeAmount)),
                feeIsToken1 ? int256(uint256(feeAmount)) : int256(0)
            );
        }
        int128 withFee = SafeCastLib.toInt128(int256(calculated) + int256(uint256(feeAmount)));
        update = feeIsToken1
            ? createPoolBalanceUpdate(update.delta0(), withFee)
            : createPoolBalanceUpdate(withFee, update.delta1());
        emit LaunchSwapped(poolId, locker, update.delta0(), update.delta1(), rate, feeAmount, feeIsToken1);
        return abi.encode(update, state);
    }

    /// @dev Swaps stop at the position bounds, so the price never leaves the installed range: buys fill partially
    /// at the upper bound and sells stop at the ask with no bid below it.
    function _withinPosition(int32 tickLower, int32 tickUpper, SwapParameters params)
        private
        pure
        returns (SwapParameters)
    {
        params = params.withDefaultSqrtRatioLimit();
        SqrtRatio limit = params.sqrtRatioLimit();
        if (params.isPriceIncreasing()) {
            SqrtRatio upper = tickToSqrtRatio(tickUpper);
            if (limit <= upper) return params;
            limit = upper;
        } else {
            SqrtRatio lower = tickToSqrtRatio(tickLower);
            if (limit >= lower) return params;
            limit = lower;
        }
        return createSwapParameters(limit, params.amount(), params.isToken1(), params.skipAhead());
    }

    function _feeAt(uint64 initialFee, uint64 finalFee, uint32 duration, uint64 start, uint256 timestamp)
        private
        pure
        returns (uint64)
    {
        if (timestamp <= start) return initialFee;
        return decayedFee(initialFee, finalFee, duration, timestamp - start);
    }

    function _validate(LaunchParameters memory parameters) private view {
        if (parameters.quoteToken != NATIVE_TOKEN_ADDRESS && parameters.quoteToken.code.length == 0) {
            revert UnsupportedQuoteToken();
        }
        if (
            bytes(parameters.name).length > MAX_METADATA_LENGTH || bytes(parameters.symbol).length > MAX_METADATA_LENGTH
        ) {
            revert MetadataTooLong();
        }
        if (parameters.supply == 0 || parameters.supply > uint128(type(int128).max)) revert InvalidParameters();
        if (
            parameters.tickSpacing == 0 || parameters.tickSpacing > MAX_TICK_SPACING || parameters.askTick < MIN_TICK
                || parameters.upperTick > MAX_TICK || parameters.askTick >= parameters.upperTick
        ) revert InvalidParameters();
        // Any uint64 initial rate is accepted (see MAX_CREATOR_FEE); only the schedule shape is checked.
        if (parameters.finalFee > parameters.initialFee || parameters.feeDuration == 0) revert InvalidFeeSchedule();
        if (parameters.tradingStart < block.timestamp) revert InvalidTradingStart();
    }

    /// @dev Token, pool key, position and initial tick for a controller and parameters: everything fixed before
    /// liquidity. Returns fresh values and reads its inputs only.
    function _geometry(address controller, LaunchParameters memory parameters)
        private
        view
        returns (address token, PoolKey memory poolKey, PositionId positionId, int32 initialTick)
    {
        token = _tokenAddress(controller, parameters.salt, parameters.name, parameters.symbol, parameters.decimals);
        if (token.code.length != 0) revert LaunchTokenExists(token);
        bool tokenIs0 = token < parameters.quoteToken;
        poolKey = PoolKey({
            token0: tokenIs0 ? token : parameters.quoteToken,
            token1: tokenIs0 ? parameters.quoteToken : token,
            config: createConcentratedPoolConfig(0, parameters.tickSpacing, address(this))
        });
        positionId = _positionId(tokenIs0, parameters.askTick, parameters.upperTick);
        positionId.validate(poolKey.config);
        // The token-only side: price at the lower economic bound, which is the pool's lower tick for a token0
        // launch and the pool's upper tick for a token1 launch.
        initialTick = tokenIs0 ? positionId.tickLower() : positionId.tickUpper();
    }

    /// @dev Economic ticks to the pool position: the same ticks for a token0 launch, negated and swapped otherwise.
    function _positionId(bool tokenIs0, int32 askTick, int32 upperTick) private pure returns (PositionId) {
        return tokenIs0
            ? createPositionId(bytes24(0), askTick, upperTick)
            : createPositionId(bytes24(0), -upperTick, -askTick);
    }

    function _sqrtRatios(PositionId positionId, int32 initialTick)
        private
        pure
        returns (SqrtRatio initial, SqrtRatio lower, SqrtRatio upper)
    {
        lower = tickToSqrtRatio(positionId.tickLower());
        upper = tickToSqrtRatio(positionId.tickUpper());
        initial = initialTick == positionId.tickLower() ? lower : upper;
    }

    /// @dev The largest liquidity `supply` pays for at the initial price, i.e. the largest whose Core debit, rounded
    /// up, is at most `supply`. A token1 launch keeps the shared helper: one floor inverts Core's single round-up
    /// exactly. A token0 launch inverts Core's nested round-up exactly instead of using the helper's
    /// `floor(lower * upper / 2**128)` first step, which can leave whole liquidity units unpaid for at low prices.
    /// Core's token0 debit is `ceil(ceil(liquidity * 2**128 * (upper - lower) / upper) / lower)`, equal to
    /// `ceil(liquidity * 2**128 * (upper - lower) / (upper * lower))`, so the largest affordable liquidity is
    /// `floor(supply * lower * upper / (2**128 * (upper - lower)))`.
    /// Each compact sqrt ratio is `mantissa * 2**shift` with `2**62 <= mantissa < 2**94` and a shift of 2, 34, 66 or
    /// 98 selected by its top two bits, so `lower < upper` gives `shiftLower <= shiftUpper`, and `upper - lower` is a
    /// multiple of `2**shiftLower`. Dividing the fixed difference by that power and multiplying by
    /// `2**(128 - shiftUpper)` (at least 2**30) is exact and leaves a denominator below 2**220, nonzero because
    /// `tickToSqrtRatio` is strictly increasing. The numerator `supply * mantissaLower * mantissaUpper` is below
    /// 2**315, within the 512-bit multiply, and the quotient is below 2**213 for every supported tick pair (adjacent
    /// ticks at the top of the range maximize `upper * lower / (upper - lower)` below 2**213), so the division never
    /// fails; above `uint128` it saturates like the helper and then fails the per-tick cap.
    function _maxLiquidity(bool tokenIs0, SqrtRatio lower, SqrtRatio upper, uint128 supply)
        private
        pure
        returns (uint128)
    {
        if (!tokenIs0) return maxLiquidity(upper, lower, upper, 0, supply);
        uint256 lowerRaw = SqrtRatio.unwrap(lower);
        uint256 upperRaw = SqrtRatio.unwrap(upper);
        uint256 shiftLower = 2 + ((lowerRaw & BIT_MASK) >> 89);
        uint256 shiftUpper = 2 + ((upperRaw & BIT_MASK) >> 89);
        uint256 mantissas = (lowerRaw & ~uint256(BIT_MASK)) * (upperRaw & ~uint256(BIT_MASK));
        uint256 denominator = ((upper.toFixed() - lower.toFixed()) >> shiftLower) << (128 - shiftUpper);
        return
            uint128(
                FixedPointMathLib.min(type(uint128).max, FixedPointMathLib.fullMulDiv(supply, mantissas, denominator))
            );
    }

    /// @dev The exact token amount Core takes for `liquidity` at the initial price, rounded up.
    function _installedSupply(bool tokenIs0, PositionId positionId, int32 initialTick, uint128 liquidity, uint128 cap)
        private
        pure
        returns (uint128)
    {
        if (liquidity == 0) revert ZeroLiquidity();
        if (liquidity > cap) revert LiquidityAboveTickCap(liquidity, cap);
        (SqrtRatio initial, SqrtRatio lower, SqrtRatio upper) = _sqrtRatios(positionId, initialTick);
        (int128 delta0, int128 delta1) = liquidityDeltaToAmountDelta(initial, int128(liquidity), lower, upper);
        return uint128(tokenIs0 ? delta0 : delta1);
    }

    function _tokenSalt(address controller, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(controller, salt));
    }

    function _tokenAddress(address controller, bytes32 salt, string memory name, string memory symbol, uint8 decimals)
        private
        view
        returns (address)
    {
        bytes32 initCodeHash = keccak256(
            bytes.concat(type(MintableERC20).creationCode, abi.encode(address(this), name, symbol, decimals))
        );
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), address(this), _tokenSalt(controller, salt), initCodeHash))
                )
            )
        );
    }
}
