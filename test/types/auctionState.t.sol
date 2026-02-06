// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {AuctionState, createAuctionState} from "../../src/types/auctionState.sol";

contract AuctionStateTest is Test {
    function test_conversionToAndFrom(AuctionState state) public pure {
        assertEq(
            AuctionState.unwrap(
                createAuctionState({
                    _creatorCollectionPercentage: state.creatorCollectionPercentage(),
                    _boostDuration: state.boostDuration(),
                    _graduationPoolFee: state.graduationPoolFee(),
                    _graduationPoolTickSpacing: state.graduationPoolTickSpacing(),
                    _totalAmountSold: state.totalAmountSold()
                })
            ),
            AuctionState.unwrap(state)
        );
    }

    function test_conversionFromAndTo(
        uint8 creatorCollectionPercentage_,
        uint24 boostDuration_,
        uint64 graduationPoolFee_,
        uint32 graduationPoolTickSpacing_,
        uint128 totalAmountSold_
    ) public pure {
        AuctionState state = createAuctionState({
            _creatorCollectionPercentage: creatorCollectionPercentage_,
            _boostDuration: boostDuration_,
            _graduationPoolFee: graduationPoolFee_,
            _graduationPoolTickSpacing: graduationPoolTickSpacing_,
            _totalAmountSold: totalAmountSold_
        });

        assertEq(state.creatorCollectionPercentage(), creatorCollectionPercentage_);
        assertEq(state.boostDuration(), boostDuration_);
        assertEq(state.graduationPoolFee(), graduationPoolFee_);
        assertEq(state.graduationPoolTickSpacing(), graduationPoolTickSpacing_);
        assertEq(state.totalAmountSold(), totalAmountSold_);
    }

    function test_parse(
        uint8 creatorCollectionPercentage_,
        uint24 boostDuration_,
        uint64 graduationPoolFee_,
        uint32 graduationPoolTickSpacing_,
        uint128 totalAmountSold_
    ) public pure {
        AuctionState state = createAuctionState({
            _creatorCollectionPercentage: creatorCollectionPercentage_,
            _boostDuration: boostDuration_,
            _graduationPoolFee: graduationPoolFee_,
            _graduationPoolTickSpacing: graduationPoolTickSpacing_,
            _totalAmountSold: totalAmountSold_
        });

        (
            uint8 parsedCreatorCollectionPercentage,
            uint24 parsedBoostDuration,
            uint64 parsedGraduationPoolFee,
            uint32 parsedGraduationPoolTickSpacing,
            uint128 parsedTotalAmountSold
        ) = state.parse();

        assertEq(parsedCreatorCollectionPercentage, creatorCollectionPercentage_);
        assertEq(parsedBoostDuration, boostDuration_);
        assertEq(parsedGraduationPoolFee, graduationPoolFee_);
        assertEq(parsedGraduationPoolTickSpacing, graduationPoolTickSpacing_);
        assertEq(parsedTotalAmountSold, totalAmountSold_);
    }

    function test_conversionFromAndToDirtyBits(
        bytes32 creatorCollectionPercentageDirty,
        bytes32 boostDurationDirty,
        bytes32 graduationPoolFeeDirty,
        bytes32 graduationPoolTickSpacingDirty,
        bytes32 totalAmountSoldDirty
    ) public pure {
        uint8 creatorCollectionPercentage_;
        uint24 boostDuration_;
        uint64 graduationPoolFee_;
        uint32 graduationPoolTickSpacing_;
        uint128 totalAmountSold_;

        assembly ("memory-safe") {
            creatorCollectionPercentage_ := creatorCollectionPercentageDirty
            boostDuration_ := boostDurationDirty
            graduationPoolFee_ := graduationPoolFeeDirty
            graduationPoolTickSpacing_ := graduationPoolTickSpacingDirty
            totalAmountSold_ := totalAmountSoldDirty
        }

        AuctionState state = createAuctionState({
            _creatorCollectionPercentage: creatorCollectionPercentage_,
            _boostDuration: boostDuration_,
            _graduationPoolFee: graduationPoolFee_,
            _graduationPoolTickSpacing: graduationPoolTickSpacing_,
            _totalAmountSold: totalAmountSold_
        });

        assertEq(state.creatorCollectionPercentage(), creatorCollectionPercentage_, "creatorCollectionPercentage");
        assertEq(state.boostDuration(), boostDuration_, "boostDuration");
        assertEq(state.graduationPoolFee(), graduationPoolFee_, "graduationPoolFee");
        assertEq(state.graduationPoolTickSpacing(), graduationPoolTickSpacing_, "graduationPoolTickSpacing");
        assertEq(state.totalAmountSold(), totalAmountSold_, "totalAmountSold");
    }
}
