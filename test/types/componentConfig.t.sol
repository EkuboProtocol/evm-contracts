// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Test} from "forge-std/Test.sol";
import {ComponentConfig, createComponentConfig} from "../../src/types/componentConfig.sol";

contract ComponentConfigTest is Test {
    function test_conversionToAndFrom(ComponentConfig config) public pure {
        assertEq(
            ComponentConfig.unwrap(
                createComponentConfig({_token: config.token(), _weight: config.weight(), _twammFee: config.twammFee()})
            ),
            ComponentConfig.unwrap(config)
        );
    }

    function test_conversionFromAndTo(address token_, uint32 weight_, uint64 twammFee_) public pure {
        ComponentConfig config = createComponentConfig({_token: token_, _weight: weight_, _twammFee: twammFee_});
        assertEq(config.token(), token_);
        assertEq(config.weight(), weight_);
        assertEq(config.twammFee(), twammFee_);
    }

    function test_conversionFromAndToDirtyBits(bytes32 tokenDirty, bytes32 weightDirty, bytes32 twammFeeDirty)
        public
        pure
    {
        address token_;
        uint32 weight_;
        uint64 twammFee_;

        assembly ("memory-safe") {
            token_ := tokenDirty
            weight_ := weightDirty
            twammFee_ := twammFeeDirty
        }

        ComponentConfig config = createComponentConfig({_token: token_, _weight: weight_, _twammFee: twammFee_});
        assertEq(config.token(), token_, "token");
        assertEq(config.weight(), weight_, "weight");
        assertEq(config.twammFee(), twammFee_, "twammFee");
    }
}
