// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {AuctionConfig, createAuctionConfig} from "../../src/types/auctionConfig.sol";

contract AuctionConfigTest is Test {
    function test_conversionToAndFrom(AuctionConfig config) public pure {
        assertEq(
            AuctionConfig.unwrap(
                createAuctionConfig({
                    _creatorFee: config.creatorFee(),
                    _isSellingToken1: config.isSellingToken1(),
                    _boostDuration: config.boostDuration(),
                    _graduationPoolFee: config.graduationPoolFee(),
                    _graduationPoolTickSpacing: config.graduationPoolTickSpacing(),
                    _startTime: config.startTime(),
                    _auctionDuration: config.auctionDuration()
                })
            ),
            AuctionConfig.unwrap(config)
        );
    }

    function test_conversionFromAndTo(
        uint64 creatorFee_,
        bool isSellingToken1_,
        uint24 boostDuration_,
        uint64 graduationPoolFee_,
        uint24 graduationPoolTickSpacing_,
        uint40 startTime_,
        uint24 auctionDuration_
    ) public pure {
        AuctionConfig config = createAuctionConfig({
            _creatorFee: creatorFee_,
            _isSellingToken1: isSellingToken1_,
            _boostDuration: boostDuration_,
            _graduationPoolFee: graduationPoolFee_,
            _graduationPoolTickSpacing: graduationPoolTickSpacing_,
            _startTime: startTime_,
            _auctionDuration: auctionDuration_
        });

        assertEq(config.creatorFee(), creatorFee_);
        assertEq(config.isSellingToken1(), isSellingToken1_);
        assertEq(config.boostDuration(), boostDuration_);
        assertEq(config.graduationPoolFee(), graduationPoolFee_);
        assertEq(config.graduationPoolTickSpacing(), graduationPoolTickSpacing_);
        assertEq(config.startTime(), startTime_);
        assertEq(config.auctionDuration(), auctionDuration_);
        assertEq(config.endTime(), uint64(startTime_) + uint64(auctionDuration_));
    }

    function test_conversionFromAndToDirtyBits(
        bytes32 creatorFeeDirty,
        bytes32 isSellingToken1Dirty,
        bytes32 boostDurationDirty,
        bytes32 graduationPoolFeeDirty,
        bytes32 graduationPoolTickSpacingDirty,
        bytes32 startTimeDirty,
        bytes32 auctionDurationDirty
    ) public pure {
        uint64 creatorFee_;
        bool isSellingToken1_;
        uint24 boostDuration_;
        uint64 graduationPoolFee_;
        uint24 graduationPoolTickSpacing_;
        uint64 startTime_;
        uint24 auctionDuration_;

        assembly ("memory-safe") {
            creatorFee_ := creatorFeeDirty
            isSellingToken1_ := isSellingToken1Dirty
            boostDuration_ := boostDurationDirty
            graduationPoolFee_ := graduationPoolFeeDirty
            graduationPoolTickSpacing_ := graduationPoolTickSpacingDirty
            startTime_ := startTimeDirty
            auctionDuration_ := auctionDurationDirty
        }

        AuctionConfig config = createAuctionConfig({
            _creatorFee: creatorFee_,
            _isSellingToken1: isSellingToken1_,
            _boostDuration: boostDuration_,
            _graduationPoolFee: graduationPoolFee_,
            _graduationPoolTickSpacing: graduationPoolTickSpacing_,
            _startTime: uint40(startTime_),
            _auctionDuration: auctionDuration_
        });

        assertEq(config.creatorFee(), creatorFee_, "creatorFee");
        assertEq(config.isSellingToken1(), isSellingToken1_, "isSellingToken1");
        assertEq(config.boostDuration(), boostDuration_, "boostDuration");
        assertEq(config.graduationPoolFee(), graduationPoolFee_, "graduationPoolFee");
        assertEq(config.graduationPoolTickSpacing(), graduationPoolTickSpacing_, "graduationPoolTickSpacing");
        assertEq(config.startTime(), uint40(startTime_), "startTime");
        assertEq(config.auctionDuration(), auctionDuration_, "auctionDuration");
    }
}
