// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "./interfaces/ICore.sol";
import {ITWAMM} from "./interfaces/extensions/ITWAMM.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {PoolKey} from "./types/poolKey.sol";
import {createFullRangePoolConfig, createConcentratedPoolConfig} from "./types/poolConfig.sol";
import {OrderKey} from "./types/orderKey.sol";
import {createOrderConfig} from "./types/orderConfig.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {AuctionConfig} from "./types/auctionConfig.sol";
import {AuctionState, createAuctionState} from "./types/auctionState.sol";
import {computeSaleRate} from "./math/twamm.sol";
import {nextValidTime} from "./math/time.sol";
import {BoostedFeesLib} from "./libraries/BoostedFeesLib.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @author Moody Salem <moody@ekubo.org>
/// @title Auctions
/// @notice Launchpad protocol for creating fair launches using Ekubo Protocol's TWAMM
contract Auctions is UsesCore, BaseLocker {
    using BoostedFeesLib for *;
    using TWAMMLib for *;
    using FlashAccountantLib for *;

    /// @notice The TWAMM extension address
    ITWAMM public immutable TWAMM;
    /// @notice The BoostedFees extension address
    address public immutable BOOSTED_FEES;

    mapping(address => mapping(AuctionConfig => AuctionState)) private auctionInfo;

    uint8 private constant CALL_TYPE_LAUNCH = 0;
    uint8 private constant CALL_TYPE_GRADUATE = 1;

    /// @notice The auction does not exist
    error AuctionNotFound();
    /// @notice The token cannot be the native token
    error InvalidToken();
    /// @notice The auction configuration does not match the existing auction
    error AuctionConfigMismatch();
    /// @notice The total amount sold cannot be decreased
    error TotalAmountSoldDecrease();
    /// @notice The auction has not ended yet
    error AuctionNotEnded();
    /// @notice The creator percentage is invalid
    error InvalidCreatorPercentage();

    constructor(ICore core, ITWAMM twamm, address boostedFees) UsesCore(core) BaseLocker(core) {
        TWAMM = twamm;
        BOOSTED_FEES = boostedFees;
    }

    function launch(
        AuctionConfig config,
        uint128 totalAmountSold,
        uint8 creatorCollectionPercentage,
        uint24 boostDuration,
        uint64 graduationPoolFee,
        uint32 graduationPoolTickSpacing
    ) external returns (bytes32 auctionId, address launchedToken, uint256 startTime, uint256 endTime) {
        return abi.decode(
            lock(
                abi.encode(
                    CALL_TYPE_LAUNCH,
                    msg.sender,
                    config,
                    totalAmountSold,
                    creatorCollectionPercentage,
                    boostDuration,
                    graduationPoolFee,
                    graduationPoolTickSpacing
                )
            ),
            (bytes32, address, uint256, uint256)
        );
    }

    function getLaunchPool(address token) public view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: token,
            config: createFullRangePoolConfig({_fee: 0, _extension: address(TWAMM)})
        });
    }

    function getSaleOrderKey(AuctionConfig config) public pure returns (OrderKey memory orderKey) {
        address token = config.token();
        uint64 startTime = config.startTime();
        uint64 endTime = startTime + config.duration();
        orderKey = OrderKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: token,
            config: createOrderConfig({_fee: 0, _isToken1: true, _startTime: startTime, _endTime: endTime})
        });
    }

    function executeVirtualOrdersAndGetSaleStatus(address owner, AuctionConfig config)
        external
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount)
    {
        (saleRate, amountSold, remainingSellAmount, purchasedAmount) =
            TWAMM.executeVirtualOrdersAndGetCurrentOrderInfo(address(this), bytes32(0), getSaleOrderKey(config));
    }

    function getGraduationPool(address owner, AuctionConfig config) public view returns (PoolKey memory poolKey) {
        AuctionState state = auctionInfo[owner][config];
        if (state.totalAmountSold() == 0) {
            revert AuctionNotFound();
        }
        poolKey = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: config.token(),
            config: createConcentratedPoolConfig(
                state.graduationPoolFee(), state.graduationPoolTickSpacing(), BOOSTED_FEES
            )
        });
    }

    function graduate(address owner, AuctionConfig config)
        external
        returns (uint128 proceeds, uint128 creatorAmount, uint128 boostAmount)
    {
        return abi.decode(lock(abi.encode(CALL_TYPE_GRADUATE, owner, config)), (uint128, uint128, uint128));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint8 callType = abi.decode(data, (uint8));

        if (callType == CALL_TYPE_LAUNCH) {
            (
                ,
                address owner,
                AuctionConfig config,
                uint128 totalAmountSold,
                uint8 creatorCollectionPercentage,
                uint24 boostDuration,
                uint64 graduationPoolFee,
                uint32 graduationPoolTickSpacing
            ) = abi.decode(data, (uint8, address, AuctionConfig, uint128, uint8, uint24, uint64, uint32));

            address configToken = config.token();
            if (configToken == NATIVE_TOKEN_ADDRESS) {
                revert InvalidToken();
            }
            if (creatorCollectionPercentage > 100) {
                revert InvalidCreatorPercentage();
            }

            uint64 startTime = config.startTime();
            uint64 endTime = startTime + config.duration();
            bytes32 auctionId = _auctionId(owner, config);

            AuctionState state = auctionInfo[owner][config];
            uint128 previousTotalAmountSold = state.totalAmountSold();

            if (previousTotalAmountSold == 0) {
                auctionInfo[owner][config] = createAuctionState({
                    _creatorCollectionPercentage: creatorCollectionPercentage,
                    _boostDuration: boostDuration,
                    _graduationPoolFee: graduationPoolFee,
                    _graduationPoolTickSpacing: graduationPoolTickSpacing,
                    _totalAmountSold: totalAmountSold
                });

                PoolKey memory twammPoolKey = PoolKey({
                    token0: NATIVE_TOKEN_ADDRESS,
                    token1: configToken,
                    config: createFullRangePoolConfig({_fee: 0, _extension: address(TWAMM)})
                });

                // The initial tick does not matter since we do not add liquidity
                CORE.initializePool(twammPoolKey, 0);
            } else {
                if (
                    state.creatorCollectionPercentage() != creatorCollectionPercentage
                        || state.boostDuration() != boostDuration || state.graduationPoolFee() != graduationPoolFee
                        || state.graduationPoolTickSpacing() != graduationPoolTickSpacing
                ) {
                    revert AuctionConfigMismatch();
                }

                if (totalAmountSold < previousTotalAmountSold) {
                    revert TotalAmountSoldDecrease();
                }

                auctionInfo[owner][config] = createAuctionState({
                    _creatorCollectionPercentage: creatorCollectionPercentage,
                    _boostDuration: boostDuration,
                    _graduationPoolFee: graduationPoolFee,
                    _graduationPoolTickSpacing: graduationPoolTickSpacing,
                    _totalAmountSold: totalAmountSold
                });
            }

            uint128 amountIncrease = totalAmountSold - previousTotalAmountSold;
            if (amountIncrease != 0) {
                uint64 realStart = uint64(FixedPointMathLib.max(block.timestamp, startTime));
                uint256 remainingDuration = endTime - realStart;
                uint112 saleRateDelta = uint112(computeSaleRate(amountIncrease, remainingDuration));

                CORE.updateSaleRate({
                    twamm: TWAMM,
                    salt: bytes32(0),
                    orderKey: OrderKey({
                        token0: NATIVE_TOKEN_ADDRESS,
                        token1: configToken,
                        config: createOrderConfig({_isToken1: true, _startTime: startTime, _endTime: endTime, _fee: 0})
                    }),
                    saleRateDelta: int112(int256(uint256(saleRateDelta)))
                });
            }

            result = abi.encode(auctionId, configToken, startTime, endTime);
        } else if (callType == CALL_TYPE_GRADUATE) {
            (, address owner, AuctionConfig config) = abi.decode(data, (uint8, address, AuctionConfig));

            AuctionState state = auctionInfo[owner][config];
            if (state.totalAmountSold() == 0) {
                revert AuctionNotFound();
            }

            uint64 startTime = config.startTime();
            uint64 endTime = startTime + config.duration();
            if (block.timestamp < endTime) {
                revert AuctionNotEnded();
            }

            OrderKey memory orderKey = getSaleOrderKey(config);
            uint128 proceeds = CORE.collectProceeds(TWAMM, bytes32(0), orderKey);

            uint256 creatorAmount = (uint256(proceeds) * state.creatorCollectionPercentage()) / 100;
            uint256 boostAmount = proceeds - creatorAmount;

            if (creatorAmount != 0) {
                ACCOUNTANT.withdraw(NATIVE_TOKEN_ADDRESS, owner, uint128(creatorAmount));
            }

            if (boostAmount != 0) {
                PoolKey memory poolKey = PoolKey({
                    token0: NATIVE_TOKEN_ADDRESS,
                    token1: config.token(),
                    config: createConcentratedPoolConfig(
                        state.graduationPoolFee(), state.graduationPoolTickSpacing(), BOOSTED_FEES
                    )
                });

                uint256 afterTime = block.timestamp + uint256(state.boostDuration());
                uint64 boostEndTime = uint64(nextValidTime(block.timestamp, afterTime));
                uint64 currentTime = uint64(block.timestamp);
                uint256 duration = boostEndTime - currentTime;
                uint112 rate0 = uint112(computeSaleRate(boostAmount, duration));

                CORE.addIncentives(poolKey, 0, boostEndTime, rate0, 0);
            }

            result = abi.encode(uint128(proceeds), uint128(creatorAmount), uint128(boostAmount));
        } else {
            revert();
        }
    }

    function _auctionId(address owner, AuctionConfig config) private pure returns (bytes32 h) {
        h = keccak256(abi.encode(owner, config));
    }
}
