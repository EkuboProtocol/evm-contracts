// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {SavedBalancesWrapper} from "../src/SavedBalancesWrapper.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {ERC6909} from "solady/tokens/ERC6909.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";

contract SavedBalancesWrapperLocker is BaseLocker {
    using FlashAccountantLib for *;
    SavedBalancesWrapper private immutable wrapper;

    constructor(ICore core, SavedBalancesWrapper _wrapper) BaseLocker(core) {
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

contract SavedBalancesWrapperTest is FullTest {
    using CoreLib for *;

    address receiver = makeAddr("receiver");

    SavedBalancesWrapper wrapper;
    SavedBalancesWrapperLocker locker;

    function setUp() public override {
        FullTest.setUp();
        wrapper = new SavedBalancesWrapper(core);
        locker = new SavedBalancesWrapperLocker(core, wrapper);
    }

    function test_uri_content() public view {
        assertEq(
            wrapper.tokenURI(1), "data:application/json;utf8,{\"token\":\"0x0000000000000000000000000000000000000001\"}"
        );
        assertEq(
            wrapper.tokenURI(wrapper.tokenId(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48)),
            "data:application/json;utf8,{\"token\":\"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48\"}"
        );
    }

    function test_uri_no_revert(address v) public view {
        vm.assume(uint160(v) != type(uint160).max);
        wrapper.tokenURI(wrapper.tokenId(v));
    }

    function test_tokenId_never_reverts(address v) public view {
        vm.assume(uint160(v) != type(uint160).max);
        assertEq(wrapper.tokenAddress(wrapper.tokenId(v)), v);
    }

    function test_uri_invalid() public {
        vm.expectRevert(abi.encodeWithSelector(SavedBalancesWrapper.InvalidTokenId.selector, type(uint256).max));
        wrapper.tokenURI(type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(SavedBalancesWrapper.InvalidTokenId.selector, type(uint160).max));
        wrapper.tokenURI(type(uint160).max);
    }

    function test_token_metadata() public {
        assertEq(wrapper.name(uint160(address(token0))), "TestToken");
        assertEq(wrapper.symbol(uint160(address(token0))), "TT");
        assertEq(wrapper.decimals(uint160(address(token0))), 18);
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
            vm.expectRevert(ERC6909.InsufficientPermission.selector);
            locker.burn(address(token0), address(this), amount);

            wrapper.temporaryAllowBurn(address(locker), wrapper.tokenId(address(token0)), amount - 1);
            vm.expectRevert(ERC6909.InsufficientPermission.selector);
            locker.burn(address(token0), address(this), amount);
        }

        wrapper.temporaryAllowBurn(address(locker), wrapper.tokenId(address(token0)), amount);
        locker.burn(address(token0), address(this), amount);

        assertEq(wrapper.balanceOf(address(receiver), id), 0, "receipt burn");
        (saved,) = core.savedBalances(address(wrapper), address(token0), address(type(uint160).max), bytes32(0));
        assertEq(saved, 0, "saved balance cleared");
        assertEq(token0.balanceOf(address(core)), 0, "core transferred out amount");
        assertEq(token0.balanceOf(address(this)), payerBalanceStart, "payer received the refund");
    }
}
