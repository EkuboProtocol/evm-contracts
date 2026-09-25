// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {ContinuousAuction, continuousAuctionCallPoints} from "../../src/extensions/ContinuousAuction.sol";
import {AuctionPositions} from "../../src/AuctionPositions.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {createPositionId} from "../../src/types/positionId.sol";
import {createSwapParameters, SwapParameters} from "../../src/types/swapParameters.sol";
import {
    PoolConfig,
    createConcentratedPoolConfig,
    createFullRangePoolConfig,
    createStableswapPoolConfig
} from "../../src/types/poolConfig.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {computeFee} from "../../src/math/fee.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

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
            (bool ok, bytes memory result) = address(core)
                .call(
                    abi.encodePacked(bytes4(keccak256("forward(address)")), abi.encode(address(auction), key, params))
                );
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(result, 32), mload(result))
                }
            }
            (update,) = abi.decode(result, (PoolBalanceUpdate, PoolState));
        }
        if (update.delta0() > 0) ACCOUNTANT.payFrom(owner, key.token0, uint128(update.delta0()));
        else if (update.delta0() < 0) ACCOUNTANT.withdraw(key.token0, owner, uint128(-update.delta0()));
        if (update.delta1() > 0) ACCOUNTANT.payFrom(owner, key.token1, uint128(update.delta1()));
        else if (update.delta1() < 0) ACCOUNTANT.withdraw(key.token1, owner, uint128(-update.delta1()));
        return abi.encode(update);
    }
}

