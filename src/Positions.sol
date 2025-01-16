// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Payable} from "./base/Payable.sol";
import {CoreLocker} from "./base/CoreLocker.sol";
import {Core} from "./Core.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {PoolKey, PositionKey} from "./types/keys.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity} from "./math/liquidity.sol";
import {shouldCallBeforeUpdatePosition, shouldCallBeforeCollectFees} from "./types/callPoints.sol";

// This functionality is externalized so it can be upgraded later, e.g. to change the URL or generate the URI on-chain
interface ITokenURIGenerator {
    function generateTokenURI(uint256 id) external view returns (string memory);
}

contract Positions is ERC721, Payable, CoreLocker {
    ITokenURIGenerator public immutable tokenURIGenerator;

    constructor(Core core, ITokenURIGenerator _tokenURIGenerator, WETH weth) CoreLocker(core) Payable(weth) {
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

    function mint() public returns (uint256 id) {
        // generates a pseudorandom salt
        // note this can have encounter conflicts if a sender sends two identical transactions in the same block
        // that happen to consume exactly the same amount of gas
        id = mint(keccak256(abi.encode(block.prevrandao, gasleft())));
    }

    // Mints an NFT for the caller with the ID given by shr(192, keccak256(minter, salt))
    // This prevents us from having to store a counter of how many were minted
    function mint(bytes32 salt) public returns (uint256 id) {
        id = saltToId(msg.sender, salt);
        _mint(msg.sender, id);
    }

    error Unauthorized(address caller, uint256 id);
    error InsufficientLiquidityReceived(uint128 liquidity);

    function getPoolPrice(PoolKey memory poolKey) public returns (uint256) {
        if (shouldCallBeforeUpdatePosition(poolKey.extension)) {
            revert("todo");
        }
        (uint192 sqrtRatio,) = core.poolPrice(poolKey.toPoolId());
        return sqrtRatio;
    }

    function deposit(
        uint256 id,
        PoolKey memory poolKey,
        PositionKey memory positionKey,
        uint128 amount0,
        uint128 amount1,
        uint128 minLiquidity
    ) public returns (uint128 liquidity) {
        if (!_isApprovedOrOwner(msg.sender, id)) {
            revert Unauthorized(msg.sender, id);
        }

        uint256 sqrtRatio = getPoolPrice(poolKey);

        liquidity = maxLiquidity(
            sqrtRatio,
            tickToSqrtRatio(positionKey.bounds.lower),
            tickToSqrtRatio(positionKey.bounds.upper),
            amount0,
            amount1
        );

        if (liquidity < minLiquidity) {
            revert InsufficientLiquidityReceived(liquidity);
        }

        lock(abi.encodePacked(uint8(0), abi.encode(id, poolKey, positionKey, liquidity)));
    }

    function mintAndDeposit(
        PoolKey memory poolKey,
        PositionKey memory positionKey,
        uint128 amount0,
        uint128 amount1,
        uint128 minLiquidity
    ) external returns (uint256 id, uint128 liquidity) {
        id = mint();
        liquidity = deposit(id, poolKey, positionKey, amount0, amount1, minLiquidity);
    }

    error UnexpectedCallTypeByte();

    function handleLockData(bytes calldata data) internal override returns (bytes memory result) {
        uint8 callType;

        assembly ("memory-safe") {
            callType := byte(0, calldataload(0))
        }

        if (callType == 0) {
            (PoolKey memory poolKey, PositionKey memory positionKey, uint128 liquidity) =
                abi.decode(data[1:], (PoolKey, PositionKey, uint128));
        } else {
            revert UnexpectedCallTypeByte();
        }
    }
}
