// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {SavedBalance1155} from "../src/SavedBalance1155.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ERC1155} from "solady/tokens/ERC1155.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";

contract ERC1155Receiver {
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xf23a6e61;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return 0xbc197c81;
    }
}

contract SavedBalance1155Locker is BaseLocker {
    using FlashAccountantLib for *;
    SavedBalance1155 private immutable wrapper;

    constructor(ICore core, SavedBalance1155 _wrapper) BaseLocker(core) {
        wrapper = _wrapper;
    }

    function mint(address token, address recipient, uint128 amount) external {
        lock(abi.encode(token, msg.sender, recipient, SafeCastLib.toInt128(amount)));
    }

    function burn(address token, address recipient, uint128 amount) external {
        lock(abi.encode(token, msg.sender, recipient, SafeCastLib.toInt128(-int256(uint256(amount)))));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (address token, address sender, address recipient, int128 delta) =
            abi.decode(data, (address, address, address, int128));

        if (delta > 0) {
            ACCOUNTANT.forward(address(wrapper), abi.encode(token, recipient, delta));
            ACCOUNTANT.payFrom(sender, token, uint128(delta));
        } else if (delta < 0) {
            ACCOUNTANT.forward(address(wrapper), abi.encode(token, sender, delta));
            ACCOUNTANT.withdraw(token, recipient, uint128(uint256(-int256(delta))));
        }
    }
}

contract SavedBalance1155Test is FullTest {
    using CoreLib for *;

    ERC1155Receiver receiver;

    SavedBalance1155 wrapper;
    SavedBalance1155Locker locker;

    function setUp() public override {
        FullTest.setUp();
        receiver = new ERC1155Receiver();
        wrapper = new SavedBalance1155(core);
        locker = new SavedBalance1155Locker(core, wrapper);
    }

    function test_mint_burn(uint128 amount) public {
        amount = uint128(bound(amount, 0, uint128(type(int128).max)));

        uint256 id = wrapper.tokenId(address(token0));
        uint256 payerBalanceStart = token0.balanceOf(address(this));

        assertEq(wrapper.balanceOf(address(receiver), id), 0, "0 starting wrapper balance");

        token0.approve(address(locker), amount);
        locker.mint(address(token0), address(receiver), amount);

        assertEq(wrapper.balanceOf(address(receiver), id), amount, "amount minted");

        (uint128 saved,) = core.savedBalances(address(wrapper), address(token0), address(type(uint160).max), bytes32(0));
        assertEq(saved, amount, "saved balance");
        assertEq(token0.balanceOf(address(core)), amount, "core now holds underlying");
        assertEq(token0.balanceOf(address(this)), payerBalanceStart - amount, "payer debited");

        vm.startPrank(address(receiver));
        if (amount != 0) {
            vm.expectRevert(ERC1155.NotOwnerNorApproved.selector);
            locker.burn(address(token0), address(this), amount);
        }

        wrapper.setApprovalForAll(address(locker), true);
        locker.burn(address(token0), address(this), amount);

        assertEq(wrapper.balanceOf(address(receiver), id), 0, "receipt burn");
        (saved,) = core.savedBalances(address(wrapper), address(token0), address(type(uint160).max), bytes32(0));
        assertEq(saved, 0, "saved balance cleared");
        assertEq(token0.balanceOf(address(core)), 0, "core transferred out amount");
        assertEq(token0.balanceOf(address(this)), payerBalanceStart, "payer received the refund");
    }
}
