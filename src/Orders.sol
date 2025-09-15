// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {Permittable} from "./base/Permittable.sol";
import {TWAMMLib} from "./libraries/TWAMMLib.sol";
import {TWAMM, orderKeyToPoolKey, OrderKey, UpdateSaleRateParams, CollectProceedsParams} from "./extensions/TWAMM.sol";
import {computeSaleRate, computeAmountFromSaleRate, computeRewardAmount} from "./math/twamm.sol";
import {BaseURIMintableNFT} from "./base/BaseURIMintableNFT.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title Ekubo Orders
/// @author Moody Salem <moody@ekubo.org>
/// @notice Tracks TWAMM orders in Ekubo Protocol
contract Orders is UsesCore, PayableMulticallable, Permittable, BaseLocker, BaseURIMintableNFT {
    using TWAMMLib for *;

    error OrderAlreadyEnded();
    error MaxSaleRateExceeded();

    TWAMM public immutable twamm;

    constructor(ICore core, TWAMM _twamm, address owner) BaseURIMintableNFT(owner) BaseLocker(core) UsesCore(core) {
        twamm = _twamm;
    }

    function name() public pure override returns (string memory) {
        return "Ekubo DCA Orders";
    }

    function symbol() public pure override returns (string memory) {
        return "ekuOrd";
    }

    function mintAndIncreaseSellAmount(OrderKey memory orderKey, uint112 amount, uint112 maxSaleRate)
        public
        payable
        returns (uint256 id, uint112 saleRate)
    {
        id = mint();
        saleRate = increaseSellAmount(id, orderKey, amount, maxSaleRate);
    }

    function increaseSellAmount(uint256 id, OrderKey memory orderKey, uint128 amount, uint112 maxSaleRate)
        public
        payable
        authorizedForNft(id)
        returns (uint112 saleRate)
    {
        uint256 realStart = FixedPointMathLib.max(block.timestamp, orderKey.startTime);

        unchecked {
            if (orderKey.endTime <= realStart) {
                revert OrderAlreadyEnded();
            }

            saleRate = uint112(computeSaleRate(amount, uint32(orderKey.endTime - realStart)));

            if (saleRate > maxSaleRate) {
                revert MaxSaleRateExceeded();
            }
        }

        lock(abi.encode(bytes1(0xdd), msg.sender, id, orderKey, saleRate));
    }

    function decreaseSaleRate(uint256 id, OrderKey memory orderKey, uint112 saleRateDecrease, address recipient)
        public
        payable
        authorizedForNft(id)
        returns (uint112 refund)
    {
        refund = uint112(
            uint256(
                -abi.decode(
                    lock(abi.encode(bytes1(0xdd), recipient, id, orderKey, -int256(uint256(saleRateDecrease)))),
                    (int256)
                )
            )
        );
    }

    function decreaseSaleRate(uint256 id, OrderKey memory orderKey, uint112 saleRateDecrease)
        external
        payable
        returns (uint112 refund)
    {
        refund = decreaseSaleRate(id, orderKey, saleRateDecrease, msg.sender);
    }

    function collectProceeds(uint256 id, OrderKey memory orderKey, address recipient)
        public
        payable
        authorizedForNft(id)
        returns (uint128 proceeds)
    {
        proceeds = abi.decode(lock(abi.encode(bytes1(0xff), id, orderKey, recipient)), (uint128));
    }

    function collectProceeds(uint256 id, OrderKey memory orderKey) external payable returns (uint128 proceeds) {
        proceeds = collectProceeds(id, orderKey, msg.sender);
    }

    function executeVirtualOrdersAndGetCurrentOrderInfo(uint256 id, OrderKey memory orderKey)
        external
        returns (uint112 saleRate, uint256 amountSold, uint256 remainingSellAmount, uint128 purchasedAmount)
    {
        unchecked {
            PoolKey memory poolKey = orderKeyToPoolKey(orderKey, address(twamm));
            twamm.lockAndExecuteVirtualOrders(poolKey);

            uint32 lastUpdateTime;
            uint256 rewardRateSnapshot;
            (saleRate, lastUpdateTime, amountSold, rewardRateSnapshot) =
                twamm.orderState(address(this), bytes32(id), orderKey.toOrderId());

            if (saleRate != 0) {
                uint256 rewardRateInside = twamm.getRewardRateInside(
                    poolKey.toPoolId(), orderKey.startTime, orderKey.endTime, orderKey.sellToken < orderKey.buyToken
                );

                purchasedAmount = computeRewardAmount(rewardRateInside - rewardRateSnapshot, saleRate);

                if (block.timestamp > orderKey.startTime) {
                    uint32 secondsSinceLastUpdate = uint32(block.timestamp) - lastUpdateTime;

                    uint32 secondsSinceOrderStart = uint32(block.timestamp - orderKey.startTime);

                    uint32 totalOrderDuration = uint32(orderKey.endTime - orderKey.startTime);

                    uint32 remainingTimeSinceLastUpdate = uint32(orderKey.endTime) - lastUpdateTime;

                    uint32 saleDuration = uint32(
                        FixedPointMathLib.min(
                            remainingTimeSinceLastUpdate,
                            FixedPointMathLib.min(
                                FixedPointMathLib.min(secondsSinceLastUpdate, secondsSinceOrderStart),
                                totalOrderDuration
                            )
                        )
                    );

                    amountSold +=
                        computeAmountFromSaleRate({saleRate: saleRate, duration: saleDuration, roundUp: false});
                }
                if (block.timestamp < orderKey.endTime) {
                    remainingSellAmount = computeAmountFromSaleRate({
                        saleRate: saleRate,
                        duration: uint32(orderKey.endTime - FixedPointMathLib.max(orderKey.startTime, block.timestamp)),
                        roundUp: true
                    });
                }
            }
        }
    }

    error UnexpectedCallTypeByte(bytes1 b);

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        bytes1 callType = data[0];
        if (callType == 0xdd) {
            (, address recipientOrPayer, uint256 id, OrderKey memory orderKey, int256 saleRateDelta) =
                abi.decode(data, (bytes1, address, uint256, OrderKey, int256));

            int256 amount = abi.decode(
                forward(
                    address(twamm),
                    abi.encode(
                        uint256(0),
                        UpdateSaleRateParams({
                            salt: bytes32(id),
                            orderKey: orderKey,
                            saleRateDelta: int112(saleRateDelta)
                        })
                    )
                ),
                (int256)
            );

            if (saleRateDelta > 0) {
                pay(recipientOrPayer, orderKey.sellToken, uint256(amount));
            } else {
                withdraw(orderKey.sellToken, uint128(uint256(-amount)), recipientOrPayer);
            }

            result = abi.encode(amount);
        } else if (callType == 0xff) {
            (, uint256 id, OrderKey memory orderKey, address recipient) =
                abi.decode(data, (bytes1, uint256, OrderKey, address));

            uint128 proceeds = abi.decode(
                forward(
                    address(twamm),
                    abi.encode(uint256(1), CollectProceedsParams({salt: bytes32(id), orderKey: orderKey}))
                ),
                (uint128)
            );

            withdraw(orderKey.buyToken, proceeds, recipient);

            result = abi.encode(proceeds);
        } else {
            revert UnexpectedCallTypeByte(callType);
        }
    }
}
