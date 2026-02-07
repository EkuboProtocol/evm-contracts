// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseOrdersTest} from "./Orders.t.sol";
import {Auctions} from "../src/Auctions.sol";
import {AuctionConfig, createAuctionConfig} from "../src/types/auctionConfig.sol";
import {nextValidTime} from "../src/math/time.sol";

contract AuctionsTest is BaseOrdersTest {
    Auctions auctions;

    function setUp() public virtual override {
        BaseOrdersTest.setUp();
        auctions = new Auctions(address(this), core, twamm, address(0), 0, 1 days, uint64((uint256(1) << 64) / 100), 1000);
    }

    function test_create_auction_gas() public {
        uint64 startTime = uint64(nextValidTime(block.timestamp, block.timestamp + 1));
        uint64 endTime = uint64(nextValidTime(block.timestamp, startTime + 3600 - 1));
        uint32 duration = uint32(endTime - startTime);
        uint128 totalAmountSold = 69_420e18;
        AuctionConfig config = createAuctionConfig(address(token1), startTime, duration);

        uint256 tokenId = auctions.mint();

        token1.approve(address(auctions), totalAmountSold);
        auctions.createAuction(tokenId, config, totalAmountSold);
        vm.snapshotGasLastCall("Auctions#createAuction");
    }
}
