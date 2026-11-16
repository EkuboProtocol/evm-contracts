// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {ERC1155Receiver, SavedBalancesWrapperLocker} from "./SavedBalancesWrapper.t.sol";
import {SavedBalancesWrapper} from "../src/SavedBalancesWrapper.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract RedeemingSavedBalanceReceiver {
    SavedBalancesWrapper public immutable wrapper;
    SavedBalancesWrapperLocker public immutable locker;
    address public immutable token;
    address public immutable recipient;
    uint128 public redeemAmount;
    uint256 public callbacks;

    constructor(SavedBalancesWrapper wrapper_, SavedBalancesWrapperLocker locker_, address token_, address recipient_) {
        wrapper = wrapper_;
        locker = locker_;
        token = token_;
        recipient = recipient_;
        wrapper_.setApprovalForAll(address(locker_), true);
    }

    function setRedeemAmount(uint128 amount) external {
        redeemAmount = amount;
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(wrapper) && id == wrapper.tokenId(token));
        callbacks++;
        // This opens a nested lock before the outer mint's payer has transferred its underlying.
        locker.burn(token, recipient, redeemAmount);
        return this.onERC1155Received.selector;
    }
}

contract SavedBalancesWrapperCallbackTest is FullTest {
    using CoreLib for *;

    SavedBalancesWrapper wrapper;
    SavedBalancesWrapper otherWrapper;
    SavedBalancesWrapperLocker locker;
    SavedBalancesWrapperLocker otherLocker;
    RedeemingSavedBalanceReceiver receiver;
    ERC1155Receiver otherHolder;
    address recipient = makeAddr("redemption-recipient");

    function setUp() public override {
        FullTest.setUp();
        wrapper = new SavedBalancesWrapper(core);
        otherWrapper = new SavedBalancesWrapper(core);
        locker = new SavedBalancesWrapperLocker(core, wrapper);
        otherLocker = new SavedBalancesWrapperLocker(core, otherWrapper);
        receiver = new RedeemingSavedBalanceReceiver(wrapper, locker, address(token0), recipient);
        otherHolder = new ERC1155Receiver();
        token0.approve(address(otherLocker), type(uint256).max);
        token1.approve(address(otherLocker), type(uint256).max);
        token0.approve(address(locker), type(uint256).max);
    }

    function _saved(SavedBalancesWrapper target, address token) internal view returns (uint128 amount) {
        (amount,) = core.savedBalances(address(target), token, address(type(uint160).max), bytes32(0));
    }

    function _seedOtherClaims(uint128 amount) internal {
        // Shared custody provides liquidity for the nested withdrawal, but its claims must remain backed.
        otherLocker.mint(address(token0), address(otherHolder), amount);
        otherLocker.mint(address(token1), address(otherHolder), 29);
    }

    function _assertOtherClaims(uint128 amount) internal view {
        assertEq(_saved(otherWrapper, address(token0)), amount, "other wrapper backing");
        assertEq(otherWrapper.balanceOf(address(otherHolder), otherWrapper.tokenId(address(token0))), amount);
        assertEq(_saved(otherWrapper, address(token1)), 29, "unrelated token backing");
        assertEq(otherWrapper.balanceOf(address(otherHolder), otherWrapper.tokenId(address(token1))), 29);
        assertEq(token1.balanceOf(address(core)), 29, "unrelated token custody");
    }

    function test_callbackRedeemsBeforeOuterPayment(uint96 minted, uint96 redeemed) public {
        minted = uint96(bound(minted, 1, type(uint96).max));
        redeemed = uint96(bound(redeemed, 1, minted));
        uint128 otherClaims = uint128(minted) + 17;
        _seedOtherClaims(otherClaims);
        receiver.setRedeemAmount(redeemed);
        uint256 payerBefore = token0.balanceOf(address(this));

        locker.mint(address(token0), address(receiver), minted);

        assertEq(receiver.callbacks(), 1, "nested callback completed");
        assertEq(token0.balanceOf(address(this)), payerBefore - minted, "outer payer settled");
        assertEq(token0.balanceOf(recipient), redeemed, "nested recipient paid");
        assertEq(wrapper.balanceOf(address(receiver), wrapper.tokenId(address(token0))), minted - redeemed);
        assertEq(_saved(wrapper, address(token0)), minted - redeemed);
        assertEq(token0.balanceOf(address(core)), uint256(otherClaims) + minted - redeemed);
        _assertOtherClaims(otherClaims);

        // The outer locker must be restored after nesting, and both claim owners can still fully exit.
        vm.prank(address(receiver));
        locker.burn(address(token0), recipient, minted - redeemed);
        vm.startPrank(address(otherHolder));
        otherWrapper.setApprovalForAll(address(otherLocker), true);
        otherLocker.burn(address(token0), address(this), otherClaims);
        otherLocker.burn(address(token1), address(this), 29);
        vm.stopPrank();
        assertEq(token0.balanceOf(recipient), minted);
        assertEq(token0.balanceOf(address(core)), 0);
        assertEq(token1.balanceOf(address(core)), 0);
        assertEq(_saved(wrapper, address(token0)), 0);
        assertEq(_saved(otherWrapper, address(token0)), 0);
        assertEq(_saved(otherWrapper, address(token1)), 0);
        assertEq(wrapper.balanceOf(address(receiver), wrapper.tokenId(address(token0))), 0);
        assertEq(otherWrapper.balanceOf(address(otherHolder), otherWrapper.tokenId(address(token0))), 0);
        assertEq(otherWrapper.balanceOf(address(otherHolder), otherWrapper.tokenId(address(token1))), 0);
    }

    function test_failedOuterPaymentRollsBackNestedRedemption(uint96 amount) public {
        amount = uint96(bound(amount, 1, type(uint96).max));
        uint128 otherClaims = uint128(amount) + 17;
        _seedOtherClaims(otherClaims);
        receiver.setRedeemAmount(amount);
        token0.approve(address(locker), 0);
        uint256 payerBefore = token0.balanceOf(address(this));

        vm.expectCall(address(locker), abi.encodeCall(locker.burn, (address(token0), recipient, amount)));
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        locker.mint(address(token0), address(receiver), amount);

        assertEq(receiver.callbacks(), 0, "callback state rolled back");
        assertEq(token0.balanceOf(recipient), 0, "nested payment rolled back");
        assertEq(token0.balanceOf(address(this)), payerBefore);
        assertEq(wrapper.balanceOf(address(receiver), wrapper.tokenId(address(token0))), 0);
        assertEq(_saved(wrapper, address(token0)), 0);
        assertEq(token0.balanceOf(address(core)), otherClaims, "other claims still backed");
        _assertOtherClaims(otherClaims);

        token0.approve(address(locker), amount);
        locker.mint(address(token0), address(receiver), amount);
        assertEq(receiver.callbacks(), 1, "retry is not poisoned by reverted nested lock");
        assertEq(token0.balanceOf(recipient), amount);
        assertEq(token0.balanceOf(address(this)), payerBefore - amount);
        assertEq(wrapper.balanceOf(address(receiver), wrapper.tokenId(address(token0))), 0);
        assertEq(_saved(wrapper, address(token0)), 0);
        assertEq(token0.balanceOf(address(core)), otherClaims);
        _assertOtherClaims(otherClaims);
    }
}
