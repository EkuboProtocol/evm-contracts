// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {ICore} from "./interfaces/ICore.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {PoolConfig} from "./types/poolConfig.sol";
import {PoolKey} from "./types/poolKey.sol";
import {FreeLPPool, FreeLPRange, createFreeLPPool, createFreeLPRange} from "./types/freeLPDescriptor.sol";
import {PoolId} from "./types/poolId.sol";
import {PositionId, createPositionId} from "./types/positionId.sol";
import {Position} from "./types/position.sol";
import {FeesPerLiquidity} from "./types/feesPerLiquidity.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity, liquidityDeltaToAmountDelta} from "./math/liquidity.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {FreeLPMetadata} from "./libraries/FreeLPMetadata.sol";

/// @notice Ownerless, zero-fee positions with one immutable pool/range per NFT and RPC-readable ownership.
/// @dev Adapted from BasePositions settlement. No swap, admin, or external metadata dependency. Pool extensions are selected by the depositor.
///      Nonpayable multicall supports ERC20 operations; native deposits are standalone and refund exact excess.
contract FreeLP is ERC721, BaseLocker, Multicallable {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    struct Descriptor {
        PoolKey poolKey;
        int32 tickLower;
        int32 tickUpper;
    }

    // Three slots per NFT: token0/config; token1/ticks/extension high; indexes/extension low.
    struct StoredPosition {
        FreeLPPool pool;
        FreeLPRange range;
        uint64 ownerIndex;
        uint64 globalIndex;
        uint128 extensionLow;
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
    error Expired();
    error Slippage();
    error InvalidValue();
    error Reentrancy();
    error EnumerationIndexOutOfBounds();
    error InvalidCore();
    error TokenIdsExhausted();

    event PositionCreated(uint256 indexed id, address indexed holder, PoolKey poolKey, int32 lower, int32 upper);
    event LiquidityAdded(uint256 indexed id, uint128 liquidity, uint128 amount0, uint128 amount1);
    event LiquidityRemoved(uint256 indexed id, uint128 liquidity, uint128 amount0, uint128 amount1);

    ICore public immutable CORE;
    uint64 private _nextId;
    bool private _mutating;
    mapping(uint256 => StoredPosition) private _positions;
    // Four IDs per slot. Lengths/indexes cannot exceed the monotonically minted ID count.
    mapping(address => uint64[]) private _owned;
    uint64[] private _tokens;

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
        return _descriptor(id);
    }

    function _descriptor(uint256 id) private view returns (Descriptor memory) {
        StoredPosition storage p = _positions[id];
        FreeLPPool pool = p.pool;
        FreeLPRange range = p.range;
        PoolConfig config = pool.fullConfig(range, p.extensionLow);
        return Descriptor(PoolKey(pool.token0(), range.token1(), config), range.tickLower(), range.tickUpper());
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x780e9d63 || super.supportsInterface(interfaceId);
    }

    function totalSupply() public view returns (uint256) {
        return _tokens.length;
    }

    function tokenByIndex(uint256 index) public view returns (uint256) {
        if (index >= _tokens.length) revert EnumerationIndexOutOfBounds();
        return _tokens[index];
    }

    /// @notice Enumeration order is unspecified. Pin reads to one block and sort in the client.
    function tokenOfOwnerByIndex(address holder, uint256 index) public view returns (uint256) {
        if (holder == address(0) || index >= _owned[holder].length) revert EnumerationIndexOutOfBounds();
        return _owned[holder][index];
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
        FeesPerLiquidity memory f = d.poolKey.config.isStableswap()
            ? CORE.getPoolFeesPerLiquidity(poolId)
            : CORE.getPoolFeesPerLiquidityInside(poolId, d.tickLower, d.tickUpper);
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
        if (_nextId == type(uint64).max) revert TokenIdsExhausted();
        id = ++_nextId;
        StoredPosition storage p = _positions[id];
        p.pool = createFreeLPPool(d.poolKey.token0, d.poolKey.config);
        p.range = createFreeLPRange(d.poolKey.token1, d.tickLower, d.tickUpper, d.poolKey.config.extension());
        p.extensionLow = uint128(uint160(d.poolKey.config.extension()));
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
        return _deposit(id, _descriptor(id), limits);
    }

    /// @notice Withdrawal always collects fees; liquidity=0 is fee collection. Minimums include fees.
    ///         Removing the remaining liquidity burns the NFT and clears its descriptor and enumeration storage.
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

    function _authorize(uint256 id) private view {
        if (!_isApprovedOrOwner(msg.sender, id)) revert Unauthorized();
    }

    function _deadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
    }

    function _validate(Descriptor memory d) private pure {
        d.poolKey.validate();
        _positionId(0, d).validate(d.poolKey.config);
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
        Descriptor memory d = _descriptor(id);
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
            if (CORE.poolPositions(d.poolKey.toPoolId(), address(this), _positionId(id, d)).liquidity == 0) {
                _burn(id);
                delete _positions[id];
            }
        }
        ACCOUNTANT.withdrawTwo(d.poolKey.token0, d.poolKey.token1, recipient, amount0, amount1);
        return abi.encode(amount0, amount1);
    }

    function _beforeTokenTransfer(address from, address to, uint256) internal view override {
        if (_mutating && from != address(0) && to != address(0)) revert Reentrancy();
    }

    function _afterTokenTransfer(address from, address to, uint256 id) internal override {
        if (from == to) return;
        if (from == address(0)) {
            _positions[id].globalIndex = uint64(_tokens.length);
            _tokens.push(uint64(id));
        } else if (to == address(0)) {
            uint64 index = _positions[id].globalIndex;
            uint64 last = _tokens[_tokens.length - 1];
            _tokens[index] = last;
            _positions[last].globalIndex = index;
            _tokens.pop();
        }
        if (from != address(0)) _removeOwned(from, id);
        if (to != address(0)) {
            _positions[id].ownerIndex = uint64(_owned[to].length);
            _owned[to].push(uint64(id));
        }
    }

    // The moved NFT index is overwritten on transfer; burn deletes its entire StoredPosition.
    function _removeOwned(address from, uint256 id) private {
        uint64 index = _positions[id].ownerIndex;
        uint64 last = _owned[from][_owned[from].length - 1];
        _owned[from][index] = last;
        _positions[last].ownerIndex = index;
        _owned[from].pop();
    }
}
