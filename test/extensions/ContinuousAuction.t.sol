// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {ContinuousAuction, continuousAuctionCallPoints} from "../../src/extensions/ContinuousAuction.sol";
import {AuctionPositions} from "../../src/AuctionPositions.sol";
import {AuctionPeriphery} from "../AuctionPeriphery.sol";
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

/// @dev A Core locker that holds a position directly, bypassing AuctionPositions, and pays with its owner's tokens.
contract PositionToucher is BaseLocker {
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

    function update(PoolKey memory key, int32 lower, int32 upper, int128 delta) external {
        lock(abi.encode(false, key, lower, upper, delta));
    }

    function collect(PoolKey memory key, int32 lower, int32 upper) external returns (uint256 rent) {
        rent = abi.decode(lock(abi.encode(true, key, lower, upper, int128(0))), (uint256));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (bool collectRent, PoolKey memory key, int32 lower, int32 upper, int128 delta) =
            abi.decode(data, (bool, PoolKey, int32, int32, int128));
        if (collectRent) {
            uint256 rent = ContinuousAuctionLib.collectRent(
                core, address(auction), key, createPositionId(bytes24(0), lower, upper)
            );
            if (rent != 0) ACCOUNTANT.withdraw(auction.bidToken(), owner, uint128(rent));
            return abi.encode(rent);
        }
        PoolBalanceUpdate update_ = core.updatePosition(key, createPositionId(bytes24(0), lower, upper), delta);
        ACCOUNTANT.payTwoFrom(owner, key.token0, key.token1, uint128(update_.delta0()), uint128(update_.delta1()));
        return "";
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
        _bid(k, bidder, SALT, rate, end, exec);
    }

    function _bid(PoolKey memory k, address bidder, bytes32 salt, uint96 rate, uint64 end, address exec) private {
        uint256 funding = uint256(rate) * (end - block.timestamp - 1);
        vm.deal(bidder, bidder.balance + funding);
        vm.prank(bidder);
        periphery.updateBid{value: funding}(k, salt, rate, end, exec, FEE, bidder);
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

    /// @dev Block gaps, in seconds, used as chain sensitivities. They are not chain commitments.
    function _blockGaps() private pure returns (uint256[4] memory) {
        return [uint256(1), 2, 6, 12];
    }

    /// @dev The smallest `end` leaving `blocks` executable blocks after the bid's inclusion block on a chain that
    /// produces a block every `gap` seconds, when the bid lands up to `lateBlocks` blocks after `placedAt`. A paid
    /// second is not a block: an on-time bid pays `(lateBlocks + blocks) * gap` seconds, `gap - 1` of them before its
    /// first usable block.
    function _usableEnd(uint256 placedAt, uint256 gap, uint256 blocks, uint256 lateBlocks)
        private
        pure
        returns (uint64)
    {
        return uint64(placedAt + (lateBlocks + blocks) * gap + 1);
    }

    /// @dev Alice rents from 101 and moves the price into a dust range above the main position, where the dust is
    /// the only active liquidity.
    function _park() private returns (uint256 dust, uint128 dustLiquidity) {
        (dust, dustLiquidity) = _createPosition(key, 3200, 3216, 1e15, 0);
        _bid(alice, RATE, 1024, address(executor));
        _time(101);
        executor.swap(key, _params(5e18, true, 3208), false);
        assertEq(core.poolState(poolId).liquidity(), dustLiquidity);
    }

    /// ECONOMIC REGRESSIONS
    /// These pin current semantics that the specification's economics depend on. They are not exploit-success
    /// invariants: each shows what the mechanism does and does not guarantee.

    function test_economic_oneSecondBidCanExpireWithoutExecutableBlock() public {
        _bid(alice, RATE, 102, address(executor));
        vm.expectRevert(ContinuousAuction.PoolClosed.selector);
        executor.swap(key, _params(1000, true, 100), false);
        _time(112);
        assertEq(auction.executorAt(poolId), address(0));
        vm.expectRevert(ContinuousAuction.PoolClosed.selector);
        executor.swap(key, _params(1000, true, 100), false);
        assertApproxEqAbs(_claim(nft, -1600, 1600), RATE, 1);
        assertEq(_remove(alice), 0);
    }

    function test_economic_shortDisplacerPaysFloorButLeavesNoExecutableTenure() public {
        _bid(alice, RATE, 512, address(executor));
        _bid(bob, RATE + 1, 102, address(outsider));
        vm.prank(bob);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, 0, 0, address(0), 0, bob);
        _time(112);
        auction.accrue(key);
        assertEq(auction.refundable(_id(alice)), uint256(RATE) * 411);
        assertEq(auction.executorAt(poolId), address(0));
        assertApproxEqAbs(_claim(nft, -1600, 1600), RATE + 1, 1);
        vm.expectRevert(ContinuousAuction.PoolClosed.selector);
        executor.swap(key, _params(1000, true, 100), false);
    }

    function test_economic_challengerPreExecutionRentGoesToParkedLiquidity() public {
        (uint256 dust, uint128 dustLiquidity) = _createPosition(key, 3200, 3216, 1e15, 0);
        _bid(alice, RATE, 1024, address(executor));
        _time(101);
        executor.swap(key, _params(5e18, true, 3208), false);
        assertEq(core.poolState(poolId).liquidity(), dustLiquidity);
        _time(113);
        assertApproxEqAbs(_claim(dust, 3200, 3216), uint256(RATE) * 12, 1);
        _bid(bob, 2 * RATE, 126, address(outsider));
        _time(125);
        assertEq(auction.executorAt(poolId), address(outsider));
        outsider.swap(key, _params(5e18, false, 0), false);
        assertEq(core.poolState(poolId).tick(), 0);
        // One old-holder second and eleven challenger seconds accrue before restoration.
        assertApproxEqAbs(_claim(dust, 3200, 3216), uint256(RATE) + uint256(2 * RATE) * 11, 1);
        assertEq(_claim(nft, -1600, 1600), 0);
        _time(126);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(2 * RATE), 1);
    }

    function test_economic_soleActiveHolderRecapturesRaisedGrossRent() public {
        (uint256 dust, uint128 dustLiquidity) = _createPosition(key, 3200, 3216, 1e15, 0);
        _bid(alice, RATE, 1024, address(executor));
        _time(101);
        executor.swap(key, _params(5e18, true, 3208), false);
        assertEq(core.poolState(poolId).liquidity(), dustLiquidity);
        uint96 raised = 1000 * RATE;
        uint256 funding = uint256(raised) * (1024 - 102);
        vm.deal(alice, funding);
        vm.prank(alice);
        periphery.updateBid{value: funding}(key, SALT, raised, 1024, address(executor), type(uint32).max, alice);
        _time(114);
        assertEq(auction.holder(poolId).rate, raised);
        assertApproxEqAbs(_claim(dust, 3200, 3216), uint256(RATE) + uint256(raised) * 12, 1);
        assertEq(_claim(nft, -1600, 1600), 0);
        vm.deal(bob, uint256(raised) * 1000);
        vm.prank(bob);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid{value: raised}(key, SALT, raised, 116, address(outsider), 0, bob);
    }

    function test_economic_challengerCanDiluteParkedRentBeforeBidding() public {
        (uint256 dust, uint128 dustLiquidity) = _createPosition(key, 3200, 3216, 1e15, 0);
        _bid(alice, RATE, 1024, address(executor));
        _time(101);
        executor.swap(key, _params(5e18, true, 3208), false);
        _time(113);
        _claim(dust, 3200, 3216);
        (uint256 entrant, uint128 entrantLiquidity) = _createPosition(key, 3200, 3216, 1e18, 1e18);
        _bid(bob, 2 * RATE, 126, address(outsider));
        _time(125);
        uint256 intervalRent = uint256(RATE) * 23;
        uint256 entrantRent = _claim(entrant, 3200, 3216);
        assertApproxEqAbs(entrantRent, intervalRent * entrantLiquidity / (uint256(entrantLiquidity) + dustLiquidity), 1);
        assertGt(entrantRent, intervalRent * 99 / 100);
        manager.withdraw(entrant, key, 3200, 3216, entrantLiquidity, address(this));
        outsider.swap(key, _params(5e18, false, 0), false);
        assertEq(core.poolState(poolId).tick(), 0);
    }

    function test_economic_nonzeroTopUpCollectsUncollectedRentFirst() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        uint256 quoted = auction.getPositionRent(key, address(manager), manager.positionId(nft, -1600, 1600));
        assertApproxEqAbs(quoted, uint256(RATE) * 100, 1);
        uint256 savedBefore = _funds();
        uint256 balanceBefore = address(this).balance;
        (uint128 added,,, uint256 rent) = manager.deposit(nft, key, -1600, 1600, 1000, 1000, 0);
        assertGt(added, 0);
        assertEq(rent, quoted);
        assertEq(address(this).balance, balanceBefore + rent);
        assertEq(_funds(), savedBefore - rent);
        assertEq(_claim(nft, -1600, 1600), 0);
    }

    /// @dev The extension still discards uncollected rent on a raw nonzero change, reachable through the
    /// manager only via the explicit escape hatch.
    function test_economic_withdrawForfeitingRentDiscardsAllUncollectedRent() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        assertApproxEqAbs(
            auction.getPositionRent(key, address(manager), manager.positionId(nft, -1600, 1600)), uint256(RATE) * 100, 1
        );
        uint256 savedBefore = _funds();
        uint256 balanceBefore = address(this).balance;
        (uint128 amount0,) = manager.withdrawForfeitingRent(nft, key, -1600, 1600, liquidity / 2, address(this));
        assertGt(amount0, 0);
        assertEq(address(this).balance, balanceBefore);
        assertEq(_claim(nft, -1600, 1600), 0);
        assertEq(_funds(), savedBefore);
    }

    function test_economic_sameBlockRestoreAndReparkDoesNotRewardTraversedLiquidity() public {
        (uint256 dust,) = _createPosition(key, 3200, 3216, 1e15, 0);
        _bid(alice, RATE, 1024, address(executor));
        _time(101);
        executor.swap(key, _params(5e18, true, 3208), false);
        _time(113);
        uint256 before0 = token0.balanceOf(address(this));
        uint256 before1 = token1.balanceOf(address(this));
        executor.swap(key, _params(5e18, false, 0), false);
        executor.swap(key, _params(5e18, true, 3208), false);
        assertApproxEqAbs(token0.balanceOf(address(this)), before0, 10);
        assertApproxEqAbs(token1.balanceOf(address(this)), before1, 10);
        assertEq(_claim(nft, -1600, 1600), 0);
        assertApproxEqAbs(_claim(dust, 3200, 3216), uint256(RATE) * 12, 1);
    }

    /// CHAIN-AWARE BIDDING
    /// Each case runs for every block gap from a snapshot. Placement times are literals because via-IR may re-read
    /// `block.timestamp` after a warp.

    function test_chainAware_minimalUsableEndPaysOneBlockGap() public {
        uint256[4] memory gaps = _blockGaps();
        for (uint256 i; i < gaps.length; i++) {
            uint256 snapshot = vm.snapshotState();
            uint256 gap = gaps[i];
            uint256 t = 100;
            uint64 end = _usableEnd(t, gap, 1, 0);
            assertEq(end - (t + 1), gap);
            _bid(alice, RATE, end, address(executor));
            _time(t + gap);
            assertEq(auction.executorAt(poolId), address(executor));
            executor.swap(key, _params(1000, true, 100), false);
            // gap - 1 paid seconds elapse before the first block in which the bid can swap.
            assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * (gap - 1), 1);
            _time(t + 2 * gap);
            assertEq(auction.executorAt(poolId), address(0));
            vm.expectRevert(ContinuousAuction.PoolClosed.selector);
            executor.swap(key, _params(1000, true, 100), false);
            assertApproxEqAbs(_claim(nft, -1600, 1600), RATE, 1);
            assertEq(_remove(alice), 0);
            vm.revertToState(snapshot);
        }
    }

    function test_chainAware_endOneSecondShortOfNextBlockPaysWithoutAccess() public {
        uint256[4] memory gaps = _blockGaps();
        for (uint256 i; i < gaps.length; i++) {
            uint256 snapshot = vm.snapshotState();
            uint256 gap = gaps[i];
            uint256 t = 100;
            uint64 end = _usableEnd(t, gap, 1, 0) - 1;
            if (gap == 1) {
                // The one-second minimum already reaches the next block.
                vm.prank(alice);
                vm.expectRevert(ContinuousAuction.InvalidBid.selector);
                periphery.updateBid(key, SALT, RATE, end, address(executor), FEE, alice);
            } else {
                _bid(alice, RATE, end, address(executor));
                _time(t + gap);
                assertEq(auction.executorAt(poolId), address(0));
                vm.expectRevert(ContinuousAuction.PoolClosed.selector);
                executor.swap(key, _params(1000, true, 100), false);
                assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * (gap - 1), 1);
                assertEq(_remove(alice), 0);
            }
            vm.revertToState(snapshot);
        }
    }

    function test_chainAware_lateBidInclusionNeedsMargin() public {
        uint256[4] memory gaps = _blockGaps();
        for (uint256 i; i < gaps.length; i++) {
            uint256 snapshot = vm.snapshotState();
            uint256 gap = gaps[i];
            uint256 t = 100;
            _time(t + gap); // The bid lands one block later than planned.
            // `end` is absolute, so a bid sized without margin reverts instead of paying for no usable block.
            vm.prank(alice);
            vm.expectRevert(ContinuousAuction.InvalidBid.selector);
            periphery.updateBid(key, SALT, RATE, _usableEnd(t, gap, 1, 0), address(executor), FEE, alice);
            _bid(alice, RATE, _usableEnd(t, gap, 1, 1), address(executor));
            _time(t + 2 * gap);
            assertEq(auction.executorAt(poolId), address(executor));
            executor.swap(key, _params(1000, true, 100), false);
            _time(t + 3 * gap);
            assertEq(auction.executorAt(poolId), address(0));
            vm.revertToState(snapshot);
        }
    }

    function test_chainAware_delayedSwapInclusionNeedsMargin() public {
        uint256[4] memory gaps = _blockGaps();
        for (uint256 i; i < gaps.length; i++) {
            uint256 gap = gaps[i];
            uint256 t = 100;
            uint256 snapshot = vm.snapshotState();
            _bid(alice, RATE, _usableEnd(t, gap, 1, 0), address(executor));
            _time(t + 2 * gap); // The swap misses the first usable block.
            vm.expectRevert(ContinuousAuction.PoolClosed.selector);
            executor.swap(key, _params(1000, true, 100), false);
            vm.revertToState(snapshot);
            uint64 end = _usableEnd(t, gap, 2, 0);
            assertEq(end - (t + 1), 2 * gap);
            _bid(alice, RATE, end, address(executor));
            _time(t + 2 * gap);
            executor.swap(key, _params(1000, true, 100), false);
            vm.revertToState(snapshot);
        }
    }

    function test_chainAware_shortDisplacementTruncatesLiveScheduleWithoutRestoringIt() public {
        _bid(alice, RATE, 1000, address(executor));
        _time(101);
        uint256[4] memory gaps = _blockGaps();
        for (uint256 i; i < gaps.length; i++) {
            uint256 snapshot = vm.snapshotState();
            uint256 gap = gaps[i];
            uint256 t = 101;
            _bid(bob, RATE + 1, uint64(t + 2), address(outsider));
            _time(t + gap);
            auction.accrue(key);
            // Alice's tail from bob's activation is credited, not reinstated.
            assertEq(auction.refundable(_id(alice)), uint256(RATE) * (1000 - (t + 1)));
            if (gap == 1) {
                assertEq(auction.executorAt(poolId), address(outsider));
                outsider.swap(key, _params(1000, true, 100), false);
            } else {
                assertEq(auction.executorAt(poolId), address(0));
                vm.expectRevert(ContinuousAuction.PoolClosed.selector);
                executor.swap(key, _params(1000, true, 100), false);
            }
            // Alice's last second, then bob's second once it has elapsed.
            assertApproxEqAbs(_claim(nft, -1600, 1600), gap == 1 ? RATE : uint256(RATE) + RATE + 1, 2);
            // Alice can only return from the next second after she re-bids.
            _bid(alice, RATE, 1000, address(executor));
            _time(t + 2 * gap);
            assertEq(auction.executorAt(poolId), address(executor));
            vm.revertToState(snapshot);
        }
    }

    function test_chainAware_preRestorationRentGoesToParkedLiquidity() public {
        (uint256 dust,) = _park();
        _time(113);
        _claim(dust, 3200, 3216);
        uint256[4] memory gaps = _blockGaps();
        for (uint256 i; i < gaps.length; i++) {
            uint256 snapshot = vm.snapshotState();
            uint256 gap = gaps[i];
            uint256 t = 113;
            _bid(bob, 2 * RATE, _usableEnd(t, gap, 1, 0), address(outsider));
            _time(t + gap);
            outsider.swap(key, _params(5e18, false, 0), false);
            assertEq(core.poolState(poolId).tick(), 0);
            // Alice's last second and bob's gap - 1 seconds before his first block accrue before the restoring swap.
            assertApproxEqAbs(_claim(dust, 3200, 3216), uint256(RATE) + uint256(2 * RATE) * (gap - 1), 1);
            assertEq(_claim(nft, -1600, 1600), 0);
            _time(t + gap + 1);
            assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(2 * RATE), 1);
            vm.revertToState(snapshot);
        }
    }

    function test_chainAware_entrantLiquidityRecapturesPreRestorationRent() public {
        (uint256 dust, uint128 dustLiquidity) = _park();
        _time(113);
        _claim(dust, 3200, 3216);
        uint256[4] memory gaps = _blockGaps();
        for (uint256 i; i < gaps.length; i++) {
            uint256 snapshot = vm.snapshotState();
            uint256 gap = gaps[i];
            uint256 t = 113;
            (uint256 entrant, uint128 entrantLiquidity) = _createPosition(key, 3200, 3216, 1e18, 1e18);
            _bid(bob, 2 * RATE, _usableEnd(t, gap, 1, 0), address(outsider));
            _time(t + gap);
            uint256 intervalRent = uint256(RATE) + uint256(2 * RATE) * (gap - 1);
            (,, uint256 entrantRent) = manager.withdraw(entrant, key, 3200, 3216, entrantLiquidity, address(this));
            assertApproxEqAbs(
                entrantRent, intervalRent * entrantLiquidity / (uint256(entrantLiquidity) + dustLiquidity), 1
            );
            assertGt(entrantRent, intervalRent * 99 / 100);
            outsider.swap(key, _params(5e18, false, 0), false);
            assertEq(core.poolState(poolId).tick(), 0);
            vm.revertToState(snapshot);
        }
    }

    function test_chainAware_maxFeeAppliesFromNextSecondAndNeedsFeeInclusiveBounds() public {
        uint64 maxFee = uint64(type(uint32).max) << 32;
        _bid(alice, RATE, 512, address(executor));
        _time(101);
        SwapParameters exactIn = _params(1e15, true, 100);
        uint256 snapshot = vm.snapshotState();
        (uint128 fee0Before,) = _fees(alice);
        uint128 quoted = uint128(-outsider.swap(key, exactIn, false).delta0());
        (uint128 fee0Quoted,) = _fees(alice);
        uint128 gross = quoted + fee0Quoted - fee0Before;
        vm.revertToState(snapshot);
        vm.prank(alice);
        periphery.updateBid(key, SALT, RATE, 512, address(executor), type(uint32).max, alice);
        // The quoted fee still holds for the rest of the current second.
        snapshot = vm.snapshotState();
        assertEq(uint128(-outsider.swap(key, exactIn, false).delta0()), quoted);
        vm.revertToState(snapshot);
        _time(102);
        uint128 out = uint128(-outsider.swap(key, exactIn, false).delta0());
        (uint128 fee0After,) = _fees(alice);
        assertEq(out + fee0After - fee0Before, gross);
        assertEq(out, gross - computeFee(gross, maxFee));
        assertLe(out, (gross >> 32) + 1);
        // A trader bounding output by its quote less 1% slippage would revert rather than accept this.
        assertLt(out, quoted * 99 / 100);
        // Exact output grosses the input up by 2**32.
        (, uint128 fee1Before) = _fees(alice);
        PoolBalanceUpdate exactOut = outsider.swap(key, _params(-1000, false, 100), false);
        (, uint128 fee1After) = _fees(alice);
        assertEq(exactOut.delta0(), -1000);
        assertEq(uint128(exactOut.delta1()), (uint128(exactOut.delta1()) - (fee1After - fee1Before)) << 32);
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
        (,, uint48 lastSettled,,) = auction.auctions(k.toPoolId());
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
        // The displaced tenure is credited when Bob's bid activates, not when placed.
        _time(201);
        auction.accrue(key);
        assertEq(auction.refundable(_id(alice)), uint256(RATE) * (1024 - 201));
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
        // Replacing a never-active pending bid credits it immediately; Alice's live tenure is
        // credited when Carol's bid activates.
        assertEq(auction.refundable(_id(bob)), uint256(RATE) * 2 * (768 - 151));
        assertEq(auction.executorAt(poolId), alice);
        _time(151);
        auction.accrue(key);
        assertEq(auction.refundable(_id(alice)), uint256(RATE) * (1024 - 151));
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
        _time(300);
        // Settle Bob's activation so Alice's displaced tenure is credited before she rebids.
        auction.accrue(key);
        uint256 credit = auction.refundable(_id(alice));
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
        assertEq(auction.executorAt(poolId), alice); // The current second is unaffected.
        // Alice's credit lands when Bob's bid activates; withdrawing it leaves the schedule alone.
        _time(201);
        auction.accrue(key);
        uint256 credit = auction.refundable(_id(alice));
        uint256 refund = _remove(alice); // Nothing scheduled to remove; the credit is withdrawn.
        assertEq(refund, credit);
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
        auction.accrue(key); // Settles Bob's activation so Alice's displaced tenure is credited.
        assertEq(auction.executorAt(poolId), bob);
        // The incumbent keeps its displaced tenure as credit.
        assertEq(auction.refundable(_id(alice)), uint256(RATE) * (1024 - 102));
    }

    function test_cancelAfterDisplacingLeavesTheIncumbentIntact() public {
        _bid(alice, RATE, 1024, alice);
        _time(101); // Alice's bid is live before Bob displaces it.
        _bid(bob, RATE * 2, 512, bob);
        uint256 pendingCost = uint256(RATE) * 2 * (512 - 102);
        // Cancelling refunds the full pending cost: the incumbent was never truncated.
        assertEq(_remove(bob), pendingCost);
        assertEq(auction.refundable(_id(alice)), 0);
        ContinuousAuction.Bid memory h = auction.holder(poolId);
        assertEq(h.bidder, _id(alice));
        assertEq(h.end, 1024);
        _time(102);
        assertEq(auction.executorAt(poolId), alice);
        // Alice's rent accrues uninterrupted by Bob's excursion.
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * (102 - 101), 1);
    }

    function test_killedPendingPromiseBindsSameStartReplacements() public {
        _bid(alice, RATE, 1024, alice);
        _time(101); // Alice's bid is live before Bob displaces it.
        _bid(bob, RATE * 2, 512, bob);
        // Bob lowers his own pending bid, but not below Alice's live rate.
        vm.prank(bob);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, RATE - 1, 512, bob, FEE, bob);
        // Replacing Alice's pending-equivalent promise via a fresh identity does not help either:
        // Carol must beat the live incumbent, and the floor only binds the same start.
        _bid(carol, RATE * 2 + 1, 512, carol);
        _time(102);
        assertEq(auction.executorAt(poolId), carol);
    }

    function test_incumbentExitSucceedsDespiteAttackerPending() public {
        _bid(alice, RATE, 1024, alice);
        _time(101); // Alice is live; Bob plants a pending bid on top of her.
        _bid(bob, RATE * 2, 512, bob);
        // Alice's rate-zero exit shortens her own live schedule even though Bob's pending exists,
        // and withdraws her prepaid tail. Bob's pending is untouched.
        uint256 refund = _remove(alice);
        assertEq(refund, uint256(RATE) * (1024 - 102));
        _time(102);
        assertEq(auction.executorAt(poolId), bob);
        // Bob's pending activated normally; Alice holds nothing.
        assertEq(auction.refundable(_id(alice)), 0);
    }

    function test_pendingFloorBlocksCancelAndRebidDowngrade() public {
        // No live incumbent. Alice promises 20 while pending; Bob kills it high, then tries to cancel
        // or re-bid low.
        _bid(alice, 20, 512, alice);
        _bid(bob, 21, 512, bob);
        vm.prank(bob);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, 0, 0, address(0), 0, bob);
        // Same-start replacements must still beat Alice's killed promise, by anyone including Bob.
        vm.prank(bob);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, 15, 512, bob, FEE, bob);
        vm.prank(bob);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, 20, 512, bob, FEE, bob);
        // Topping the killed promise by one wei is enough, and the floor expires next second.
        _bid(bob, 21, 102, bob);
        _time(101);
        assertEq(auction.executorAt(poolId), bob);
        _time(102);
        _bid(alice, 1, 512, alice);
        _remove(alice); // An undisplacing pending bid remains freely cancellable.
    }

    /// CANCELLATION SUPPRESSION

    function test_displacerCannotCancelToKeepTheLowerIncumbent() public {
        bytes32 alt = bytes32(uint256(1));
        _bid(alice, RATE, 512, alice);
        _time(101);
        _bid(bob, RATE * 2, 512, bob);
        // Alice backruns Bob with a second salt and one second of funding.
        _bid(key, alice, alt, RATE * 2 + 1, 103, alice);
        assertEq(auction.refundable(_id(bob)), uint256(RATE) * 2 * (512 - 102));
        // She may neither cancel it nor lower it to Bob's killed promise.
        vm.startPrank(alice);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, alt, 0, 0, address(0), 0, alice);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, alt, RATE * 2, 103, alice, FEE, alice);
        vm.stopPrank();
        _time(102);
        auction.accrue(key);
        // The displacing bid holds the pool at the higher rate and her lower-rate schedule ended.
        ContinuousAuction.Bid memory h = auction.holder(poolId);
        assertEq(h.bidder, periphery.bidderId(alice, alt));
        assertEq(h.rate, RATE * 2 + 1);
        assertEq(auction.refundable(_id(alice)), uint256(RATE) * (512 - 102));
        _time(103);
        assertEq(auction.executorAt(poolId), address(0));
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) + uint256(RATE) * 2 + 1, 2);
    }

    function test_displacerCannotCancelToLeaveThePoolClosed() public {
        _bid(bob, RATE, 512, bob);
        // Same identity type as the board reproduction: no incumbent, one second of funding.
        _bid(alice, RATE + 1, 102, alice);
        vm.prank(alice);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, 0, 0, address(0), 0, alice);
        assertEq(auction.refundable(_id(bob)), uint256(RATE) * (512 - 101));
        _time(101);
        assertEq(auction.executorAt(poolId), alice);
        _time(102);
        assertEq(auction.executorAt(poolId), address(0));
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) + 1, 1);
    }

    function test_chainedSameSecondDisplacementsBindEachDisplacerAndKeepExitRights() public {
        bytes32 alt = bytes32(uint256(1));
        _bid(alice, RATE, 512, alice);
        _time(101);
        _bid(bob, RATE * 2, 512, bob);
        _bid(key, alice, alt, RATE * 2 + 1, 103, alice);
        _bid(carol, RATE * 3, 104, carol);
        // The floor follows the latest killed promise and binds the latest displacer.
        vm.startPrank(carol);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, 0, 0, address(0), 0, carol);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, RATE * 2 + 1, 104, carol, FEE, carol);
        vm.stopPrank();
        // Displaced pending bidders only hold credit and withdraw it in full.
        vm.prank(alice);
        int256 delta = periphery.updateBid(key, alt, 0, 0, address(0), 0, alice);
        assertEq(uint256(-delta), uint256(RATE * 2 + 1));
        assertEq(_remove(bob), uint256(RATE) * 2 * (512 - 102));
        // The incumbent still exits its own schedule while a bound pending bid sits on top.
        assertEq(_remove(alice), uint256(RATE) * (512 - 102));
        // The bound displacer may lower to one wei above the floor, or raise and extend.
        _bid(carol, RATE * 2 + 2, 103, carol);
        _bid(carol, RATE * 4, 110, carol);
        // Escrow is Alice's unsettled current second plus Carol's schedule.
        assertEq(_funds(), uint256(RATE) + uint256(RATE) * 4 * (110 - 102));
        _time(102);
        assertEq(auction.executorAt(poolId), carol);
        assertEq(auction.refundable(_id(alice)), 0);
        _time(110);
        uint256 rent = _claim(nft, -1600, 1600);
        assertApproxEqAbs(rent, uint256(RATE) + uint256(RATE) * 4 * (110 - 102), 2);
        assertLe(_funds(), 2);
    }

    function test_incumbentSelfExtensionThatDisplacedAChallengerIsBound() public {
        _bid(alice, RATE, 512, alice);
        _time(101);
        _bid(bob, RATE * 2, 512, bob);
        // Alice outbids Bob with her live bid's own salt: her tail is netted into the new pending bid.
        _bid(alice, RATE * 2 + 1, 1024, alice);
        assertEq(auction.refundable(_id(alice)), 0);
        assertEq(auction.refundable(_id(bob)), uint256(RATE) * 2 * (512 - 102));
        // Having displaced Bob, she can neither exit at rate zero nor lower to his killed promise.
        vm.startPrank(alice);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, 0, 0, address(0), 0, alice);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, RATE * 2, 1024, alice, FEE, alice);
        vm.stopPrank();
        // Her obligation is one second above the floor: shortening to it refunds the rest.
        vm.prank(alice);
        int256 delta = periphery.updateBid(key, SALT, RATE * 2 + 1, 103, alice, FEE, alice);
        assertEq(uint256(-delta), uint256(RATE * 2 + 1) * (1024 - 103));
        assertEq(_funds(), uint256(RATE) + auction.refundable(_id(bob)) + uint256(RATE * 2 + 1));
        _time(102);
        assertEq(auction.executorAt(poolId), alice);
        assertEq(auction.holder(poolId).rate, RATE * 2 + 1);
        _time(103);
        assertEq(auction.executorAt(poolId), address(0));
        assertEq(_remove(bob), uint256(RATE) * 2 * (512 - 102));
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) + uint256(RATE * 2 + 1), 2);
        assertLe(_funds(), 2);
    }

    function test_displacerExitsByTruncationAfterActivationAndTheIncumbentIsNotRestored() public {
        _bid(alice, RATE, 512, alice);
        _time(101);
        _bid(bob, RATE * 2, 512, bob);
        _bid(carol, RATE * 2 + 1, 512, carol);
        _time(102);
        auction.accrue(key);
        // At activation Alice's tail is credited, not restored as a fallback schedule.
        assertEq(auction.holder(poolId).bidder, _id(carol));
        assertEq(auction.refundable(_id(alice)), uint256(RATE) * (512 - 102));
        // The floor has expired: Carol exits her live bid by truncation and keeps only the current second.
        assertEq(_remove(carol), uint256(RATE * 2 + 1) * (512 - 103));
        assertEq(
            _funds(),
            uint256(RATE * 2 + 1) + auction.refundable(_id(alice)) + auction.refundable(_id(bob)) + uint256(RATE)
        );
        _time(103);
        assertEq(auction.executorAt(poolId), address(0));
        assertEq(auction.holder(poolId).bidder, bytes32(0));
        assertEq(_remove(alice), uint256(RATE) * (512 - 102));
        assertEq(_remove(bob), uint256(RATE) * 2 * (512 - 102));
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) + uint256(RATE * 2 + 1), 2);
        assertLe(_funds(), 2);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_displacedPendingPromiseIsNeverErasedForFree(
        bool incumbent,
        uint8 identity,
        uint96 incumbentRate,
        uint96 bump,
        uint64 displacerTenure
    ) public {
        incumbentRate = uint96(bound(incumbentRate, 1, 1e15));
        uint96 challenge = incumbentRate + uint96(bound(bump, 1, 1e15));
        displacerTenure = uint64(bound(displacerTenure, 1, 64));
        uint256 incumbentSeconds;
        if (incumbent) {
            _bid(alice, incumbentRate, 512, alice);
            _time(101);
            incumbentSeconds = 1;
        }
        uint48 start = uint48(block.timestamp + 1);
        _bid(bob, challenge, 512, bob);
        (address who, bytes32 salt) =
            identity % 3 == 0 ? (alice, SALT) : identity % 3 == 1 ? (alice, bytes32(uint256(1))) : (carol, SALT);
        uint96 displacerRate = challenge + 1;
        _bid(key, who, salt, displacerRate, start + displacerTenure, who);

        vm.startPrank(who);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, salt, 0, 0, address(0), 0, who);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, salt, challenge, start + displacerTenure, who, FEE, who);
        vm.stopPrank();

        _time(start);
        auction.accrue(key);
        ContinuousAuction.Bid memory h = auction.holder(poolId);
        assertEq(h.bidder, periphery.bidderId(who, salt));
        assertGt(h.rate, challenge);
        // Escrow is exactly accrued rent, outstanding credit and the live schedule.
        uint256 bobCredit = auction.refundable(_id(bob));
        assertEq(bobCredit, uint256(challenge) * (512 - start));
        uint256 aliceCredit = auction.refundable(_id(alice));
        // The displaced incumbent's tail is credited at activation, or netted at placement when it displaced itself.
        bool selfDisplaced = who == alice && salt == SALT;
        assertEq(aliceCredit, incumbent && !selfDisplaced ? uint256(incumbentRate) * (512 - start) : 0);
        assertEq(
            _funds(),
            uint256(incumbentRate) * incumbentSeconds + bobCredit + aliceCredit + uint256(displacerRate)
                * displacerTenure
        );
    }

    function test_pendingChainKeepsLiveCurrentIntact() public {
        // X holds live at 10; A promises 20 while pending; B outbids the pending at 21.
        _bid(alice, 10, 1024, alice);
        _time(101);
        _bid(bob, 20, 512, bob);
        _bid(carol, 21, 512, carol);
        // Bob's killed promise is fully credited; Alice's live schedule was never truncated.
        assertEq(auction.refundable(_id(bob)), uint256(20) * (512 - 102));
        assertEq(auction.holder(poolId).bidder, _id(alice));
        // Carol's pending displaced Bob's promise, so lowering below 20 reverts via the floor,
        // while staying above it remains allowed.
        vm.prank(carol);
        vm.expectRevert(ContinuousAuction.BidTooLow.selector);
        periphery.updateBid(key, SALT, 20, 512, carol, FEE, carol);
        _bid(carol, 205, 5120, carol);
        _time(102);
        assertEq(auction.executorAt(poolId), carol);
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_sameSecondChainBindsTheLatestDisplacerAndConservesEscrow(uint256 seed, bool incumbent) public {
        uint256 incumbentEscrow;
        if (incumbent) {
            _bid(alice, RATE, 512, alice);
            _time(101);
            incumbentEscrow = uint256(RATE) * (512 - 101);
        }
        uint48 start = uint48(block.timestamp + 1);
        address[6] memory users;
        bytes32[6] memory salts;
        for (uint256 k; k < 6; ++k) {
            users[k] = address(uint160(2000 + k / 2));
            salts[k] = bytes32(k % 2);
        }
        uint256 steps = 2 + seed % 5;
        uint96 rate = RATE;
        uint256 owner = type(uint256).max;
        uint256 nextCost;
        bool displaced;
        for (uint256 i; i < steps; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 k = seed % 6;
            rate += uint96(1 + (seed >> 8) % RATE);
            uint64 end = uint64(start + 1 + (seed >> 64) % 32);
            _bid(key, users[k], salts[k], rate, end, users[k]);
            // Replacing one's own pending bid displaces nobody; the floor binds after any displacement.
            displaced = displaced || (i != 0 && k != owner);
            owner = k;
            nextCost = uint256(rate) * (end - start);
            // Whoever holds the pending bid after a displacement cannot cancel it.
            if (displaced) {
                vm.startPrank(users[k]);
                vm.expectRevert(ContinuousAuction.BidTooLow.selector);
                periphery.updateBid(key, salts[k], 0, 0, address(0), 0, users[k]);
                vm.stopPrank();
            }
            // A displaced identity withdraws its full credit without touching the pending bid.
            uint256 other = (seed >> 128) % 6;
            if (other != owner && (seed >> 136) % 2 == 0) {
                uint256 credit = auction.refundable(periphery.bidderId(users[other], salts[other]));
                vm.prank(users[other]);
                int256 delta = periphery.updateBid(key, salts[other], 0, 0, address(0), 0, users[other]);
                assertEq(uint256(-delta), credit);
            }
            uint256 credits;
            for (uint256 j; j < 6; ++j) {
                credits += auction.refundable(periphery.bidderId(users[j], salts[j]));
            }
            assertEq(_funds(), incumbentEscrow + credits + nextCost);
        }
        _time(start);
        auction.accrue(key);
        ContinuousAuction.Bid memory h = auction.holder(poolId);
        assertEq(h.bidder, periphery.bidderId(users[owner], salts[owner]));
        assertEq(h.rate, rate);
        if (incumbent) assertEq(auction.refundable(_id(alice)), uint256(RATE) * (512 - start));
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
        uint256 earned = _claim(nft, -1600, 1600);
        assertApproxEqAbs(earned, uint256(RATE) * 99, 1);
        (,, uint256 rent) = manager.withdraw(nft, key, -1600, 1600, liquidity);
        assertEq(rent, 0);
        _time(300);
        vm.prank(bob);
        vm.expectRevert();
        manager.collectRent(nft, key, -1600, 1600, bob);
        manager.transferFrom(address(this), bob, nft);
        vm.prank(bob);
        // Nothing accrued with no liquidity and nothing was banked.
        assertEq(manager.collectRent(nft, key, -1600, 1600, bob), 0);
        assertEq(bob.balance, 0);
        vm.prank(bob);
        assertEq(manager.collectRent(nft, key, -1600, 1600, bob), 0);
    }

    function test_zeroDeltaTouchPreservesAccruedRent() public {
        PositionToucher toucher = new PositionToucher(core, auction);
        token0.approve(address(toucher), type(uint256).max);
        token1.approve(address(toucher), type(uint256).max);
        toucher.update(key, -1600, 1600, 1e18);
        _bid(alice, RATE, 512, alice);
        _time(201);
        // A zero-delta Core update modifies nothing and must not discard accrued rent.
        toucher.update(key, -1600, 1600, 0);
        uint256 collected = toucher.collect(key, -1600, 1600);
        assertGt(collected, 0);
        assertApproxEqAbs(collected + _claim(nft, -1600, 1600), uint256(RATE) * 100, 2);
    }

    function test_depositCollectsExistingRentToRecipient() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        (uint128 added,,, uint256 rent) = manager.deposit(nft, key, -1600, 1600, 1e18, 1e18, 0, carol);
        assertGt(added, 0);
        assertApproxEqAbs(rent, uint256(RATE) * 100, 1);
        assertEq(carol.balance, rent);
        // The rent was collected, so the grown position starts earning from zero.
        assertEq(_claim(nft, -1600, 1600), 0);
        _time(301);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 100, 1);
    }

    function test_zeroDepositCollectsRent() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        (uint128 added,,, uint256 rent) = manager.deposit(nft, key, -1600, 1600, 0, 0, 0);
        assertEq(added, 0);
        assertApproxEqAbs(rent, uint256(RATE) * 100, 1);
        assertEq(_claim(nft, -1600, 1600), 0);
    }

    function test_freshDepositCollectsNothing() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        uint256 id = manager.mint();
        uint256 balanceBefore = address(this).balance;
        (,,, uint256 rent) = manager.deposit(id, key, -1600, 1600, 1e18, 1e18, 0);
        assertEq(rent, 0);
        assertEq(address(this).balance, balanceBefore);
    }

    function test_withdrawCollectsRentInOneLock() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        (uint128 amount0, uint128 amount1, uint256 rent) = manager.withdraw(nft, key, -1600, 1600, liquidity, carol);
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
        (,, uint256 kept) = manager.withdraw(nft, key, -1600, 1600, liquidity, address(this));
        assertApproxEqAbs(kept, uint256(RATE) * 100, 1);
        _time(301);
        (uint256 other,) = _createPosition(key, -1600, 1600, 1e18, 1e18);
        _time(401);
        assertEq(_claim(nft, -1600, 1600), 0);
        assertApproxEqAbs(_claim(other, -1600, 1600), uint256(RATE) * 100, 1);
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
        _time(401);
        assertApproxEqAbs(_claim(nft, -1600, 1600), uint256(RATE) * 200, 2);
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

    function test_getPositionRentIncludesUnsettledRent() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        uint256 quoted = auction.getPositionRent(key, address(manager), manager.positionId(nft, -1600, 1600));
        (,,, uint256 viaManager) = manager.getPositionRentAndLiquidity(nft, key, -1600, 1600);
        assertEq(viaManager, quoted);
        assertApproxEqAbs(quoted, uint256(RATE) * 100, 1);
        assertEq(_claim(nft, -1600, 1600), quoted);
    }

    function test_getPositionRentIncludesPendingActivationAndOutOfRange() public {
        (uint256 upper,) = _createPosition(key, 1600, 3200, 0, 1e18);
        _bid(alice, RATE, 512, alice);
        _time(150);
        // A higher bid placed now is pending until next second; the quote must include its handover.
        _bid(bob, RATE * 3, 700, bob);
        _time(201);
        uint256 quoted = auction.getPositionRent(key, address(manager), manager.positionId(nft, -1600, 1600));
        assertApproxEqAbs(quoted, uint256(RATE) * 50 + uint256(RATE) * 3 * 50, 1);
        assertEq(auction.getPositionRent(key, address(manager), manager.positionId(upper, 1600, 3200)), 0);
        assertEq(_claim(nft, -1600, 1600), quoted);
        assertEq(_claim(upper, 1600, 3200), 0);
    }

    function test_getPositionRentIncludesUnsettledStableswapRent() public {
        PoolKey memory stable =
            createPool(address(token0), address(token1), 0, createStableswapPoolConfig(0, 20, 0, address(auction)));
        (int32 lower, int32 upper) = stable.config.stableswapActiveLiquidityTickRange();
        (uint256 id,) = _createPosition(stable, lower, upper, 1e18, 1e18);
        _bid(stable, alice, RATE, 512, address(executor));
        _time(101);
        executor.swap(stable, _params(3e18, true, upper + 5000), false);
        _time(201);
        uint256 quoted = auction.getPositionRent(stable, address(manager), manager.positionId(id, lower, upper));
        assertApproxEqAbs(quoted, uint256(RATE) * 100, 1);
        assertEq(manager.collectRent(id, stable, lower, upper, address(this)), quoted);
    }

    /// @dev The quote in any block equals what collecting in that block pays, across settlements with
    /// carried remainders, pending activations, price moves and liquidity changes.
    function testFuzz_getPositionRentEqualsCollectInSameBlock(uint256 seed) public {
        (uint256 upper,) = _createPosition(key, 0, 3200, 0, 1e18);
        uint256[2] memory ids = [nft, upper];
        int32[2] memory lowers = [int32(-1600), int32(0)];
        int32[2] memory uppers = [int32(1600), int32(3200)];
        _bid(alice, RATE, 2000, address(executor));
        uint256 now_ = 100;
        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            now_ += 1 + seed % 30;
            _time(now_);
            uint256 action = (seed >> 8) % 6;
            if (action == 0) {
                address bidder = address(uint160(1000 + i));
                _bid(
                    bidder,
                    uint96(RATE * (2 + i) + (seed >> 16) % 997),
                    uint64(now_ + 2 + (seed >> 32) % 400),
                    address(executor)
                );
            } else if (action == 1 && auction.executorAt(poolId) == address(executor)) {
                executor.swap(
                    key,
                    _params(
                        int128(int256(1e15 + (seed >> 16) % 1e17)),
                        (seed >> 80) % 2 == 0,
                        (seed >> 80) % 2 == 0 ? int32(3100) : int32(-1500)
                    ),
                    false
                );
            } else if (action == 2) {
                auction.accrue(key);
            } else if (action == 3) {
                manager.deposit(upper, key, 0, 3200, 0, uint128(1e15 + (seed >> 16) % 1e16), 0);
            } else if (action == 4) {
                (uint128 current,,,) = manager.getPositionRentAndLiquidity(upper, key, 0, 3200);
                manager.withdraw(upper, key, 0, 3200, current / 2);
            }
            uint256 j = (seed >> 120) % 2;
            uint256 quoted =
                auction.getPositionRent(key, address(manager), manager.positionId(ids[j], lowers[j], uppers[j]));
            assertEq(_claim(ids[j], lowers[j], uppers[j]), quoted);
            // A second quote in the same block after collection is zero.
            assertEq(
                auction.getPositionRent(key, address(manager), manager.positionId(ids[j], lowers[j], uppers[j])), 0
            );
        }
    }

    /// @dev Burning does not settle anything, so the safe exit is withdrawing every position (which
    /// collects its rent) and burning in one multicall.
    function test_multicallWithdrawAllAndBurnLeavesNothingBehind() public {
        _bid(alice, RATE, 512, alice);
        _time(201);
        uint256 balanceBefore = address(this).balance;
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature(
            "withdraw(uint256,(address,address,bytes32),int32,int32,uint128)",
            nft,
            key,
            int32(-1600),
            int32(1600),
            liquidity
        );
        calls[1] = abi.encodeWithSelector(manager.burn.selector, nft);
        manager.multicall(calls);
        assertApproxEqAbs(address(this).balance - balanceBefore, uint256(RATE) * 100, 1);
        (uint128 remaining,,, uint256 rent) = manager.getPositionRentAndLiquidity(nft, key, -1600, 1600);
        assertEq(remaining, 0);
        assertEq(rent, 0);
        vm.expectRevert();
        manager.ownerOf(nft);
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
            // Tails displaced this iteration land at the next settlement, not at placement.
            uint256[8] memory unlanded;
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
                        unlanded[holders[t]] += rates[t];
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
                assertEq(auction.refundable(_id(address(uint160(1000 + j)))), credits[j] - unlanded[j]);
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

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_crossingsAllocateRentToActiveRangesLikeReference(uint256 seed) public {
        uint256 n = 5;
        int32[6] memory lowers;
        int32[6] memory uppers;
        uint128[6] memory liqs;
        uint256[6] memory ids;
        uint256[6] memory expected;
        (ids[0], lowers[0], uppers[0], liqs[0]) = (nft, -1600, 1600, liquidity);
        // A wide range keeps liquidity active everywhere the swaps go.
        (lowers[1], uppers[1]) = (-163840, 163840);
        (ids[1], liqs[1]) = _createPosition(key, lowers[1], uppers[1], 1e18, 1e18);
        for (uint256 i = 2; i <= n; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            // Ranges on the spacing-16 grid spanning up to 80 bitmap words, some bounded at zero.
            int32 a = int32(int256(seed % 20481)) * 16 - 163840;
            int32 b = int32(int256((seed >> 16) % 20481)) * 16 - 163840;
            if ((seed >> 32) % 4 == 0) a = 0;
            if (a == b) b = a == 163840 ? int32(-163840) : a + 16;
            (lowers[i], uppers[i]) = a < b ? (a, b) : (b, a);
            (ids[i], liqs[i]) = _createPosition(key, lowers[i], uppers[i], 1e16, 1e16);
        }
        _bid(alice, RATE, 4096, address(executor));
        _time(101);
        auction.accrue(key);
        uint256 now_ = 101;
        for (uint256 step; step < 12; ++step) {
            seed = uint256(keccak256(abi.encode(seed, "step", step)));
            uint256 dt = 1 + seed % 5;
            now_ += dt;
            _time(now_);
            int32 tick = core.poolState(poolId).tick();
            _allocate(tick, uint256(RATE) * dt, lowers, uppers, liqs, expected);
            // Targets anywhere in [-160000, 160000], landing on or off the grid, with any skip-ahead.
            // Half stay near zero so short swaps cross nearby boundaries too.
            int32 target = (seed >> 40) % 2 == 0
                ? int32(int256((seed >> 8) % 320001)) - 160000
                : int32(int256((seed >> 8) % 3201)) - 1600;
            if (target == tick) continue;
            executor.swap(
                key,
                createSwapParameters({
                    _amount: 1e30,
                    _isToken1: target > tick,
                    _sqrtRatioLimit: tickToSqrtRatio(target),
                    _skipAhead: (seed >> 24) % 4
                }),
                false
            );
        }
        _time(now_ + 1);
        _allocate(core.poolState(poolId).tick(), uint256(RATE), lowers, uppers, liqs, expected);
        auction.accrue(key);
        for (uint256 i; i <= n; ++i) {
            assertApproxEqAbs(_claim(ids[i], lowers[i], uppers[i]), expected[i], 16);
        }
    }

    /// @dev Reference allocation: rent of an interval goes pro rata to ranges containing the tick.
    function _allocate(
        int32 tick,
        uint256 rent,
        int32[6] memory lowers,
        int32[6] memory uppers,
        uint128[6] memory liqs,
        uint256[6] memory expected
    ) private pure {
        uint256 active;
        for (uint256 i; i < 6; ++i) {
            if (liqs[i] != 0 && lowers[i] <= tick && tick < uppers[i]) active += liqs[i];
        }
        for (uint256 i; i < 6; ++i) {
            if (liqs[i] != 0 && lowers[i] <= tick && tick < uppers[i]) expected[i] += rent * liqs[i] / active;
        }
    }

    function testFuzz_escrowConservationAcrossLiquidityGaps(uint256 seed) public {
        uint256[2048] memory rates;
        uint8[2048] memory holders;
        bool[2048] memory active;
        uint256[8] memory credits;
        uint256 total;
        uint256 now_ = 100;
        bool hasLiquidity = true;
        // Rent must be collected before each withdrawal: uncollected rent is discarded on any
        // liquidity change, mirroring Core fee and Ve33 reward accounting.
        uint256 collected;
        for (uint256 i; i < 8; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 next = now_ + 1 + seed % 20;
            for (uint256 t = now_; t < next; ++t) {
                active[t] = hasLiquidity;
            }
            now_ = next;
            _time(now_);
            if ((seed >> 16) % 2 == 1) {
                if (hasLiquidity) {
                    (,, uint256 rent) = manager.withdraw(nft, key, -1600, 1600, liquidity, address(this));
                    collected += rent;
                } else {
                    (liquidity,,,) = manager.deposit(nft, key, -1600, 1600, 1e18, 1e18, 0);
                }
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
        uint256 paid = _claim(nft, -1600, 1600) + collected;
        assertApproxEqAbs(paid, expectedRent, 25);
        // Empty-interval rent is discarded, not counted; conservation below still holds exactly.
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

    /// @dev A pool that has already activated and expired two bids, as in steady operation.
    function _settledHistory() private {
        _bid(carol, RATE, 150, carol);
        _time(150);
        _bid(carol, RATE, 180, carol);
        _time(180);
        auction.accrue(key);
        _time(201);
    }

    function test_gas_newBidSteadyState() public {
        _settledHistory();
        _cold();
        vm.deal(alice, 1e20);
        vm.prank(alice);
        periphery.updateBid{value: uint256(RATE) * (1024 - 202)}(key, SALT, RATE, 1024, address(executor), FEE, alice);
        vm.snapshotGasLastCall("AuctionPeriphery#newBidSteadyState");
    }

    function test_gas_displaceSettledLiveBid() public {
        _settledHistory();
        _bid(alice, RATE, 1024, address(executor));
        _time(250);
        auction.accrue(key);
        _time(300);
        _cold();
        vm.deal(bob, 1e20);
        vm.prank(bob);
        periphery.updateBid{value: uint256(RATE) * 2 * (512 - 301)}(key, SALT, RATE * 2, 512, bob, FEE, bob);
        vm.snapshotGasLastCall("AuctionPeriphery#displaceSettledLiveBid");
    }

    function test_gas_accrueSteadyStateActivation() public {
        // Activation into bid storage that previous bids already used.
        _settledHistory();
        _bid(alice, RATE, 1024, address(executor));
        _time(250);
        _cold();
        auction.accrue(key);
        vm.snapshotGasLastCall("Auction#accrueSteadyStateActivation");
    }

    function test_gas_accrueSteadyStateDisplacement() public {
        // Activation that ends a live incumbent early and credits its tail.
        _settledHistory();
        _bid(alice, RATE, 1024, address(executor));
        _time(250);
        auction.accrue(key);
        _time(300);
        _bid(bob, RATE * 2, 512, bob);
        _time(320);
        _cold();
        auction.accrue(key);
        vm.snapshotGasLastCall("Auction#accrueSteadyStateDisplacement");
    }

    function test_gas_replaceOwnSettledBid() public {
        _settledHistory();
        _bid(alice, RATE, 512, address(executor));
        _time(250);
        auction.accrue(key);
        _time(300);
        _cold();
        vm.deal(alice, 1e20);
        vm.prank(alice);
        periphery.updateBid{value: uint256(RATE) * 512}(key, SALT, RATE, 1024, address(executor), FEE, alice);
        vm.snapshotGasLastCall("AuctionPeriphery#replaceOwnSettledBid");
    }

    function test_gas_displacePendingBid() public {
        _settledHistory();
        _bid(alice, RATE, 1024, address(executor));
        _cold();
        vm.deal(bob, 1e20);
        vm.prank(bob);
        periphery.updateBid{value: uint256(RATE) * 2 * (512 - 202)}(key, SALT, RATE * 2, 512, bob, FEE, bob);
        vm.snapshotGasLastCall("AuctionPeriphery#displacePendingBid");
    }

    function test_gas_cancelPendingBid() public {
        _settledHistory();
        _bid(alice, RATE, 1024, address(executor));
        _cold();
        vm.prank(alice);
        periphery.updateBid(key, SALT, 0, 0, address(0), 0, alice);
        vm.snapshotGasLastCall("AuctionPeriphery#cancelPendingBid");
    }

    function test_gas_accrueNoActivation() public {
        _bid(alice, RATE, 512, address(executor));
        _time(150);
        auction.accrue(key);
        _time(201);
        _cold();
        auction.accrue(key);
        vm.snapshotGasLastCall("Auction#accrueNoActivation");
    }

    function test_gas_holderSwapNoActivation() public {
        _bid(alice, RATE, 512, address(executor));
        _time(150);
        auction.accrue(key);
        _time(201);
        _cold();
        executor.swap(key, _params(1000, true, 100), false);
        vm.snapshotGasLastCall("Auction#holderSwapNoActivation");
    }

    function test_gas_outsiderSwapNoActivation() public {
        _bid(alice, RATE, 512, address(executor));
        _time(150);
        auction.accrue(key);
        _time(201);
        _cold();
        outsider.swap(key, _params(1000, true, 100), false);
        vm.snapshotGasLastCall("Auction#outsiderSwapNoActivation");
    }

    function test_gas_holderSwapSameSecond() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        executor.swap(key, _params(1000, true, 100), false);
        executor.swap(key, _params(1000, true, 100), false);
        vm.snapshotGasLastCall("Auction#holderSwapSameSecond");
    }

    function test_gas_swapCrossingFourTicksDown() public {
        _createPosition(key, -3200, -1600, 0, 2e18);
        _createPosition(key, -4800, -3200, 0, 2e18);
        _createPosition(key, -6400, -4800, 0, 2e18);
        _createPosition(key, -8000, -6400, 0, 2e18);
        _bid(alice, RATE, 512, address(executor));
        _time(150);
        auction.accrue(key);
        _time(201);
        _cold();
        executor.swap(key, _params(10e18, false, -7000), false);
        vm.snapshotGasLastCall("Auction#swapCrossingFourTicksDown");
        assertLe(core.poolState(poolId).tick(), -6400);
    }

    function test_gas_swapCrossingSixteenTicks() public {
        for (int32 t = 1600; t < 1600 + 16 * 1024; t += 1024) {
            _createPosition(key, t, t + 1024, 1e18, 0);
        }
        _bid(alice, RATE, 512, address(executor));
        _time(150);
        auction.accrue(key);
        _time(201);
        _cold();
        executor.swap(key, _params(100e18, true, 1600 + 16 * 1024 + 8), false);
        vm.snapshotGasLastCall("Auction#swapCrossingSixteenTicks");
        assertGe(core.poolState(poolId).tick(), 1600 + 16 * 1024);
    }

    function test_gas_swapAcrossEmptyWords() public {
        _bid(alice, RATE, 512, address(executor));
        _time(150);
        auction.accrue(key);
        _time(201);
        _cold();
        // Leaves every position and moves through about 100 empty bitmap words (spacing 16).
        executor.swap(key, _params(10e18, true, 400000), false);
        vm.snapshotGasLastCall("Auction#swapAcrossEmptyWords");
        assertEq(core.poolState(poolId).tick(), 400000);
    }

    function test_gas_mintAndDepositNewRange() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        manager.mintAndDeposit(key, -3200, 3200, 1e18, 1e18, 0);
        vm.snapshotGasLastCall("AuctionPositions#mintAndDepositNewRange");
    }

    function test_gas_withdrawAll() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        manager.withdraw(nft, key, -1600, 1600, liquidity, address(this));
        vm.snapshotGasLastCall("AuctionPositions#withdrawAll");
    }

    function test_gas_withdrawForfeitingRent() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        manager.withdrawForfeitingRent(nft, key, -1600, 1600, liquidity / 2, address(this));
        vm.snapshotGasLastCall("AuctionPositions#withdrawForfeitingRentHalf");
    }

    function test_gas_getPositionRentUnsettled() public {
        _bid(alice, RATE, 512, address(executor));
        _time(201);
        _cold();
        auction.getPositionRent(key, address(manager), manager.positionId(nft, -1600, 1600));
        vm.snapshotGasLastCall("ContinuousAuction#getPositionRentUnsettled");
    }

    function test_gas_collectRentSettled() public {
        _bid(alice, RATE, 512, address(executor));
        _time(150);
        auction.accrue(key);
        _time(201);
        _cold();
        _claim(nft, -1600, 1600);
        vm.snapshotGasLastCall("AuctionPositions#collectRentNoActivation");
    }
}
