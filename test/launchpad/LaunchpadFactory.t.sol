// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {ScheduledLaunch, scheduledLaunchCallPoints} from "../../src/extensions/ScheduledLaunch.sol";
import {TWAMM, twammCallPoints} from "../../src/extensions/TWAMM.sol";
import {LockedLaunchLiquidity} from "../../src/LockedLaunchLiquidity.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {LaunchpadFactory} from "../../src/launchpad/LaunchpadFactory.sol";
import {RevenueAllocator} from "../../src/launchpad/RevenueAllocator.sol";
import {TreasuryVault} from "../../src/launchpad/TreasuryVault.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {MIN_TICK, MAX_TICK} from "../../src/math/constants.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract LaunchpadFactoryTest is FullTest {
    using CoreLib for *;

    ScheduledLaunch extension;
    LockedLaunchLiquidity vault;
    TWAMM twamm;
    TreasuryVault treasury;
    RevenueAllocator allocator;
    LaunchpadFactory factory;

    address constant LOW_QUOTE = address(0x10000);
    address constant HIGH_QUOTE = address(type(uint160).max);
    address constant OPS = address(0x0505);
    address creator = makeAddr("creator");
    uint128 constant SUPPLY = 1_000_000e18;
    uint64 constant START = 100;
    uint64 constant END = 1100;
    uint64 constant INITIAL_FEE = uint64(uint256(1 << 64) / 10);
    uint64 constant FINAL_FEE = uint64(uint256(1 << 64) / 100);
    uint8 constant TIER = 1;
    uint16 constant CREATOR_BPS = 5000;

    function setUp() public override {
        super.setUp();
        vm.warp(1);
        address target = address(uint160(scheduledLaunchCallPoints().toUint8()) << 152);
        address twammTarget = address(uint160(twammCallPoints().toUint8()) << 152);
        deployCodeTo("TWAMM.sol", abi.encode(core), twammTarget);
        twamm = TWAMM(twammTarget);
        deployCodeTo("ScheduledLaunch.sol", abi.encode(core, twammTarget), target);
        extension = ScheduledLaunch(target);
        vault = extension.LIQUIDITY();
        treasury = new TreasuryVault(address(this));
        allocator = new RevenueAllocator(address(this), treasury, OPS);
        treasury.setDepositor(address(allocator), true);
        factory = new LaunchpadFactory(address(this), core, extension, address(allocator));
        deployCodeTo("TestToken.sol", abi.encode(address(this)), LOW_QUOTE);
        deployCodeTo("TestToken.sol", abi.encode(address(this)), HIGH_QUOTE);
        TestToken(LOW_QUOTE).approve(address(factory), type(uint256).max);
        TestToken(HIGH_QUOTE).approve(address(factory), type(uint256).max);
        TestToken(LOW_QUOTE).approve(address(router), type(uint256).max);
        TestToken(HIGH_QUOTE).approve(address(router), type(uint256).max);
        factory.setQuoteAllowed(LOW_QUOTE, true);
        factory.setQuoteAllowed(HIGH_QUOTE, true);
        factory.setTier(TIER, true, CREATOR_BPS);
    }

    function _config(address quote) internal view returns (ScheduledLaunch.LaunchConfig memory) {
        return ScheduledLaunch.LaunchConfig({
            owner: address(0xdead),
            quoteToken: quote,
            name: "Launch",
            symbol: "LAUNCH",
            decimals: 18,
            totalSupply: SUPPLY,
            quoteAmount: 0,
            startTime: START,
            endTime: END,
            targetTick: 0,
            upperTick: 100_000,
            tickSpacing: 100,
            initialFee: INITIAL_FEE,
            finalFee: FINAL_FEE,
            migrationTickLower: MIN_TICK,
            migrationTickUpper: MAX_TICK
        });
    }

    function _create(bool tokenIs0) internal returns (PoolKey memory key) {
        vm.prank(creator);
        key = factory.create(_config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE), TIER);
        address token = _token(key);
        assertEq(token == key.token0, tokenIs0);
        MintableERC20(token).approve(address(factory), type(uint256).max);
        MintableERC20(token).approve(address(router), type(uint256).max);
    }

    function _token(PoolKey memory key) internal view returns (address) {
        return extension.getLaunch(key.toPoolId()).token;
    }

    function _buy(PoolKey memory key, uint128 amount, uint128 minOut) internal returns (PoolBalanceUpdate) {
        bool tokenIs0 = _token(key) == key.token0;
        return factory.swap(
            key, createSwapParameters(SqrtRatio.wrap(0), int128(amount), tokenIs0, 0), minOut, block.timestamp
        );
    }

    function _balances(address holder, PoolKey memory key) internal view returns (uint256, uint256) {
        return (TestToken(key.token0).balanceOf(holder), TestToken(key.token1).balanceOf(holder));
    }

    function _finish(PoolKey memory key) internal {
        vm.warp(END);
        extension.advance(key);
        assertTrue(extension.getLaunch(key.toPoolId()).complete);
    }

    /// @dev Claims and asserts every received unit went to creator or allocator by the tier share.
    function _claimAndCheckSplit(PoolKey memory key, uint16 bps) internal returns (uint256 total0, uint256 total1) {
        (uint256 c0, uint256 c1) = _balances(creator, key);
        (uint256 a0, uint256 a1) = _balances(address(allocator), key);
        factory.claim(key);
        (uint256 c0After, uint256 c1After) = _balances(creator, key);
        (uint256 a0After, uint256 a1After) = _balances(address(allocator), key);
        total0 = (c0After - c0) + (a0After - a0);
        total1 = (c1After - c1) + (a1After - a1);
        assertEq(c0After - c0, total0 * bps / 10_000, "creator share 0");
        assertEq(c1After - c1, total1 * bps / 10_000, "creator share 1");
        (uint256 f0, uint256 f1) = _balances(address(factory), key);
        assertEq(f0, 0, "factory holds token0");
        assertEq(f1, 0, "factory holds token1");
    }

    function testFuzz_createRegistersLaunchOwnedByFactory(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
        assertEq(launch.owner, address(factory));
        LaunchpadFactory.Registration memory registration = factory.getRegistration(key.toPoolId());
        assertEq(registration.creator, creator);
        assertEq(registration.creatorBps, CREATOR_BPS);
        assertEq(registration.tier, TIER);
        assertEq(MintableERC20(launch.token).balanceOf(address(core)), SUPPLY);
    }

    function testFuzz_createPaysQuoteSeedFromCreator(bool tokenIs0) public {
        address quote = tokenIs0 ? HIGH_QUOTE : LOW_QUOTE;
        TestToken(quote).transfer(creator, 100e18);
        vm.startPrank(creator);
        TestToken(quote).approve(address(factory), 100e18);
        ScheduledLaunch.LaunchConfig memory config = _config(quote);
        config.quoteAmount = 100e18;
        PoolKey memory key = factory.create(config, TIER);
        vm.stopPrank();
        assertEq(TestToken(quote).balanceOf(creator), 0);
        (uint128 r0, uint128 r1) =
            core.savedBalances(address(extension), key.token0, key.token1, PoolId.unwrap(key.toPoolId()));
        assertEq(tokenIs0 ? r1 : r0, 100e18);
    }

    function test_createRejectsUnlistedQuoteAndDisabledTier() public {
        vm.expectRevert(LaunchpadFactory.QuoteNotAllowed.selector);
        factory.create(_config(address(token0)), TIER);
        vm.expectRevert(LaunchpadFactory.TierDisabled.selector);
        factory.create(_config(LOW_QUOTE), 7);
        vm.expectRevert(LaunchpadFactory.QuoteNotAllowed.selector);
        factory.setQuoteAllowed(address(0), true);
        vm.expectRevert(LaunchpadFactory.InvalidShare.selector);
        factory.setTier(2, true, 10_001);
        vm.prank(creator);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setTier(2, true, 1);
        vm.prank(creator);
        vm.expectRevert(Ownable.Unauthorized.selector);
        factory.setQuoteAllowed(address(token0), true);
    }

    function testFuzz_swapChargesFeeAndSettlesTrader(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        (uint256 q0, uint256 q1) = _balances(address(this), key);
        vm.recordLogs();
        PoolBalanceUpdate update = _buy(key, 10_000e18, 1);
        (uint256 after0, uint256 after1) = _balances(address(this), key);
        int128 dq = tokenIs0 ? update.delta1() : update.delta0();
        int128 dt = tokenIs0 ? update.delta0() : update.delta1();
        assertEq(dq, int128(10_000e18));
        assertLt(dt, 0);
        assertEq((tokenIs0 ? q1 : q0) - (tokenIs0 ? after1 : after0), 10_000e18);
        assertEq((tokenIs0 ? after0 : after1) - (tokenIs0 ? q0 : q1), uint128(-dt));
        (uint128 fee0, uint128 fee1) =
            core.savedBalances(address(extension), key.token0, key.token1, extension.creatorFeeSalt(key.toPoolId()));
        assertGt(tokenIs0 ? fee0 : fee1, 0);
        assertEq(tokenIs0 ? fee1 : fee0, 0);
    }

    function testFuzz_swapSlippageAndDeadline(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        vm.expectRevert(LaunchpadFactory.SlippageExceeded.selector);
        factory.swap(
            key,
            createSwapParameters(SqrtRatio.wrap(0), int128(10_000e18), tokenIs0, 0),
            type(uint128).max,
            block.timestamp
        );
        vm.expectRevert(LaunchpadFactory.Expired.selector);
        factory.swap(key, createSwapParameters(SqrtRatio.wrap(0), int128(1e18), tokenIs0, 0), 0, block.timestamp - 1);
        // Exact output of launch token: the calculated side is the quote input.
        vm.expectRevert(LaunchpadFactory.SlippageExceeded.selector);
        factory.swap(key, createSwapParameters(SqrtRatio.wrap(0), -int128(100e18), !tokenIs0, 0), 0, block.timestamp);
        uint256 before = MintableERC20(_token(key)).balanceOf(address(this));
        PoolBalanceUpdate update = factory.swap(
            key,
            createSwapParameters(SqrtRatio.wrap(0), -int128(100e18), !tokenIs0, 0),
            type(uint128).max,
            block.timestamp
        );
        assertEq(MintableERC20(_token(key)).balanceOf(address(this)) - before, 100e18);
        assertGt(tokenIs0 ? update.delta1() : update.delta0(), 0);
    }

    function test_swapAndClaimRejectUnknownLaunch() public {
        PoolKey memory key = _create(true);
        key.token0 = address(token0);
        vm.expectRevert(LaunchpadFactory.UnknownLaunch.selector);
        factory.swap(key, createSwapParameters(SqrtRatio.wrap(0), int128(1e18), true, 0), 0, block.timestamp);
        vm.expectRevert(LaunchpadFactory.UnknownLaunch.selector);
        factory.claim(key);
    }

    function testFuzz_claimBeforeMigrationSkipsUnregisteredTerminal(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        _buy(key, 10_000e18, 1);
        assertEq(vault.getTerminal(key.toPoolId()).owner, address(0));
        (uint128 fee0, uint128 fee1) =
            core.savedBalances(address(extension), key.token0, key.token1, extension.creatorFeeSalt(key.toPoolId()));
        (uint256 total0, uint256 total1) = _claimAndCheckSplit(key, CREATOR_BPS);
        assertEq(total0, fee0);
        assertEq(total1, fee1);
        assertGt(tokenIs0 ? total0 : total1, 0);
        // Nothing left to claim: a second claim moves nothing.
        (total0, total1) = _claimAndCheckSplit(key, CREATOR_BPS);
        assertEq(total0 + total1, 0);
    }

    function testFuzz_claimAfterMigrationSplitsBothLedgers(bool tokenIs0, uint16 creatorBps) public {
        creatorBps = uint16(bound(creatorBps, 0, 10_000));
        factory.setTier(2, true, creatorBps);
        vm.prank(creator);
        PoolKey memory key = factory.create(_config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE), 2);
        MintableERC20(_token(key)).approve(address(factory), type(uint256).max);
        vm.warp(START + 100);
        _buy(key, 10_000e18, 1);
        _finish(key);
        assertEq(vault.getTerminal(key.toPoolId()).owner, address(factory));
        PoolKey memory terminal = extension.terminalPool(key);
        // Sell quote on the terminal pool to earn fees for the locked position.
        router.swapAllowPartialFill(terminal, tokenIs0, int128(100e18), SqrtRatio.wrap(0), 0);
        (uint256 total0, uint256 total1) = _claimAndCheckSplit(key, creatorBps);
        // Launch-phase fees are in the launch token; terminal fees are in the quote sold above.
        assertGt(total0, 0);
        assertGt(total1, 0);
        assertEq(vault.getTerminal(key.toPoolId()).owner, address(factory));
        // Principal stays locked and the creator cannot bypass the factory.
        assertGt(core.poolPositions(terminal.toPoolId(), address(vault), vault.positionId(key.toPoolId())).liquidity, 0);
        vm.prank(creator);
        vm.expectRevert(ScheduledLaunch.OwnerOnly.selector);
        extension.claimFees(key, creator);
        vm.prank(creator);
        vm.expectRevert(LockedLaunchLiquidity.OwnerOnly.selector);
        vault.claimFees(key.toPoolId(), creator);
    }

    function testFuzz_allocatorReceivesSplitRemainder(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        _buy(key, 10_000e18, 1);
        (uint256 total0, uint256 total1) = _claimAndCheckSplit(key, CREATOR_BPS);
        address token = _token(key);
        uint256 total = tokenIs0 ? total0 : total1;
        assertEq(allocator.pending(token), total - total * CREATOR_BPS / 10_000);
        allocator.allocate(token);
        assertEq(allocator.pending(token), 0);
        assertEq(treasury.ledger(token, TreasuryVault.Category.UNRESTRICTED), allocator.totals(token).treasury);
    }

    function test_lockCallbackRejectsUnknownActionAndForeignCaller() public {
        bytes memory payload = abi.encodePacked(BaseLocker.locked_6416899205.selector, uint256(0), abi.encode(uint8(7)));
        vm.prank(address(core));
        vm.expectRevert(LaunchpadFactory.InvalidAction.selector);
        (bool success,) = address(factory).call(payload);
        assertTrue(success);
        vm.expectRevert(BaseLocker.BaseLockerAccountantOnly.selector);
        factory.locked_6416899205(0);
    }
}
