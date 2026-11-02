// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {AuctionConfig, createAuctionConfig} from "../../src/types/auctionConfig.sol";

contract AuctionConfigTest is Test {
    /// @dev Reserved bits: [239..224], [223..217] (above the selling flag at 216), [191..144], [127..104]
    function test_conversionToAndFrom(AuctionConfig config) public pure {
        uint256 rawConfig = uint256(AuctionConfig.unwrap(config));
        // normalize the selling flag bit like the original: any nonzero flag byte reads as true
        uint256 canonicalConfig = rawConfig & ~(uint256(0xff) << 216);
        if (((rawConfig >> 216) & 0xff) != 0) canonicalConfig |= (uint256(1) << 216);
        // reserved bits must be zero for an exact round trip:
        // [239..224], [223..217] (bit 216 is the selling flag), [191..144], [127..104]
        vm.assume(rawConfig & 0x0000fffffe000000ffffffffffff0000ffffff00000000000000000000000000 == 0);

        assertEq(
            AuctionConfig.unwrap(
                createAuctionConfig({
                    _creatorFee: config.creatorFee(),
                    _isSellingToken1: config.isSellingToken1(),
                    _minBoostDuration: config.minBoostDuration(),
                    _graduationPoolFee: config.graduationPoolFee(),
                    _graduationPoolTickSpacingExp: config.graduationPoolTickSpacing(),
                    _startTime: config.startTime(),
                    _auctionDuration: config.auctionDuration()
                })
            ),
            bytes32(canonicalConfig)
        );
    }

    function test_conversionFromAndTo(
        uint16 creatorFee_,
        bool isSellingToken1_,
        uint24 minBoostDuration_,
        uint16 graduationPoolFee_,
        uint8 graduationPoolTickSpacingExp_,
        uint64 startTime_,
        uint32 auctionDuration_
    ) public pure {
        AuctionConfig config = createAuctionConfig({
            _creatorFee: creatorFee_,
            _isSellingToken1: isSellingToken1_,
            _minBoostDuration: minBoostDuration_,
            _graduationPoolFee: graduationPoolFee_,
            _graduationPoolTickSpacingExp: graduationPoolTickSpacingExp_,
            _startTime: startTime_,
            _auctionDuration: auctionDuration_
        });

        assertEq(config.creatorFee(), creatorFee_);
        assertEq(config.isSellingToken1(), isSellingToken1_);
        assertEq(config.minBoostDuration(), minBoostDuration_);
        assertEq(config.graduationPoolFee(), graduationPoolFee_);
        assertEq(config.graduationPoolTickSpacing(), graduationPoolTickSpacingExp_);
        assertEq(config.startTime(), startTime_);
        assertEq(config.auctionDuration(), auctionDuration_);
        uint64 expectedEndTime;
        unchecked {
            expectedEndTime = startTime_ + uint64(auctionDuration_);
        }
        assertEq(config.endTime(), expectedEndTime);
    }

    function test_conversionFromAndToDirtyBits(
        bytes32 creatorFeeDirty,
        bytes32 isSellingToken1Dirty,
        bytes32 minBoostDurationDirty,
        bytes32 graduationPoolFeeDirty,
        bytes32 graduationPoolTickSpacingExpDirty,
        bytes32 startTimeDirty,
        bytes32 auctionDurationDirty
    ) public pure {
        uint16 creatorFee_;
        bool isSellingToken1_;
        uint24 minBoostDuration_;
        uint16 graduationPoolFee_;
        uint8 graduationPoolTickSpacingExp_;
        uint64 startTime_;
        uint32 auctionDuration_;

        assembly ("memory-safe") {
            creatorFee_ := creatorFeeDirty
            isSellingToken1_ := isSellingToken1Dirty
            minBoostDuration_ := minBoostDurationDirty
            graduationPoolFee_ := graduationPoolFeeDirty
            graduationPoolTickSpacingExp_ := graduationPoolTickSpacingExpDirty
            startTime_ := startTimeDirty
            auctionDuration_ := auctionDurationDirty
        }

        AuctionConfig config = createAuctionConfig({
            _creatorFee: creatorFee_,
            _isSellingToken1: isSellingToken1_,
            _minBoostDuration: minBoostDuration_,
            _graduationPoolFee: graduationPoolFee_,
            _graduationPoolTickSpacingExp: graduationPoolTickSpacingExp_,
            _startTime: startTime_,
            _auctionDuration: auctionDuration_
        });

        assertEq(config.creatorFee(), creatorFee_, "creatorFee");
        assertEq(config.isSellingToken1(), isSellingToken1_, "isSellingToken1");
        assertEq(config.minBoostDuration(), minBoostDuration_, "minBoostDuration");
        assertEq(config.graduationPoolFee(), graduationPoolFee_, "graduationPoolFee");
        assertEq(config.graduationPoolTickSpacing(), graduationPoolTickSpacingExp_, "graduationPoolTickSpacingExp");
        assertEq(config.startTime(), startTime_, "startTime");
        assertEq(config.auctionDuration(), auctionDuration_, "auctionDuration");
    }
}
