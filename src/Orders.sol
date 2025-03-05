// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC721} from "solady/tokens/ERC721.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {UsesCore} from "./base/UsesCore.sol";
import {ICore} from "./interfaces/ICore.sol";
import {FeesPerLiquidity} from "./types/feesPerLiquidity.sol";
import {Position} from "./types/position.sol";
import {tickToSqrtRatio} from "./math/ticks.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {Permittable} from "./base/Permittable.sol";
import {SlippageChecker} from "./base/SlippageChecker.sol";
import {ITokenURIGenerator} from "./interfaces/ITokenURIGenerator.sol";
import {SqrtRatio} from "./types/sqrtRatio.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {TWAMM, OrderKey, UpdateSaleRateParams, CollectProceedsParams} from "./extensions/TWAMM.sol";
import {computeSaleRate} from "./math/twamm.sol";
import {MintableNFT} from "./base/MintableNFT.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract Orders is UsesCore, PayableMulticallable, SlippageChecker, Permittable, BaseLocker, MintableNFT {
    error InvalidDuration();
    error OrderAlreadyEnded();
    error MaxSaleRateExceeded();

    TWAMM public immutable twamm;

    constructor(ICore core, TWAMM _twamm, ITokenURIGenerator tokenURIGenerator)
        MintableNFT(tokenURIGenerator)
        BaseLocker(core)
        UsesCore(core)
    {
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
        returns (uint256 id, uint112 saleRate)
    {
        id = mint();
        saleRate = increaseSellAmount(id, orderKey, amount, maxSaleRate);
    }

    function increaseSellAmount(uint256 id, OrderKey memory orderKey, uint112 amount, uint112 maxSaleRate)
        public
        authorizedForNft(id)
        returns (uint112 saleRate)
    {
        if (orderKey.endTime <= orderKey.startTime || orderKey.endTime - orderKey.startTime > type(uint32).max) {
            revert InvalidDuration();
        }

        if (orderKey.endTime <= block.timestamp) revert OrderAlreadyEnded();

        saleRate = computeSaleRate(
            amount, uint32(orderKey.endTime - FixedPointMathLib.max(block.timestamp, orderKey.startTime))
        );

        if (saleRate > maxSaleRate) {
            revert MaxSaleRateExceeded();
        }

        lock(abi.encode(bytes1(0xdd), msg.sender, id, orderKey, saleRate));
    }

    function decreaseSaleRate(
        uint256 id,
        OrderKey memory orderKey,
        uint112 saleRateDecrease,
        uint112 minRefund,
        address recipient
    ) public authorizedForNft(id) returns (uint112 refund) {
        refund = abi.decode(
            lock(abi.encode(bytes1(0xdd), recipient, id, orderKey, -int256(uint256(saleRateDecrease)), minRefund)),
            (uint112)
        );
    }

    function collectProceeds(uint256 id, OrderKey memory orderKey, address recipient)
        public
        authorizedForNft(id)
        returns (uint128 proceeds)
    {
        proceeds = abi.decode(lock(abi.encode(bytes1(0xff), id, orderKey, recipient)), (uint128));
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