contract AuctionReenterReceiver {
    address public target;
    bytes public payload;
    bool public reentered;

    function configure(address target_, bytes memory payload_) external {
        target = target_;
        payload = payload_;
    }

    receive() external payable {
        (reentered,) = target.call(payload);
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

    ContinuousAuction auction;
    AuctionPositions auctionPositions;
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
    uint64 constant FEE = 184467440737095516; // 1% as a 0.64 fixed-point fraction
    uint32 constant NOTICE = 100;
    uint16 constant INCREMENT = 1000;

    function setUp() public override {
        super.setUp();
        vm.warp(100);
        vm.roll(10);
        vm.deal(address(this), 1e30);
        auction = _deploy(address(0), 0);
        auctionPositions = new AuctionPositions(core, auction, owner);
        positions = auctionPositions;
        executor = new AuctionExecutor(core, auction);
        outsider = new AuctionExecutor(core, auction);
        token0.approve(address(executor), type(uint256).max);
        token1.approve(address(executor), type(uint256).max);
        token0.approve(address(outsider), type(uint256).max);
        token1.approve(address(outsider), type(uint256).max);
        key = _createPool(auction, createConcentratedPoolConfig(0, 16, address(auction)), RATE);
        poolId = key.toPoolId();
        (nft, liquidity) = createPosition(key, -1600, 1600, 1e18, 1e18);
    }

    function _deploy(address token, uint160 salt) private returns (ContinuousAuction a) {
        address target = address((uint160(continuousAuctionCallPoints().toUint8()) << 152) | salt);
        deployCodeTo("ContinuousAuction.sol:ContinuousAuction", abi.encode(core, token), target);
        return ContinuousAuction(target);
    }

    function _createPool(ContinuousAuction a, PoolConfig config, uint96 minRate) private returns (PoolKey memory k) {
        k = PoolKey({token0: address(token0), token1: address(token1), config: config});
        a.createPool(k, 0, FEE, minRate, NOTICE, INCREMENT);
    }

    function _bid(address bidder, uint96 rate, uint64 end, address exec) private {
        _bid(key, bidder, rate, end, exec);
    }

    function _bid(PoolKey memory k, address bidder, uint96 rate, uint64 end, address exec) private {
        uint256 funding = uint256(rate) * (end - block.timestamp - 1);
        vm.deal(bidder, bidder.balance + funding);
        vm.prank(bidder);
        auction.bid{value: funding}(k, rate, end, exec);
    }

    function _time(uint256 time) private {
        vm.warp(time);
        vm.roll(block.number + 1);
    }

    function _claim(uint256 id, int32 lower, int32 upper) private returns (uint256) {
        return auctionPositions.collectRent(id, key, lower, upper, address(this));
    }

    function _params(int128 amount, bool isToken1, int32 limit) private pure returns (SwapParameters) {
        return createSwapParameters({
            _amount: amount, _isToken1: isToken1, _sqrtRatioLimit: tickToSqrtRatio(limit), _skipAhead: 0
        });
    }

    function _minimumOutbid(uint96 rate) private pure returns (uint96) {
        return rate + uint96(FixedPointMathLib.fullMulDivUp(rate, INCREMENT, 10000));
    }

    /// POOL CREATION

    function test_poolsMustBeCreatedThroughExtensionWithValidTerms() public {
        PoolKey memory k = key;
        k.config = createConcentratedPoolConfig(0, 64, address(auction));
        vm.expectRevert(ContinuousAuction.InvalidPool.selector);
        core.initializePool(k, 0);
        vm.expectRevert(ContinuousAuction.InvalidTerms.selector);
        auction.createPool(k, 0, 0, RATE, NOTICE, INCREMENT);
        k.config = createConcentratedPoolConfig(1, 64, address(auction));
        vm.expectRevert(ContinuousAuction.InvalidPool.selector);
        auction.createPool(k, 0, FEE, RATE, NOTICE, INCREMENT);
        k.config = createConcentratedPoolConfig(0, 3, address(auction));
        vm.expectRevert(ContinuousAuction.InvalidPool.selector);
        auction.createPool(k, 0, FEE, RATE, NOTICE, INCREMENT);
        vm.expectRevert(ContinuousAuction.InvalidPool.selector);
        auction.createPool(key, 0, FEE, RATE, NOTICE, INCREMENT);
        (,, uint64 fee, uint96 minRate, uint32 notice, uint16 increment,,) = auction.auctions(poolId);
        assertEq(fee, FEE);
        assertEq(minRate, RATE);
        assertEq(notice, NOTICE);
        assertEq(increment, INCREMENT);
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
        (, uint128 fee1) = auction.swapFeesOwed(poolId, alice);
        assertEq(fee1, 0);
        (uint128 fee0,) = auction.swapFeesOwed(poolId, alice);
        assertGt(fee0, 0);
        _bid(bob, _minimumOutbid(RATE), 256, address(outsider));
        executor.swap(key, params, false); // Incumbent retains the current second.
        _time(102);
        assertEq(auction.executorAt(poolId), address(outsider));
        PoolBalanceUpdate charged = executor.swap(key, params, false); // The old executor now pays the fee.
        (uint128 after0,) = auction.swapFeesOwed(poolId, bob);
        assertEq(after0, computeFee(uint128(-charged.delta0()) + after0, FEE));
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
        (, uint128 fee1) = auction.swapFeesOwed(poolId, alice);
        assertGt(fee1, 0);
        assertEq(
            uint128(charged.delta1()),
            FixedPointMathLib.fullMulDivUp(uint128(charged.delta1()) - fee1, 1 << 64, (1 << 64) - FEE)
        );
    }

    function test_holderWithdrawsSwapFees() public {
        _bid(alice, RATE, 512, address(executor));
        _time(101);
        outsider.swap(key, _params(1e17, true, 100), false);
        outsider.swap(key, _params(1e17, false, -100), false);
        (uint128 fee0, uint128 fee1) = auction.swapFeesOwed(poolId, alice);
        assertGt(fee0, 0);
        assertGt(fee1, 0);
        vm.prank(bob);
        (uint128 none0, uint128 none1) = auction.withdrawSwapFees(key, bob);
        assertEq(none0 + none1, 0);
        vm.prank(alice);
        (uint128 paid0, uint128 paid1) = auction.withdrawSwapFees(key, carol);
        assertEq(paid0, fee0);
        assertEq(paid1, fee1);
        assertEq(token0.balanceOf(carol), fee0);
        assertEq(token1.balanceOf(carol), fee1);
        (fee0, fee1) = auction.swapFeesOwed(poolId, alice);
        assertEq(fee0 + fee1, 0);
    }

    /// BIDDING RULES

    function test_reserveIncrementNoticeAndSelfRaise() public {
        vm.deal(address(this), 1e30);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        auction.bid{value: 1e20}(key, RATE - 1, 512, alice);
        vm.expectRevert(ContinuousAuction.InvalidBid.selector);
        auction.bid{value: 1e20}(key, RATE, 100 + NOTICE, alice);
        vm.expectRevert(ContinuousAuction.InvalidBid.selector);
        auction.bid{value: 1e20}(key, RATE, 512, address(0));
        vm.expectRevert(ContinuousAuction.IncorrectFunding.selector);
        auction.bid{value: 1}(key, RATE, 512, alice);
        _bid(alice, RATE, 512, alice);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        auction.bid{value: 1e20}(key, _minimumOutbid(RATE) - 1, 512, bob);
        vm.deal(alice, 1e20);
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        auction.bid{value: 1e20}(key, RATE, 512, alice);
        _bid(alice, RATE + 1, 512, alice); // The scheduled bidder raises without the increment.
        assertEq(auction.refundable(alice), uint256(RATE) * (512 - 101));
        _bid(bob, _minimumOutbid(RATE + 1), 512, bob);
        _time(101);
        assertEq(auction.executorAt(poolId), bob);
        _time(512);
        vm.expectRevert(ContinuousAuction.InvalidBid.selector);
        auction.bid{value: 1e20}(key, RATE, 513 + uint64(type(uint32).max) + 1, alice);
        _bid(carol, RATE, 1024, carol); // An expired incumbent need not be outbid.
        _time(513);
        assertEq(auction.executorAt(poolId), carol);
    }

    function test_displacementRefundsRemainderAndTransfersAccess() public {
        _bid(alice, RATE, 1024, alice);
        _time(200);
        _bid(bob, RATE * 2, 512, bob);
        assertEq(auction.executorAt(poolId), alice);
        assertEq(auction.refundable(alice), uint256(RATE) * (1024 - 201));
        _time(201);
        assertEq(auction.executorAt(poolId), bob);
        _time(600);
        assertEq(auction.executorAt(poolId), address(0)); // Displaced funding is not rescheduled.
        uint256 expected = uint256(RATE) * (201 - 101) + uint256(RATE) * 2 * (512 - 201);
        uint256 paid = _claim(nft, -1600, 1600);
        assertApproxEqAbs(paid, expected, 2);
        vm.prank(alice);
        uint256 refund = auction.withdrawRefund(alice);
        assertEq(refund, uint256(RATE) * (1024 - 201));
        assertEq(alice.balance, refund);
        assertEq(address(auction).balance, expected - paid);
    }

    function test_sameSecondPendingBidIsFullyRefundedWhenReplaced() public {
        _bid(alice, RATE, 1024, alice);
        _time(150);
        _bid(bob, RATE * 2, 768, bob);
        _bid(carol, RATE * 3, 256, carol);
        assertEq(auction.refundable(alice), uint256(RATE) * (1024 - 151));
        assertEq(auction.refundable(bob), uint256(RATE) * 2 * (768 - 151));
        assertEq(auction.executorAt(poolId), alice);
        _time(151);
        assertEq(auction.executorAt(poolId), carol);
        ContinuousAuction.Bid memory h = auction.holder(poolId);
        assertEq(h.bidder, carol);
        assertEq(h.start, 151);
        assertEq(h.end, 256);
        _time(256);
        uint256 expected = uint256(RATE) * (151 - 101) + uint256(RATE) * 3 * (256 - 151);
        assertApproxEqAbs(_claim(nft, -1600, 1600), expected, 2);
        assertEq(auction.holder(poolId).bidder, address(0));
    }

    function test_extendAndShortenWithNotice() public {
        _bid(alice, RATE, 400, alice);
        vm.prank(bob);
        vm.expectRevert(ContinuousAuction.NotHolder.selector);
        auction.extend{value: 0}(key, 800);
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.InvalidBid.selector);
        auction.extend(key, 400);
        vm.deal(alice, 1);
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.IncorrectFunding.selector);
        auction.extend{value: 1}(key, 800);
        vm.deal(alice, uint256(RATE) * 400 + 5);
        vm.prank(alice);
        auction.extend{value: uint256(RATE) * 400 + 5}(key, 800);
        assertEq(auction.refundable(alice), 5);
        assertEq(auction.holder(poolId).bidder, address(0)); // Not live until the next second.
        _time(300);
        assertEq(auction.holder(poolId).end, 800);
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.InvalidBid.selector);
        auction.shorten(key, 300 + NOTICE - 1);
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.InvalidBid.selector);
        auction.shorten(key, 800);
        vm.prank(alice);
        auction.shorten(key, 300 + NOTICE);
        assertEq(auction.refundable(alice), 5 + uint256(RATE) * (800 - 400));
        _time(399);
        assertEq(auction.executorAt(poolId), alice);
        _time(400);
        assertEq(auction.executorAt(poolId), address(0));
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.NotHolder.selector);
        auction.extend(key, 900);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * (400 - 101), 3);
    }

    function test_displacedIncumbentCannotExtendOrShorten() public {
        _bid(alice, RATE, 1024, alice);
        _time(200);
        _bid(bob, RATE * 2, 512, bob);
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.NotHolder.selector);
        auction.extend(key, 2048);
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.NotHolder.selector);
        auction.shorten(key, 300);
        vm.deal(bob, uint256(RATE) * 2 * 100);
        vm.prank(bob);
        auction.extend{value: uint256(RATE) * 2 * 100}(key, 612); // The pending bidder may extend.
        _time(201);
        assertEq(auction.holder(poolId).end, 612);
    }

    /// RENT ALLOCATION

    function test_parkedPriceIsArbitragedBackByOutsiders() public {
        (uint256 dust, uint128 dustLiquidity) = createPosition(key, 3200, 3216, 1e15, 0);
        _bid(alice, RATE, 1024, address(executor));
        _time(101);
        // The holder parks the price in its own dust range above every other position.
        executor.swap(key, _params(5e18, true, 3208), false);
        assertGe(core.poolState(poolId).tick(), 3200);
        assertEq(core.poolState(poolId).liquidity(), dustLiquidity);
        _time(201);
        assertEq(_claim(nft, -1600, 1600), 0);
        assertApproxEqAbs(_claim(dust, 3200, 3216), uint256(RATE) * 100, 1);
        // Anyone can swap the price back at the pool fee, so the parked price only survives inside the fee band.
        outsider.swap(key, _params(5e18, false, 0), false);
        assertEq(core.poolState(poolId).tick(), 0);
        assertEq(core.poolState(poolId).liquidity(), liquidity);
        (, uint128 fee1) = auction.swapFeesOwed(poolId, alice);
        assertGt(fee1, 0);
        _time(301);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 100, 1);
        assertEq(_claim(dust, 3200, 3216), 0);
    }

    function test_holderLiquidityInRangeSharesRentProRata() public {
        (uint256 own, uint128 ownLiquidity) = createPosition(key, -1600, 1600, 3e18, 3e18);
        _bid(alice, RATE, 512, alice);
        _time(201);
        uint256 total = uint256(RATE) * 100;
        assertApproxEqAbs(_claim(nft, -1600, 1600), total * liquidity / (liquidity + ownLiquidity), 1);
        assertApproxEqAbs(_claim(own, -1600, 1600), total * ownLiquidity / (liquidity + ownLiquidity), 1);
    }

    function test_stableswapRentIsIndependentOfPrice() public {
        PoolKey memory stable = _createPool(auction, createStableswapPoolConfig(0, 20, 0, address(auction)), RATE);
        (int32 lower, int32 upper) = stable.config.stableswapActiveLiquidityTickRange();
        (uint256 id, uint128 stableLiquidity) = createPosition(stable, lower, upper, 1e18, 1e18);
        _bid(stable, alice, RATE, 512, address(executor));
        _time(101);
        executor.swap(stable, _params(3e18, true, upper + 5000), false);
        assertGe(core.poolState(stable.toPoolId()).tick(), upper);
        assertEq(core.poolState(stable.toPoolId()).liquidity(), stableLiquidity);
        _time(201);
        uint256 paid = auctionPositions.collectRent(id, stable, lower, upper, address(this));
        assertApproxEqAbs(paid, uint256(RATE) * 100, 1);
        assertEq(auction.unallocatedRent(stable.toPoolId()), 0);
    }

    function test_fullRangePoolWithErc20BidToken() public {
        TestToken asset = new TestToken(address(this));
        ContinuousAuction erc = _deploy(address(asset), 1);
        AuctionPositions manager = new AuctionPositions(core, erc, owner);
        positions = manager;
        PoolKey memory full = PoolKey({
            token0: address(token0), token1: address(token1), config: createFullRangePoolConfig(0, address(erc))
        });
        erc.createPool(full, 0, FEE, 0, 0, 0);
        (uint256 id,) = createPosition(full, MIN_TICK, MAX_TICK, 1e18, 1e18);
        asset.approve(address(erc), type(uint256).max);
        erc.bid(full, RATE, 512, alice);
        _time(201);
        uint256 balance = asset.balanceOf(bob);
        uint256 paid = manager.collectRent(id, full, MIN_TICK, MAX_TICK, bob);
        assertApproxEqAbs(paid, uint256(RATE) * 100, 1);
        assertEq(asset.balanceOf(bob) - balance, paid);
        vm.expectRevert(ContinuousAuction.IncorrectFunding.selector);
        erc.bid{value: 1}(full, RATE * 2, 512, bob);
    }

    function test_taxedFundingRevertsAtomically() public {
        TaxedAuctionToken asset = new TaxedAuctionToken(address(this));
        ContinuousAuction erc = _deploy(address(asset), 2);
        PoolKey memory full = PoolKey({
            token0: address(token0), token1: address(token1), config: createFullRangePoolConfig(0, address(erc))
        });
        erc.createPool(full, 0, FEE, 0, 0, 0);
        asset.approve(address(erc), type(uint256).max);
        vm.expectRevert(ContinuousAuction.IncorrectFunding.selector);
        erc.bid(full, RATE, 512, alice);
        assertEq(asset.balanceOf(address(erc)), 0);
        _time(101);
        assertEq(erc.executorAt(full.toPoolId()), address(0));
    }

    function test_rentOwnerAuthorizationTransferAndFullWithdrawal() public {
        _bid(alice, RATE, 512, alice);
        _time(200);
        positions.withdraw(nft, key, -1600, 1600, liquidity);
        _time(300);
        vm.prank(bob);
        vm.expectRevert();
        auctionPositions.collectRent(nft, key, -1600, 1600, bob);
        positions.transferFrom(address(this), bob, nft);
        vm.prank(bob);
        uint256 paid = auctionPositions.collectRent(nft, key, -1600, 1600, bob);
        assertApproxEqAbs(paid, uint256(RATE) * 99, 1);
        assertEq(bob.balance, paid);
        assertEq(auction.refundable(alice), 0);
        assertEq(auction.unallocatedRent(poolId), uint256(RATE) * 100);
        vm.prank(bob);
        assertEq(auctionPositions.collectRent(nft, key, -1600, 1600, bob), 0);
    }

    function test_lateLiquidityDoesNotReceiveEarlierRent() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        (uint256 other,) = createPosition(key, -1600, 1600, 1e18, 1e18);
        _time(301);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 150, 2);
        assertApproxEqAbs(_claim(other, -1600, 1600), uint256(RATE) * 50, 1);
    }

    function test_tickCrossingsAllocateOnlyToActiveRanges() public {
        (uint256 upper,) = createPosition(key, 1600, 3200, 2e18, 0);
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
        positions.withdraw(nft, key, -1600, 1600, liquidity);
        _time(301);
        (uint256 other,) = createPosition(key, -1600, 1600, 1e18, 1e18);
        _time(401);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 100, 1);
        assertApproxEqAbs(_claim(other, -1600, 1600), uint256(RATE) * 100, 1);
        assertEq(auction.refundable(alice), 0);
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
        assertEq(auction.refundable(alice), 0);
        assertEq(auction.unallocatedRent(poolId), uint256(RATE) * 100);
        _time(401);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 200, 2);
        assertEq(auction.unallocatedRent(poolId), uint256(RATE) * 100);
    }

    function test_crossingZeroTickDoesNotTakeSameCellShortcut() public {
        (uint256 below, uint128 belowLiquidity) = createPosition(key, -16, 0, 0, 1e16);
        (uint256 above, uint128 aboveLiquidity) = createPosition(key, 0, 16, 1e16, 0);
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

    function test_unownedPositionCannotClaimOtherPositionsRent() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        assertEq(auction.collectRent(key, createPositionId(bytes24(uint192(nft)), -1600, 1600), bob), 0);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 100, 1);
    }

    function test_approvedOperatorCanCollectButMetadataOwnerCannot() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        vm.prank(owner);
        vm.expectRevert();
        auctionPositions.collectRent(nft, key, -1600, 1600, owner);
        positions.approve(bob, nft);
        vm.prank(bob);
        uint256 amount = auctionPositions.collectRent(nft, key, -1600, 1600, alice);
        assertApproxEqAbs(amount, uint256(RATE) * 100, 1);
        assertEq(alice.balance, amount);
    }

    function test_getPositionRentMatchesClaimAfterAccrue() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        auction.accrue(key);
        uint256 quoted =
            auction.getPositionRent(key, address(positions), createPositionId(bytes24(uint192(nft)), -1600, 1600));
        assertEq(_claim(nft, -1600, 1600), quoted);
        assertApproxEqAbs(quoted, uint256(RATE) * 100, 1);
    }

    /// PAYMENT SAFETY

    function test_failedRefundTransferPreservesCredit() public {
        _bid(alice, RATE, 512, alice);
        _bid(bob, RATE * 2, 512, bob);
        uint256 credit = auction.refundable(alice);
        vm.prank(alice);
        vm.expectRevert();
        auction.withdrawRefund(address(token0));
        assertEq(auction.refundable(alice), credit);
        vm.prank(alice);
        assertEq(auction.withdrawRefund(alice), credit);
    }

    function test_claimRecipientCannotReenterAccounting() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        AuctionReenterReceiver receiver = new AuctionReenterReceiver();
        receiver.configure(address(auction), abi.encodeCall(auction.accrue, (key)));
        uint256 amount = auctionPositions.collectRent(nft, key, -1600, 1600, address(receiver));
        assertFalse(receiver.reentered());
        assertEq(address(receiver).balance, amount);
        assertApproxEqAbs(amount, uint256(RATE) * 100, 1);
        assertEq(_claim(nft, -1600, 1600), 0);
    }

    function test_nativeFundingSurvivesInclusionDelay() public {
        uint256 preparedFunding = uint256(RATE) * (512 - 101);
        _time(105);
        auction.bid{value: preparedFunding}(key, RATE, 512, alice);
        assertEq(auction.refundable(address(this)), uint256(RATE) * 5);
        _time(512);
        uint256 earned = _claim(nft, -1600, 1600);
        uint256 refund = auction.withdrawRefund(address(this));
        assertApproxEqAbs(earned + refund, preparedFunding, 1);
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
        uint256[8] memory expectedRefunds;
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
                uint256 end = ends[h] + 1 + (seed >> 24) % (4000 - ends[h] - 1);
                address holder_ = address(uint160(1000 + h));
                uint256 funding = rates[now_] * (end - ends[h]);
                vm.deal(holder_, holder_.balance + funding);
                vm.prank(holder_);
                auction.extend{value: funding}(key, uint64(end));
                for (uint256 t = ends[h]; t < end; ++t) {
                    holders[t] = h;
                    rates[t] = rates[now_];
                }
                total += funding;
                ends[h] = end;
            } else if (choice == 1 && rates[now_] != 0 && now_ + NOTICE < ends[h]) {
                uint256 end = now_ + NOTICE + (seed >> 24) % (ends[h] - now_ - NOTICE);
                vm.prank(address(uint160(1000 + h)));
                auction.shorten(key, uint64(end));
                for (uint256 t = end; t < ends[h]; ++t) {
                    expectedRefunds[h] += rates[t];
                    rates[t] = 0;
                }
                ends[h] = end;
            } else {
                uint96 rate = rates[now_ + 1] == 0 ? RATE : _minimumOutbid(uint96(rates[now_ + 1]));
                uint256 end = now_ + 1 + NOTICE + (seed >> 24) % 1500;
                address bidder = address(uint160(1000 + i));
                total += uint256(rate) * (end - now_ - 1);
                _bid(bidder, rate, uint64(end), bidder);
                for (uint256 t = now_ + 1; t < 4096; ++t) {
                    if (rates[t] != 0) {
                        expectedRefunds[holders[t]] += rates[t];
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
                assertEq(auction.refundable(address(uint160(1000 + j))), expectedRefunds[j]);
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
        uint256 refunds;
        for (uint256 i; i < 8; ++i) {
            address bidder = address(uint160(1000 + i));
            vm.prank(bidder);
            refunds += auction.withdrawRefund(bidder);
        }
        assertEq(total, refunds + rent);
        assertEq(address(auction).balance, rent - paid);
    }

    function testFuzz_escrowConservationAcrossLiquidityGaps(uint256 seed) public {
        uint256[2048] memory rates;
        uint8[2048] memory holders;
        bool[2048] memory active;
        uint256[8] memory refunds;
        uint256 total;
        uint256 now_ = 100;
        bool hasLiquidity = true;
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 next = now_ + 1 + seed % 20;
            for (uint256 t = now_; t < next; ++t) {
                active[t] = hasLiquidity;
            }
            now_ = next;
            _time(now_);
            if ((seed >> 16) % 2 == 1) {
                if (hasLiquidity) positions.withdraw(nft, key, -1600, 1600, liquidity);
                else (liquidity,,) = positions.deposit(nft, key, -1600, 1600, 1e18, 1e18, 0);
                hasLiquidity = !hasLiquidity;
            }
            uint96 rate = rates[now_ + 1] == 0 ? RATE : _minimumOutbid(uint96(rates[now_ + 1]));
            uint256 end = now_ + 1 + NOTICE + (seed >> 24) % 1500;
            address bidder = address(uint160(1000 + i));
            total += uint256(rate) * (end - now_ - 1);
            _bid(bidder, rate, uint64(end), bidder);
            for (uint256 t = now_ + 1; t < 2048; ++t) {
                if (rates[t] != 0) refunds[holders[t]] += rates[t];
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
        uint256 refunded;
        for (uint256 i; i < 8; ++i) {
            address bidder = address(uint160(1000 + i));
            assertEq(auction.refundable(bidder), refunds[i]);
            vm.prank(bidder);
            refunded += auction.withdrawRefund(bidder);
        }
        assertEq(total, refunded + expectedRent + unallocated);
        assertEq(address(auction).balance, expectedRent - paid + unallocated);
    }

    /// GAS

    function _cold() private {
        coolAllContracts();
        vm.cool(address(auction));
        vm.cool(address(executor));
        vm.cool(address(outsider));
    }

    function test_gas_initialBid() public {
        _cold();
        _bid(alice, RATE, 1024, address(executor));
        vm.snapshotGasLastCall("Auction#initialBid");
    }

    function test_gas_activeReplacement() public {
        _bid(alice, RATE, 1024, address(executor));
        _time(201);
        _cold();
        _bid(bob, RATE * 2, 512, bob);
        vm.snapshotGasLastCall("Auction#activeReplacement");
    }

    function test_gas_extend() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        vm.deal(alice, uint256(RATE) * 512);
        vm.prank(alice);
        auction.extend{value: uint256(RATE) * 512}(key, 1024);
        vm.snapshotGasLastCall("Auction#extend");
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

    function test_gas_claim() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        _claim(nft, -1600, 1600);
        vm.snapshotGasLastCall("AuctionPositions#claim");
    }

    function test_gas_refund() public {
        _bid(alice, RATE, 512, alice);
        _bid(bob, RATE * 2, 1024, bob);
        _cold();
        vm.prank(alice);
        auction.withdrawRefund(alice);
        vm.snapshotGasLastCall("Auction#refund");
    }

    function test_gas_withdrawSwapFees() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        outsider.swap(key, _params(1e17, true, 100), false);
        _cold();
        vm.prank(alice);
        auction.withdrawSwapFees(key, alice);
        vm.snapshotGasLastCall("Auction#withdrawSwapFees");
    }
}
