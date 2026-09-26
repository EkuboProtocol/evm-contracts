// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {ContinuousAuction, continuousAuctionCallPoints} from "../../src/extensions/ContinuousAuction.sol";
import {AuctionPositions} from "../../src/AuctionPositions.sol";
import {AuctionPeriphery} from "../../src/AuctionPeriphery.sol";
import {
    AUCTION_FUNDS_SAVED_BALANCE_ID,
    AUCTION_SAVED_BALANCE_PAIR_TOKEN
} from "../../src/interfaces/extensions/IContinuousAuction.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {ContinuousAuctionLib} from "../../src/libraries/ContinuousAuctionLib.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {CoreStorageLayout} from "../../src/libraries/CoreStorageLayout.sol";
import {ExposedStorageLib} from "../../src/libraries/ExposedStorageLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {createPositionId} from "../../src/types/positionId.sol";
import {createSwapParameters, SwapParameters} from "../../src/types/swapParameters.sol";
import {createConcentratedPoolConfig, createStableswapPoolConfig} from "../../src/types/poolConfig.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {computeFee} from "../../src/math/fee.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @dev A Core locker that swaps through the auction and settles with its owner's tokens.
contract AuctionExecutor is BaseLocker {
    using CoreLib for *;
    using FlashAccountantLib for *;

    ICore private immutable core;
    ContinuousAuction private immutable auction;
    address private immutable owner;

    constructor(ICore c, ContinuousAuction a) BaseLocker(c) {
        core = c;
        auction = a;
        owner = msg.sender;
    }

    function swap(PoolKey memory key, SwapParameters params, bool direct) external returns (PoolBalanceUpdate update) {
        require(msg.sender == owner);
        update = abi.decode(lock(abi.encode(key, params, direct)), (PoolBalanceUpdate));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory key, SwapParameters params, bool direct) = abi.decode(data, (PoolKey, SwapParameters, bool));
        PoolBalanceUpdate update;
        if (direct) {
            (update,) = core.swap(0, key, params);
        } else {
            (update,) = ContinuousAuctionLib.swap(core, address(auction), key, params);
        }
        if (update.delta0() > 0) ACCOUNTANT.payFrom(owner, key.token0, uint128(update.delta0()));
        else if (update.delta0() < 0) ACCOUNTANT.withdraw(key.token0, owner, uint128(-update.delta0()));
        if (update.delta1() > 0) ACCOUNTANT.payFrom(owner, key.token1, uint128(update.delta1()));
        else if (update.delta1() < 0) ACCOUNTANT.withdraw(key.token1, owner, uint128(-update.delta1()));
        return abi.encode(update);
    }
}

contract TaxedAuctionToken is TestToken {
    constructor(address recipient) TestToken(recipient) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        return super.transferFrom(from, to, amount - 1);
    }
}

