// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC721} from "solady/tokens/ERC721.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {ICore} from "./interfaces/ICore.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolKeyIndex} from "./PoolKeyIndex.sol";
import {PoolId} from "./types/poolId.sol";
import {PositionId, createPositionId} from "./types/positionId.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity} from "./math/liquidity.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {FreeLPMetadata} from "./libraries/FreeLPMetadata.sol";

/// @notice Ownerless, zero-fee positions with one immutable pool/range per NFT and RPC-readable ownership.
/// @dev Adapted from BasePositions settlement. No swap, admin, or external metadata dependency. Pool extensions are selected by the depositor.
///      Native deposits spend the shared call balance; append refundNativeToken to refund excess.
contract FreeLP is ERC721, BaseLocker, PayableMulticallable {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    struct Descriptor {
        PoolKey poolKey;
        int32 tickLower;
        int32 tickUpper;
    }

    // Two slots per NFT. Bounds occupy 64 of the ERC721 owner slot's 96 extra bits.
    // Pool keys live in the shared PoolKeyIndex and survive the last position's burn.
    struct StoredPosition {
        PoolId poolId;
        uint64 ownerIndex;
        uint64 globalIndex;
    }

    error Unauthorized();
    error Slippage();
    error InvalidValue();
    error EnumerationIndexOutOfBounds();
    error InvalidCore();
    error TokenIdsExhausted();

    event PositionCreated(uint256 indexed id, address indexed holder, PoolKey poolKey, int32 lower, int32 upper);
    event LiquidityAdded(uint256 indexed id, uint128 liquidity, uint128 amount0, uint128 amount1);
    event LiquidityRemoved(uint256 indexed id, uint128 liquidity, uint128 amount0, uint128 amount1);

    ICore public immutable CORE;
    PoolKeyIndex public immutable POOL_KEY_INDEX;
    uint64 private _nextId;
    mapping(uint256 => StoredPosition) private _positions;
    // Four IDs per slot. Lengths/indexes cannot exceed the monotonically minted ID count.
    mapping(address => uint64[]) private _owned;
    uint64[] private _tokens;

    /// @param index The shared PoolKeyIndex deployed for this core.
    constructor(ICore core, PoolKeyIndex index) BaseLocker(core) {
        if (address(core).code.length == 0) revert InvalidCore();
        if (address(index).code.length == 0) revert InvalidValue();
        CORE = core;
        POOL_KEY_INDEX = index;
    }

    receive() external payable {
        if (msg.sender != address(CORE)) revert Unauthorized();
    }

    function name() public pure override returns (string memory) {
        return "Liquidity Position";
    }

    function symbol() public pure override returns (string memory) {
        return "LP";
    }

    function position(uint256 id) public view returns (PoolId poolId, int32 tickLower, int32 tickUpper) {
        ownerOf(id);
        uint96 bounds = _getExtraData(id);
        return (_positions[id].poolId, int32(uint32(bounds)), int32(uint32(bounds >> 32)));
    }

    function _descriptor(uint256 id) private view returns (Descriptor memory) {
        uint96 bounds = _getExtraData(id);
        PoolKey memory key;
        (key.token0, key.token1, key.config) = POOL_KEY_INDEX.poolKeyById(_positions[id].poolId);
        return Descriptor(key, int32(uint32(bounds)), int32(uint32(bounds >> 32)));
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
        ownerOf(id);
        Descriptor memory d = _descriptor(id);
        return FreeLPMetadata.tokenURI(id, address(CORE), d.poolKey, d.tickLower, d.tickUpper);
    }

    /// @notice Initializes a missing pool at initialTick, then mints and funds a position atomically.
    function createPosition(
        PoolKey memory key,
        int32 lower,
        int32 upper,
        int32 initialTick,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1) {
        Descriptor memory d = Descriptor(key, lower, upper);
        _validate(d);
        PoolId poolId = key.toPoolId();
        if (CORE.poolState(poolId).sqrtRatio().isZero()) CORE.initializePool(key, initialTick);
        if (!POOL_KEY_INDEX.isRegistered(poolId)) POOL_KEY_INDEX.register(key);
        if (_nextId == type(uint64).max) revert TokenIdsExhausted();
        id = ++_nextId;
        _positions[id].poolId = poolId;
        _mintAndSetExtraDataUnchecked(msg.sender, id, uint96(uint32(lower)) | (uint96(uint32(upper)) << 32));
        (liquidity, amount0, amount1) = _deposit(id, d, maxAmount0, maxAmount1, minLiquidity);
        emit PositionCreated(id, msg.sender, d.poolKey, d.tickLower, d.tickUpper);
    }

    function addLiquidity(uint256 id, uint128 maxAmount0, uint128 maxAmount1, uint128 minLiquidity)
        external
        payable
        returns (uint128 liquidity, uint128 amount0, uint128 amount1)
    {
        _authorize(id);
        return _deposit(id, _descriptor(id), maxAmount0, maxAmount1, minLiquidity);
    }

    /// @notice Withdrawal always collects fees; liquidity=0 is fee collection. Minimums include fees.
    ///         Removing the remaining liquidity burns the NFT and clears its descriptor and enumeration storage.
    function withdraw(uint256 id, uint128 liquidity, address recipient, uint128 min0, uint128 min1)
        external
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        _authorize(id);
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

    function _validate(Descriptor memory d) private pure {
        d.poolKey.validate();
        _positionId(0, d).validate(d.poolKey.config);
    }

    function _positionId(uint256 id, Descriptor memory d) private pure returns (PositionId) {
        return createPositionId(bytes24(uint192(id)), d.tickLower, d.tickUpper);
    }

    function _deposit(uint256 id, Descriptor memory d, uint128 maxAmount0, uint128 maxAmount1, uint128 minLiquidity)
        private
        returns (uint128 liquidity, uint128 amount0, uint128 amount1)
    {
        liquidity = maxLiquidity(
            CORE.poolState(d.poolKey.toPoolId()).sqrtRatio(),
            tickToSqrtRatio(d.tickLower),
            tickToSqrtRatio(d.tickUpper),
            maxAmount0,
            maxAmount1
        );
        if (liquidity == 0 || liquidity < minLiquidity) revert Slippage();
        if (liquidity > uint128(type(int128).max)) revert InvalidValue();
        (amount0, amount1) =
            abi.decode(lock(abi.encode(true, msg.sender, id, liquidity, address(0))), (uint128, uint128));
        if (amount0 > maxAmount0 || amount1 > maxAmount1) revert Slippage();
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
        // Callbacks may transfer or mutate positions. Never leave a funded Core position without an NFT.
        ownerOf(id);
        if (
            CORE.poolPositions(d.poolKey.toPoolId(), address(this), _positionId(id, d)).liquidity
                > uint128(type(int128).max)
        ) {
            revert InvalidValue();
        }
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
                _setExtraData(id, 0);
                delete _positions[id];
            }
        }
        ACCOUNTANT.withdrawTwo(d.poolKey.token0, d.poolKey.token1, recipient, amount0, amount1);
        return abi.encode(amount0, amount1);
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
