// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {LibString} from "solady/utils/LibString.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ICore} from "./interfaces/ICore.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {SqrtRatio, toSqrtRatio} from "./types/sqrtRatio.sol";
import {sqrtRatioToTick} from "./math/ticks.sol";
import {NATIVE_TOKEN_ADDRESS, MIN_TICK} from "./math/constants.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {PoolKey, Config, toConfig} from "./types/poolKey.sol";
import {CallPoints} from "./types/callPoints.sol";
import {OrderKey} from "./types/orderKey.sol";
import {createPositionId} from "./types/positionId.sol";
import {SimpleToken} from "./SimpleToken.sol";
import {nextValidTime} from "./math/time.sol";
import {BaseExtension} from "./base/BaseExtension.sol";
import {BaseForwardee} from "./base/BaseForwardee.sol";
import {LaunchInfo, createLaunchInfo} from "./types/LaunchInfo.sol";
import {Locker} from "./types/locker.sol";

function roundDownToNearest(int32 tick, int32 tickSpacing) pure returns (int32) {
    unchecked {
        if (tick < 0) {
            tick = int32(FixedPointMathLib.max(MIN_TICK, tick - (tickSpacing - 1)));
        }
        return tick / tickSpacing * tickSpacing;
    }
}

/// @dev Computes the start and end time for the next batch of launches, given the duration and minimum lead time
function getNextLaunchTime(uint256 orderDuration, uint256 minLeadTime)
    view
    returns (uint256 startTime, uint256 endTime)
{
    startTime = nextValidTime(block.timestamp, block.timestamp + minLeadTime);
    endTime = nextValidTime(block.timestamp, startTime + orderDuration - 1);
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
contract SniperNoSniping is BaseExtension, BaseForwardee {
    using TWAMMLib for *;

    /// @notice The TWAMM extension address
    ITWAMM public immutable TWAMM;

    /// @dev The duration of the sale for any newly created tokens
    uint256 public immutable ORDER_DURATION;

    /// @dev The minimum amount of time in the future that the order must start
    uint256 public immutable MIN_LEAD_TIME;

    /// @dev The total supply that all tokens are created with.
    uint256 public immutable TOKEN_TOTAL_SUPPLY;

    /// @dev The fee used for both the launch pool and graduation pool
    uint64 public immutable POOL_FEE;

    /// @dev The tick spacing to use for the graduation pool
    uint32 public immutable GRADUATION_POOL_TICK_SPACING;

    /// @dev The min usable tick, based on tick spacing, for adding liquidity
    int32 public immutable MIN_USABLE_TICK;

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

    constructor(
        ICore core,
        ITWAMM twamm,
        uint256 orderDurationMagnitude,
        uint256 tokenTotalSupply,
        uint64 poolFee,
        uint32 tickSpacing
    ) BaseExtension(core) BaseForwardee(core) {
        TWAMM = twamm;
        POOL_FEE = poolFee;

        assert(orderDurationMagnitude > 1 && orderDurationMagnitude < 6);
        ORDER_DURATION = 16 ** orderDurationMagnitude;
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
        poolKey = PoolKey({token0: address(0), token1: address(token), config: toConfig(POOL_FEE, 0, address(TWAMM))});
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
        uint256 endTime = li.endTime();
        if (endTime == 0) {
            revert TokenNotLaunched();
        }
        uint256 startTime = endTime - ORDER_DURATION;
        orderKey = OrderKey({
            startTime: startTime,
            endTime: endTime,
            sellToken: address(token),
            buyToken: NATIVE_TOKEN_ADDRESS,
            fee: POOL_FEE
        });
    }

    function executeVirtualOrdersAndGetSaleStatus(SimpleToken token)
        external
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount)
    {
        (saleRate, amountSold, remainingSellAmount, purchasedAmount) =
            TWAMM.executeVirtualOrdersAndGetCurrentOrderInfo(address(this), bytes32(0), getSaleOrderKey(token));
    }

    function getExpectedTokenAddress(address creator, bytes32 salt, string memory symbol, string memory name)
        external
        view
        returns (address token)
    {
        token = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            bytes1(0xff),
                            address(this),
                            keccak256(abi.encode(creator, salt)),
                            keccak256(
                                abi.encodePacked(
                                    type(SimpleToken).creationCode,
                                    abi.encode(LibString.packOne(symbol), LibString.packOne(name), TOKEN_TOTAL_SUPPLY)
                                )
                            )
                        )
                    )
                )
            )
        );
    }

    function getGraduationPool(SimpleToken token) public view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            token0: address(0),
            token1: address(token),
            config: toConfig(POOL_FEE, GRADUATION_POOL_TICK_SPACING, address(this))
        });
    }

    struct LaunchTokenParameters {
        address creator;
        string name;
        string symbol;
    }

    function handleForwardData(Locker, bytes memory data) internal override returns (bytes memory result) {
        (uint8 kind) = abi.decode(data, (uint8));

        // either launch, graduate, or collect
        if (kind == 0) {
            (, LaunchTokenParameters memory params) = abi.decode(data, (uint8, LaunchTokenParameters));

            if (!LibString.is7BitASCII(params.name) || !LibString.is7BitASCII(params.symbol)) {
                revert InvalidNameOrSymbol();
            }

            // todo: enforce an immutable configurable bytes prefix on the token address
            SimpleToken token = new SimpleToken({
                symbolPacked: LibString.packOne(params.symbol),
                namePacked: LibString.packOne(params.name),
                totalSupply: TOKEN_TOTAL_SUPPLY
            });

            (uint256 startTime, uint256 endTime) =
                getNextLaunchTime({orderDuration: ORDER_DURATION, minLeadTime: MIN_LEAD_TIME});

            LaunchInfo info = createLaunchInfo({_endTime: uint64(endTime), _creator: params.creator, _saleEndTick: 0});

            assembly ("memory-safe") {
                sstore(token, info)
            }

            result = abi.encode(token, startTime, endTime);
        } else if (kind == 1) {
            // todo: graduate the token
        } else if (kind == 2) {
            // todo: collect fees
        }
    }
}
