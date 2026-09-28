// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {AuctionPeriphery} from "./AuctionPeriphery.sol";
import {AuctionExecutor} from "../src/AuctionExecutor.sol";
import {ContinuousAuction, continuousAuctionCallPoints} from "../src/extensions/ContinuousAuction.sol";
import {ContinuousAuctionLib} from "../src/libraries/ContinuousAuctionLib.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {AmountBeforeFeeOverflow, amountBeforeFee, computeFee} from "../src/math/fee.sol";
import {MAX_TICK, MIN_TICK, NATIVE_TOKEN_ADDRESS} from "../src/math/constants.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {PoolBalanceUpdate, createPoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {createFullRangePoolConfig} from "../src/types/poolConfig.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {SwapParameters, createSwapParameters} from "../src/types/swapParameters.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

contract AuctionExecutorTest is FullTest {
    using CoreLib for *;

    uint96 constant RATE = 1e12;
    uint32 constant FEE = 42949672; // 1% as a 0.32 fixed-point fraction
    uint32 constant MAX_FEE = type(uint32).max;
    bytes32 constant SALT = bytes32(0);
    PoolBalanceUpdate LOOSE;

    ContinuousAuction auction;
    AuctionPeriphery periphery;
    AuctionExecutor executor;
    AuctionExecutor rival;
    PoolKey key;
    PoolId poolId;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);

    function setUp() public override {
        super.setUp();
        vm.warp(100);
        vm.roll(10);
        LOOSE = createPoolBalanceUpdate(type(int128).max, type(int128).max);
        auction = _deploy(NATIVE_TOKEN_ADDRESS, 0);
        periphery = new AuctionPeriphery(core, auction);
        executor = _executor(auction, address(this));
        rival = _executor(auction, bob);
        key = createPool(0, 0, 16, address(auction));
        poolId = key.toPoolId();
        createPosition(key, -1600, 1600, 1e18, 1e18);
    }

    function _deploy(address token, uint160 salt) private returns (ContinuousAuction a) {
        address target = address((uint160(continuousAuctionCallPoints().toUint8()) << 152) | salt);
        deployCodeTo("ContinuousAuction.sol:ContinuousAuction", abi.encode(core, token), target);
        return ContinuousAuction(target);
    }

    function _executor(ContinuousAuction a, address owner_) private returns (AuctionExecutor e) {
        e = new AuctionExecutor(core, address(a), owner_);
        token0.transfer(address(e), 1e30);
        token1.transfer(address(e), 1e30);
        vm.deal(address(e), 1e24);
    }

    function _params(int128 amount, bool isToken1, int32 limit) private pure returns (SwapParameters) {
        return createSwapParameters({
            _amount: amount, _isToken1: isToken1, _sqrtRatioLimit: tickToSqrtRatio(limit), _skipAhead: 0
        });
    }

    function _time(uint256 time) private {
        vm.warp(time);
        vm.roll(block.number + 1);
    }

    /// @dev Alice bids through the test periphery, naming `exec` as executor.
    function _peripheryBid(PoolKey memory k, uint96 rate, uint64 end, address exec, uint32 fee) private {
        uint256 funding = uint256(rate) * (end - block.timestamp - 1);
        vm.deal(alice, alice.balance + funding);
        vm.prank(alice);
        periphery.updateBid{value: funding}(k, SALT, rate, end, exec, fee, alice);
    }

    function _aliceFees() private view returns (uint128 amount0, uint128 amount1) {
        return auction.swapFeesOwed(key, address(periphery), periphery.bidderSalt(alice, SALT));
    }

    function _balances(address who) private view returns (uint256, uint256, uint256) {
        return (token0.balanceOf(who), token1.balanceOf(who), who.balance);
    }

    /// AUTHENTICATION

    function test_onlyOwnerOperates() public {
        vm.startPrank(alice);
        vm.expectRevert(Ownable.Unauthorized.selector);
        executor.updateBid(key, SALT, RATE, 1100, FEE, type(uint256).max);
        vm.expectRevert(Ownable.Unauthorized.selector);
        executor.swap(key, _params(1000, true, 100), LOOSE, type(uint256).max);
        vm.expectRevert(Ownable.Unauthorized.selector);
        executor.collectSwapFees(key, SALT);
        vm.expectRevert(Ownable.Unauthorized.selector);
        executor.call(address(token0), 0, abi.encodeCall(token0.transfer, (alice, 1)));
        vm.stopPrank();
    }

    function test_bidNamesTheExecutorItself() public {
        executor.updateBid(key, SALT, RATE, 1100, FEE, block.timestamp);
        _time(101);
        assertEq(auction.executorAt(poolId), address(executor));
        ContinuousAuction.Bid memory bid = auction.holder(poolId);
        assertEq(bid.bidder, ContinuousAuctionLib.bidderId(address(executor), SALT));
        assertEq(bid.fee, FEE);
    }

    /// BID SETTLEMENT

    function test_updateBid_paysFromAndRefundsToOwnBalance_native() public {
        uint256 before = address(executor).balance;
        int256 delta = executor.updateBid(key, SALT, RATE, 1100, FEE, block.timestamp);
        assertEq(delta, int256(uint256(RATE) * (1100 - 101)));
        assertEq(address(executor).balance, before - uint256(delta));
        _time(101);
        // Removing at 101 refunds every second from 102 on.
        delta = executor.updateBid(key, SALT, 0, 0, 0, block.timestamp);
        assertEq(delta, -int256(uint256(RATE) * (1100 - 102)));
        assertEq(address(executor).balance, before - RATE);
    }

    function test_updateBid_fundedByCallValue() public {
        AuctionExecutor empty = new AuctionExecutor(core, address(auction), address(this));
        uint256 cost = uint256(RATE) * (1100 - 101);
        int256 delta = empty.updateBid{value: cost}(key, SALT, RATE, 1100, FEE, block.timestamp);
        assertEq(delta, int256(cost));
        assertEq(address(empty).balance, 0);
    }

    function test_updateBid_paysFromAndRefundsToOwnBalance_erc20() public {
        ContinuousAuction erc20Auction = _deploy(address(token1), 1);
        AuctionExecutor e = _executor(erc20Auction, address(this));
        PoolKey memory k = createPool(0, 0, 16, address(erc20Auction));
        createPosition(k, -1600, 1600, 1e18, 1e18);
        uint256 before = token1.balanceOf(address(e));
        int256 delta = e.updateBid(k, SALT, RATE, 1100, FEE, block.timestamp);
        assertEq(delta, int256(uint256(RATE) * (1100 - 101)));
        assertEq(token1.balanceOf(address(e)), before - uint256(delta));
        _time(101);
        delta = e.updateBid(k, SALT, 0, 0, 0, block.timestamp);
        assertEq(delta, -int256(uint256(RATE) * (1100 - 102)));
        assertEq(token1.balanceOf(address(e)), before - RATE);
    }

    /// @dev A bid starts the second after inclusion, so a late inclusion buys less usable tenure. Setting the
    /// deadline to `end - 1 - minUsable` rejects any inclusion that would leave less than `minUsable` seconds,
    /// on every block cadence.
    function test_updateBid_deadlineBoundsUsableTenure() public {
        uint256[4] memory gaps = [uint256(1), 2, 6, 12];
        for (uint256 i; i < gaps.length; i++) {
            uint256 gap = gaps[i];
            uint256 snapshot = vm.snapshotState();
            uint64 end = uint64(100 + 10 * gap + 1);
            uint256 minUsable = 8 * gap;
            uint256 deadline = end - 1 - minUsable;
            for (uint256 late; late <= 3; late++) {
                uint256 inclusion = 100 + late * gap;
                _time(inclusion);
                if (inclusion > deadline) {
                    vm.expectRevert(abi.encodeWithSelector(AuctionExecutor.DeadlineExpired.selector, deadline));
                    executor.updateBid(key, SALT, RATE, end, FEE, deadline);
                } else {
                    executor.updateBid(key, SALT, RATE, end, FEE, deadline);
                    assertGe(end - (inclusion + 1), minUsable);
                }
            }
            vm.revertToState(snapshot);
        }
    }

    /// SWAPS

    function test_swap_feeFreeWhileHolding() public {
        executor.updateBid(key, SALT, RATE, 1100, FEE, block.timestamp);
        _time(101);
        (uint256 a0, uint256 a1,) = _balances(address(executor));
        PoolBalanceUpdate u = executor.swap(key, _params(1e15, true, 100), LOOSE, block.timestamp);
        assertEq(u.delta1(), 1e15);
        assertLt(u.delta0(), 0);
        (uint256 b0, uint256 b1,) = _balances(address(executor));
        assertEq(b0, a0 + uint128(-u.delta0()));
        assertEq(b1, a1 - uint128(u.delta1()));
        (uint128 fee0, uint128 fee1) = auction.swapFeesOwed(key, address(executor), SALT);
        assertEq(fee0, 0);
        assertEq(fee1, 0);
        // Another owner's executor is not the holder's executor and pays the fee.
        vm.prank(bob);
        PoolBalanceUpdate r = rival.swap(key, _params(1e15, true, 200), LOOSE, block.timestamp);
        (fee0,) = auction.swapFeesOwed(key, address(executor), SALT);
        assertEq(fee0, computeFee(uint128(-r.delta0()) + fee0, uint64(FEE) << 32));
    }

    function test_swap_expiredDeadlineReverts() public {
        executor.updateBid(key, SALT, RATE, 1100, FEE, block.timestamp);
        _time(101);
        vm.expectRevert(abi.encodeWithSelector(AuctionExecutor.DeadlineExpired.selector, 100));
        executor.swap(key, _params(1e15, true, 100), LOOSE, 100);
    }

    function test_swap_closedPoolReverts() public {
        vm.expectRevert(ContinuousAuction.PoolClosed.selector);
        executor.swap(key, _params(1e15, true, 100), LOOSE, block.timestamp);
    }

    /// @dev The executor's bid is displaced by a max-fee bid. Bounds taken from the fee-free quote reject the
    /// displaced swap in both exact-input and exact-output form; a loose bound executes and pays the fee.
    function test_swap_boundsAreFeeInclusiveWhenDisplaced() public {
        executor.updateBid(key, SALT, RATE, 1100, FEE, block.timestamp);
        _time(101);
        SwapParameters exactIn = _params(1e15, true, 100);
        SwapParameters exactOut = _params(-1e15, false, 100);
        uint256 snapshot = vm.snapshotState();
        PoolBalanceUpdate quotedIn = executor.swap(key, exactIn, LOOSE, block.timestamp);
        vm.revertToState(snapshot);
        PoolBalanceUpdate quotedOut = executor.swap(key, exactOut, LOOSE, block.timestamp);
        vm.revertToState(snapshot);
        // 1% slippage on the calculated amount.
        PoolBalanceUpdate boundIn = createPoolBalanceUpdate(quotedIn.delta0() * 99 / 100, 1e15);
        PoolBalanceUpdate boundOut = createPoolBalanceUpdate(-1e15, quotedOut.delta1() * 101 / 100);

        _peripheryBid(key, RATE + 1, 1100, alice, MAX_FEE);
        _time(102);
        assertEq(auction.executorAt(poolId), alice);

        snapshot = vm.snapshotState();
        vm.expectPartialRevert(AuctionExecutor.MaxBalanceUpdateExceeded.selector);
        executor.swap(key, exactIn, boundIn, block.timestamp);
        vm.expectPartialRevert(AuctionExecutor.MaxBalanceUpdateExceeded.selector);
        executor.swap(key, exactOut, boundOut, block.timestamp);

        (uint128 fee0Before,) = _aliceFees();
        PoolBalanceUpdate paid = executor.swap(key, exactIn, LOOSE, block.timestamp);
        (uint128 fee0After,) = _aliceFees();
        uint128 gross = uint128(-paid.delta0()) + fee0After - fee0Before;
        assertEq(fee0After - fee0Before, computeFee(gross, uint64(MAX_FEE) << 32));
        vm.revertToState(snapshot);
    }

    /// @dev A price limit can stop an exact-output swap short of its requested output. Bounding the output token by
    /// the requested amount rejects that partial fill; relaxing it accepts it.
    function test_swap_boundRejectsPartialExactOutput() public {
        executor.updateBid(key, SALT, RATE, 1100, FEE, block.timestamp);
        _time(101);
        SwapParameters partialOut = _params(-1e18, false, 100);
        PoolBalanceUpdate requested = createPoolBalanceUpdate(-1e18, type(int128).max);
        vm.expectPartialRevert(AuctionExecutor.MaxBalanceUpdateExceeded.selector);
        executor.swap(key, partialOut, requested, block.timestamp);
        PoolBalanceUpdate u = executor.swap(key, partialOut, LOOSE, block.timestamp);
        assertGt(u.delta0(), -1e18);
        assertEq(core.poolState(poolId).tick(), 100);
    }

    /// @dev The bound applies to the balance update after the holder's fee, exactly: the realized update passes and
    /// one unit less in either token reverts, for any fee, size and direction, exact input and exact output alike.
    function testFuzz_swap_boundIsTheFeeInclusiveUpdate(uint32 fee, uint128 magnitude, bool isToken1, bool exactOut)
        public
    {
        _peripheryBid(key, RATE, 1100, alice, fee);
        _time(101);
        int128 amount = int128(uint128(bound(magnitude, 1, 1e17)));
        if (exactOut) amount = -amount;
        SwapParameters params = createSwapParameters({
            _amount: amount, _isToken1: isToken1, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        }).withDefaultSqrtRatioLimit();
        uint256 snapshot = vm.snapshotState();
        // Inputs up to 1e17 gross up by at most 2**32, far inside Core's amounts, so every swap executes.
        PoolBalanceUpdate realized = executor.swap(key, params, LOOSE, block.timestamp);
        vm.revertToState(snapshot);
        snapshot = vm.snapshotState();
        assertEq(
            PoolBalanceUpdate.unwrap(executor.swap(key, params, realized, block.timestamp)),
            PoolBalanceUpdate.unwrap(realized)
        );
        vm.revertToState(snapshot);
        vm.expectPartialRevert(AuctionExecutor.MaxBalanceUpdateExceeded.selector);
        executor.swap(key, params, createPoolBalanceUpdate(realized.delta0() - 1, realized.delta1()), block.timestamp);
        vm.expectPartialRevert(AuctionExecutor.MaxBalanceUpdateExceeded.selector);
        executor.swap(key, params, createPoolBalanceUpdate(realized.delta0(), realized.delta1() - 1), block.timestamp);
    }

    /// @dev At the maximum fee, 1 - 2**-32, an exact-output swap's input grosses up by exactly 2**32. Core amounts are
    /// int128, so the swap reverts instead of executing once the fee-free input reaches 2**95, and the fee math
    /// itself reverts once the gross-up exceeds uint128.
    function test_swap_maxFeeExactOutGrossUpRevertsAtRepresentationalLimits() public {
        uint64 maxFee = uint64(MAX_FEE) << 32;
        assertEq(amountBeforeFee(uint128(2 ** 95 - 1), maxFee), uint128(2 ** 95 - 1) << 32);
        assertLe(amountBeforeFee(uint128(2 ** 95 - 1), maxFee), uint128(type(int128).max));
        assertGt(amountBeforeFee(uint128(2 ** 95), maxFee), uint128(type(int128).max));
        vm.expectRevert(AmountBeforeFeeOverflow.selector);
        this.grossUp(uint128(2 ** 96), maxFee);

        PoolKey memory k = PoolKey({
            token0: address(token0), token1: address(token1), config: createFullRangePoolConfig(0, address(auction))
        });
        core.initializePool(k, 0);
        createPosition(k, MIN_TICK, MAX_TICK, 1e30, 1e30);
        _peripheryBid(k, RATE, 1100, alice, MAX_FEE);
        _time(101);

        // Small exact output: the input is grossed up by 2**32 and executes.
        uint256 snapshot = vm.snapshotState();
        (, uint128 fee1Before) = auction.swapFeesOwed(k, address(periphery), periphery.bidderSalt(alice, SALT));
        PoolBalanceUpdate u = executor.swap(k, _exactOut0(1000), LOOSE, block.timestamp);
        (, uint128 fee1After) = auction.swapFeesOwed(k, address(periphery), periphery.bidderSalt(alice, SALT));
        assertEq(u.delta0(), -1000);
        assertEq(uint128(u.delta1()), (uint128(u.delta1()) - (fee1After - fee1Before)) << 32);
        vm.revertToState(snapshot);

        // Fee-free input between 2**95 and 2**96: the gross-up fits uint128 but not int128.
        vm.expectRevert(SafeCastLib.Overflow.selector);
        executor.swap(k, _exactOut0(5e28), LOOSE, block.timestamp);
        // Fee-free input above 2**96: the gross-up exceeds uint128.
        vm.expectRevert(AmountBeforeFeeOverflow.selector);
        executor.swap(k, _exactOut0(1e29), LOOSE, block.timestamp);
    }

    function grossUp(uint128 afterFee, uint64 fee) external pure returns (uint128) {
        return amountBeforeFee(afterFee, fee);
    }

    function _exactOut0(int128 out) private pure returns (SwapParameters) {
        return createSwapParameters({
            _amount: -out, _isToken1: false, _sqrtRatioLimit: SqrtRatio.wrap(0), _skipAhead: 0
        }).withDefaultSqrtRatioLimit();
    }

    /// FEES

    function test_collectSwapFees_withdrawsToOwnBalanceAndOwnerRecoversThem() public {
        executor.updateBid(key, SALT, RATE, 1100, FEE, block.timestamp);
        _time(101);
        vm.prank(bob);
        rival.swap(key, _params(1e15, true, 100), LOOSE, block.timestamp);
        (uint128 owed0, uint128 owed1) = auction.swapFeesOwed(key, address(executor), SALT);
        assertGt(owed0, 0);
        assertEq(owed1, 0);

        (uint256 a0,,) = _balances(address(executor));
        uint256 ownerBefore = token0.balanceOf(address(this));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(executor.collectSwapFees, (key, SALT));
        calls[1] = abi.encodeCall(
            executor.call, (address(token0), 0, abi.encodeCall(token0.transfer, (address(this), a0 + owed0)))
        );
        executor.multicall(calls);
        assertEq(token0.balanceOf(address(executor)), 0);
        assertEq(token0.balanceOf(address(this)), ownerBefore + a0 + owed0);
        (owed0, owed1) = auction.swapFeesOwed(key, address(executor), SALT);
        assertEq(owed0, 0);
        assertEq(owed1, 0);
    }
}
