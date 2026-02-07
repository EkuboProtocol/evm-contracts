// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {AuctionKey} from "../../src/types/auctionKey.sol";
import {AuctionConfig, createAuctionConfig} from "../../src/types/auctionConfig.sol";

contract AuctionKeyTest is Test {
    function test_sellToken_whenIsSellingToken1False(
        address token0,
        address token1,
        uint64 creatorFee,
        uint24 boostDuration,
        uint64 graduationPoolFee,
        uint24 graduationPoolTickSpacing,
        uint40 startTime,
        uint24 auctionDuration
    ) public pure {
        vm.assume(token0 != token1);
        AuctionConfig config = createAuctionConfig({
            _creatorFee: creatorFee,
            _isSellingToken1: false,
            _boostDuration: boostDuration,
            _graduationPoolFee: graduationPoolFee,
            _graduationPoolTickSpacing: graduationPoolTickSpacing,
            _startTime: startTime,
            _auctionDuration: auctionDuration
        });
        AuctionKey memory key = AuctionKey({token0: token0, token1: token1, config: config});

        assertEq(key.sellToken(), token0);
        assertEq(key.buyToken(), token1);
    }

    function test_sellToken_whenIsSellingToken1True(
        address token0,
        address token1,
        uint64 creatorFee,
        uint24 boostDuration,
        uint64 graduationPoolFee,
        uint24 graduationPoolTickSpacing,
        uint40 startTime,
        uint24 auctionDuration
    ) public pure {
        vm.assume(token0 != token1);
        AuctionConfig config = createAuctionConfig({
            _creatorFee: creatorFee,
            _isSellingToken1: true,
            _boostDuration: boostDuration,
            _graduationPoolFee: graduationPoolFee,
            _graduationPoolTickSpacing: graduationPoolTickSpacing,
            _startTime: startTime,
            _auctionDuration: auctionDuration
        });
        AuctionKey memory key = AuctionKey({token0: token0, token1: token1, config: config});

        assertEq(key.sellToken(), token1);
        assertEq(key.buyToken(), token0);
    }
}
