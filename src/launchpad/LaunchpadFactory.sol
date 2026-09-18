// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ICore} from "../interfaces/ICore.sol";
import {BaseLocker} from "../base/BaseLocker.sol";
import {CoreLib} from "../libraries/CoreLib.sol";
import {FlashAccountantLib} from "../libraries/FlashAccountantLib.sol";
import {ScheduledLaunch} from "../extensions/ScheduledLaunch.sol";
import {LockedLaunchLiquidity} from "../LockedLaunchLiquidity.sol";
import {PoolKey} from "../types/poolKey.sol";
import {PoolId} from "../types/poolId.sol";
import {PoolState} from "../types/poolState.sol";
import {PoolBalanceUpdate} from "../types/poolBalanceUpdate.sol";
import {SwapParameters} from "../types/swapParameters.sol";
import {NATIVE_TOKEN_ADDRESS} from "../math/constants.sol";

/// @title Launchpad Factory
/// @notice Governance-gated front end for ScheduledLaunch: creates launches it owns, routes launch-phase
/// swaps with slippage protection, and splits creator fees between the creator and the revenue allocator.
/// @dev The factory is the launch owner on the extension and the terminal owner on LockedLaunchLiquidity,
/// so it is the only address that can claim either fee ledger. Claims are permissionless and always split
/// by the creator share snapshotted at creation. Post-expiry trades are ordinary swaps on the terminal pool
/// returned by ScheduledLaunch.terminalPool and route through the existing Router; nothing here is needed.
/// Native ETH quotes are not supported: all settlement uses ERC20 allowances to this contract.
contract LaunchpadFactory is BaseLocker, Ownable {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    uint256 public constant BPS = 10_000;

    ICore public immutable CORE;
    ScheduledLaunch public immutable EXTENSION;
    LockedLaunchLiquidity public immutable VAULT;
    address public immutable ALLOCATOR;

    struct Tier {
        bool enabled;
        uint16 creatorBps;
    }

    struct Registration {
        address creator;
        uint16 creatorBps;
        uint8 tier;
    }

    /// @notice Quote assets approved by governance.
    mapping(address token => bool allowed) public allowedQuote;

    /// @notice Creator revenue share per tier, in basis points.
    mapping(uint8 tier => Tier config) public tiers;

    mapping(PoolId => Registration) private _registrations;

    error QuoteNotAllowed();
    error TierDisabled();
    error InvalidShare();
    error UnknownLaunch();
    error Expired();
    error SlippageExceeded();
    error InvalidAction();

    event QuoteAllowlistUpdated(address indexed token, bool allowed);
    event TierUpdated(uint8 indexed tier, bool enabled, uint16 creatorBps);
    event LaunchRegistered(
        PoolId indexed poolId, address indexed creator, address indexed token, uint8 tier, uint16 creatorBps
    );
    event LaunchSwap(
        PoolId indexed poolId, address indexed trader, int128 delta0, int128 delta1, uint128 fee0, uint128 fee1
    );
    event FeesSplit(PoolId indexed poolId, address indexed token, uint256 creatorAmount, uint256 allocatorAmount);

    constructor(address owner, ICore core, ScheduledLaunch extension, address allocator) BaseLocker(core) {
        _initializeOwner(owner);
        CORE = core;
        EXTENSION = extension;
        VAULT = extension.LIQUIDITY();
        ALLOCATOR = allocator;
    }

    /// GOVERNANCE

    function setQuoteAllowed(address token, bool allowed) external onlyOwner {
        if (token == NATIVE_TOKEN_ADDRESS) revert QuoteNotAllowed();
        allowedQuote[token] = allowed;
        emit QuoteAllowlistUpdated(token, allowed);
    }

    function setTier(uint8 tier, bool enabled, uint16 creatorBps) external onlyOwner {
        if (creatorBps > BPS) revert InvalidShare();
        tiers[tier] = Tier(enabled, creatorBps);
        emit TierUpdated(tier, enabled, creatorBps);
    }

    /// VIEWS

    function getRegistration(PoolId poolId) external view returns (Registration memory) {
        return _registrations[poolId];
    }

    /// LAUNCH LIFECYCLE

    /// @notice Creates a launch owned by this factory. The caller funds `quoteAmount` via allowance.
    /// @dev `config.owner` is overwritten; the caller is recorded as creator for fee splitting.
    function create(ScheduledLaunch.LaunchConfig memory config, uint8 tier) external returns (PoolKey memory key) {
        if (!allowedQuote[config.quoteToken]) revert QuoteNotAllowed();
        Tier memory selected = tiers[tier];
        if (!selected.enabled) revert TierDisabled();
        config.owner = address(this);
        key = abi.decode(lock(abi.encode(uint8(0), msg.sender, config)), (PoolKey));
        PoolId poolId = key.toPoolId();
        _registrations[poolId] = Registration(msg.sender, selected.creatorBps, tier);
        emit LaunchRegistered(poolId, msg.sender, EXTENSION.getLaunch(poolId).token, tier, selected.creatorBps);
    }

    /// @notice Trades against a registered launch. Deltas are fee-inclusive and settled from the caller.
    /// @param calculatedLimit Minimum output for exact-input swaps, maximum input for exact-output swaps.
    function swap(PoolKey memory key, SwapParameters params, uint128 calculatedLimit, uint256 deadline)
        external
        returns (PoolBalanceUpdate update)
    {
        if (block.timestamp > deadline) revert Expired();
        PoolId poolId = key.toPoolId();
        _requireRegistered(poolId);
        uint128 fee0;
        uint128 fee1;
        (update, fee0, fee1) =
            abi.decode(lock(abi.encode(uint8(1), msg.sender, key, params)), (PoolBalanceUpdate, uint128, uint128));
        _checkSlippage(params, update, calculatedLimit);
        emit LaunchSwap(poolId, msg.sender, update.delta0(), update.delta1(), fee0, fee1);
    }

    /// @notice Claims launch-phase and terminal-position fees and splits them. Anyone may call.
    function claim(PoolKey memory key) external {
        PoolId poolId = key.toPoolId();
        Registration memory registration = _registrations[poolId];
        if (registration.creator == address(0)) revert UnknownLaunch();
        uint256 before0 = SafeTransferLib.balanceOf(key.token0, address(this));
        uint256 before1 = SafeTransferLib.balanceOf(key.token1, address(this));
        EXTENSION.claimFees(key, address(this));
        if (VAULT.getTerminal(poolId).owner != address(0)) VAULT.claimFees(poolId, address(this));
        _split(poolId, registration, key.token0, SafeTransferLib.balanceOf(key.token0, address(this)) - before0);
        _split(poolId, registration, key.token1, SafeTransferLib.balanceOf(key.token1, address(this)) - before1);
    }

    /// LOCK HANDLING

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        uint8 action = abi.decode(data, (uint8));
        if (action == 0) return _create(data);
        if (action == 1) return _swap(data);
        revert InvalidAction();
    }

    function _create(bytes memory data) private returns (bytes memory result) {
        (, address creator, ScheduledLaunch.LaunchConfig memory config) =
            abi.decode(data, (uint8, address, ScheduledLaunch.LaunchConfig));
        result = ACCOUNTANT.forward(address(EXTENSION), abi.encode(uint8(0), config));
        if (config.quoteAmount != 0) ACCOUNTANT.payFrom(creator, config.quoteToken, config.quoteAmount);
    }

    function _swap(bytes memory data) private returns (bytes memory) {
        (, address trader, PoolKey memory key, SwapParameters params) =
            abi.decode(data, (uint8, address, PoolKey, SwapParameters));
        (uint128 before0, uint128 before1) = _creatorFees(key);
        (PoolBalanceUpdate update,) = abi.decode(
            ACCOUNTANT.forward(address(EXTENSION), abi.encode(uint8(1), key, params)), (PoolBalanceUpdate, PoolState)
        );
        (uint128 after0, uint128 after1) = _creatorFees(key);
        _settle(trader, key.token0, update.delta0());
        _settle(trader, key.token1, update.delta1());
        return abi.encode(update, after0 - before0, after1 - before1);
    }

    function _settle(address trader, address token, int128 delta) private {
        if (delta > 0) ACCOUNTANT.payFrom(trader, token, uint128(delta));
        else if (delta < 0) ACCOUNTANT.withdraw(token, trader, uint128(-delta));
    }

    function _creatorFees(PoolKey memory key) private view returns (uint128, uint128) {
        return CORE.savedBalances(address(EXTENSION), key.token0, key.token1, EXTENSION.creatorFeeSalt(key.toPoolId()));
    }

    /// @dev The fee is charged on the calculated side: output for exact-in, input for exact-out.
    function _checkSlippage(SwapParameters params, PoolBalanceUpdate update, uint128 calculatedLimit) private pure {
        int128 calculated = params.isToken1() ? update.delta0() : update.delta1();
        if (params.isExactOut()) {
            if (uint128(calculated) > calculatedLimit) revert SlippageExceeded();
        } else if (uint128(-calculated) < calculatedLimit) {
            revert SlippageExceeded();
        }
    }

    function _split(PoolId poolId, Registration memory registration, address token, uint256 amount) private {
        if (amount == 0) return;
        uint256 creatorAmount = amount * registration.creatorBps / BPS;
        uint256 allocatorAmount = amount - creatorAmount;
        if (creatorAmount != 0) SafeTransferLib.safeTransfer(token, registration.creator, creatorAmount);
        if (allocatorAmount != 0) SafeTransferLib.safeTransfer(token, ALLOCATOR, allocatorAmount);
        emit FeesSplit(poolId, token, creatorAmount, allocatorAmount);
    }

    function _requireRegistered(PoolId poolId) private view {
        if (_registrations[poolId].creator == address(0)) revert UnknownLaunch();
    }
}
