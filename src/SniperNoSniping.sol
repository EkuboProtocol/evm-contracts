// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {LibString} from "solady/utils/LibString.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {Orders} from "./Orders.sol";
import {SqrtRatio, toSqrtRatio} from "./types/sqrtRatio.sol";
import {sqrtRatioToTick, tickToSqrtRatio} from "./math/ticks.sol";
import {OrderKey} from "./extensions/TWAMM.sol";
import {NATIVE_TOKEN_ADDRESS, MIN_TICK, MAX_TICK} from "./math/constants.sol";
import {Positions} from "./Positions.sol";
import {Router} from "./Router.sol";
import {PoolKey, toConfig} from "./types/poolKey.sol";
import {Bounds} from "./types/positionKey.sol";
import {SNOSToken} from "./SNOSToken.sol";

/// @author Moody Salem <moody@ekubo.org>
/// @title Sniper No Sniping
/// @notice Launchpad for creating fair launches using Ekubo Protocol's TWAMM implementation
contract SniperNoSniping {
    Router private immutable router;
    Orders private immutable orders;
    Positions private immutable positions;

    /// @dev The duration of the sale for any newly created tokens
    uint32 public immutable orderDuration;
    /// @dev The minimum amount of time in the future that the order must start
    uint32 public immutable minLeadTime;

    /// @dev The total supply that all tokens are created with.
    uint80 public immutable tokenTotalSupply;

    /// @dev The fee of the pools that are used by this contract
    uint64 public immutable fee;

    /// @dev The tick spacing of the pool that is created post-graduation
    uint32 public immutable tickSpacing;

    /// @dev The ID of the order that is used for all sale NFTs
    uint256 public immutable orderId;
    /// @dev The ID of the position that is used for all positions created by this contract
    uint256 public immutable positionId;

    /// @dev The min usable tick, based on tick spacing, for adding liquidity
    int32 public immutable minUsableTick;

    error StartTimeTooSoon();
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
        Router _router,
        Positions _positions,
        Orders _orders,
        uint32 _orderDuration,
        uint32 _minLeadTime,
        uint80 _tokenTotalSupply,
        uint64 _fee,
        uint32 _tickSpacing
    ) {
        router = _router;
        positions = _positions;
        orders = _orders;

        orderDuration = _orderDuration;
        minLeadTime = _minLeadTime;
        tokenTotalSupply = _tokenTotalSupply;
        fee = _fee;
        tickSpacing = _tickSpacing;

        orderId = orders.mint();
        positionId = positions.mint();

        minUsableTick = (MIN_TICK / int32(_tickSpacing)) * int32(_tickSpacing);
    }

    event Launched(address token, address owner, uint256 startTime, uint256 endTime);

    function getLaunchPool(SNOSToken token) public view returns (PoolKey memory poolKey) {
        poolKey =
            PoolKey({token0: address(0), token1: address(token), config: toConfig(fee, 0, address(orders.twamm()))});
    }

    function getSaleOrderKey(SNOSToken token) public view returns (OrderKey memory orderKey) {
        TokenInfo memory tokenInfo = tokenInfos[token];
        uint256 endTime = tokenInfo.endTime;
        if (endTime == 0) {
            revert TokenNotLaunched();
        }
        uint256 startTime = endTime - orderDuration;
        orderKey = OrderKey({
            startTime: startTime,
            endTime: endTime,
            sellToken: address(token),
            buyToken: NATIVE_TOKEN_ADDRESS,
            fee: fee
        });
    }

    function executeVirtualOrdersAndGetSaleStatus(SNOSToken token)
        external
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount)
    {
        (saleRate, amountSold, remainingSellAmount, purchasedAmount) =
            orders.executeVirtualOrdersAndGetCurrentOrderInfo(orderId, getSaleOrderKey(token));
    }

    function getExpectedTokenAddress(address creator, bytes32 salt, bytes32 symbol, bytes32 name)
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
                                    abi.encode(
                                        address(router),
                                        address(positions),
                                        address(orders),
                                        symbol,
                                        name,
                                        tokenTotalSupply
                                    )
                                )
                            )
                        )
                    )
                )
            )
        );
    }

    function launch(bytes32 salt, bytes32 symbol, bytes32 name, uint64 startTime) external returns (SNOSToken token) {
        if (startTime < block.timestamp + minLeadTime) {
            revert StartTimeTooSoon();
        }

        token = new SNOSToken{salt: keccak256(abi.encode(msg.sender, salt))}(
            address(router), address(positions), address(orders), symbol, name, tokenTotalSupply
        );

        positions.maybeInitializePool(getLaunchPool(token), 0);

        uint256 endTime = uint256(startTime) + orderDuration;
        require(endTime < type(uint64).max);

        orders.increaseSellAmount(
            orderId,
            OrderKey({
                sellToken: address(token),
                buyToken: NATIVE_TOKEN_ADDRESS,
                fee: fee,
                startTime: startTime,
                endTime: endTime
            }),
            tokenTotalSupply,
            type(uint112).max
        );

        tokenInfos[token] = TokenInfo({endTime: uint64(endTime), creator: msg.sender, saleEndTick: 0});

        emit Launched(address(token), msg.sender, startTime, endTime);
    }

    function getGraduationPool(SNOSToken token) public view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({token0: address(0), token1: address(token), config: toConfig(fee, tickSpacing, address(0))});
    }

    function graduate(SNOSToken token) external returns (uint256 proceeds) {
        TokenInfo memory tokenInfo = tokenInfos[token];

        if (block.timestamp < tokenInfo.endTime) {
            revert SaleStillOngoing();
        }

        proceeds = orders.collectProceeds(
            orderId,
            OrderKey({
                sellToken: address(token),
                buyToken: NATIVE_TOKEN_ADDRESS,
                fee: fee,
                startTime: tokenInfo.endTime - orderDuration,
                endTime: tokenInfo.endTime
            })
        );

        // This will also trigger if graduate has already been called
        if (proceeds == 0) {
            revert NoProceeds();
        }

        PoolKey memory graduationPool = getGraduationPool(token);

        // computes the number of tokens that people received per eth, rounded down
        SqrtRatio sqrtSaleRatio =
            toSqrtRatio(FixedPointMathLib.sqrt((uint256(tokenTotalSupply) << 176) / proceeds) << 40, false);

        int32 saleTick = sqrtRatioToTick(sqrtSaleRatio);
        // todo: round towards negative infinity
        saleTick -= saleTick % int32(tickSpacing);

        (bool didInitialize, SqrtRatio sqrtRatioCurrent) = positions.maybeInitializePool(graduationPool, saleTick);

        uint256 purchasedTokens;

        // someone already created the graduation pool
        // we need to make sure the price is not worse than our computed average sale price
        if (!didInitialize) {
            SqrtRatio targetRatio = tickToSqrtRatio(saleTick);
            // if the price is lower than average sale price, i.e. eth is too expensive in terms of tokens, we need to buy any leftover
            if (sqrtRatioCurrent > targetRatio) {
                (int128 delta0, int128 delta1) = router.swap{value: proceeds}(
                    graduationPool, false, int128(int256(uint256(proceeds))), targetRatio, 0, 0, address(this)
                );

                router.refundNativeToken();

                proceeds -= uint256(int256(delta0));
                purchasedTokens += uint256(-int256(delta1));
            }
        }

        if (proceeds > 0) {
            positions.deposit{value: proceeds}(
                positionId, graduationPool, Bounds(saleTick, saleTick + int32(tickSpacing)), uint128(proceeds), 0, 0
            );
        }

        if (purchasedTokens > 0) {
            positions.deposit(
                positionId, graduationPool, Bounds(minUsableTick, saleTick), 0, uint128(purchasedTokens), 0
            );
        }

        // used to recompute the bounds later
        tokenInfos[token].saleEndTick = saleTick;
    }

    /// The creator can call this method to get what they are due
    function collect(SNOSToken token, address recipient) external {
        TokenInfo memory tokenInfo = tokenInfos[token];
        if (msg.sender != tokenInfo.creator) revert CreatorOnly();

        PoolKey memory graduationPool = getGraduationPool(token);

        positions.collectFees(
            positionId,
            graduationPool,
            Bounds(tokenInfo.saleEndTick, tokenInfo.saleEndTick + int32(tickSpacing)),
            recipient
        );
        positions.collectFees(positionId, graduationPool, Bounds(minUsableTick, tokenInfo.saleEndTick), recipient);
    }

    receive() external payable {}
}
