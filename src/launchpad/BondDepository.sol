// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TreasuryVault} from "./TreasuryVault.sol";

/// @title Bond Depository
/// @notice Sells RUNR from prefunded inventory for approved assets, paid out on a linear vesting schedule.
/// @dev V1 mints nothing. Every bond is backed at purchase time by unowed RUNR already held here, so total
/// outstanding payout can never exceed inventory. Purchased assets go straight to the treasury under the
/// BOND category; the treasury must register this contract as a depositor. Vesting is linear from purchase
/// and fully claimable at `start + duration`.
contract BondDepository is Ownable {
    uint256 public constant PRICE_SCALE = 1e18;
    uint32 public constant MIN_VESTING = 1 days;
    uint32 public constant MAX_VESTING = 365 days;

    address public immutable RUNR;
    TreasuryVault public immutable TREASURY;

    struct Market {
        bool enabled;
        /// @dev RUNR paid per unit of asset, scaled by PRICE_SCALE.
        uint128 runrPerAsset;
        /// @dev Remaining RUNR payout this market may still issue.
        uint128 capacity;
        uint32 vesting;
    }

    struct Bond {
        address owner;
        uint128 payout;
        uint128 claimed;
        uint64 start;
        uint32 duration;
    }

    mapping(address asset => Market market) public markets;
    mapping(uint256 bondId => Bond bond) private _bonds;

    uint256 public nextBondId;

    /// @notice RUNR promised to bond holders and not yet claimed.
    uint256 public owed;

    bool public paused;

    error Paused();
    error MarketDisabled();
    error InvalidMarket();
    error InvalidVesting();
    error ZeroPayout();
    error PayoutBelowMinimum();
    error CapacityExceeded();
    error InsufficientInventory();
    error BondOwnerOnly();
    error NothingToClaim();

    event MarketConfigured(address indexed asset, bool enabled, uint128 runrPerAsset, uint128 capacity, uint32 vesting);
    event PausedUpdated(bool paused);
    event InventoryFunded(address indexed from, uint256 amount);
    event InventoryWithdrawn(address indexed to, uint256 amount);
    event BondPurchased(
        uint256 indexed bondId, address indexed owner, address indexed asset, uint256 amountIn, uint128 payout
    );
    event BondClaimed(uint256 indexed bondId, address indexed owner, uint128 amount);

    constructor(address owner, address runr, TreasuryVault treasury) {
        _initializeOwner(owner);
        RUNR = runr;
        TREASURY = treasury;
    }

    /// GOVERNANCE

    /// @notice Enables or updates a bond market for `asset` within the hard vesting caps.
    function configure(address asset, bool enabled, uint128 runrPerAsset, uint128 capacity, uint32 vesting)
        external
        onlyOwner
    {
        if (asset == RUNR || asset == address(0)) revert InvalidMarket();
        if (vesting < MIN_VESTING || vesting > MAX_VESTING) revert InvalidVesting();
        markets[asset] = Market(enabled, runrPerAsset, capacity, vesting);
        emit MarketConfigured(asset, enabled, runrPerAsset, capacity, vesting);
    }

    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PausedUpdated(value);
    }

    /// @notice Pulls RUNR from the caller into inventory backing future bonds.
    function fund(uint256 amount) external {
        SafeTransferLib.safeTransferFrom(RUNR, msg.sender, address(this), amount);
        emit InventoryFunded(msg.sender, amount);
    }

    /// @notice Withdraws RUNR that is not owed to any bond holder.
    function withdrawInventory(address to, uint256 amount) external onlyOwner {
        if (amount > inventory()) revert InsufficientInventory();
        SafeTransferLib.safeTransfer(RUNR, to, amount);
        emit InventoryWithdrawn(to, amount);
    }

    /// VIEWS

    function getBond(uint256 bondId) external view returns (Bond memory) {
        return _bonds[bondId];
    }

    /// @notice RUNR held here that is not yet promised to a bond.
    function inventory() public view returns (uint256) {
        return SafeTransferLib.balanceOf(RUNR, address(this)) - owed;
    }

    /// @notice RUNR payout for depositing `amount` of `asset` at the current market price.
    function payoutFor(address asset, uint256 amount) public view returns (uint128) {
        return uint128(FixedPointMathLib.fullMulDiv(amount, markets[asset].runrPerAsset, PRICE_SCALE));
    }

    /// @notice Amount of a bond's payout unlocked so far.
    function vested(uint256 bondId) public view returns (uint128) {
        Bond storage bond = _bonds[bondId];
        uint256 elapsed = block.timestamp - bond.start;
        if (elapsed >= bond.duration) return bond.payout;
        return uint128(uint256(bond.payout) * elapsed / bond.duration);
    }

    function claimable(uint256 bondId) public view returns (uint128) {
        return vested(bondId) - _bonds[bondId].claimed;
    }

    /// USER ACTIONS

    /// @notice Deposits `amount` of `asset` into the treasury and opens a vesting RUNR bond.
    function deposit(address asset, uint256 amount, uint128 minPayout) external returns (uint256 bondId) {
        if (paused) revert Paused();
        Market storage market = markets[asset];
        uint128 payout = _quote(market, asset, amount, minPayout);
        market.capacity -= payout;
        owed += payout;
        bondId = nextBondId++;
        _bonds[bondId] = Bond(msg.sender, payout, 0, uint64(block.timestamp), market.vesting);
        SafeTransferLib.safeTransferFrom(asset, msg.sender, address(this), amount);
        SafeTransferLib.safeApproveWithRetry(asset, address(TREASURY), amount);
        TREASURY.deposit(asset, TreasuryVault.Category.BOND, amount);
        emit BondPurchased(bondId, msg.sender, asset, amount, payout);
    }

    /// @notice Pays out whatever has vested on `bondId` and not yet been claimed.
    function claim(uint256 bondId) external returns (uint128 amount) {
        Bond storage bond = _bonds[bondId];
        if (bond.owner != msg.sender) revert BondOwnerOnly();
        amount = claimable(bondId);
        if (amount == 0) revert NothingToClaim();
        bond.claimed += amount;
        owed -= amount;
        SafeTransferLib.safeTransfer(RUNR, msg.sender, amount);
        emit BondClaimed(bondId, msg.sender, amount);
    }

    function _quote(Market storage market, address asset, uint256 amount, uint128 minPayout)
        private
        view
        returns (uint128 payout)
    {
        if (!market.enabled) revert MarketDisabled();
        payout = payoutFor(asset, amount);
        if (payout == 0) revert ZeroPayout();
        if (payout < minPayout) revert PayoutBelowMinimum();
        if (payout > market.capacity) revert CapacityExceeded();
        if (payout > inventory()) revert InsufficientInventory();
    }
}
