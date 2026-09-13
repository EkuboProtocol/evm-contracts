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
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity} from "./math/liquidity.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {IFreeLPMetadataRenderer} from "./interfaces/IFreeLPMetadataRenderer.sol";

/// @notice Ownerless, zero-fee positions with one immutable pool/range per NFT and RPC-readable ownership.
/// @dev Pool initialization and native refunds are explicit payable multicall steps.
contract FreeLP is ERC721, BaseLocker, PayableMulticallable {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    error Unauthorized();
    error Slippage();
    error InvalidValue();
    error EnumerationIndexOutOfBounds();

    /// @notice Links an NFT to its stored pool and bounds. Financial changes are emitted by Core.
    event PositionCreated(uint256 indexed id, PoolId indexed poolId, int32 lower, int32 upper);

    ICore public immutable CORE;
    PoolKeyIndex public immutable POOL_KEY_INDEX;
    IFreeLPMetadataRenderer public immutable METADATA_RENDERER;
    /// @notice IDs below this high-water mark have been allocated; ownerOf rejects burned IDs.
    uint64 public nextId = 1;
    mapping(uint256 => PoolId) private _poolIds;
    mapping(uint256 => uint256) private _ownerIndexes;
    mapping(address => uint64[]) private _owned;

    constructor(ICore core, PoolKeyIndex index, IFreeLPMetadataRenderer renderer) BaseLocker(core) {
        CORE = core;
        POOL_KEY_INDEX = index;
        METADATA_RENDERER = renderer;
    }

    modifier authorizedForNft(uint256 id) {
        if (!_isApprovedOrOwner(msg.sender, id)) revert Unauthorized();
        _;
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
        return (_poolIds[id], int32(uint32(bounds)), int32(uint32(bounds >> 32)));
    }

    function _poolKey(PoolId poolId) private view returns (PoolKey memory key) {
        (key.token0, key.token1, key.config) = POOL_KEY_INDEX.poolKeyById(poolId);
    }

    function _positionKey(uint256 id) private view returns (PoolKey memory key, PositionId positionId) {
        uint96 bounds = _getExtraData(id);
        key = _poolKey(_poolIds[id]);
        positionId = createPositionId(bytes24(uint192(id)), int32(uint32(bounds)), int32(uint32(bounds >> 32)));
    }

    /// @notice Owner-only enumeration; order is unspecified. Pin reads to one block.
    /// @dev This extension does not advertise ERC721Enumerable: there is no global live-token array.
    function tokenOfOwnerByIndex(address holder, uint256 index) public view returns (uint256) {
        if (holder == address(0) || index >= _owned[holder].length) revert EnumerationIndexOutOfBounds();
        return _owned[holder][index];
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        (PoolId poolId, int32 lower, int32 upper) = position(id);
        return METADATA_RENDERER.tokenURI(id, address(CORE), _poolKey(poolId), lower, upper);
    }

    /// @notice Initializes a missing pool; compose with createPosition in a payable multicall.
    function maybeInitializePool(PoolKey memory key, int32 tick)
        external
        payable
        returns (bool initialized, SqrtRatio sqrtRatio)
    {
        sqrtRatio = CORE.poolState(key.toPoolId()).sqrtRatio();
        if (sqrtRatio.isZero()) {
            initialized = true;
            sqrtRatio = CORE.initializePool(key, tick);
        }
    }

    /// @notice Funds an initialized pool position, then mints its NFT after every deposit callback.
    function createPosition(
        PoolKey memory key,
        int32 lower,
        int32 upper,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity
    ) external payable returns (uint256 id, uint128 liquidity, uint128 amount0, uint128 amount1) {
        // register is idempotent and rejects uninitialized pools.
        POOL_KEY_INDEX.register(key);
        id = nextId++;
        PositionId positionId = createPositionId(bytes24(uint192(id)), lower, upper);
        positionId.validate(key.config);
        emit PositionCreated(id, key.toPoolId(), lower, upper);
        (liquidity, amount0, amount1) = _deposit(id, key, positionId, maxAmount0, maxAmount1, minLiquidity, true);
        _poolIds[id] = key.toPoolId();
        _mintAndSetExtraDataUnchecked(msg.sender, id, uint96(uint32(lower)) | (uint96(uint32(upper)) << 32));
    }

    function addLiquidity(uint256 id, uint128 maxAmount0, uint128 maxAmount1, uint128 minLiquidity)
        external
        payable
        authorizedForNft(id)
        returns (uint128 liquidity, uint128 amount0, uint128 amount1)
    {
        (PoolKey memory key, PositionId positionId) = _positionKey(id);
        return _deposit(id, key, positionId, maxAmount0, maxAmount1, minLiquidity, false);
    }

    /// @notice Always collects fees; liquidity=0 is fee collection. Full withdrawals burn before callbacks.
    function withdraw(uint256 id, uint128 liquidity, address recipient)
        external
        payable
        authorizedForNft(id)
        returns (uint128 amount0, uint128 amount1)
    {
        if (recipient == address(0) || liquidity > uint128(type(int128).max)) {
            revert InvalidValue();
        }
        (PoolKey memory key, PositionId positionId) = _positionKey(id);
        (amount0, amount1) = abi.decode(
            lock(abi.encode(false, false, ownerOf(id), id, key, positionId, liquidity, recipient)), (uint128, uint128)
        );
    }

    function _deposit(
        uint256 id,
        PoolKey memory key,
        PositionId positionId,
        uint128 maxAmount0,
        uint128 maxAmount1,
        uint128 minLiquidity,
        bool isNew
    ) private returns (uint128 liquidity, uint128 amount0, uint128 amount1) {
        if (minLiquidity == 0) revert Slippage();
        liquidity = maxLiquidity(
            CORE.poolState(key.toPoolId()).sqrtRatio(),
            tickToSqrtRatio(positionId.tickLower()),
            tickToSqrtRatio(positionId.tickUpper()),
            maxAmount0,
            maxAmount1
        );
        if (liquidity < minLiquidity) revert Slippage();
        if (liquidity > uint128(type(int128).max)) revert InvalidValue();
        (amount0, amount1) = abi.decode(
            lock(abi.encode(true, isNew, msg.sender, id, key, positionId, liquidity, address(0))), (uint128, uint128)
        );
        if (amount0 > maxAmount0 || amount1 > maxAmount1) revert Slippage();
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (
            bool deposit,
            bool isNew,
            address payerOrHolder,
            uint256 id,
            PoolKey memory key,
            PositionId positionId,
            uint128 liquidity,
            address recipient
        ) = abi.decode(data, (bool, bool, address, uint256, PoolKey, PositionId, uint128, address));
        if (deposit) return _settleDeposit(id, key, positionId, payerOrHolder, liquidity, isNew);
        return _settleWithdraw(id, key, positionId, payerOrHolder, recipient, liquidity);
    }

    function _settleDeposit(
        uint256 id,
        PoolKey memory key,
        PositionId positionId,
        address payer,
        uint128 liquidity,
        bool isNew
    ) private returns (bytes memory) {
        PoolBalanceUpdate update = CORE.updatePosition(key, positionId, int128(liquidity));
        uint128 amount0 = uint128(update.delta0());
        uint128 amount1 = uint128(update.delta1());
        if (key.token0 == NATIVE_TOKEN_ADDRESS) {
            if (amount0 != 0) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount0);
            if (amount1 != 0) ACCOUNTANT.payFrom(payer, key.token1, amount1);
        } else {
            ACCOUNTANT.payTwoFrom(payer, key.token0, key.token1, amount0, amount1);
        }
        // Existing positions cannot be burned by callbacks and left funded. New NFTs do not exist yet.
        if (!isNew) ownerOf(id);
        if (CORE.poolPositions(key.toPoolId(), address(this), positionId).liquidity > uint128(type(int128).max)) {
            revert InvalidValue();
        }
        return abi.encode(amount0, amount1);
    }

    function _settleWithdraw(
        uint256 id,
        PoolKey memory key,
        PositionId positionId,
        address holder,
        address recipient,
        uint128 liquidity
    ) private returns (bytes memory) {
        uint128 beforeLiquidity = CORE.poolPositions(key.toPoolId(), address(this), positionId).liquidity;
        if (liquidity > beforeLiquidity) revert InvalidValue();
        bool closing = liquidity != 0 && liquidity == beforeLiquidity;
        if (closing) {
            _burn(id);
            _poolIds[id] = PoolId.wrap(bytes32(0));
            delete _ownerIndexes[id];
            _setExtraData(id, 0);
        }
        (uint128 amount0, uint128 amount1) = CORE.collectFees(key, positionId);
        if (liquidity != 0) {
            PoolBalanceUpdate update = CORE.updatePosition(key, positionId, -int128(liquidity));
            amount0 += uint128(-update.delta0());
            amount1 += uint128(-update.delta1());
        }
        // Core's before-hooks can reenter before its accounting changes. Only open NFTs need this check.
        if (
            !closing
                && (ownerOf(id) != holder
                    || CORE.poolPositions(key.toPoolId(), address(this), positionId).liquidity == 0)
        ) {
            revert InvalidValue();
        }
        ACCOUNTANT.withdrawTwo(key.token0, key.token1, recipient, amount0, amount1);
        return abi.encode(amount0, amount1);
    }

    function _afterTokenTransfer(address from, address to, uint256 id) internal override {
        if (from == to) return;
        if (from != address(0)) {
            uint256 index = _ownerIndexes[id];
            uint64 last = _owned[from][_owned[from].length - 1];
            _owned[from][index] = last;
            _ownerIndexes[last] = index;
            _owned[from].pop();
        }
        // ERC721 rejects public transfers to zero before this hook; only an internal burn reaches zero.
        if (to != address(0)) {
            _ownerIndexes[id] = _owned[to].length;
            _owned[to].push(uint64(id));
        }
    }
}
