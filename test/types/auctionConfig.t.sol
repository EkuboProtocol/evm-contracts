// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {AuctionConfig, createAuctionConfig} from "../../src/types/auctionConfig.sol";

contract AuctionConfigTest is Test {
    function test_conversionToAndFrom(AuctionConfig config) public pure {
        assertEq(
            AuctionConfig.unwrap(
                createAuctionConfig({_token: config.token(), _startTime: config.startTime(), _duration: config.duration()})
            ),
            AuctionConfig.unwrap(config)
        );
    }

    function test_conversionFromAndTo(address token_, uint64 startTime_, uint32 duration_) public pure {
        AuctionConfig config = createAuctionConfig({_token: token_, _startTime: startTime_, _duration: duration_});

        assertEq(config.token(), token_);
        assertEq(config.startTime(), startTime_);
        assertEq(config.duration(), duration_);
    }

    function test_conversionFromAndToDirtyBits(bytes32 tokenDirty, bytes32 startTimeDirty, bytes32 durationDirty)
        public
        pure
    {
        address token_;
        uint64 startTime_;
        uint32 duration_;

        assembly ("memory-safe") {
            token_ := tokenDirty
            startTime_ := startTimeDirty
            duration_ := durationDirty
        }

        AuctionConfig config = createAuctionConfig({_token: token_, _startTime: startTime_, _duration: duration_});

        assertEq(config.token(), token_, "token");
        assertEq(config.startTime(), startTime_, "startTime");
        assertEq(config.duration(), duration_, "duration");
    }
}