contract ContinuousAuctionTest is FullTest {
    using CoreLib for *;
    using ExposedStorageLib for *;

    ContinuousAuction auction;
    AuctionPositions manager;
    AuctionPeriphery periphery;
    AuctionExecutor executor;
    AuctionExecutor outsider;
    PoolKey key;
    PoolId poolId;
    uint256 nft;
    uint128 liquidity;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    address carol = address(0xca401);
    uint96 constant RATE = 1e12;
    uint32 constant FEE = 42949672; // 1% as a 0.32 fixed-point fraction
    uint64 constant FEE64 = uint64(FEE) << 32;
    bytes32 constant SALT = bytes32(0);

    function setUp() public override {
        super.setUp();
        vm.warp(100);
        vm.roll(10);
        vm.deal(address(this), 1e30);
        auction = _deploy(address(0), 0);
        manager = new AuctionPositions(core, auction, owner);
        periphery = new AuctionPeriphery(core, auction);
        executor = new AuctionExecutor(core, auction);
        outsider = new AuctionExecutor(core, auction);
        token0.approve(address(executor), type(uint256).max);
        token1.approve(address(executor), type(uint256).max);
        token0.approve(address(outsider), type(uint256).max);
        token1.approve(address(outsider), type(uint256).max);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
        key = createPool(0, 0, 16, address(auction));
        poolId = key.toPoolId();
        (nft, liquidity) = _createPosition(key, -1600, 1600, 1e18, 1e18);
    }

    function _deploy(address token, uint160 salt) private returns (ContinuousAuction a) {
        address target = address((uint160(continuousAuctionCallPoints().toUint8()) << 152) | salt);
        deployCodeTo("ContinuousAuction.sol:ContinuousAuction", abi.encode(core, token), target);
        return ContinuousAuction(target);
    }

    function _createPosition(PoolKey memory k, int32 lower, int32 upper, uint128 amount0, uint128 amount1)
        private
        returns (uint256 id, uint128 liq)
    {
        (id, liq,,) = manager.mintAndDeposit(k, lower, upper, amount0, amount1, 0);
    }

    function _id(address user) private view returns (bytes32) {
        return periphery.bidderId(user, SALT);
    }

    /// @dev Places or replaces `bidder`'s bid, funding exactly the net amount the extension charges.
    function _bid(PoolKey memory k, address bidder, uint96 rate, uint64 end, address exec) private {
        uint256 funding = uint256(rate) * (end - block.timestamp - 1);
        vm.deal(bidder, bidder.balance + funding);
        vm.prank(bidder);
        periphery.updateBid{value: funding}(k, SALT, rate, end, exec, FEE, bidder);
        vm.prank(bidder);
        periphery.refundNativeToken();
    }

    function _bid(address bidder, uint96 rate, uint64 end, address exec) private {
        _bid(key, bidder, rate, end, exec);
    }

    /// @dev Removes `bidder`'s scheduled bid, if any, and withdraws its credit. Returns the amount withdrawn.
    function _remove(address bidder) private returns (uint256 refund) {
        vm.prank(bidder);
        int256 delta = periphery.updateBid(key, SALT, 0, 0, address(0), 0, bidder);
        refund = uint256(-delta);
    }

    function _fees(address user) private view returns (uint128 amount0, uint128 amount1) {
        return auction.swapFeesOwed(key, address(periphery), periphery.bidderSalt(user, SALT));
    }

    function _funds() private view returns (uint256) {
        return uint256(
            core.sload(
            CoreStorageLayout.savedBalancesSlot(
            address(auction), address(0), AUCTION_SAVED_BALANCE_PAIR_TOKEN, AUCTION_FUNDS_SAVED_BALANCE_ID
        )
        )
        ) >> 128;
    }

    function _time(uint256 time) private {
        vm.warp(time);
        vm.roll(block.number + 1);
    }

    function _claim(uint256 id, int32 lower, int32 upper) private returns (uint256) {
        return manager.collectRent(id, key, lower, upper, address(this));
    }

    function _params(int128 amount, bool isToken1, int32 limit) private pure returns (SwapParameters) {
        return createSwapParameters({
            _amount: amount, _isToken1: isToken1, _sqrtRatioLimit: tickToSqrtRatio(limit), _skipAhead: 0
        });
    }

    /// POOLS

    function test_anyoneCreatesPoolsDirectlyAndThereAreNoTerms() public {
        PoolKey memory k = key;
        k.config = createConcentratedPoolConfig(1, 64, address(auction));
        vm.expectRevert(ContinuousAuction.InvalidPool.selector);
        core.initializePool(k, 0);
        k.config = createConcentratedPoolConfig(0, 3, address(auction));
        vm.expectRevert(ContinuousAuction.InvalidPool.selector);
        core.initializePool(k, 0);
        k.config = createConcentratedPoolConfig(0, 64, address(auction));
        vm.prank(alice);
        core.initializePool(k, 0);
        (,, uint48 lastSettled,) = auction.auctions(k.toPoolId());
        assertEq(lastSettled, 0);
        k.config = createConcentratedPoolConfig(0, 256, address(auction));
        vm.deal(alice, 1e20);
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.InvalidPool.selector);
        periphery.updateBid{value: 1e20}(k, SALT, RATE, 512, alice, FEE, alice); // Bids need an initialized pool.
    }

    /// ACCESS

    function test_nextSecondAccessOutsiderFeeAndDirectSwapRejected() public {
        SwapParameters params = _params(1000, true, 100);
        vm.expectRevert(ContinuousAuction.PoolClosed.selector);
        executor.swap(key, params, false);
        _bid(alice, RATE, 512, address(executor));
        vm.roll(11); // A new block sharing the timestamp does not activate a bid.
        assertEq(auction.executorAt(poolId), address(0));
        vm.expectRevert(ContinuousAuction.PoolClosed.selector);
        outsider.swap(key, params, false);
        vm.warp(101);
        assertEq(auction.executorAt(poolId), address(executor));
        executor.swap(key, params, false);
        vm.expectRevert(ContinuousAuction.SwapMustHappenThroughForward.selector);
        executor.swap(key, params, true);
        outsider.swap(key, params, false);
        (uint128 fee0, uint128 fee1) = _fees(alice);
        assertGt(fee0, 0);
        assertEq(fee1, 0);
        _bid(bob, RATE + 1, 256, address(outsider));
        executor.swap(key, params, false); // Incumbent retains the current second.
        _time(102);
        assertEq(auction.executorAt(poolId), address(outsider));
        PoolBalanceUpdate charged = executor.swap(key, params, false); // The old executor now pays the fee.
        (uint128 after0,) = _fees(bob);
        assertEq(after0, computeFee(uint128(-charged.delta0()) + after0, FEE64));
        _time(256);
        vm.expectRevert(ContinuousAuction.PoolClosed.selector);
        outsider.swap(key, params, false);
        assertEq(auction.executorAt(poolId), address(0));
    }

    function test_exactOutputSwapsPayFeeOnInput() public {
        _bid(alice, RATE, 512, address(executor));
        _time(101);
        PoolBalanceUpdate charged = outsider.swap(key, _params(-1000, false, 100), false);
        assertEq(charged.delta0(), -1000);
        (, uint128 fee1) = _fees(alice);
        assertGt(fee1, 0);
        assertEq(
            uint128(charged.delta1()),
            FixedPointMathLib.fullMulDivUp(uint128(charged.delta1()) - fee1, 1 << 64, (1 << 64) - FEE64)
        );
    }

    function test_holderCollectsSwapFeesThroughPeriphery() public {
        _bid(alice, RATE, 512, address(executor));
        _time(101);
        outsider.swap(key, _params(1e17, true, 100), false);
        outsider.swap(key, _params(1e17, false, -100), false);
        (uint128 fee0, uint128 fee1) = _fees(alice);
        assertGt(fee0, 0);
        assertGt(fee1, 0);
        vm.prank(bob);
        (uint128 none0, uint128 none1) = periphery.collectSwapFees(key, SALT, bob);
        assertEq(none0 + none1, 0);
        vm.prank(alice);
        (uint128 paid0, uint128 paid1) = periphery.collectSwapFees(key, SALT, carol);
        assertEq(paid0, fee0);
        assertEq(paid1, fee1);
        assertEq(token0.balanceOf(carol), fee0);
        assertEq(token1.balanceOf(carol), fee1);
        (fee0, fee1) = _fees(alice);
        assertEq(fee0 + fee1, 0);
    }

    function test_feeTravelsWithTheBidAndOnlyTheLiveHolderChangesItNow() public {
        _bid(alice, RATE, 512, address(executor));
        _time(101);
        PoolBalanceUpdate charged = outsider.swap(key, _params(1e17, true, 100), false);
        (uint128 fee0,) = _fees(alice);
        assertEq(fee0, computeFee(uint128(-charged.delta0()) + fee0, FEE64));
        // Replacing the own bid with a zero fee takes effect next second.
        vm.prank(alice);
        periphery.updateBid(key, SALT, RATE, 512, address(executor), 0, alice);
        outsider.swap(key, _params(1e17, false, -100), false);
        (uint128 still0, uint128 still1) = _fees(alice);
        assertEq(still0, fee0);
        assertGt(still1, 0);
        _time(102);
        outsider.swap(key, _params(1e17, true, 100), false);
        (uint128 free0,) = _fees(alice);
        assertEq(free0, fee0);
        // A pending bidder's fee applies at activation, not during the incumbent's last second.
        _bid(bob, RATE * 2, 512, bob);
        outsider.swap(key, _params(1e17, false, -100), false);
        (, uint128 alice1) = _fees(alice);
        assertEq(alice1, still1);
        _time(103);
        charged = executor.swap(key, _params(1e17, false, -100), false);
        (, uint128 bob1) = _fees(bob);
        assertEq(bob1, computeFee(uint128(-charged.delta1()) + bob1, FEE64));
        vm.prank(bob);
        periphery.updateBid(key, SALT, RATE * 2, 512, bob, type(uint32).max, bob); // No cap.
        _time(104);
        PoolBalanceUpdate exclusive = executor.swap(key, _params(1e17, true, 100), false);
        (uint128 bob0,) = _fees(bob);
        assertGt(bob0, 0);
        assertLt(uint128(-exclusive.delta0()) * 1e6, bob0); // The swapper keeps about 2**-32 of the output.
    }

    /// BIDDING RULES

    function test_bidValidationAndStrictOutbid() public {
        vm.deal(alice, 1e20);
        vm.deal(bob, 1e20);
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.InvalidBid.selector);
        periphery.updateBid{value: 1e20}(key, SALT, RATE, 101, alice, FEE, alice); // At least one second.
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.InvalidBid.selector);
        periphery.updateBid{value: 1e20}(key, SALT, RATE, 512, address(0), FEE, alice);
        vm.prank(alice);
        vm.expectRevert();
        periphery.updateBid{value: 1}(key, SALT, RATE, 512, alice, FEE, alice); // Underfunded lock reverts.
        _bid(alice, RATE, 512, alice);
        vm.prank(bob);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid{value: 1e20}(key, SALT, RATE, 512, bob, FEE, bob); // Equal rates do not displace.
        _bid(alice, RATE + 1, 512, alice); // The scheduled bidder replaces its own bid at any rate.
        assertEq(auction.refundable(_id(alice)), 0);
        _bid(alice, RATE - 1, 512, alice); // Including a lower one.
        _bid(bob, RATE, 512, bob);
        _time(101);
        assertEq(auction.executorAt(poolId), bob);
        _time(512);
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.InvalidBid.selector);
        periphery.updateBid{value: 1e20}(key, SALT, RATE, 513 + uint64(type(uint32).max) + 1, alice, FEE, alice);
        _bid(carol, 1, 1024, carol); // An expired incumbent need not be outbid, and there is no reserve.
        _time(513);
        assertEq(auction.executorAt(poolId), carol);
    }

    function test_displacementCreditsRemainderAndTransfersAccess() public {
        _bid(alice, RATE, 1024, alice);
        _time(200);
        _bid(bob, RATE * 2, 512, bob);
        assertEq(auction.executorAt(poolId), alice);
        assertEq(auction.refundable(_id(alice)), uint256(RATE) * (1024 - 201));
        _time(201);
        assertEq(auction.executorAt(poolId), bob);
        _time(600);
        assertEq(auction.executorAt(poolId), address(0)); // Displaced funding is not rescheduled.
        uint256 expected = uint256(RATE) * (201 - 101) + uint256(RATE) * 2 * (512 - 201);
        uint256 paid = _claim(nft, -1600, 1600);
        assertApproxEqAbs(paid, expected, 2);
        uint256 refund = _remove(alice);
        assertEq(refund, uint256(RATE) * (1024 - 201));
        assertEq(alice.balance, refund);
        assertEq(_funds(), expected - paid);
    }

    function test_sameSecondPendingBidIsFullyCreditedWhenReplaced() public {
        _bid(alice, RATE, 1024, alice);
        _time(150);
        _bid(bob, RATE * 2, 768, bob);
        _bid(carol, RATE * 3, 256, carol);
        assertEq(auction.refundable(_id(alice)), uint256(RATE) * (1024 - 151));
        assertEq(auction.refundable(_id(bob)), uint256(RATE) * 2 * (768 - 151));
        assertEq(auction.executorAt(poolId), alice);
        _time(151);
        assertEq(auction.executorAt(poolId), carol);
        ContinuousAuction.Bid memory h = auction.holder(poolId);
        assertEq(h.bidder, _id(carol));
        assertEq(h.start, 151);
        assertEq(h.end, 256);
        _time(256);
        uint256 expected = uint256(RATE) * (151 - 101) + uint256(RATE) * 3 * (256 - 151);
        assertApproxEqAbs(_claim(nft, -1600, 1600), expected, 2);
        assertEq(auction.holder(poolId).bidder, bytes32(0));
    }

    function test_creditIsNettedIntoTheNextBid() public {
        _bid(alice, RATE, 1024, alice);
        _time(200);
        _bid(bob, RATE * 2, 512, bob);
        uint256 credit = auction.refundable(_id(alice));
        _time(300);
        uint256 funding = uint256(RATE) * 3 * (2048 - 301);
        vm.deal(alice, funding);
        vm.prank(alice);
        int256 delta = periphery.updateBid{value: funding}(key, SALT, RATE * 3, 2048, alice, FEE, alice);
        assertEq(uint256(delta), funding - credit);
        assertEq(auction.refundable(_id(alice)), 0);
        vm.prank(alice);
        periphery.refundNativeToken();
        assertEq(alice.balance, credit);
    }

    function test_replaceOwnBidExtendsShortensAndExitsImmediately() public {
        _bid(alice, RATE, 400, alice);
        vm.prank(bob);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, RATE, 800, bob, FEE, bob);
        // Extend: the own pending bid is replaced; the delta is the added tenure.
        vm.deal(alice, uint256(RATE) * 400 + 5);
        vm.prank(alice);
        int256 delta = periphery.updateBid{value: uint256(RATE) * 400 + 5}(key, SALT, RATE, 800, alice, FEE, alice);
        assertEq(delta, int256(uint256(RATE) * 400));
        vm.prank(alice);
        periphery.refundNativeToken();
        assertEq(alice.balance, 5);
        assertEq(auction.holder(poolId).bidder, bytes32(0)); // Not live until the next second.
        _time(300);
        assertEq(auction.holder(poolId).end, 800);
        // Shorten: the live bid ends at the next second and the new schedule is paid net.
        vm.prank(alice);
        delta = periphery.updateBid(key, SALT, RATE, 400, alice, FEE, alice);
        assertEq(delta, -int256(uint256(RATE) * (800 - 400)));
        assertEq(alice.balance, 5 + uint256(RATE) * 400);
        _time(399);
        assertEq(auction.executorAt(poolId), alice);
        // Exit: rate zero removes the schedule from the next second and withdraws the remainder.
        uint256 refund = _remove(alice);
        assertEq(refund, uint256(RATE) * (400 - 400));
        assertEq(auction.executorAt(poolId), alice); // Still holds the current second.
        _time(400);
        assertEq(auction.executorAt(poolId), address(0));
        _bid(alice, RATE, 2048, alice);
        _time(500);
        refund = _remove(alice);
        assertEq(refund, uint256(RATE) * (2048 - 501));
        _time(501);
        assertEq(auction.executorAt(poolId), address(0));
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * (400 - 101) + uint256(RATE) * (501 - 401), 3);
    }

    function test_displacedIncumbentCannotTouchItsFormerSchedule() public {
        _bid(alice, RATE, 1024, alice);
        _time(200);
        _bid(bob, RATE * 2, 512, bob);
        uint256 credit = auction.refundable(_id(alice));
        uint256 refund = _remove(alice); // Nothing scheduled to remove; the credit is withdrawn.
        assertEq(refund, credit);
        assertEq(auction.executorAt(poolId), alice); // The current second is unaffected.
        _time(201);
        assertEq(auction.executorAt(poolId), bob);
        assertEq(auction.holder(poolId).end, 512);
    }

    function test_pendingWinnerCannotDowngradeBelowTheDisplacedIncumbent() public {
        _bid(alice, RATE, 1024, alice);
        _time(101); // Alice's bid is live before Bob displaces it.
        _bid(bob, RATE * 2, 512, bob);
        // The pending winner may replace its own bid, but not below the live incumbent it displaced.
        vm.prank(bob);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, RATE - 1, 512, bob, FEE, bob);
        // Lowering to exactly the incumbent rate is still displacement without a strict improvement.
        vm.prank(bob);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, RATE, 512, bob, FEE, bob);
        // Raising, or lowering while staying above the incumbent, remains allowed.
        _bid(bob, RATE * 3, 512, bob);
        _time(102);
        assertEq(auction.executorAt(poolId), bob);
        // The incumbent keeps its displaced tenure as credit.
        assertEq(auction.refundable(_id(alice)), uint256(RATE) * (1024 - 102));
    }

    function test_cancelAfterDisplacingRestoresTheVictim() public {
        _bid(alice, RATE, 1024, alice);
        _time(101); // Alice's bid is live before Bob displaces it.
        _bid(bob, RATE * 2, 512, bob);
        uint256 pendingCost = uint256(RATE) * 2 * (512 - 102);
        // Cancelling refunds the full pending cost: nothing was destroyed.
        assertEq(_remove(bob), pendingCost);
        // Alice's schedule is restored and her credit is debited back.
        assertEq(auction.refundable(_id(alice)), 0);
        assertEq(auction.displacedEnd(poolId), 0);
        ContinuousAuction.Bid memory h = auction.holder(poolId);
        assertEq(h.bidder, _id(alice));
        assertEq(h.end, 1024);
        _time(102);
        assertEq(auction.executorAt(poolId), alice);
    }

    function test_cancelAfterVictimWithdrewFallsBackToForfeit() public {
        _bid(alice, RATE, 1024, alice);
        _time(101); // Alice's bid is live before Bob displaces it.
        _bid(bob, RATE * 2, 512, bob);
        // Alice withdraws her displaced tenure credit first, so there is nothing left to restore.
        assertEq(_remove(alice), uint256(RATE) * (1024 - 102));
        uint256 pendingCost = uint256(RATE) * 2 * (512 - 102);
        assertEq(_remove(bob), pendingCost - uint256(RATE) * 2);
        // The victim keeps one second at the pending rate; the pool stays schedule-less until rebid.
        assertEq(auction.refundable(_id(alice)), uint256(RATE) * 2);
        _time(102);
        assertEq(auction.executorAt(poolId), address(0));
    }

    /// RENT ALLOCATION

    function test_parkedPriceIsArbitragedBackByOutsiders() public {
        (uint256 dust, uint128 dustLiquidity) = _createPosition(key, 3200, 3216, 1e15, 0);
        _bid(alice, RATE, 1024, address(executor));
        _time(101);
        // The holder parks the price in its own dust range above every other position.
        executor.swap(key, _params(5e18, true, 3208), false);
        assertGe(core.poolState(poolId).tick(), 3200);
        assertEq(core.poolState(poolId).liquidity(), dustLiquidity);
        _time(201);
        assertEq(_claim(nft, -1600, 1600), 0);
        assertApproxEqAbs(_claim(dust, 3200, 3216), uint256(RATE) * 100, 1);
        // Anyone can swap the price back at the holder's fee, so the parked price only survives inside the band.
        outsider.swap(key, _params(5e18, false, 0), false);
        assertEq(core.poolState(poolId).tick(), 0);
        assertEq(core.poolState(poolId).liquidity(), liquidity);
        (, uint128 fee1) = _fees(alice);
        assertGt(fee1, 0);
        _time(301);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 100, 1);
        assertEq(_claim(dust, 3200, 3216), 0);
    }

    function test_holderLiquidityInRangeSharesRentProRata() public {
        (uint256 own, uint128 ownLiquidity) = _createPosition(key, -1600, 1600, 3e18, 3e18);
        _bid(alice, RATE, 512, alice);
        _time(201);
        uint256 total = uint256(RATE) * 100;
        assertApproxEqAbs(_claim(nft, -1600, 1600), total * liquidity / (liquidity + ownLiquidity), 1);
        assertApproxEqAbs(_claim(own, -1600, 1600), total * ownLiquidity / (liquidity + ownLiquidity), 1);
    }

    function test_stableswapRentIsIndependentOfPrice() public {
        PoolKey memory stable =
            createPool(address(token0), address(token1), 0, createStableswapPoolConfig(0, 20, 0, address(auction)));
        (int32 lower, int32 upper) = stable.config.stableswapActiveLiquidityTickRange();
        (uint256 id, uint128 stableLiquidity) = _createPosition(stable, lower, upper, 1e18, 1e18);
        _bid(stable, alice, RATE, 512, address(executor));
        _time(101);
        executor.swap(stable, _params(3e18, true, upper + 5000), false);
        assertGe(core.poolState(stable.toPoolId()).tick(), upper);
        assertEq(core.poolState(stable.toPoolId()).liquidity(), stableLiquidity);
        _time(201);
        uint256 paid = manager.collectRent(id, stable, lower, upper, address(this));
        assertApproxEqAbs(paid, uint256(RATE) * 100, 1);
        assertEq(auction.unallocatedRent(stable.toPoolId()), 0);
    }

    function test_fullRangePoolWithErc20BidToken() public {
        TestToken asset = new TestToken(address(this));
        ContinuousAuction erc = _deploy(address(asset), 1);
        AuctionPositions ercManager = new AuctionPositions(core, erc, owner);
        AuctionPeriphery ercPeriphery = new AuctionPeriphery(core, erc);
        PoolKey memory full = createFullRangePool(0, 0, address(erc));
        token0.approve(address(ercManager), 1e18);
        token1.approve(address(ercManager), 1e18);
        (uint256 id,,,) = ercManager.mintAndDeposit(full, MIN_TICK, MAX_TICK, 1e18, 1e18, 0);
        asset.approve(address(ercPeriphery), type(uint256).max);
        ercPeriphery.updateBid(full, SALT, RATE, 512, alice, FEE, address(this));
        assertEq(asset.balanceOf(address(core)), uint256(RATE) * (512 - 101));
        _time(201);
        uint256 balance = asset.balanceOf(bob);
        uint256 paid = ercManager.collectRent(id, full, MIN_TICK, MAX_TICK, bob);
        assertApproxEqAbs(paid, uint256(RATE) * 100, 1);
        assertEq(asset.balanceOf(bob) - balance, paid);
        uint256 before = asset.balanceOf(address(this));
        int256 delta = ercPeriphery.updateBid(full, SALT, 0, 0, address(0), 0, address(this));
        assertEq(uint256(-delta), uint256(RATE) * (512 - 202));
        assertEq(asset.balanceOf(address(this)) - before, uint256(-delta));
    }

    function test_taxedFundingReverts() public {
        TaxedAuctionToken asset = new TaxedAuctionToken(address(this));
        ContinuousAuction erc = _deploy(address(asset), 2);
        AuctionPeriphery ercPeriphery = new AuctionPeriphery(core, erc);
        PoolKey memory full = createFullRangePool(0, 0, address(erc));
        asset.approve(address(ercPeriphery), type(uint256).max);
        vm.expectRevert();
        ercPeriphery.updateBid(full, SALT, RATE, 512, alice, FEE, address(this));
        _time(101);
        assertEq(erc.executorAt(full.toPoolId()), address(0));
    }

    function test_rentOwnerAuthorizationTransferAndFullWithdrawal() public {
        _bid(alice, RATE, 512, alice);
        _time(200);
        manager.withdraw(nft, key, -1600, 1600, liquidity);
        _time(300);
        vm.prank(bob);
        vm.expectRevert();
        manager.collectRent(nft, key, -1600, 1600, bob);
        manager.transferFrom(address(this), bob, nft);
        vm.prank(bob);
        uint256 paid = manager.collectRent(nft, key, -1600, 1600, bob);
        assertApproxEqAbs(paid, uint256(RATE) * 99, 1);
        assertEq(bob.balance, paid);
        assertEq(auction.refundable(_id(alice)), 0);
        assertEq(auction.unallocatedRent(poolId), uint256(RATE) * 100);
        vm.prank(bob);
        assertEq(manager.collectRent(nft, key, -1600, 1600, bob), 0);
    }

    function test_withdrawAndCollectRentInOneLock() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        (uint128 amount0, uint128 amount1, uint256 rent) =
            manager.withdrawAndCollectRent(nft, key, -1600, 1600, liquidity, carol);
        assertGt(amount0, 0);
        assertGt(amount1, 0);
        assertApproxEqAbs(rent, uint256(RATE) * 100, 1);
        assertEq(carol.balance, rent);
        assertEq(token0.balanceOf(carol), amount0);
        assertEq(token1.balanceOf(carol), amount1);
        (uint128 remaining,,, uint256 pending) = manager.getPositionRentAndLiquidity(nft, key, -1600, 1600);
        assertEq(remaining, 0);
        assertEq(pending, 0);
    }

    function test_lateLiquidityDoesNotReceiveEarlierRent() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        (uint256 other,) = _createPosition(key, -1600, 1600, 1e18, 1e18);
        _time(301);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 150, 2);
        assertApproxEqAbs(_claim(other, -1600, 1600), uint256(RATE) * 50, 1);
    }

    function test_tickCrossingsAllocateOnlyToActiveRanges() public {
        (uint256 upper,) = _createPosition(key, 1600, 3200, 2e18, 0);
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        executor.swap(key, _params(2e18, true, 2000), false);
        assertGe(core.poolState(poolId).tick(), 1600);
        _time(301);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 100, 1);
        assertApproxEqAbs(_claim(upper, 1600, 3200), uint256(RATE) * 100, 1);
        executor.swap(key, _params(2e18, false, 0), false);
        _time(401);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 100, 1);
        assertEq(_claim(upper, 1600, 3200), 0);
    }

    function test_reinitializedTicksDoNotGiveAwayHistoricalRent() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        manager.withdraw(nft, key, -1600, 1600, liquidity);
        _time(301);
        (uint256 other,) = _createPosition(key, -1600, 1600, 1e18, 1e18);
        _time(401);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 100, 1);
        assertApproxEqAbs(_claim(other, -1600, 1600), uint256(RATE) * 100, 1);
        assertEq(auction.unallocatedRent(poolId), uint256(RATE) * 100);
    }

    function test_emptyRangeDoesNotLetExecutorAvoidRent() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        executor.swap(key, _params(2e18, true, 2000), false);
        assertEq(core.poolState(poolId).liquidity(), 0);
        _time(301);
        executor.swap(key, _params(2e18, false, 0), false);
        assertGt(core.poolState(poolId).liquidity(), 0);
        assertEq(auction.refundable(_id(alice)), 0);
        assertEq(auction.unallocatedRent(poolId), uint256(RATE) * 100);
        _time(401);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 200, 2);
        assertEq(auction.unallocatedRent(poolId), uint256(RATE) * 100);
    }

    function test_crossingZeroTickDoesNotTakeSameCellShortcut() public {
        (uint256 below, uint128 belowLiquidity) = _createPosition(key, -16, 0, 0, 1e16);
        (uint256 above, uint128 aboveLiquidity) = _createPosition(key, 0, 16, 1e16, 0);
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        executor.swap(key, _params(1e16, false, -1), false);
        assertEq(core.poolState(poolId).tick(), -1);
        _time(301);
        uint256 aboveExpected = uint256(RATE) * 100 * aboveLiquidity / (liquidity + aboveLiquidity);
        uint256 belowExpected = uint256(RATE) * 100 * belowLiquidity / (liquidity + belowLiquidity);
        assertApproxEqAbs(_claim(above, 0, 16), aboveExpected, 1);
        assertApproxEqAbs(_claim(below, -16, 0), belowExpected, 1);
        executor.swap(key, _params(1e16, true, 1), false);
        _time(401);
        assertApproxEqAbs(_claim(above, 0, 16), aboveExpected, 1);
        assertEq(_claim(below, -16, 0), 0);
    }

    function test_approvedOperatorCanCollectButMetadataOwnerCannot() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        vm.prank(owner);
        vm.expectRevert();
        manager.collectRent(nft, key, -1600, 1600, owner);
        manager.approve(bob, nft);
        vm.prank(bob);
        uint256 amount = manager.collectRent(nft, key, -1600, 1600, alice);
        assertApproxEqAbs(amount, uint256(RATE) * 100, 1);
        assertEq(alice.balance, amount);
    }

    function test_getPositionRentMatchesClaimAfterAccrue() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        auction.accrue(key);
        uint256 quoted =
            auction.getPositionRent(key, address(manager), createPositionId(bytes24(uint192(nft)), -1600, 1600));
        (,,, uint256 viaManager) = manager.getPositionRentAndLiquidity(nft, key, -1600, 1600);
        assertEq(viaManager, quoted);
        assertEq(_claim(nft, -1600, 1600), quoted);
        assertApproxEqAbs(quoted, uint256(RATE) * 100, 1);
    }

    /// PAYMENT SAFETY

    function test_failedWithdrawalRevertsWholeLockAndPreservesCredit() public {
        _bid(alice, RATE, 512, alice);
        _bid(bob, RATE * 2, 512, bob);
        uint256 credit = auction.refundable(_id(alice));
        vm.prank(alice);
        vm.expectRevert();
        periphery.updateBid(key, SALT, 0, 0, address(0), 0, address(token0)); // Recipient rejects ETH.
        assertEq(auction.refundable(_id(alice)), credit);
        assertEq(_remove(alice), credit);
    }

    function test_nativeFundingSurvivesInclusionDelay() public {
        uint256 preparedFunding = uint256(RATE) * (512 - 101);
        _time(105);
        vm.deal(alice, preparedFunding);
        vm.prank(alice);
        periphery.updateBid{value: preparedFunding}(key, SALT, RATE, 512, alice, FEE, alice);
        assertEq(address(periphery).balance, uint256(RATE) * 5);
        vm.prank(alice);
        periphery.refundNativeToken();
        assertEq(alice.balance, uint256(RATE) * 5);
        _time(512);
        uint256 earned = _claim(nft, -1600, 1600);
        assertApproxEqAbs(earned, uint256(RATE) * (512 - 106), 1);
    }

    function test_maxRateAndMaxTenureFitAccounting() public {
        _time(uint256(type(uint32).max) + 100);
        uint64 end = uint64(block.timestamp + 1 + type(uint32).max);
        uint256 expected = uint256(type(uint96).max) * type(uint32).max;
        _bid(alice, type(uint96).max, end, alice);
        _time(end);
        assertApproxEqAbs(_claim(nft, -1600, 1600), expected, 2);
    }

    /// REFERENCE MODEL

    function testFuzz_scheduleMatchesPerSecondReference(uint256 seed) public {
        uint256[4096] memory rates;
        uint8[4096] memory holders;
        uint256[8] memory credits;
        uint256[8] memory paidOut;
        uint256[8] memory ends;
        uint256 total;
        uint256 now_ = 100;
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            now_ += 1 + seed % 20;
            _time(now_);
            uint256 choice = (seed >> 8) % 4;
            uint8 h = holders[now_];
            if (choice == 0 && rates[now_] != 0 && ends[h] + 1 < 4000) {
                // The holder extends: replacing its own bid nets the added tenure.
                uint256 end = ends[h] + 1 + (seed >> 24) % (4000 - ends[h] - 1);
                address holder_ = address(uint160(1000 + h));
                uint256 funding = rates[now_] * (end - ends[h]);
                vm.deal(holder_, holder_.balance + funding);
                vm.prank(holder_);
                int256 delta = periphery.updateBid{value: funding}(
                    key, SALT, uint96(rates[now_]), uint64(end), holder_, FEE, holder_
                );
                assertEq(uint256(delta), funding);
                for (uint256 t = ends[h]; t < end; ++t) {
                    holders[t] = h;
                    rates[t] = rates[now_];
                }
                total += funding;
                ends[h] = end;
            } else if (choice == 1 && rates[now_] != 0 && now_ + 2 < ends[h]) {
                // The holder shortens: the relinquished tenure is withdrawn at once.
                uint256 end = now_ + 2 + (seed >> 24) % (ends[h] - now_ - 2);
                address holder_ = address(uint160(1000 + h));
                vm.prank(holder_);
                int256 delta = periphery.updateBid(key, SALT, uint96(rates[now_]), uint64(end), holder_, FEE, holder_);
                assertEq(uint256(-delta), rates[now_] * (ends[h] - end));
                paidOut[h] += uint256(-delta);
                for (uint256 t = end; t < ends[h]; ++t) {
                    rates[t] = 0;
                }
                ends[h] = end;
            } else {
                uint96 rate = uint96(rates[now_ + 1] + 1);
                uint256 end = now_ + 2 + (seed >> 24) % 1600;
                address bidder = address(uint160(1000 + i));
                total += uint256(rate) * (end - now_ - 1);
                _bid(bidder, rate, uint64(end), bidder);
                for (uint256 t = now_ + 1; t < 4096; ++t) {
                    if (rates[t] != 0) {
                        credits[holders[t]] += rates[t];
                        ends[holders[t]] = now_ + 1;
                    }
                    if (t < end) {
                        holders[t] = uint8(i);
                        rates[t] = rate;
                    } else {
                        rates[t] = 0;
                    }
                }
                ends[i] = end;
            }
            for (uint256 j; j <= i; ++j) {
                assertEq(auction.refundable(_id(address(uint160(1000 + j)))), credits[j]);
            }
            assertEq(auction.executorAt(poolId), rates[now_] == 0 ? address(0) : address(uint160(1000 + holders[now_])));
        }
        uint256 rent;
        for (uint256 t; t < 4096; ++t) {
            rent += rates[t];
        }
        _time(4096);
        uint256 paid = _claim(nft, -1600, 1600);
        assertApproxEqAbs(paid, rent, 16);
        uint256 withdrawn;
        for (uint256 i; i < 8; ++i) {
            withdrawn += _remove(address(uint160(1000 + i))) + paidOut[i];
        }
        assertEq(total, withdrawn + rent);
        assertEq(_funds(), rent - paid);
    }

    function testFuzz_escrowConservationAcrossLiquidityGaps(uint256 seed) public {
        uint256[2048] memory rates;
        uint8[2048] memory holders;
        bool[2048] memory active;
        uint256[8] memory credits;
        uint256 total;
        uint256 now_ = 100;
        bool hasLiquidity = true;
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 next = now_ + 1 + seed % 20;
            for (uint256 t = now_; t < next; ++t) {
                active[t] = hasLiquidity;
            }
            now_ = next;
            _time(now_);
            if ((seed >> 16) % 2 == 1) {
                if (hasLiquidity) manager.withdraw(nft, key, -1600, 1600, liquidity);
                else (liquidity,,) = manager.deposit(nft, key, -1600, 1600, 1e18, 1e18, 0);
                hasLiquidity = !hasLiquidity;
            }
            uint96 rate = uint96(rates[now_ + 1] + 1);
            uint256 end = now_ + 2 + (seed >> 24) % 1600;
            address bidder = address(uint160(1000 + i));
            total += uint256(rate) * (end - now_ - 1);
            _bid(bidder, rate, uint64(end), bidder);
            for (uint256 t = now_ + 1; t < 2048; ++t) {
                if (rates[t] != 0) credits[holders[t]] += rates[t];
                if (t < end) {
                    holders[t] = uint8(i);
                    rates[t] = rate;
                } else {
                    rates[t] = 0;
                }
            }
        }
        for (uint256 t = now_; t < 2048; ++t) {
            active[t] = hasLiquidity;
        }
        uint256 expectedRent;
        uint256 unallocated;
        for (uint256 t; t < 2048; ++t) {
            if (active[t]) expectedRent += rates[t];
            else unallocated += rates[t];
        }
        _time(2048);
        uint256 paid = _claim(nft, -1600, 1600);
        assertApproxEqAbs(paid, expectedRent, 25);
        assertEq(auction.unallocatedRent(poolId), unallocated);
        uint256 withdrawn;
        for (uint256 i; i < 8; ++i) {
            address bidder = address(uint160(1000 + i));
            assertEq(auction.refundable(_id(bidder)), credits[i]);
            withdrawn += _remove(bidder);
        }
        assertEq(total, withdrawn + expectedRent + unallocated);
        assertEq(_funds(), expectedRent - paid + unallocated);
    }

    /// GAS

    function _cold() private {
        coolAllContracts();
        vm.cool(address(auction));
        vm.cool(address(manager));
        vm.cool(address(periphery));
        vm.cool(address(executor));
        vm.cool(address(outsider));
    }

    function test_gas_newBid() public {
        _cold();
        vm.deal(alice, 1e20);
        vm.prank(alice);
        periphery.updateBid{value: uint256(RATE) * (1024 - 101)}(key, SALT, RATE, 1024, address(executor), FEE, alice);
        vm.snapshotGasLastCall("AuctionPeriphery#newBid");
    }

    function test_gas_displaceLiveBid() public {
        _bid(alice, RATE, 1024, address(executor));
        _time(201);
        _cold();
        vm.deal(bob, 1e20);
        vm.prank(bob);
        periphery.updateBid{value: uint256(RATE) * 2 * (512 - 202)}(key, SALT, RATE * 2, 512, bob, FEE, bob);
        vm.snapshotGasLastCall("AuctionPeriphery#displaceLiveBid");
    }

    function test_gas_replaceOwnBid() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        vm.deal(alice, 1e20);
        vm.prank(alice);
        periphery.updateBid{value: uint256(RATE) * 512}(key, SALT, RATE, 1024, address(executor), FEE, alice);
        vm.snapshotGasLastCall("AuctionPeriphery#replaceOwnBid");
    }

    function test_gas_removeBidAndWithdraw() public {
        _bid(alice, RATE, 1024, address(executor));
        _time(201);
        _cold();
        vm.prank(alice);
        periphery.updateBid(key, SALT, 0, 0, address(0), 0, alice);
        vm.snapshotGasLastCall("AuctionPeriphery#removeBidAndWithdraw");
    }

    function test_gas_accrue() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        auction.accrue(key);
        vm.snapshotGasLastCall("Auction#accrue");
    }

    function test_gas_initializePool() public {
        PoolKey memory k = key;
        k.config = createConcentratedPoolConfig(0, 64, address(auction));
        _cold();
        core.initializePool(k, 0);
        vm.snapshotGasLastCall("Auction#initializePool");
    }

    function test_gas_holderSwap() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        executor.swap(key, _params(1000, true, 100), false);
        vm.snapshotGasLastCall("Auction#holderSwapWithAccrual");
    }

    function test_gas_outsiderSwap() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        outsider.swap(key, _params(1000, true, 100), false);
        vm.snapshotGasLastCall("Auction#outsiderSwapWithAccrual");
    }

    function test_gas_swapInsideTickSpacing() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        executor.swap(key, _params(1e18, true, 8), false);
        vm.snapshotGasLastCall("Auction#swapInsideTickSpacing");
        assertEq(core.poolState(poolId).tick(), 8);
    }

    function test_gas_swapCrossingOneTick() public {
        _createPosition(key, 1600, 3200, 2e18, 0);
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        executor.swap(key, _params(2e18, true, 2000), false);
        vm.snapshotGasLastCall("Auction#swapCrossingOneTick");
        assertGe(core.poolState(poolId).tick(), 1600);
    }

    function test_gas_swapCrossingFourTicks() public {
        _createPosition(key, 1600, 3200, 2e18, 0);
        _createPosition(key, 3200, 4800, 2e18, 0);
        _createPosition(key, 4800, 6400, 2e18, 0);
        _createPosition(key, 6400, 8000, 2e18, 0);
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        executor.swap(key, _params(10e18, true, 7000), false);
        vm.snapshotGasLastCall("Auction#swapCrossingFourTicks");
        assertGe(core.poolState(poolId).tick(), 6400);
    }

    function test_gas_collectRent() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        _claim(nft, -1600, 1600);
        vm.snapshotGasLastCall("AuctionPositions#collectRent");
    }

    function test_gas_deposit() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        manager.deposit(nft, key, -1600, 1600, 1e18, 1e18, 0);
        vm.snapshotGasLastCall("AuctionPositions#deposit");
    }

    function test_gas_withdraw() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        manager.withdraw(nft, key, -1600, 1600, liquidity / 2);
        vm.snapshotGasLastCall("AuctionPositions#withdrawHalf");
    }

    function test_gas_collectSwapFees() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        outsider.swap(key, _params(1e17, true, 100), false);
        _cold();
        vm.prank(alice);
        periphery.collectSwapFees(key, SALT, alice);
        vm.snapshotGasLastCall("AuctionPeriphery#collectSwapFees");
    }
}
