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
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {nextValidTime, MAX_NUM_VALID_TIMES} from "../../src/math/time.sol";

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
                assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
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
    PoolKey key;
    uint256 nft;
    uint128 liquidity;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    address carol = address(0xca401);
    uint96 constant RATE = 1e12;

    function setUp() public override {
        super.setUp();
        vm.warp(100);
        vm.roll(10);
        vm.deal(address(this), 1e30);
        auction = _deploy(address(0), 0);
        auctionPositions = new AuctionPositions(core, auction, owner);
        positions = auctionPositions;
        executor = new AuctionExecutor(core, auction);
        token0.approve(address(executor), type(uint256).max);
        token1.approve(address(executor), type(uint256).max);
        key = createPool(0, 0, 16, address(auction));
        (nft, liquidity) = createPosition(key, -1600, 1600, 1e18, 1e18);
    }

    function _deploy(address token, uint160 salt) private returns (ContinuousAuction a) {
        address target = address((uint160(continuousAuctionCallPoints().toUint8()) << 152) | salt);
        deployCodeTo("ContinuousAuction.sol:ContinuousAuction", abi.encode(core, token), target);
        return ContinuousAuction(target);
    }

    function _bid(address bidder, uint96 rate, uint64 end, address exec) private returns (uint256) {
        uint256 funding = uint256(rate) * (end - block.timestamp - 1);
        vm.deal(bidder, funding);
        vm.prank(bidder);
        return auction.bid{value: funding}(key, rate, end, exec);
    }

    function _time(uint256 time) private {
        vm.warp(time);
        vm.roll(block.number + 1);
    }

    function _claim(uint256 id, int32 lower, int32 upper) private returns (uint256) {
        return auctionPositions.collectAuctionFees(id, key, lower, upper, address(this));
    }

    function test_nextBlockAccessAndDirectSwapRejected() public {
        _bid(alice, RATE, 512, address(executor));
        SwapParameters params = createSwapParameters({
            _amount: 1000, _isToken1: true, _sqrtRatioLimit: tickToSqrtRatio(100), _skipAhead: 0
        });
        vm.expectRevert(ContinuousAuction.UnauthorizedExecutor.selector);
        executor.swap(key, params, false);
        vm.roll(11); // A new block sharing the timestamp does not activate a bid.
        assertEq(auction.executorAt(key.toPoolId()), address(0));
        vm.warp(101);
        executor.swap(key, params, false);
        vm.expectRevert(ContinuousAuction.SwapMustHappenThroughForward.selector);
        executor.swap(key, params, true);
        _bid(bob, RATE * 2, 256, bob);
        executor.swap(key, params, false); // Incumbent retains the current block.
        _time(102);
        vm.expectRevert(ContinuousAuction.UnauthorizedExecutor.selector);
        executor.swap(key, params, false);
    }

    function test_nestedBidsRefundOnlyOverlapAndResumeTails() public {
        _bid(alice, RATE, 1024, alice);
        _bid(bob, RATE * 2, 768, bob);
        _bid(carol, RATE * 3, 256, carol);
        assertEq(auction.refundable(alice), uint256(RATE) * (768 - 101));
        assertEq(auction.refundable(bob), uint256(RATE) * 2 * (256 - 101));
        _time(101);
        assertEq(auction.executorAt(key.toPoolId()), carol);
        _time(256);
        assertEq(auction.executorAt(key.toPoolId()), bob);
        _time(768);
        assertEq(auction.executorAt(key.toPoolId()), alice);
        _time(1024);
        assertEq(auction.executorAt(key.toPoolId()), address(0));
        uint256 expected = uint256(RATE) * (3 * (256 - 101) + 2 * (768 - 256) + (1024 - 768));
        assertApproxEqAbs(_claim(nft, -1600, 1600), expected, 1);
        vm.prank(alice);
        uint256 refund = auction.withdrawRefund(alice);
        assertEq(alice.balance, refund);
        vm.prank(alice);
        assertEq(auction.withdrawRefund(alice), 0);
    }

    function test_longerBidReplacesMultipleTails() public {
        _bid(alice, RATE, 1024, alice);
        _bid(bob, RATE * 2, 768, bob);
        _bid(carol, RATE * 3, 256, carol);
        address dan = address(0xda);
        _bid(dan, RATE * 4, 1024, dan);
        assertEq(auction.refundable(alice), uint256(RATE) * (1024 - 101));
        assertEq(auction.refundable(bob), uint256(RATE) * 2 * (768 - 101));
        assertEq(auction.refundable(carol), uint256(RATE) * 3 * (256 - 101));
        _time(101);
        assertEq(auction.executorAt(key.toPoolId()), dan);
    }

    function test_activePrefixIsPaidAndTailPreserved() public {
        _bid(alice, RATE, 1024, alice);
        _time(200);
        _bid(bob, RATE * 2, 512, bob);
        assertEq(auction.executorAt(key.toPoolId()), alice);
        assertEq(auction.refundable(alice), uint256(RATE) * (512 - 201));
        _time(201);
        assertEq(auction.executorAt(key.toPoolId()), bob);
        _time(1024);
        uint256 expected = uint256(RATE) * ((201 - 101) + 2 * (512 - 201) + (1024 - 512));
        assertApproxEqAbs(_claim(nft, -1600, 1600), expected, 3);
    }

    function test_fundingAndRateValidation() public {
        vm.expectRevert(ContinuousAuction.IncorrectFunding.selector);
        auction.bid{value: 1}(key, RATE, 512, alice);
        _bid(alice, RATE, 512, alice);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        auction.bid(key, RATE, 512, bob);
        vm.expectRevert(ContinuousAuction.InvalidBid.selector);
        auction.bid(key, RATE * 2, 513, bob);
        vm.expectRevert(ContinuousAuction.InvalidBid.selector);
        auction.bid(key, 0, 512, bob);
    }

    function test_feeOwnerAuthorizationTransferAndFullWithdrawal() public {
        _bid(alice, RATE, 512, alice);
        _time(200);
        positions.withdraw(nft, key, -1600, 1600, liquidity);
        _time(300);
        vm.prank(bob);
        vm.expectRevert();
        auctionPositions.collectAuctionFees(nft, key, -1600, 1600, bob);
        positions.transferFrom(address(this), bob, nft);
        vm.prank(bob);
        uint256 paid = auctionPositions.collectAuctionFees(nft, key, -1600, 1600, bob);
        assertApproxEqAbs(paid, uint256(RATE) * 99, 1);
        assertEq(bob.balance, paid);
        assertEq(auction.refundable(alice), 0);
        assertEq(auction.unallocatedRent(key.toPoolId()), uint256(RATE) * 100);
        vm.prank(bob);
        assertEq(auctionPositions.collectAuctionFees(nft, key, -1600, 1600, bob), 0);
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
        executor.swap(
            key,
            createSwapParameters({
                _amount: 2e18, _isToken1: true, _sqrtRatioLimit: tickToSqrtRatio(2000), _skipAhead: 0
            }),
            false
        );
        assertGe(core.poolState(key.toPoolId()).tick(), 1600);
        _time(301);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 100, 1);
        assertApproxEqAbs(_claim(upper, 1600, 3200), uint256(RATE) * 100, 1);
        executor.swap(
            key,
            createSwapParameters({_amount: 2e18, _isToken1: false, _sqrtRatioLimit: tickToSqrtRatio(0), _skipAhead: 0}),
            false
        );
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
        assertEq(auction.unallocatedRent(key.toPoolId()), uint256(RATE) * 100);
    }

    function test_erc20BidAssetAndFullRange() public {
        TestToken asset = new TestToken(address(this));
        ContinuousAuction erc = _deploy(address(asset), 1);
        AuctionPositions manager = new AuctionPositions(core, erc, owner);
        positions = manager;
        PoolKey memory full = createFullRangePool(0, 0, address(erc));
        (uint256 id,) = createPosition(full, MIN_TICK, MAX_TICK, 1e18, 1e18);
        asset.approve(address(erc), type(uint256).max);
        erc.bid(full, RATE, 512, alice);
        _time(201);
        uint256 balance = asset.balanceOf(bob);
        uint256 paid = manager.collectAuctionFees(id, full, MIN_TICK, MAX_TICK, bob);
        assertApproxEqAbs(paid, uint256(RATE) * 100, 1);
        assertEq(asset.balanceOf(bob) - balance, paid);
        vm.expectRevert(ContinuousAuction.IncorrectFunding.selector);
        erc.bid{value: 1}(full, RATE * 2, 512, bob);
    }

    function testFuzz_scheduleConservesFunding(uint96 rateSeed, uint8 stepsSeed) public {
        uint96 rate = uint96(bound(rateSeed, 1, 1e20));
        uint256 steps = bound(stepsSeed, 1, 12);
        uint256 total;
        for (uint256 i; i < steps; ++i) {
            uint64 end = uint64(256 * (steps - i));
            uint96 r = rate * uint96(i + 1);
            total += uint256(r) * (end - 101);
            _bid(address(uint160(1000 + i)), r, end, address(uint160(1000 + i)));
        }
        uint256 expectedRent;
        uint256 from = 101;
        for (uint256 i; i < steps; ++i) {
            uint256 to = 256 * (i + 1);
            expectedRent += uint256(rate) * (steps - i) * (to - from);
            from = to;
        }
        _time(256 * steps);
        uint256 paid = _claim(nft, -1600, 1600);
        assertApproxEqAbs(paid, expectedRent, 1);
        uint256 refunds;
        for (uint256 i; i < steps; ++i) {
            address bidder = address(uint160(1000 + i));
            vm.prank(bidder);
            refunds += auction.withdrawRefund(bidder);
        }
        assertEq(refunds + expectedRent, total);
        assertEq(address(auction).balance, expectedRent - paid);
    }

    function testFuzz_mixedEndTimesMatchPerSecondReference(uint256 seed) public {
        // An independent per-second model checks prefix/tail splitting as both time and bid ends change.
        uint256[2048] memory rates;
        address[2048] memory bidders;
        uint256[8] memory expectedRefunds;
        uint256 total;
        uint256 now_ = 100;
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            now_ += seed % 20;
            _time(now_);
            uint64 end = uint64(256 * (2 + (seed >> 8) % 7));
            uint96 rate = RATE * uint96(i + 1);
            address bidder = address(uint160(1000 + i));
            total += uint256(rate) * (end - now_ - 1);
            _bid(bidder, rate, end, bidder);
            for (uint256 t = now_ + 1; t < end; ++t) {
                if (bidders[t] != address(0)) expectedRefunds[uint160(bidders[t]) - 1000] += rates[t];
                bidders[t] = bidder;
                rates[t] = rate;
            }
            for (uint256 j; j <= i; ++j) {
                assertEq(auction.refundable(address(uint160(1000 + j))), expectedRefunds[j]);
            }
            assertEq(auction.executorAt(key.toPoolId()), bidders[now_]);
        }
        uint256 rent;
        for (uint256 t; t < 2048; ++t) {
            rent += rates[t];
        }
        _time(2048);
        uint256 paid = _claim(nft, -1600, 1600);
        assertApproxEqAbs(paid, rent, 9);
        uint256 refunds;
        for (uint256 i; i < 8; ++i) {
            address bidder = address(uint160(1000 + i));
            vm.prank(bidder);
            refunds += auction.withdrawRefund(bidder);
        }
        assertEq(total, refunds + rent);
        assertEq(address(auction).balance, rent - paid);
    }

    function test_unownedPositionCannotClaimOtherPositionsFees() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        assertEq(auction.collectFees(key, createPositionId(bytes24(uint192(nft)), -1600, 1600), bob), 0);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 100, 1);
    }

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

    function test_rejectNonzeroPoolFeesAndNonPowerOfFourSpacing() public {
        PoolKey memory invalid = key;
        invalid.config = createConcentratedPoolConfig(1, 16, address(auction));
        vm.expectRevert(ContinuousAuction.InvalidPool.selector);
        core.initializePool(invalid, 0);
        invalid.config = createConcentratedPoolConfig(0, 3, address(auction));
        vm.expectRevert(ContinuousAuction.InvalidPool.selector);
        core.initializePool(invalid, 0);
    }

    function _cold() private {
        coolAllContracts();
        vm.cool(address(auction));
        vm.cool(address(executor));
    }

    function test_gas_initialBid() public {
        _cold();
        _bid(alice, RATE, 1024, address(executor));
        vm.snapshotGasLastCall("Auction#initialBid");
    }

    function test_gas_pendingReplacement() public {
        _bid(alice, RATE, 1024, address(executor));
        _cold();
        _bid(bob, RATE * 2, 512, bob);
        vm.snapshotGasLastCall("Auction#pendingReplacement");
    }

    function test_gas_activeReplacement() public {
        _bid(alice, RATE, 1024, address(executor));
        _time(201);
        _cold();
        _bid(bob, RATE * 2, 512, bob);
        vm.snapshotGasLastCall("Auction#activeReplacementWithTail");
    }

    function test_gas_activeReplacementFull() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        _bid(bob, RATE * 2, 1024, bob);
        vm.snapshotGasLastCall("Auction#activeReplacementFull");
    }

    function test_gas_swap() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        executor.swap(
            key,
            createSwapParameters({
                _amount: 1000, _isToken1: true, _sqrtRatioLimit: tickToSqrtRatio(100), _skipAhead: 0
            }),
            false
        );
        vm.snapshotGasLastCall("Auction#swapWithAccrual");
    }

    function test_gas_swapInsideTickSpacing() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        executor.swap(
            key,
            createSwapParameters({_amount: 1e18, _isToken1: true, _sqrtRatioLimit: tickToSqrtRatio(8), _skipAhead: 0}),
            false
        );
        vm.snapshotGasLastCall("Auction#swapInsideTickSpacing");
        assertEq(core.poolState(key.toPoolId()).tick(), 8);
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

    function _maximalSchedule() private returns (uint64 last, uint256 expectedRent, uint96 count) {
        uint64[MAX_NUM_VALID_TIMES] memory ends;
        uint256 time = block.timestamp;
        while (true) {
            time = nextValidTime(block.timestamp, time);
            if (time == 0) break;
            ends[count++] = uint64(time);
        }
        last = ends[count - 1];
        for (uint256 i = count; i != 0;) {
            --i;
            _bid(address(uint160(1000 + i)), uint96(count - i), ends[i], alice);
        }
        uint256 from = block.timestamp + 1;
        for (uint256 i; i < count; ++i) {
            expectedRent += (count - i) * (ends[i] - from);
            from = ends[i];
        }
    }

    function test_gas_maximalExpirySchedule() public {
        (uint64 end, uint256 expected,) = _maximalSchedule();
        _time(end);
        _cold();
        uint256 gasBefore = gasleft();
        auction.accrue(key);
        uint256 used = gasBefore - gasleft();
        vm.snapshotGasLastCall("Auction#maximalScheduleExpiry");
        assertLt(used, 4_250_000, "must fit Lighter target block gas");
        assertApproxEqAbs(_claim(nft, -1600, 1600), expected, 1);
    }

    function test_gas_maximalScheduleReplacement() public {
        (uint64 end,, uint96 count) = _maximalSchedule();
        _time(101);
        _cold();
        uint256 gasBefore = gasleft();
        _bid(bob, count + 1, end, bob);
        uint256 used = gasBefore - gasleft();
        vm.snapshotGasLastCall("Auction#maximalScheduleReplacement");
        assertLt(used, 4_250_000, "must fit Lighter target block gas");
        _time(102);
        assertEq(auction.executorAt(key.toPoolId()), bob);
    }

    function test_maxRateAndTimestampPastUint32() public {
        _time(uint256(type(uint32).max) + 100);
        uint64 end = uint64(nextValidTime(block.timestamp, block.timestamp + 4096));
        uint256 expected = uint256(type(uint96).max) * (end - block.timestamp - 1);
        _bid(alice, type(uint96).max, end, alice);
        _time(end);
        assertApproxEqAbs(_claim(nft, -1600, 1600), expected, 1);
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

    function test_claimRecipientCannotReenterAccounting() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        AuctionReenterReceiver receiver = new AuctionReenterReceiver();
        receiver.configure(address(auction), abi.encodeCall(auction.accrue, (key)));
        uint256 amount = auctionPositions.collectAuctionFees(nft, key, -1600, 1600, address(receiver));
        assertFalse(receiver.reentered());
        assertEq(address(receiver).balance, amount);
        assertApproxEqAbs(amount, uint256(RATE) * 100, 1);
        assertEq(_claim(nft, -1600, 1600), 0);
    }

    function test_taxedFundingRevertsAtomically() public {
        TaxedAuctionToken asset = new TaxedAuctionToken(address(this));
        ContinuousAuction erc = _deploy(address(asset), 2);
        PoolKey memory full = createFullRangePool(0, 0, address(erc));
        asset.approve(address(erc), type(uint256).max);
        vm.expectRevert(ContinuousAuction.IncorrectFunding.selector);
        erc.bid(full, RATE, 512, alice);
        assertEq(asset.balanceOf(address(erc)), 0);
        assertEq(erc.nextSegmentId(), 0);
        assertEq(erc.executorAt(full.toPoolId()), address(0));
    }

    function test_approvedOperatorCanCollectButMetadataOwnerCannot() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        vm.prank(owner);
        vm.expectRevert();
        auctionPositions.collectAuctionFees(nft, key, -1600, 1600, owner);
        positions.approve(bob, nft);
        vm.prank(bob);
        uint256 amount = auctionPositions.collectAuctionFees(nft, key, -1600, 1600, alice);
        assertApproxEqAbs(amount, uint256(RATE) * 100, 1);
        assertEq(alice.balance, amount);
    }

    function test_emptyRangeDoesNotLetExecutorAvoidRent() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        executor.swap(
            key,
            createSwapParameters({
                _amount: 2e18, _isToken1: true, _sqrtRatioLimit: tickToSqrtRatio(2000), _skipAhead: 0
            }),
            false
        );
        assertEq(core.poolState(key.toPoolId()).liquidity(), 0);
        _time(301);
        executor.swap(
            key,
            createSwapParameters({_amount: 2e18, _isToken1: false, _sqrtRatioLimit: tickToSqrtRatio(0), _skipAhead: 0}),
            false
        );
        assertGt(core.poolState(key.toPoolId()).liquidity(), 0);
        assertEq(auction.refundable(alice), 0);
        assertEq(auction.unallocatedRent(key.toPoolId()), uint256(RATE) * 100);
        _time(401);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 200, 2);
        assertEq(auction.unallocatedRent(key.toPoolId()), uint256(RATE) * 100);
    }

    function testFuzz_escrowConservationAcrossLiquidityGaps(uint256 seed) public {
        uint256[2048] memory rates;
        address[2048] memory bidders;
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
            uint64 end = uint64(256 * (2 + (seed >> 8) % 7));
            uint96 rate = RATE * uint96(i + 1);
            address bidder = address(uint160(1000 + i));
            total += uint256(rate) * (end - now_ - 1);
            _bid(bidder, rate, end, bidder);
            for (uint256 t = now_ + 1; t < end; ++t) {
                if (bidders[t] != address(0)) refunds[uint160(bidders[t]) - 1000] += rates[t];
                bidders[t] = bidder;
                rates[t] = rate;
            }
        }
        for (uint256 t = now_; t < 2048; ++t) {
            active[t] = hasLiquidity;
        }
        uint256 expectedFees;
        uint256 unallocated;
        for (uint256 t; t < 2048; ++t) {
            if (active[t]) expectedFees += rates[t];
            else unallocated += rates[t];
        }
        _time(2048);
        uint256 paid = _claim(nft, -1600, 1600);
        assertApproxEqAbs(paid, expectedFees, 25);
        assertEq(auction.unallocatedRent(key.toPoolId()), unallocated);
        uint256 refunded;
        for (uint256 i; i < 8; ++i) {
            address bidder = address(uint160(1000 + i));
            assertEq(auction.refundable(bidder), refunds[i]);
            vm.prank(bidder);
            refunded += auction.withdrawRefund(bidder);
        }
        assertEq(total, refunded + expectedFees + unallocated);
        assertEq(address(auction).balance, expectedFees - paid + unallocated);
    }

    function test_crossingZeroTickDoesNotTakeSameCellShortcut() public {
        (uint256 below, uint128 belowLiquidity) = createPosition(key, -16, 0, 0, 1e16);
        (uint256 above, uint128 aboveLiquidity) = createPosition(key, 0, 16, 1e16, 0);
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        executor.swap(
            key,
            createSwapParameters({
                _amount: 1e16, _isToken1: false, _sqrtRatioLimit: tickToSqrtRatio(-1), _skipAhead: 0
            }),
            false
        );
        assertEq(core.poolState(key.toPoolId()).tick(), -1);
        _time(301);
        uint256 aboveExpected = uint256(RATE) * 100 * aboveLiquidity / (liquidity + aboveLiquidity);
        uint256 belowExpected = uint256(RATE) * 100 * belowLiquidity / (liquidity + belowLiquidity);
        assertApproxEqAbs(_claim(above, 0, 16), aboveExpected, 1);
        assertApproxEqAbs(_claim(below, -16, 0), belowExpected, 1);
        executor.swap(
            key,
            createSwapParameters({_amount: 1e16, _isToken1: true, _sqrtRatioLimit: tickToSqrtRatio(1), _skipAhead: 0}),
            false
        );
        _time(401);
        assertApproxEqAbs(_claim(above, 0, 16), aboveExpected, 1);
        assertEq(_claim(below, -16, 0), 0);
    }
}
