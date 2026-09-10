// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {ICore} from "./interfaces/ICore.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolId} from "./types/poolId.sol";
import {PositionId, createPositionId} from "./types/positionId.sol";
import {Position} from "./types/position.sol";
import {FeesPerLiquidity} from "./types/feesPerLiquidity.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity, liquidityDeltaToAmountDelta} from "./math/liquidity.sol";
import {MIN_TICK, MAX_TICK, NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {FreeLPMetadata} from "./libraries/FreeLPMetadata.sol";

/// @notice Ownerless, zero-fee positions with one immutable pool/range per NFT and RPC-readable ownership.
/// @dev Adapted from BasePositions settlement. No swap, extension, admin, or external metadata dependency.
///      Nonpayable multicall supports ERC20 operations; native deposits are standalone and refund exact excess.
contract FreeLP is ERC721, BaseLocker, Multicallable {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    struct Descriptor {
        PoolKey poolKey;
        int32 tickLower;
        int32 tickUpper;
    }

    struct Amounts {
        uint128 liquidity;
        uint128 principal0;
        uint128 principal1;
        uint128 fees0;
        uint128 fees1;
    }

    struct DepositLimits {
        uint128 maxAmount0;
        uint128 maxAmount1;
        uint128 minLiquidity;
        uint256 deadline;
    }

    error Unauthorized();
    error UnsupportedPool();
    error InvalidRange();
    error Expired();
    error Slippage();
    error InvalidValue();
    error PositionNotEmpty();
    error Reentrancy();
    error InvalidPage();
    error InvalidCore();

    event PositionCreated(uint256 indexed id, address indexed holder, PoolKey poolKey, int32 lower, int32 upper);
    event LiquidityAdded(uint256 indexed id, uint128 liquidity, uint128 amount0, uint128 amount1);
    event LiquidityRemoved(uint256 indexed id, uint128 liquidity, uint128 amount0, uint128 amount1);

    ICore public immutable CORE;
    uint192 private _nextId;
    bool private _mutating;
    mapping(uint256 => Descriptor) private _descriptors;
    mapping(address => uint256[]) private _owned;
    mapping(uint256 => uint256) private _index;

    constructor(ICore core) BaseLocker(core) {
        if (address(core).code.length == 0) revert InvalidCore();
        CORE = core;
    }

    modifier guarded() {
        if (_mutating) revert Reentrancy();
        _mutating = true;
        _;
        _mutating = false;
    }

    function name() public pure override returns (string memory) {
        return "Liquidity Position";
    }

    function symbol() public pure override returns (string memory) {
        return "LP";
    }

    function descriptor(uint256 id) public view returns (Descriptor memory) {
        ownerOf(id);
        return _descriptors[id];
    }

    /// @notice Read all pages at the same block to obtain a consistent ownership snapshot.
    function ownedIds(address holder, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 total)
    {
        if (limit == 0 || limit > 100) revert InvalidPage();
        total = _owned[holder].length;
        if (offset >= total) return (new uint256[](0), total);
        uint256 count = total - offset;
        if (count > limit) count = limit;
        ids = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            ids[i] = _owned[holder][offset + i];
        }
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        Descriptor memory d = descriptor(id);
        return FreeLPMetadata.tokenURI(id, address(CORE), d.poolKey, d.tickLower, d.tickUpper);
    }

    function poolState(PoolKey memory key) public view returns (uint256 sqrtRatio, int32 tick, uint128 liquidity) {
        SqrtRatio ratio;
        (ratio, tick, liquidity) = CORE.poolState(key.toPoolId()).parse();
        sqrtRatio = ratio.toFixed();
    }

    function positionAmounts(uint256 id) public view returns (Amounts memory a) {
        Descriptor memory d = descriptor(id);
        PoolId poolId = d.poolKey.toPoolId();
        Position memory p = CORE.poolPositions(poolId, address(this), _positionId(id, d));
        a.liquidity = p.liquidity;
        (int128 delta0, int128 delta1) = liquidityDeltaToAmountDelta(
            CORE.poolState(poolId).sqrtRatio(),
            -int128(p.liquidity),
            tickToSqrtRatio(d.tickLower),
            tickToSqrtRatio(d.tickUpper)
        );
        (a.principal0, a.principal1) = (uint128(-delta0), uint128(-delta1));
        FeesPerLiquidity memory f = CORE.getPoolFeesPerLiquidityInside(poolId, d.tickLower, d.tickUpper);
        (a.fees0, a.fees1) = p.fees(f);
    }

    /// @notice Quote a deposit without approvals or token transfers, including a not-yet-initialized pool.
    function quoteDeposit(Descriptor memory d, int32 initialTick, uint128 max0, uint128 max1)
        external
        view
        returns (uint128 liquidity, uint128 amount0, uint128 amount1)
    {
        _validate(d);
        SqrtRatio ratio = CORE.poolState(d.poolKey.toPoolId()).sqrtRatio();
        if (ratio.isZero()) ratio = tickToSqrtRatio(initialTick);
        liquidity = maxLiquidity(ratio, tickToSqrtRatio(d.tickLower), tickToSqrtRatio(d.tickUpper), max0, max1);
        if (liquidity > uint128(type(int128).max)) revert InvalidValue();
        (int128 a, int128 b) = liquidityDeltaToAmountDelta(
            ratio, int128(liquidity), tickToSqrtRatio(d.tickLower), tickToSqrtRatio(d.tickUpper)
        );
        (amount0, amount1) = (uint128(a), uint128(b));
    }

    /// @notice Initializes a missing pool at initialTick, then mints and funds a position atomically.
    function createPosition(Descriptor memory d, int32 initialTick, DepositLimits memory limits)
        external
        payable
        guarded
        returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1)
    {
        _validate(d);
        _deadline(limits.deadline);
        if (CORE.poolState(d.poolKey.toPoolId()).sqrtRatio().isZero()) CORE.initializePool(d.poolKey, initialTick);
        id = ++_nextId;
        _descriptors[id] = d;
        _mint(msg.sender, id);
        (liquidity, amount0, amount1) = _deposit(id, d, limits);
        emit PositionCreated(id, msg.sender, d.poolKey, d.tickLower, d.tickUpper);
    }

    function addLiquidity(uint256 id, DepositLimits memory limits)
        external
        payable
        guarded
        returns (uint128 liquidity, uint128 amount0, uint128 amount1)
    {
        _authorize(id);
        _deadline(limits.deadline);
        return _deposit(id, _descriptors[id], limits);
    }

    /// @notice Withdrawal always collects fees; liquidity=0 is fee collection. Minimums include fees.
    function withdraw(uint256 id, uint128 liquidity, address recipient, uint128 min0, uint128 min1, uint256 deadline)
        external
        guarded
        returns (uint128 amount0, uint128 amount1)
    {
        _authorize(id);
        _deadline(deadline);
        if (recipient == address(0)) revert InvalidValue();
        if (liquidity > uint128(type(int128).max)) revert InvalidValue();
        (amount0, amount1) =
            abi.decode(lock(abi.encode(false, msg.sender, id, liquidity, recipient)), (uint128, uint128));
        if (amount0 < min0 || amount1 < min1) revert Slippage();
        emit LiquidityRemoved(id, liquidity, amount0, amount1);
    }

    function burn(uint256 id) external guarded {
        _authorize(id);
        Amounts memory a = positionAmounts(id);
        if (a.liquidity != 0 || a.fees0 != 0 || a.fees1 != 0) revert PositionNotEmpty();
        _burn(id);
        delete _descriptors[id];
    }

    function _authorize(uint256 id) private view {
        if (!_isApprovedOrOwner(msg.sender, id)) revert Unauthorized();
    }

    function _deadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
    }

    function _validate(Descriptor memory d) private pure {
        d.poolKey.validate();
        if (d.poolKey.config.extension() != address(0) || !d.poolKey.config.isConcentrated()) revert UnsupportedPool();
        if (d.tickLower < MIN_TICK || d.tickUpper > MAX_TICK || d.tickLower >= d.tickUpper) revert InvalidRange();
        int32 spacing = int32(d.poolKey.config.concentratedTickSpacing());
        if (d.tickLower % spacing != 0 || d.tickUpper % spacing != 0) revert InvalidRange();
    }

    function _positionId(uint256 id, Descriptor memory d) private pure returns (PositionId) {
        return createPositionId(bytes24(uint192(id)), d.tickLower, d.tickUpper);
    }

    function _deposit(uint256 id, Descriptor memory d, DepositLimits memory limits)
        private
        returns (uint128 liquidity, uint128 amount0, uint128 amount1)
    {
        liquidity = maxLiquidity(
            CORE.poolState(d.poolKey.toPoolId()).sqrtRatio(),
            tickToSqrtRatio(d.tickLower),
            tickToSqrtRatio(d.tickUpper),
            limits.maxAmount0,
            limits.maxAmount1
        );
        uint128 existing = CORE.poolPositions(d.poolKey.toPoolId(), address(this), _positionId(id, d)).liquidity;
        if (liquidity == 0 || liquidity < limits.minLiquidity) revert Slippage();
        if (uint256(existing) + liquidity > uint128(type(int128).max)) revert InvalidValue();
        (amount0, amount1) =
            abi.decode(lock(abi.encode(true, msg.sender, id, liquidity, address(0))), (uint128, uint128));
        if (amount0 > limits.maxAmount0 || amount1 > limits.maxAmount1) revert Slippage();
        uint256 spent = d.poolKey.token0 == NATIVE_TOKEN_ADDRESS ? amount0 : 0;
        if (msg.value < spent) revert InvalidValue();
        if (msg.value > spent) SafeTransferLib.safeTransferETH(msg.sender, msg.value - spent);
        emit LiquidityAdded(id, liquidity, amount0, amount1);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (bool deposit, address payer, uint256 id, uint128 liquidity, address recipient) =
            abi.decode(data, (bool, address, uint256, uint128, address));
        Descriptor memory d = _descriptors[id];
        if (deposit) return _settleDeposit(id, d, payer, liquidity);
        return _settleWithdraw(id, d, recipient, liquidity);
    }

    function _settleDeposit(uint256 id, Descriptor memory d, address payer, uint128 liquidity)
        private
        returns (bytes memory)
    {
        PoolBalanceUpdate update = CORE.updatePosition(d.poolKey, _positionId(id, d), int128(liquidity));
        uint128 amount0 = uint128(update.delta0());
        uint128 amount1 = uint128(update.delta1());
        if (d.poolKey.token0 == NATIVE_TOKEN_ADDRESS) {
            if (amount0 != 0) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount0);
            if (amount1 != 0) ACCOUNTANT.payFrom(payer, d.poolKey.token1, amount1);
        } else {
            ACCOUNTANT.payTwoFrom(payer, d.poolKey.token0, d.poolKey.token1, amount0, amount1);
        }
        return abi.encode(amount0, amount1);
    }

    function _settleWithdraw(uint256 id, Descriptor memory d, address recipient, uint128 liquidity)
        private
        returns (bytes memory)
    {
        (uint128 amount0, uint128 amount1) = CORE.collectFees(d.poolKey, _positionId(id, d));
        if (liquidity != 0) {
            PoolBalanceUpdate update = CORE.updatePosition(d.poolKey, _positionId(id, d), -int128(liquidity));
            amount0 += uint128(-update.delta0());
            amount1 += uint128(-update.delta1());
        }
        ACCOUNTANT.withdrawTwo(d.poolKey.token0, d.poolKey.token1, recipient, amount0, amount1);
        return abi.encode(amount0, amount1);
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        if (_mutating && from != address(0) && to != address(0)) revert Reentrancy();
    }

    function _afterTokenTransfer(address from, address to, uint256 id) internal override {
        if (from == to) return;
        if (from != address(0)) _removeOwned(from, id);
        if (to != address(0)) {
            _index[id] = _owned[to].length;
            _owned[to].push(id);
        }
    }

    function _removeOwned(address from, uint256 id) private {
        uint256 index = _index[id];
        uint256 last = _owned[from][_owned[from].length - 1];
        _owned[from][index] = last;
        _index[last] = index;
        _owned[from].pop();
        delete _index[id];
    }
}
