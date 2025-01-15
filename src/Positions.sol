// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {Payable} from "./base/Payable.sol";
import {Clearable} from "./base/Clearable.sol";
import {CoreLocker} from "./base/CoreLocker.sol";
import {Core, ILocker} from "./Core.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {PoolKey, PositionKey} from "./types/keys.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {maxLiquidity} from "./math/liquidity.sol";

// This functionality is externalized so it can be upgraded later, e.g. to change the URL or generate the URI on-chain
interface ITokenURIGenerator {
    function generateTokenURI(uint256 id) external view returns (string memory);
}

contract Positions is ILocker, ERC721, Multicallable, Payable, Clearable, CoreLocker {
    ITokenURIGenerator public immutable tokenURIGenerator;

    constructor(Core core, ITokenURIGenerator _tokenURIGenerator, WETH weth)
        CoreLocker(core)
        Payable(weth)
        Clearable(weth)
    {
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

    // Mints an NFT for the caller with the ID given by shr(192, keccak256(minter, salt))
    // This prevents us from having to store a counter of how many were minted
    function mint(bytes32 salt) external {
        _mint(msg.sender, saltToId(msg.sender, salt));
    }

    error Unauthorized(address caller, uint256 id);
    error InsufficientLiquidityReceived(uint128 liquidity);

    function deposit(
        uint256 id,
        PoolKey memory poolKey,
        PositionKey memory positionKey,
        uint128 amount0,
        uint128 amount1,
        uint128 minLiquidity
    ) external {
        if (!_isApprovedOrOwner(msg.sender, id)) {
            revert Unauthorized(msg.sender, id);
        }

        (uint192 sqrtRatio,) = core.poolPrice(poolKey.toPoolId());

        uint128 liquidity = maxLiquidity(
            sqrtRatio,
            tickToSqrtRatio(positionKey.bounds.lower),
            tickToSqrtRatio(positionKey.bounds.upper),
            amount0,
            amount1
        );

        if (liquidity < minLiquidity) {
            revert InsufficientLiquidityReceived(liquidity);
        }

        lock(abi.encode(0, id, poolKey, positionKey, liquidity));
    }

    function handleLockData(bytes calldata data) internal override returns (bytes memory result) {
        revert("todo");
    }
}
