// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC721} from "solady/tokens/ERC721.sol";
import {CoreLocker} from "./base/CoreLocker.sol";
import {ICore, UpdatePositionParameters} from "./interfaces/ICore.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {PoolKey, Bounds, maxBounds} from "./types/keys.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity} from "./math/liquidity.sol";
import {shouldCallBeforeUpdatePosition} from "./types/callPoints.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {Permittable} from "./base/Permittable.sol";

// This functionality is externalized so it can be upgraded later, e.g. to change the URL or generate the URI on-chain
interface ITokenURIGenerator {
    function generateTokenURI(uint256 id) external view returns (string memory);
}

contract Positions is Multicallable, Permittable, CoreLocker, ERC721 {
    using CoreLib for ICore;

    ITokenURIGenerator public immutable tokenURIGenerator;

    constructor(ICore core, ITokenURIGenerator _tokenURIGenerator) CoreLocker(core) {
        tokenURIGenerator = _tokenURIGenerator;
    }

    function name() public pure override returns (string memory) {
        return "Ekubo Positions";
    }

    function symbol() public pure override returns (string memory) {
        return "ekuPo";
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        return tokenURIGenerator.generateTokenURI(id);
    }

    function saltToId(address minter, bytes32 salt) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(minter, salt))) >> 192;
    }

    function mint() public payable returns (uint256 id) {
        // generates a pseudorandom salt
        // note this can have encounter conflicts if a sender sends two identical transactions in the same block
        // that happen to consume exactly the same amount of gas
        id = mint(keccak256(abi.encode(block.prevrandao, gasleft())));
    }

    // Mints an NFT for the caller with the ID given by shr(192, keccak256(minter, salt))
    // This prevents us from having to store a counter of how many were minted
    function mint(bytes32 salt) public payable returns (uint256 id) {
        id = saltToId(msg.sender, salt);
        _mint(msg.sender, id);
    }

    error Unauthorized(address caller, uint256 id);

    modifier authorizedForNft(uint256 id) {
        if (!_isApprovedOrOwner(msg.sender, id)) {
            revert Unauthorized(msg.sender, id);
        }
        _;
    }

    error InsufficientLiquidityReceived(uint128 liquidity);

    // Gets the pool price of a pool, accounting for any before update position extension behavior
    function getPoolPrice(PoolKey memory poolKey) public returns (uint256) {
        if (shouldCallBeforeUpdatePosition(poolKey.extension)) {
            return abi.decode(lock(abi.encodePacked(uint8(3), abi.encode(poolKey))), (uint256));
        }
        (uint192 sqrtRatio,) = core.poolPrice(poolKey.toPoolId());
        return sqrtRatio;
    }

    function deposit(
        uint256 id,
        PoolKey memory poolKey,
        Bounds memory bounds,
        uint128 amount0,
        uint128 amount1,
        uint128 minLiquidity
    ) public payable authorizedForNft(id) returns (uint128 liquidity) {
        uint256 sqrtRatio = getPoolPrice(poolKey);

        liquidity =
            maxLiquidity(sqrtRatio, tickToSqrtRatio(bounds.lower), tickToSqrtRatio(bounds.upper), amount0, amount1);

        if (liquidity < minLiquidity) {
            revert InsufficientLiquidityReceived(liquidity);
        }

        lock(abi.encodePacked(uint8(0), abi.encode(msg.sender, id, poolKey, bounds, liquidity)));
    }

    function collectFees(uint256 id, PoolKey memory poolKey, Bounds memory bounds, address recipient)
        public
        payable
        authorizedForNft(id)
        returns (uint128 amount0, uint128 amount1)
    {
        return
            abi.decode(lock(abi.encodePacked(uint8(1), abi.encode(id, poolKey, bounds, recipient))), (uint128, uint128));
    }

    function withdraw(
        uint256 id,
        PoolKey memory poolKey,
        Bounds memory bounds,
        uint128 liquidity,
        address recipient,
        uint128 minAmount0,
        uint128 minAmount1
    ) public payable authorizedForNft(id) returns (uint128 amount0, uint128 amount1) {
        (amount0, amount1) = abi.decode(
            lock(
                abi.encodePacked(
                    uint8(2), abi.encode(id, poolKey, bounds, liquidity, recipient, minAmount0, minAmount1)
                )
            ),
            (uint128, uint128)
        );
    }

    function maybeInitializePool(PoolKey memory poolKey, int32 tick) external payable {
        uint256 price = getPoolPrice(poolKey);
        if (price == 0) {
            core.initializePool(poolKey, tick);
        }
    }

    function mintAndDeposit(
        PoolKey memory poolKey,
        Bounds memory bounds,
        uint128 amount0,
        uint128 amount1,
        uint128 minLiquidity
    ) external payable returns (uint256 id, uint128 liquidity) {
        id = mint();
        liquidity = deposit(id, poolKey, bounds, amount0, amount1, minLiquidity);
    }

    error UnexpectedCallTypeByte();
    error InsufficientAmountWithdrawn();

    function handleLockData(bytes calldata data) internal override returns (bytes memory result) {
        uint8 callType;

        assembly ("memory-safe") {
            callType := byte(0, calldataload(data.offset))
        }

        if (callType == 0) {
            (address caller, uint256 id, PoolKey memory poolKey, Bounds memory bounds, uint128 liquidity) =
                abi.decode(data[1:], (address, uint256, PoolKey, Bounds, uint128));

            (int128 delta0, int128 delta1) = core.updatePosition(
                poolKey,
                UpdatePositionParameters({salt: bytes32(id), bounds: bounds, liquidityDelta: int128(liquidity)})
            );

            payCore(caller, poolKey.token0, uint128(delta0));
            payCore(caller, poolKey.token1, uint128(delta1));
        } else if (callType == 1) {
            (uint256 id, PoolKey memory poolKey, Bounds memory bounds, address recipient) =
                abi.decode(data[1:], (uint256, PoolKey, Bounds, address));

            (uint128 amount0, uint128 amount1) = core.collectFees(poolKey, bytes32(id), bounds);

            withdrawFromCore(poolKey.token0, amount0, recipient);
            withdrawFromCore(poolKey.token1, amount1, recipient);

            result = abi.encode(amount0, amount1);
        } else if (callType == 2) {
            (
                uint256 id,
                PoolKey memory poolKey,
                Bounds memory bounds,
                uint128 liquidity,
                address recipient,
                uint128 minToken0,
                uint128 minToken1
            ) = abi.decode(data[1:], (uint256, PoolKey, Bounds, uint128, address, uint128, uint128));

            (int128 delta0, int128 delta1) = core.updatePosition(
                poolKey,
                UpdatePositionParameters({salt: bytes32(id), bounds: bounds, liquidityDelta: -int128(liquidity)})
            );

            (uint128 amount0, uint128 amount1) = (uint128(-delta0), uint128(-delta1));

            if (amount0 < minToken0 || amount1 < minToken1) {
                revert InsufficientAmountWithdrawn();
            }

            withdrawFromCore(poolKey.token0, amount0, recipient);
            withdrawFromCore(poolKey.token1, amount1, recipient);

            result = abi.encode(amount0, amount1);
        } else if (callType == 3) {
            (PoolKey memory poolKey) = abi.decode(data[1:], (PoolKey));

            // an empty update that we expect to succeed in all cases for well-behaving extensions
            core.updatePosition(
                poolKey,
                UpdatePositionParameters({salt: bytes32(0), bounds: maxBounds(poolKey.tickSpacing), liquidityDelta: 0})
            );

            (uint256 price,) = core.poolPrice(poolKey.toPoolId());

            result = abi.encode(price);
        } else {
            revert UnexpectedCallTypeByte();
        }
    }
}
