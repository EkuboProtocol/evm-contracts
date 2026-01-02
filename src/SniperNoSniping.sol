// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity >=0.8.30;

import {LibString} from "solady/utils/LibString.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

import {ICore} from "./interfaces/ICore.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {SqrtRatio, toSqrtRatio} from "./types/sqrtRatio.sol";
import {sqrtRatioToTick} from "./math/ticks.sol";
import {NATIVE_TOKEN_ADDRESS, MIN_TICK} from "./math/constants.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolConfig, createFullRangePoolConfig, createConcentratedPoolConfig} from "./types/poolConfig.sol";
import {CallPoints} from "./types/callPoints.sol";
import {OrderKey} from "./types/orderKey.sol";
import {OrderConfig, createOrderConfig} from "./types/orderConfig.sol";
import {createPositionId} from "./types/positionId.sol";
import {SimpleToken} from "./SimpleToken.sol";
import {nextValidTime} from "./math/time.sol";
import {BaseExtension} from "./base/BaseExtension.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {ExposedStorage} from "./base/ExposedStorage.sol";
import {LaunchInfo, createLaunchInfo} from "./types/launchInfo.sol";
import {MAX_ABS_VALUE_SALE_RATE_DELTA} from "./math/time.sol";

/// @dev Computes the start and end time for the next batch of launches, given the duration and minimum lead time
/// @dev Assumes that orderDuration is a power of 16
function getNextLaunchTime(uint32 orderDuration, uint32 minLeadTime) view returns (uint64 startTime, uint64 endTime) {
    startTime = uint64(nextValidTime(block.timestamp, block.timestamp + minLeadTime));
    endTime = uint64(nextValidTime(block.timestamp, startTime + orderDuration - 1));
    startTime = endTime - orderDuration;
}

/// @notice Returns the call points configuration for the SniperNoSniping extension
/// @dev Specifies which hooks the extension needs
/// @return The call points configuration for SniperNoSniping functionality
function sniperNoSnipingCallPoints() pure returns (CallPoints memory) {
    return CallPoints({
        beforeInitializePool: true,
        afterInitializePool: false,
        beforeUpdatePosition: false,
        afterUpdatePosition: false,
        beforeSwap: false,
        afterSwap: false,
        beforeCollectFees: false,
        afterCollectFees: false
    });
}

