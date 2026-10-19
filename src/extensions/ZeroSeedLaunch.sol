// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore, CallPoints} from "../interfaces/ICore.sol";
import {IFlashAccountant} from "../interfaces/IFlashAccountant.sol";
import {IZeroSeedLaunch} from "../interfaces/extensions/IZeroSeedLaunch.sol";
import {BaseExtension} from "../base/BaseExtension.sol";
import {BaseForwardee} from "../base/BaseForwardee.sol";
import {BaseLocker} from "../base/BaseLocker.sol";
import {MintableERC20} from "../MintableERC20.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolState} from "../types/poolState.sol";
import {createConcentratedPoolConfig} from "../types/poolConfig.sol";
import {PositionId, createPositionId} from "../types/positionId.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "../types/swapParameters.sol";
import {Locker} from "../types/locker.sol";
import {SqrtRatio} from "../types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../math/ticks.sol";
import {MIN_TICK, MAX_TICK, MAX_TICK_SPACING, NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";
import {maxLiquidity, liquidityDeltaToAmountDelta} from "../math/liquidity.sol";
import {computeFee, amountBeforeFee} from "../math/fee.sol";
import {decayedFee} from "../math/feeDecay.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @dev Highest creator fee rate, Q0.64: floor(2**64 * 99 / 100) = 99%. Exactly 100% (2**64) is not encodable.
uint64 constant MAX_CREATOR_FEE = 18262276632972456099;

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
/// @notice Mints a fixed supply and installs all of it as one token-only position from the ask price up, with
/// no quote seed. Buyers fund the only quote reserve. The position, its principal and the pool never change
/// except through swaps; time only lowers the creator fee, from `initialFee` at `tradingStart` along a rescaled
/// exponential with per-second factor `decayFactor` to `finalFee` after `feeDuration`, and it stays there.
/// @dev No admin, upgrade, withdrawal, migration or staging path. The pool fee is zero; the creator fee is taken
/// on the calculated side of each forwarded swap and saved in Core under this extension, salt = pool id.
/// Every launch of one deployment uses the single quote token fixed in the constructor. The deployer must pass a
/// plain token (no transfer fee, rebase, callback, pause, blocklist, upgrade or misreported balance); nothing here
/// can detect a token that only behaves later.
contract ZeroSeedLaunch is IZeroSeedLaunch, BaseExtension, BaseForwardee, BaseLocker {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    uint256 private constant ACTION_CREATE = 0;
    uint256 private constant ACTION_CLAIM = 1;

    address private immutable QUOTE_TOKEN;

    mapping(PoolId => Launch) private _launches;

    constructor(ICore core, address quote) BaseExtension(core) BaseForwardee(core) BaseLocker(core) {
        if (quote == NATIVE_TOKEN_ADDRESS || quote.code.length == 0) revert UnsupportedQuoteToken();
        QUOTE_TOKEN = quote;
    }

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
    function create(LaunchParameters calldata parameters) external returns (Installation memory) {
        return abi.decode(lock(abi.encode(ACTION_CREATE, abi.encode(msg.sender, parameters))), (Installation));
    }

    /// @inheritdoc IZeroSeedLaunch
    function claimFees(PoolKey calldata poolKey, address recipient) external returns (uint128, uint128) {
        if (_launches[poolKey.toPoolId()].creator != msg.sender) revert CreatorOnly();
        // Tokens sent to any of these are stranded: Core and this extension book nothing for a bare transfer, and
        // neither pool token can return a balance held at its own address.
        if (
            recipient == address(0) || recipient == address(CORE) || recipient == address(this)
                || recipient == poolKey.token0 || recipient == poolKey.token1
        ) revert InvalidRecipient();
        return abi.decode(lock(abi.encode(ACTION_CLAIM, abi.encode(poolKey, recipient))), (uint128, uint128));
    }

    /// @inheritdoc IZeroSeedLaunch
    function quoteToken() external view returns (address) {
        return QUOTE_TOKEN;
    }

    /// @inheritdoc IZeroSeedLaunch
    function previewInstallation(address creator, LaunchParameters memory parameters)
        public
        view
        returns (Installation memory installation)
    {
        _validate(parameters);
        installation = _geometry(creator, parameters);
        (SqrtRatio initial, SqrtRatio lower, SqrtRatio upper) = _sqrtRatios(installation);
        bool tokenIs0 = installation.poolKey.token0 == installation.token;
        uint128 liquidity =
            maxLiquidity(initial, lower, upper, tokenIs0 ? parameters.supply : 0, tokenIs0 ? 0 : parameters.supply);
        _install(installation, liquidity);
    }

    /// @dev Token, pool key, position and initial tick for a creator and parameters, before any liquidity.
    function _geometry(address creator, LaunchParameters memory parameters)
        private
        view
        returns (Installation memory installation)
    {
        installation.token = _tokenAddress(creator, parameters);
        if (installation.token.code.length != 0) revert LaunchTokenExists(installation.token);
        bool tokenIs0 = installation.token < parameters.quoteToken;
        installation.poolKey = PoolKey({
            token0: tokenIs0 ? installation.token : parameters.quoteToken,
            token1: tokenIs0 ? parameters.quoteToken : installation.token,
            config: createConcentratedPoolConfig(0, parameters.tickSpacing, address(this))
        });
        int32 tickLower = tokenIs0 ? parameters.askTick : -parameters.upperTick;
        int32 tickUpper = tokenIs0 ? parameters.upperTick : -parameters.askTick;
        installation.positionId = createPositionId(bytes24(0), tickLower, tickUpper);
        installation.positionId.validate(installation.poolKey.config);
        // The token-only side: price at the lower economic bound, which is the pool's lower tick for a token0
        // launch and the pool's upper tick for a token1 launch.
        installation.initialTick = tokenIs0 ? tickLower : tickUpper;
    }

    function _sqrtRatios(Installation memory installation)
        private
        pure
        returns (SqrtRatio initial, SqrtRatio lower, SqrtRatio upper)
    {
        lower = tickToSqrtRatio(installation.positionId.tickLower());
        upper = tickToSqrtRatio(installation.positionId.tickUpper());
        initial = installation.initialTick == installation.positionId.tickLower() ? lower : upper;
    }

    /// @dev Sets the liquidity and the exact token amount Core takes for it at the initial price, rounded up.
    function _install(Installation memory installation, uint128 liquidity) private pure {
        if (liquidity == 0) revert ZeroLiquidity();
        uint128 cap = installation.poolKey.config.concentratedMaxLiquidityPerTick();
        if (liquidity > cap) revert LiquidityAboveTickCap(liquidity, cap);
        (SqrtRatio initial, SqrtRatio lower, SqrtRatio upper) = _sqrtRatios(installation);
        (int128 delta0, int128 delta1) = liquidityDeltaToAmountDelta(initial, int128(liquidity), lower, upper);
        installation.liquidity = liquidity;
        installation.installedSupply = uint128(installation.poolKey.token0 == installation.token ? delta0 : delta1);
    }

    /// @inheritdoc IZeroSeedLaunch
    function feeAt(PoolId poolId, uint256 timestamp) external view returns (uint64) {
        Launch storage launch = _launches[poolId];
        if (launch.creator == address(0)) revert UnknownLaunch();
        return _feeAt(launch, timestamp);
    }

    /// @inheritdoc IZeroSeedLaunch
    function getLaunch(PoolId poolId) external view returns (Launch memory) {
        return _launches[poolId];
    }

    /// @inheritdoc IZeroSeedLaunch
    function creatorFees(PoolKey calldata poolKey) external view returns (uint128, uint128) {
        return CORE.savedBalances(address(this), poolKey.token0, poolKey.token1, PoolId.unwrap(poolKey.toPoolId()));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (uint256 action, bytes memory args) = abi.decode(data, (uint256, bytes));
        if (action == ACTION_CREATE) {
            (address creator, LaunchParameters memory parameters) = abi.decode(args, (address, LaunchParameters));
            return abi.encode(_create(creator, parameters));
        }
        (PoolKey memory poolKey, address recipient) = abi.decode(args, (PoolKey, address));
        return _claim(poolKey, recipient);
    }

    /// @dev The supply is minted to Core and credited to this lock, then all of it is taken by one position, so
    /// the lock settles with nothing owed and nothing left over.
    function _create(address creator, LaunchParameters memory parameters) private returns (Installation memory) {
        _validate(parameters);
        Installation memory installation = _geometry(creator, parameters);
        _install(installation, parameters.liquidity);
        if (installation.installedSupply != parameters.supply) {
            revert SupplyNotExactlyInstallable(parameters.supply, installation.installedSupply);
        }
        MintableERC20 token = new MintableERC20{salt: _tokenSalt(creator, parameters.salt)}(
            address(this), parameters.name, parameters.symbol, parameters.decimals
        );
        assert(address(token) == installation.token);

        PoolKey memory poolKey = installation.poolKey;
        PoolId poolId = poolKey.toPoolId();
        _launches[poolId] = Launch({
            creator: creator,
            tradingStart: parameters.tradingStart,
            feeDuration: parameters.feeDuration,
            initialFee: parameters.initialFee,
            finalFee: parameters.finalFee,
            tickLower: installation.positionId.tickLower(),
            tickUpper: installation.positionId.tickUpper(),
            decayFactor: parameters.decayFactor
        });
        CORE.initializePool(poolKey, installation.initialTick);
        PoolBalanceUpdate update = CORE.updatePosition(poolKey, installation.positionId, int128(installation.liquidity));
        bool tokenIs0 = poolKey.token0 == address(token);
        // Equal to the preview by construction; checked again because the principal claim depends on it.
        assert(
            (tokenIs0 ? update.delta0() : update.delta1()) == int128(parameters.supply)
                && (tokenIs0 ? update.delta1() : update.delta0()) == 0
        );

        bytes memory tokenArg = abi.encode(token);
        (bool started,) = address(CORE).call(bytes.concat(IFlashAccountant.startPayments.selector, tokenArg));
        token.mint(address(CORE), parameters.supply);
        (bool completed,) = address(CORE).call(bytes.concat(IFlashAccountant.completePayments.selector, tokenArg));
        assert(started && completed);
        token.renounceOwnership();

        emit LaunchCreated(
            poolId, address(token), creator, poolKey, installation.positionId, installation.liquidity, parameters
        );
        return installation;
    }

    /// @dev Only a forward reaches here, so the forwarding locker settles the fee-inclusive update.
    /// Payload: abi.encode(PoolKey, SwapParameters); returns abi.encode(PoolBalanceUpdate, PoolState).
    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory poolKey, SwapParameters params) = abi.decode(data, (PoolKey, SwapParameters));
        PoolId poolId = poolKey.toPoolId();
        Launch storage launch = _launches[poolId];
        if (launch.creator == address(0)) revert UnknownLaunch();
        if (block.timestamp < launch.tradingStart) revert TradingNotStarted();

        (PoolBalanceUpdate update, PoolState state) = CORE.swap(0, poolKey, _withinPosition(launch, params));

        // Fee on the calculated side of the actual fill: output for exact input, input for exact output.
        bool feeIsToken1 = !params.isToken1();
        int128 calculated = feeIsToken1 ? update.delta1() : update.delta0();
        uint128 amount = uint128(FixedPointMathLib.abs(calculated));
        uint64 rate = _feeAt(launch, block.timestamp);
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
        emit LaunchSwapped(poolId, original.addr(), update.delta0(), update.delta1(), rate, feeAmount, feeIsToken1);
        return abi.encode(update, state);
    }

    /// @dev Swaps stop at the position bounds, so the price never leaves the installed range: buys fill partially
    /// at the upper bound and sells stop at the ask with no bid below it.
    function _withinPosition(Launch storage launch, SwapParameters params) private view returns (SwapParameters) {
        params = params.withDefaultSqrtRatioLimit();
        SqrtRatio limit = params.sqrtRatioLimit();
        if (params.isPriceIncreasing()) {
            SqrtRatio upper = tickToSqrtRatio(launch.tickUpper);
            if (limit <= upper) return params;
            limit = upper;
        } else {
            SqrtRatio lower = tickToSqrtRatio(launch.tickLower);
            if (limit >= lower) return params;
            limit = lower;
        }
        return createSwapParameters(limit, params.amount(), params.isToken1(), params.skipAhead());
    }

    function _claim(PoolKey memory poolKey, address recipient) private returns (bytes memory) {
        PoolId poolId = poolKey.toPoolId();
        (uint128 amount0, uint128 amount1) =
            CORE.savedBalances(address(this), poolKey.token0, poolKey.token1, PoolId.unwrap(poolId));
        CORE.updateSavedBalances(
            poolKey.token0, poolKey.token1, PoolId.unwrap(poolId), -int256(uint256(amount0)), -int256(uint256(amount1))
        );
        ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, recipient, amount0, amount1);
        emit CreatorFeesClaimed(poolId, _launches[poolId].creator, recipient, amount0, amount1);
        return abi.encode(amount0, amount1);
    }

    function _feeAt(Launch storage launch, uint256 timestamp) internal view virtual returns (uint64) {
        uint64 initialFee = launch.initialFee;
        uint256 start = launch.tradingStart;
        if (timestamp <= start) return initialFee;
        return decayedFee(initialFee, launch.finalFee, launch.decayFactor, launch.feeDuration, timestamp - start);
    }

    function _validate(LaunchParameters memory parameters) private view {
        if (parameters.quoteToken != QUOTE_TOKEN) revert UnsupportedQuoteToken();
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
        if (parameters.initialFee > MAX_CREATOR_FEE) revert FeeTooHigh();
        if (parameters.finalFee > parameters.initialFee || parameters.feeDuration == 0 || parameters.decayFactor == 0) {
            revert InvalidFeeSchedule();
        }
        if (parameters.tradingStart < block.timestamp) revert InvalidTradingStart();
    }

    function _tokenSalt(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }

    function _tokenAddress(address creator, LaunchParameters memory parameters) private view returns (address) {
        bytes32 initCodeHash = keccak256(
            bytes.concat(
                type(MintableERC20).creationCode,
                abi.encode(address(this), parameters.name, parameters.symbol, parameters.decimals)
            )
        );
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff), address(this), _tokenSalt(creator, parameters.salt), initCodeHash
                        )
                    )
                )
            )
        );
    }
}
