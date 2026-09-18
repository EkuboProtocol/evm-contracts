// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {TreasuryVault} from "./TreasuryVault.sol";
import {EarmarkVault} from "./EarmarkVault.sol";
import {HolderVault} from "./HolderVault.sol";

/// @title Revenue Allocator
/// @notice Splits protocol revenue arriving from the launchpad factory into five fixed legs.
/// @dev Permissionless: anyone may call allocate for any ERC20 the contract holds. Fees denominated in a
/// launch token are split the same way as quote-token fees and are held unconverted by each destination.
/// The three earmark destinations are deployed by this contract so their ALLOCATOR is fixed to it.
/// The treasury must register this contract as a depositor before the first allocation.
contract RevenueAllocator {
    uint256 public constant BPS = 10_000;
    uint256 public constant TREASURY_BPS = 2500;
    uint256 public constant HOLDER_BPS = 2000;
    uint256 public constant RUNR_BUYBACK_BPS = 3000;
    uint256 public constant ECO_BPS = 1500;
    uint256 public constant OPS_BPS = 1000;

    TreasuryVault public immutable TREASURY;
    HolderVault public immutable HOLDER_VAULT;
    EarmarkVault public immutable RUNR_VAULT;
    EarmarkVault public immutable ECO_VAULT;
    address public immutable OPS;

    /// @notice Cumulative amount routed to each leg, per token.
    struct Totals {
        uint256 treasury;
        uint256 holders;
        uint256 runrBuyback;
        uint256 ecosystem;
        uint256 ops;
    }

    /// @notice Balance retained after the last allocation; new revenue is anything above it.
    mapping(address token => uint256 balance) public accounted;

    mapping(address token => Totals totals) private _totals;

    error NothingToAllocate();
    error InvalidDestination();

    event Allocated(
        address indexed token,
        uint256 amount,
        uint256 treasury,
        uint256 holders,
        uint256 runrBuyback,
        uint256 ecosystem,
        uint256 ops
    );

    constructor(address vaultOwner, TreasuryVault treasury, address ops) {
        if (address(treasury) == address(0) || ops == address(0)) revert InvalidDestination();
        TREASURY = treasury;
        OPS = ops;
        HOLDER_VAULT = new HolderVault(vaultOwner, address(this));
        RUNR_VAULT = new EarmarkVault(vaultOwner, address(this), "RUNR buyback");
        ECO_VAULT = new EarmarkVault(vaultOwner, address(this), "Ecosystem buyback");
    }

    function totals(address token) external view returns (Totals memory) {
        return _totals[token];
    }

    /// @notice Revenue received since the last allocation.
    function pending(address token) public view returns (uint256) {
        return SafeTransferLib.balanceOf(token, address(this)) - accounted[token];
    }

    /// @notice Splits all newly arrived `token` across the five legs. Rounding dust goes to the treasury.
    function allocate(address token) external {
        uint256 amount = pending(token);
        if (amount == 0) revert NothingToAllocate();
        Totals memory legs = split(amount);
        _pushTreasury(token, legs.treasury);
        _pushEarmark(HOLDER_VAULT, token, legs.holders);
        _pushEarmark(RUNR_VAULT, token, legs.runrBuyback);
        _pushEarmark(ECO_VAULT, token, legs.ecosystem);
        if (legs.ops != 0) SafeTransferLib.safeTransfer(token, OPS, legs.ops);
        _record(token, legs);
        accounted[token] = SafeTransferLib.balanceOf(token, address(this));
        emit Allocated(token, amount, legs.treasury, legs.holders, legs.runrBuyback, legs.ecosystem, legs.ops);
    }

    /// @notice Pure split of `amount`; the treasury leg absorbs the rounding remainder.
    function split(uint256 amount) public pure returns (Totals memory legs) {
        legs.holders = amount * HOLDER_BPS / BPS;
        legs.runrBuyback = amount * RUNR_BUYBACK_BPS / BPS;
        legs.ecosystem = amount * ECO_BPS / BPS;
        legs.ops = amount * OPS_BPS / BPS;
        legs.treasury = amount - legs.holders - legs.runrBuyback - legs.ecosystem - legs.ops;
    }

    function _pushTreasury(address token, uint256 amount) private {
        if (amount == 0) return;
        SafeTransferLib.safeApproveWithRetry(token, address(TREASURY), amount);
        TREASURY.deposit(token, TreasuryVault.Category.UNRESTRICTED, amount);
    }

    function _pushEarmark(EarmarkVault vault, address token, uint256 amount) private {
        if (amount == 0) return;
        SafeTransferLib.safeApproveWithRetry(token, address(vault), amount);
        vault.deposit(token, amount);
    }

    function _record(address token, Totals memory legs) private {
        Totals storage running = _totals[token];
        running.treasury += legs.treasury;
        running.holders += legs.holders;
        running.runrBuyback += legs.runrBuyback;
        running.ecosystem += legs.ecosystem;
        running.ops += legs.ops;
    }
}
