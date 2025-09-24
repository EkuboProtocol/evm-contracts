// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ICore} from "./interfaces/ICore.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {SqrtRatio, toSqrtRatio} from "./types/sqrtRatio.sol";
import {sqrtRatioToTick, tickToSqrtRatio} from "./math/ticks.sol";
import {NATIVE_TOKEN_ADDRESS, MIN_TICK, MAX_TICK} from "./math/constants.sol";
import {IPositions} from "./interfaces/IPositions.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {PoolKey, Config, toConfig} from "./types/poolKey.sol";
import {CallPoints} from "./types/callPoints.sol";
import {OrderKey} from "./types/orderKey.sol";
import {createPositionId} from "./types/positionId.sol";
import {SNOSToken} from "./SNOSToken.sol";
import {nextValidTime} from "./math/time.sol";
import {BaseExtension} from "./base/BaseExtension.sol";

function roundDownToNearest(int32 tick, int32 POOL_TICK_SPACING) pure returns (int32) {
    unchecked {
        if (tick < 0) {
            tick = int32(FixedPointMathLib.max(MIN_TICK, tick - (POOL_TICK_SPACING - 1)));
        }
        return tick / POOL_TICK_SPACING * POOL_TICK_SPACING;
    }
}

function getNextLaunchTime(uint256 ORDER_DURATION, uint256 MIN_LEAD_TIME)
    view
    returns (uint256 startTime, uint256 endTime)
{
    startTime = nextValidTime(block.timestamp, block.timestamp + MIN_LEAD_TIME);
    endTime = nextValidTime(block.timestamp, startTime + ORDER_DURATION - 1);
    startTime = endTime - ORDER_DURATION;
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
/// @notice Launchpad protocol for creating fair launches using Ekubo Protocol's TWAMM implementation
contract SniperNoSniping is BaseExtension {
    using TWAMMLib for *;

    ITWAMM private immutable TWAMM;
    IPositions private immutable POSITIONS;

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

    error InvalidNameOrSymbol();
    error SaleStillOngoing();
    error NoProceeds();
    error CreatorOnly();
    error TokenNotLaunched();

    struct TokenInfo {
        uint64 endTime;
        address creator;
        int32 saleEndTick;
    }

    mapping(SNOSToken => TokenInfo) public tokenInfos;

    constructor(
        ICore core,
        ITWAMM twamm,
        uint256 orderDurationMagnitude,
        uint256 tokenTotalSupply,
        uint64 poolFee,
        uint32 tickSpacing
    ) BaseExtension(core) {
        TWAMM = twamm;
        POOL_FEE = poolFee;

        // LAUNCH_POOL_CONFIG = toConfig(poolFee, 0, address(TWAMM));
        // GRADUATION_POOL_CONFIG = toConfig(POOL_FEE, tickSpacing, address(this));

        assert(orderDurationMagnitude > 1 && orderDurationMagnitude < 6);
        ORDER_DURATION = 16 ** orderDurationMagnitude;
        MIN_LEAD_TIME = ORDER_DURATION / 2;
        TOKEN_TOTAL_SUPPLY = tokenTotalSupply;

        MIN_USABLE_TICK = (MIN_TICK / int32(tickSpacing)) * int32(tickSpacing);
        GRADUATION_POOL_TICK_SPACING = tickSpacing;
    }

    function getCallPoints() internal override returns (CallPoints memory) {
        return sniperNoSnipingCallPoints();
    }

    event Launched(address token, address owner, uint256 startTime, uint256 endTime, string symbol, string name);

    /// @notice Returns the next available launch time
    function nextLaunchTime() external view returns (uint256 startTime, uint256 endTime) {
        (startTime, endTime) = getNextLaunchTime(ORDER_DURATION, MIN_LEAD_TIME);
    }

    function getLaunchPool(SNOSToken token) public view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({token0: address(0), token1: address(token), config: toConfig(POOL_FEE, 0, address(TWAMM))});
    }

    function getSaleOrderKey(SNOSToken token) public view returns (OrderKey memory orderKey) {
        TokenInfo memory tokenInfo = tokenInfos[token];
        uint256 endTime = tokenInfo.endTime;
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

    function executeVirtualOrdersAndGetSaleStatus(SNOSToken token)
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
                                    type(SNOSToken).creationCode,
                                    abi.encode(LibString.packOne(symbol), LibString.packOne(name), TOKEN_TOTAL_SUPPLY)
                                )
                            )
                        )
                    )
                )
            )
        );
    }

    function launch(bytes32 salt, string memory symbol, string memory name)
        external
        payable
        returns (SNOSToken token)
    {
        (uint256 startTime, uint256 endTime) = getNextLaunchTime(ORDER_DURATION, MIN_LEAD_TIME);

        if (
            !LibString.is7BitASCII(symbol) || !LibString.is7BitASCII(name) || bytes(symbol).length < 3
                || bytes(symbol).length > 31 || bytes(name).length < 3 || bytes(name).length > 31
        ) {
            revert InvalidNameOrSymbol();
        }

        token = new SNOSToken{salt: keccak256(abi.encode(msg.sender, salt))}(
            LibString.packOne(symbol), LibString.packOne(name), TOKEN_TOTAL_SUPPLY
        );

        // POSITIONS.maybeInitializePool(getLaunchPool(token), 0);

        // ORDERS.increaseSellAmount(
        //     ORDER_ID,
        //     OrderKey({
        //         sellToken: address(token),
        //         buyToken: NATIVE_TOKEN_ADDRESS,
        //         startTime: startTime,
        //         endTime: endTime,
        //         fee: POOL_FEE
        //     }),
        //     TOKEN_TOTAL_SUPPLY,
        //     type(uint112).max
        // );

        tokenInfos[token] = TokenInfo({endTime: uint64(endTime), creator: msg.sender, saleEndTick: 0});

        emit Launched(address(token), msg.sender, startTime, endTime, symbol, name);

        if (msg.value > 0) {
            // (uint256 id,) = ORDERS.mintAndIncreaseSellAmount{value: msg.value}(
            //     OrderKey({
            //         sellToken: NATIVE_TOKEN_ADDRESS,
            //         buyToken: address(token),
            //         poolFee: POOL_FEE,
            //         startTime: startTime,
            //         endTime: endTime
            //     }),
            //     uint112(msg.value),
            //     type(uint112).max
            // );

            // ORDERS.transferFrom(address(this), msg.sender, id);
        }
    }

    function getGraduationPool(SNOSToken token) public view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            token0: address(0),
            token1: address(token),
            config: toConfig(POOL_FEE, GRADUATION_POOL_TICK_SPACING, address(this))
        });
    }

    function graduate(SNOSToken token) external returns (uint256 proceeds) {
        TokenInfo memory tokenInfo = tokenInfos[token];

        if (block.timestamp < tokenInfo.endTime) {
            revert SaleStillOngoing();
        }

        // proceeds = ORDERS.collectProceeds(
        //     ORDER_ID,
        //     OrderKey({
        //         sellToken: address(token),
        //         buyToken: NATIVE_TOKEN_ADDRESS,
        //         POOL_FEE: POOL_FEE,
        //         startTime: tokenInfo.endTime - ORDER_DURATION,
        //         endTime: tokenInfo.endTime
        //     })
        // );

        // This will also trigger if graduate has already been called
        if (proceeds == 0) {
            revert NoProceeds();
        }

        PoolKey memory graduationPool = getGraduationPool(token);

        // computes the number of tokens that people received per eth, rounded down
        SqrtRatio sqrtSaleRatio =
            toSqrtRatio(FixedPointMathLib.sqrt((uint256(TOKEN_TOTAL_SUPPLY) << 176) / proceeds) << 40, false);

        int32 saleTick = roundDownToNearest(sqrtRatioToTick(sqrtSaleRatio), int32(GRADUATION_POOL_TICK_SPACING));

        (bool didInitialize, SqrtRatio sqrtRatioCurrent) = POSITIONS.maybeInitializePool(graduationPool, saleTick);

        uint256 purchasedTokens;

        // someone already created the graduation pool
        // we need to make sure the price is not worse than our computed average sale price
        if (!didInitialize) {
            SqrtRatio targetRatio = tickToSqrtRatio(saleTick);
            // if the price is lower than average sale price, i.e. eth is too expensive in terms of tokens, we need to buy any leftover
            if (sqrtRatioCurrent > targetRatio) {
                // todo: do this swap via lock, possibly must happen in forward
                // (int128 delta0, int128 delta1) = ROUTER.swap{value: proceeds}(
                //     graduationPool, false, int128(int256(uint256(proceeds))), targetRatio, 0, 0, address(this)
                // );

                // proceeds -= uint256(int256(delta0));
                // purchasedTokens += uint256(-int256(delta1));
            }
        }

        if (proceeds > 0) {
            // POSITIONS.deposit{value: proceeds}(
            //     POSITION_ID,
            //     graduationPool,
            //     createPositionId(bytes24(0), saleTick, saleTick + int32(POOL_TICK_SPACING)),
            //     uint128(proceeds),
            //     0,
            //     0
            // );
        }

        if (purchasedTokens > 0) {
            // POSITIONS.deposit(
            //     POSITION_ID,
            //     graduationPool,
            //     createPositionId(bytes24(0), MIN_USABLE_TICK, saleTick),
            //     0,
            //     uint128(purchasedTokens),
            //     0
            // );
        }

        // used to recompute the bounds later
        tokenInfos[token].saleEndTick = saleTick;
    }

    function getGraduationPositionFeesAndLiquidity(SNOSToken token)
        external
        view
        returns (uint128 principal0, uint128 principal1, uint128 fees0, uint128 fees1)
    {
        TokenInfo memory tokenInfo = tokenInfos[token];
        PoolKey memory graduationPool = getGraduationPool(token);
        // (, principal0, principal1, fees0, fees1) = POSITIONS.getPositionFeesAndLiquidity(
        //     POSITION_ID,
        //     graduationPool,
        //     createPositionId(bytes24(0), tokenInfo.saleEndTick, tokenInfo.saleEndTick + int32(POOL_TICK_SPACING))
        // );

        // (
        //     uint128 liquidityAbove,
        //     uint128 principal0Above,
        //     uint128 principal1Above,
        //     uint128 fees0Above,
        //     uint128 fees1Above
        // ) = POSITIONS.getPositionFeesAndLiquidity(
        //     POSITION_ID, graduationPool, createPositionId(bytes24(0), MIN_USABLE_TICK, tokenInfo.saleEndTick)
        // );

        // if (liquidityAbove != 0) {
        //     principal0 += principal0Above;
        //     principal1 += principal1Above;
        //     fees0 += fees0Above;
        //     fees1 += fees1Above;
        // }
    }

    // Collect to caller
    function collect(SNOSToken token) external {
        collect(token, msg.sender);
    }

    /// The creator can call this method to get what they are due
    function collect(SNOSToken token, address recipient) public {
        TokenInfo memory tokenInfo = tokenInfos[token];
        if (msg.sender != tokenInfo.creator) revert CreatorOnly();

        PoolKey memory graduationPool = getGraduationPool(token);

        // POSITIONS.collectFees(
        //     POSITION_ID,
        //     graduationPool,
        //     createPositionId(bytes24(0), tokenInfo.saleEndTick, tokenInfo.saleEndTick + int32(POOL_TICK_SPACING)),
        //     recipient
        // );
        // POSITIONS.collectFees(
        //     POSITION_ID, graduationPool, createPositionId(bytes24(0), MIN_USABLE_TICK, tokenInfo.saleEndTick), recipient
        // );
    }

    receive() external payable {}
}
