// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {MintableERC20} from "./MintableERC20.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {BaseForwardee} from "./base/BaseForwardee.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolId} from "./types/poolId.sol";
import {PoolState} from "./types/poolState.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {PositionId, createPositionId} from "./types/positionId.sol";
import {createSwapParameters} from "./types/swapParameters.sol";
import {Locker} from "./types/locker.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {sqrtRatioToTick} from "./math/ticks.sol";
import {LaunchLiquidityMath} from "./math/launchLiquidity.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Permanently owns migrated launch principal. Only position fees can leave.
/// @dev No withdrawal, approval, arbitrary execution, upgrade, or ownership-transfer path.
contract LockedLaunchLiquidity is BaseForwardee, BaseLocker, UsesCore {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    uint8 private constant LOCK_MIGRATE = 0;
    uint8 private constant LOCK_CLAIM = 1;
    uint8 private constant LOCK_FUND = 2;

    address public immutable EXTENSION;

    struct Registration {
        PoolId launchId;
        address owner;
        PoolKey poolKey;
        SqrtRatio lower;
        SqrtRatio upper;
        uint128 amount0;
        uint128 amount1;
    }

    struct Terminal {
        address owner;
        PoolKey poolKey;
        SqrtRatio lower;
        SqrtRatio upper;
    }

    mapping(PoolId => Terminal) private _terminals;

    error ExtensionOnly();
    error UnknownLaunch();
    error OwnerOnly();
    error InvalidRecipient();
    error InvalidPayment();

    /// @param from The launch extension for migrated principal, or the payer of `fund`.
    event PrincipalReceived(PoolId indexed launchId, address indexed from, uint128 amount0, uint128 amount1);
    event LiquidityLocked(PoolId indexed launchId, PoolId indexed terminalPoolId, uint128 liquidity);
    event FeesClaimed(PoolId indexed launchId, address indexed recipient, uint128 amount0, uint128 amount1);

    constructor(ICore core, address extension) BaseForwardee(core) BaseLocker(core) UsesCore(core) {
        EXTENSION = extension;
    }

    /// @notice Deploys fixed launch inventory for the extension's atomic creation path.
    function createToken(string memory name, string memory symbol, uint8 decimals, uint128 supply)
        external
        returns (address)
    {
        if (msg.sender != EXTENSION) revert ExtensionOnly();
        MintableERC20 token = new MintableERC20(address(this), name, symbol, decimals);
        token.mint(EXTENSION, supply);
        token.renounceOwnership();
        return address(token);
    }

    function getTerminal(PoolId launchId) external view returns (Terminal memory) {
        return _terminals[launchId];
    }

    function creatorFeeSalt(PoolId launchId) public pure returns (bytes32) {
        return keccak256(abi.encode("LockedLaunchLiquidity creator fees", launchId));
    }

    function positionId(PoolId launchId) public pure returns (PositionId) {
        return createPositionId(bytes24(PoolId.unwrap(launchId)), MIN_TICK, MAX_TICK);
    }

    /// @notice Retry balancing/depositing locked reserves; never removes existing principal.
    function migrate(PoolId launchId) external {
        _requireLaunch(launchId);
        lock(abi.encode(LOCK_MIGRATE, launchId, address(0), uint128(0), uint128(0)));
    }

    /// @notice Collect only this launch's position fees, never fees belonging to other LPs.
    function claimFees(PoolId launchId, address recipient) external {
        if (_terminals[launchId].owner != msg.sender) revert OwnerOnly();
        if (recipient == address(0)) revert InvalidRecipient();
        lock(abi.encode(LOCK_CLAIM, launchId, recipient, uint128(0), uint128(0)));
    }

    /// @notice Adds counterpart assets to a migrated launch's locked principal, paid by msg.sender: exactly
    /// msg.value for a native token0, otherwise by transferFrom. Funds are never withdrawable; the next
    /// migration deposits them.
    function fund(PoolId launchId, uint128 amount0, uint128 amount1) external payable {
        _requireLaunch(launchId);
        if (msg.value != (_terminals[launchId].poolKey.token0 == NATIVE_TOKEN_ADDRESS ? amount0 : 0)) {
            revert InvalidPayment();
        }
        lock(abi.encode(LOCK_FUND, launchId, msg.sender, amount0, amount1));
    }

    /// @dev Only the extension forwards, with abi.encode(Registration), to move principal at migration.
    function handleForwardData(Locker original, bytes memory data) internal override returns (bytes memory) {
        if (original.addr() != EXTENSION) revert ExtensionOnly();
        _receivePrincipal(abi.decode(data, (Registration)));
        return "";
    }

    function _receivePrincipal(Registration memory registration) private {
        if (_terminals[registration.launchId].owner == address(0)) {
            _terminals[registration.launchId] =
                Terminal(registration.owner, registration.poolKey, registration.lower, registration.upper);
        }
        _save(registration.launchId, int256(uint256(registration.amount0)), int256(uint256(registration.amount1)));
        emit PrincipalReceived(registration.launchId, EXTENSION, registration.amount0, registration.amount1);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (uint8 action, PoolId launchId, address account, uint128 amount0, uint128 amount1) =
            abi.decode(data, (uint8, PoolId, address, uint128, uint128));
        if (action == LOCK_MIGRATE) _migrate(launchId);
        else if (action == LOCK_CLAIM) _claim(launchId, account);
        else _fund(launchId, account, amount0, amount1);
        return "";
    }

    function _fund(PoolId launchId, address payer, uint128 amount0, uint128 amount1) private {
        _save(launchId, int256(uint256(amount0)), int256(uint256(amount1)));
        emit PrincipalReceived(launchId, payer, amount0, amount1);
        PoolKey memory key = _terminals[launchId].poolKey;
        _pay(payer, key.token0, amount0);
        _pay(payer, key.token1, amount1);
    }

    function _pay(address payer, address token, uint128 amount) private {
        if (amount == 0) return;
        if (token == NATIVE_TOKEN_ADDRESS) SafeTransferLib.safeTransferETH(address(CORE), amount);
        else CORE.payFrom(payer, token, amount);
    }

    function _requireLaunch(PoolId launchId) private view {
        if (_terminals[launchId].owner == address(0)) revert UnknownLaunch();
    }

    function _balances(PoolId launchId) private view returns (uint128, uint128) {
        PoolKey memory key = _terminals[launchId].poolKey;
        return CORE.savedBalances(address(this), key.token0, key.token1, PoolId.unwrap(launchId));
    }

    function _save(PoolId launchId, int256 delta0, int256 delta1) private {
        PoolKey memory key = _terminals[launchId].poolKey;
        CORE.updateSavedBalances(key.token0, key.token1, PoolId.unwrap(launchId), delta0, delta1);
    }

    function _migrate(PoolId launchId) private {
        Terminal storage terminal = _terminals[launchId];
        (uint128 amount0, uint128 amount1) = _balances(launchId);
        PoolKey memory key = terminal.poolKey;
        PoolState state = CORE.poolState(key.toPoolId());
        // Pending virtual orders execute on the first pool touch; settle them before the price is read.
        if (state.isInitialized()) {
            ITWAMM(key.config.extension()).lockAndExecuteVirtualOrders(key);
            state = CORE.poolState(key.toPoolId());
        }
        if (state.liquidity() == 0) {
            if (!_prepareEmpty(terminal, amount0, amount1)) return;
        } else {
            if (state.liquidity() == type(uint128).max) return;
            if (state.sqrtRatio() < terminal.lower || state.sqrtRatio() > terminal.upper) return;
            _balance(launchId, state, amount0, amount1);
        }
        _deposit(launchId);
    }

    function _prepareEmpty(Terminal storage terminal, uint128 amount0, uint128 amount1) private returns (bool) {
        // Without either an external counterparty or both assets there is no funded XYK pool.
        if (amount0 == 0 || amount1 == 0) return false;
        SqrtRatio price = LaunchLiquidityMath.depositPrice(amount0, amount1);
        if (price < terminal.lower || price > terminal.upper) return false;
        PoolKey memory key = terminal.poolKey;
        PoolState state = CORE.poolState(key.toPoolId());
        if (!state.isInitialized()) {
            CORE.initializePool(key, sqrtRatioToTick(price));
            state = CORE.poolState(key.toPoolId());
        }
        // An empty pool's price is not meaningful and can have been moved by anyone.
        CORE.swap(0, key, createSwapParameters(price, 1, state.sqrtRatio() < price, 0));
        return true;
    }

    function _balance(PoolId launchId, PoolState state, uint128 amount0, uint128 amount1) private {
        Terminal storage terminal = _terminals[launchId];
        LaunchLiquidityMath.Market memory market = LaunchLiquidityMath.Market(
            state.sqrtRatio(),
            terminal.lower,
            terminal.upper,
            state.liquidity(),
            terminal.poolKey.config.fee(),
            amount0,
            amount1,
            CORE.poolPositions(terminal.poolKey.toPoolId(), address(this), positionId(launchId)).liquidity
        );
        (bool token1, uint128 amount) = LaunchLiquidityMath.optimalSwap(market);
        if (amount == 0) return;
        // Preserve fees earned before this internal operation for the creator.
        _collectBeforeRebalance(launchId);
        SqrtRatio limit = token1 ? terminal.upper : terminal.lower;
        (PoolBalanceUpdate update,) =
            CORE.swap(0, terminal.poolKey, createSwapParameters(limit, int128(amount), token1, 0));
        _save(launchId, -int256(update.delta0()), -int256(update.delta1()));
        // Fees this position earns from its own migration swap remain locked principal.
        (uint128 fee0, uint128 fee1) = CORE.collectFees(terminal.poolKey, positionId(launchId));
        _save(launchId, int256(uint256(fee0)), int256(uint256(fee1)));
    }

    function _collectBeforeRebalance(PoolId launchId) private {
        PoolKey memory key = _terminals[launchId].poolKey;
        (uint128 fee0, uint128 fee1) = CORE.collectFees(key, positionId(launchId));
        CORE.updateSavedBalances(
            key.token0, key.token1, creatorFeeSalt(launchId), int256(uint256(fee0)), int256(uint256(fee1))
        );
    }

    function _deposit(PoolId launchId) private {
        Terminal storage terminal = _terminals[launchId];
        (uint128 amount0, uint128 amount1) = _balances(launchId);
        PoolState state = CORE.poolState(terminal.poolKey.toPoolId());
        if (state.sqrtRatio() < terminal.lower || state.sqrtRatio() > terminal.upper) return;
        uint128 liquidity = LaunchLiquidityMath.liquidityFor(
            state.sqrtRatio(),
            uint128(FixedPointMathLib.min(amount0, uint128(type(int128).max))),
            uint128(FixedPointMathLib.min(amount1, uint128(type(int128).max)))
        );
        liquidity = uint128(FixedPointMathLib.min(liquidity, type(uint128).max - state.liquidity()));
        liquidity = uint128(FixedPointMathLib.min(liquidity, uint128(type(int128).max)));
        if (liquidity == 0) return;
        PoolBalanceUpdate update = CORE.updatePosition(terminal.poolKey, positionId(launchId), int128(liquidity));
        _save(launchId, -int256(update.delta0()), -int256(update.delta1()));
        emit LiquidityLocked(launchId, terminal.poolKey.toPoolId(), liquidity);
    }

    function _claim(PoolId launchId, address recipient) private {
        PoolKey memory key = _terminals[launchId].poolKey;
        (uint128 amount0, uint128 amount1) = CORE.collectFees(key, positionId(launchId));
        CORE.withdrawTwo(key.token0, key.token1, recipient, amount0, amount1);
        emit FeesClaimed(launchId, recipient, amount0, amount1);
        bytes32 salt = creatorFeeSalt(launchId);
        (amount0, amount1) = CORE.savedBalances(address(this), key.token0, key.token1, salt);
        CORE.updateSavedBalances(key.token0, key.token1, salt, -int256(uint256(amount0)), -int256(uint256(amount1)));
        CORE.withdrawTwo(key.token0, key.token1, recipient, amount0, amount1);
        emit FeesClaimed(launchId, recipient, amount0, amount1);
    }
}
