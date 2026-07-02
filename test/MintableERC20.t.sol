// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Ownable} from "solady/auth/Ownable.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {Test} from "forge-std/Test.sol";

import {MintableERC20} from "../src/MintableERC20.sol";

contract MintableERC20Test is Test {
    function test_ownerCanMintToRecipient() public {
        MintableERC20 token = new MintableERC20(address(this), "Mintable TestToken", "mTT");
        token.mint(address(0xbeef), 123);

        assertEq(token.balanceOf(address(0xbeef)), 123);
    }

    function test_metadata() public {
        MintableERC20 token = new MintableERC20(address(this), "Mintable TestToken", "mTT");

        assertEq(token.name(), "Mintable TestToken");
        assertEq(token.symbol(), "mTT");
        assertEq(token.decimals(), 18);
    }

    function test_constructorFailsIfMetadataIsTooLong() public {
        vm.expectRevert(MintableERC20.PackedStringTooLong.selector);
        new MintableERC20(address(this), "This token name is too long to pack", "mTT");

        vm.expectRevert(MintableERC20.PackedStringTooLong.selector);
        new MintableERC20(address(this), "Mintable TestToken", "This token symbol is too long to pack");
    }

    function test_mintFailsIfNotOwner() public {
        MintableERC20 token = new MintableERC20(address(this), "Mintable TestToken", "mTT");

        vm.prank(address(0xbeef));
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.mint(address(0xbeef), 123);
    }

    function test_mintFailsIfTotalSupplyWouldExceedUint128Max() public {
        MintableERC20 token = new MintableERC20(address(this), "Mintable TestToken", "mTT");
        token.mint(address(0xbeef), type(uint128).max);

        vm.expectRevert(ERC20.TotalSupplyOverflow.selector);
        token.mint(address(0xbeef), 1);
    }
}