/// @author Moody Salem <moody@ekubo.org>
/// @title Sniper No Sniping
/// @notice Launchpad protocol for creating fair launches using Ekubo Protocol's TWAMM
contract SniperNoSniping is ExposedStorage, BaseExtension, BaseLocker {
    using FlashAccountantLib for *;
    using TWAMMLib for *;
    using LibString for *;

    /// @notice The TWAMM extension address
    ITWAMM public immutable TWAMM;

    /// @dev The duration of the sale for any newly created tokens
    uint32 public immutable ORDER_DURATION;

    /// @dev The minimum amount of time in the future that the order must start
    uint32 public immutable MIN_LEAD_TIME;

    /// @dev The total supply that all tokens are created with.
    uint128 public immutable TOKEN_TOTAL_SUPPLY;

    /// @dev The fee used for both the launch pool and graduation pool
    uint64 public immutable POOL_FEE;

    /// @dev The tick spacing to use for the graduation pool
    uint32 public immutable GRADUATION_POOL_TICK_SPACING;

    /// @dev The min usable tick, based on tick spacing, for adding liquidity
    int32 public immutable MIN_USABLE_TICK;

    /// @dev The sale rate of the order that is created for launches
    int112 public immutable ORDER_SALE_RATE;

    /// @notice The name or symbol of the token is invalid. Both must be 7-bit ASCII and less than 32 bytes in length.
    error InvalidNameOrSymbol();
    /// @notice The sale is still ongoing so graduation is not allowed
    error SaleStillOngoing();
    /// @notice No proceeds were collected from the launch
    error NoProceeds();
    /// @notice Only the token creator may call the function
    error CreatorOnly();
    /// @notice The token has not yet been launched
    error TokenNotLaunched();

    /// @notice Thrown when the order duration and total supply parameters create a sale rate that exceeds TWAMM's maximum
    error SaleRateTooLarge();
    /// @notice Thrown when the order duration magnitude is too large
    error OrderDurationMagnitude();

    constructor(
        ICore core,
        ITWAMM twamm,
        uint8 orderDurationMagnitude,
        uint128 tokenTotalSupply,
        uint64 poolFee,
        uint32 tickSpacing
    ) BaseExtension(core) BaseLocker(core) {
        TWAMM = twamm;
        POOL_FEE = poolFee;

        if (orderDurationMagnitude == 0 || orderDurationMagnitude > 5) revert OrderDurationMagnitude();

        ORDER_DURATION = uint32(16) ** orderDurationMagnitude;

        if ((uint256(tokenTotalSupply) << 32) / ORDER_DURATION > MAX_ABS_VALUE_SALE_RATE_DELTA) {
            revert SaleRateTooLarge();
        }

        ORDER_SALE_RATE = int112(int256((uint256(TOKEN_TOTAL_SUPPLY) << 32) / (2 * ORDER_DURATION)));

        MIN_LEAD_TIME = ORDER_DURATION / 2;
        TOKEN_TOTAL_SUPPLY = tokenTotalSupply;

        MIN_USABLE_TICK = (MIN_TICK / int32(tickSpacing)) * int32(tickSpacing);
        GRADUATION_POOL_TICK_SPACING = tickSpacing;
    }

    function getCallPoints() internal pure override returns (CallPoints memory) {
        return sniperNoSnipingCallPoints();
    }

    /// @notice Returns the next available launch time
    function nextLaunchTime() external view returns (uint256 startTime, uint256 endTime) {
        (startTime, endTime) = getNextLaunchTime(ORDER_DURATION, MIN_LEAD_TIME);
    }

    function getLaunchPool(SimpleToken token) public view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: address(token),
            config: createFullRangePoolConfig(POOL_FEE, address(TWAMM))
        });
    }

    function readLaunchInfo(SimpleToken token) internal view returns (LaunchInfo launchInfo) {
        assembly ("memory-safe") {
            launchInfo := sload(token)
        }
    }

    function writeLaunchInfo(SimpleToken token, LaunchInfo launchInfo) internal {
        assembly ("memory-safe") {
            sstore(token, launchInfo)
        }
    }

    function getSaleOrderKey(SimpleToken token) public view returns (OrderKey memory orderKey) {
        LaunchInfo li = readLaunchInfo(token);
        uint64 endTime = li.endTime();
        if (endTime == 0) {
            revert TokenNotLaunched();
        }
        uint64 startTime = endTime - ORDER_DURATION;
        orderKey = OrderKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: address(token),
            config: createOrderConfig({_fee: POOL_FEE, _isToken1: true, _startTime: startTime, _endTime: endTime})
        });
    }

    function executeVirtualOrdersAndGetSaleStatus(SimpleToken token)
        external
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount)
    {
        (saleRate, amountSold, remainingSellAmount, purchasedAmount) =
            TWAMM.executeVirtualOrdersAndGetCurrentOrderInfo(address(this), bytes32(0), getSaleOrderKey(token));
    }

    function getGraduationPool(SimpleToken token) public view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: address(token),
            config: createConcentratedPoolConfig(POOL_FEE, GRADUATION_POOL_TICK_SPACING, address(this))
        });
    }

    function launch(bytes32 salt, string memory symbol, string memory name)
        external
        returns (SimpleToken token, uint256 startTime, uint256 endTime)
    {
        if (!LibString.is7BitASCII(name) || !LibString.is7BitASCII(symbol)) {
            revert InvalidNameOrSymbol();
        }

        (token, startTime, endTime) = abi.decode(
            lock(abi.encode(0, msg.sender, salt, name.packOne(), symbol.packOne())), (SimpleToken, uint256, uint256)
        );
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        (uint8 kind) = abi.decode(data, (uint8));

        // either launch, graduate, or collect
        if (kind == 0) {
            (, address creator, bytes32 salt, bytes32 namePacked, bytes32 symbolPacked) =
                abi.decode(data, (uint8, address, bytes32, bytes32, bytes32));

            // todo: enforce an immutable configurable bytes prefix on the token address for branding and DDOS protection
            SimpleToken token = new SimpleToken{salt: EfficientHashLib.hash(bytes32(uint256(uint160(creator))), salt)}({
                symbolPacked: symbolPacked, namePacked: namePacked, totalSupply: TOKEN_TOTAL_SUPPLY
            });

            CORE.pay(address(token), TOKEN_TOTAL_SUPPLY);

            (uint64 startTime, uint64 endTime) =
                getNextLaunchTime({orderDuration: ORDER_DURATION, minLeadTime: MIN_LEAD_TIME});

            PoolKey memory twammPoolKey = PoolKey({
                token0: NATIVE_TOKEN_ADDRESS,
                token1: address(token),
                config: createFullRangePoolConfig({_fee: POOL_FEE, _extension: address(TWAMM)})
            });

            // The initial tick does not matter since we do not add liquidity
            CORE.initializePool(twammPoolKey, 0);

            int256 amountDelta = CORE.updateSaleRate({
                twamm: TWAMM,
                salt: bytes32(0),
                orderKey: OrderKey({
                    token0: NATIVE_TOKEN_ADDRESS,
                    token1: address(token),
                    config: createOrderConfig({
                        _isToken1: true, _startTime: startTime, _endTime: endTime, _fee: POOL_FEE
                    })
                }),
                saleRateDelta: ORDER_SALE_RATE
            });

            // save the rest for creating the liquidity position later
            CORE.updateSavedBalances(
                NATIVE_TOKEN_ADDRESS, address(token), bytes32(0), 0, int256(uint256(TOKEN_TOTAL_SUPPLY)) - amountDelta
            );

            LaunchInfo info = createLaunchInfo({_endTime: uint64(endTime), _creator: creator, _saleEndTick: 0});
            // prevents the case where endTime happens to be a multiple of 2**64
            assert(info.endTime() != 0);

            assembly ("memory-safe") {
                sstore(token, info)
            }

            result = abi.encode(token, startTime, endTime);
        } else if (kind == 1) {
            revert("todo: graduate the token");
        } else if (kind == 2) {
            revert("todo: collect fees");
        }
    }
}
