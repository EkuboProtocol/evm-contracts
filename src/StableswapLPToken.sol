// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ERC20} from "solady/tokens/ERC20.sol";
import {Initializable} from "solady/utils/Initializable.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolId} from "./types/poolId.sol";
import {CoreLib} from "./libraries/CoreLib.sol";

/// @title Stableswap LP Token
/// @author Bogdan Sivochkin
/// @notice ERC20 LP token for stableswap positions with Uniswap V2-style auto-compounding
/// @dev Fees auto-compound into the position, increasing LP token value over time
/// @dev Uses clone pattern (EIP-1167) for gas-efficient deployment
contract StableswapLPToken is ERC20, Initializable {
    using CoreLib for *;
    /// @notice Minimum liquidity burned on first deposit to prevent inflation attacks
    /// @dev Following Uniswap V2 pattern - first depositor loses 1000 wei worth of LP tokens
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    /// @notice The positions contract that can mint/burn LP tokens
    /// @dev Set in constructor for implementation, inherited by clones
    address public immutable positionsContract;

    /// @notice The token0 address (set during initialization)
    address public token0;

    /// @notice The token1 address (set during initialization)
    address public token1;

    /// @notice The pool ID (set during initialization)
    PoolId public poolId;

    /// @notice Total liquidity tracked by this LP token
    /// @dev Used for proportional mint/burn calculations
    uint128 public totalLiquidity;

    /// @notice Restricts access to only the positions contract
    modifier onlyPositions() {
        require(msg.sender == positionsContract, "Only positions contract");
        _;
    }

    /// @notice Creates the LP token implementation
    /// @param _positionsContract The address of the StableswapLPPositions contract
    constructor(address _positionsContract) {
        positionsContract = _positionsContract;
        // Disable initialization on implementation contract
        _disableInitializers();
    }

    /// @notice Initializes the LP token clone with pool-specific data
    /// @param _poolKey The pool key this LP token represents
    function initialize(PoolKey memory _poolKey) external initializer {
        token0 = _poolKey.token0;
        token1 = _poolKey.token1;
        poolId = _poolKey.toPoolId();
    }

    /// @inheritdoc ERC20
    function name() public pure override returns (string memory) {
        return "Ekubo Stableswap LP";
    }

    /// @inheritdoc ERC20
    function symbol() public pure override returns (string memory) {
        return "EKUBO-SLP";
    }

    /// @notice Mints LP tokens in exchange for liquidity added to the position
    /// @dev On first deposit, burns MINIMUM_LIQUIDITY to prevent inflation attacks
    /// @param to The address to mint LP tokens to
    /// @param liquidityAdded The amount of liquidity being added to the Core position
    /// @return lpTokensMinted The amount of LP tokens minted
    function mint(address to, uint128 liquidityAdded) external onlyPositions returns (uint256 lpTokensMinted) {
        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            // First deposit - burn minimum liquidity to address(0xdead) for security
            // This prevents first-depositor inflation attacks where an attacker:
            // 1. Deposits 1 wei -> gets 1 LP token
            // 2. Donates huge amount directly to position
            // 3. Next depositor gets heavily diluted
            lpTokensMinted = uint256(liquidityAdded) - MINIMUM_LIQUIDITY;
            _mint(address(0xdead), MINIMUM_LIQUIDITY);
            _mint(to, lpTokensMinted);
        } else {
            // Subsequent deposits - mint proportional to share of total liquidity
            // Formula: lpToMint = (liquidityAdded * totalSupply) / totalLiquidity
            lpTokensMinted = (uint256(liquidityAdded) * _totalSupply) / uint256(totalLiquidity);
            _mint(to, lpTokensMinted);
        }

        // Update total liquidity tracking
        totalLiquidity += liquidityAdded;
    }

    /// @notice Burns LP tokens and calculates proportional liquidity to remove
    /// @param from The address to burn LP tokens from
    /// @param lpTokensToBurn The amount of LP tokens to burn
    /// @return liquidityToRemove The amount of liquidity to remove from the Core position
    function burn(address from, uint256 lpTokensToBurn) external onlyPositions returns (uint128 liquidityToRemove) {
        uint256 _totalSupply = totalSupply();

        // Calculate proportional liquidity to remove
        // Formula: liquidityToRemove = (lpTokensBurned * totalLiquidity) / totalSupply
        liquidityToRemove = uint128((lpTokensToBurn * uint256(totalLiquidity)) / _totalSupply);

        _burn(from, lpTokensToBurn);
        totalLiquidity -= liquidityToRemove;
    }

    /// @notice Increments total liquidity when fees are auto-compounded
    /// @dev Called by StableswapLPPositions after compounding fees back into the position
    /// @param liquidityDelta The amount of liquidity added from compounded fees
    function incrementTotalLiquidity(uint128 liquidityDelta) external onlyPositions {
        totalLiquidity += liquidityDelta;
    }
}
