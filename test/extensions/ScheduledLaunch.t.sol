// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "../FullTest.sol";
import {TestToken} from "../TestToken.sol";
import {ScheduledLaunch, scheduledLaunchCallPoints} from "../../src/extensions/ScheduledLaunch.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {BaseLocker} from "../../src/base/BaseLocker.sol";
import {BaseForwardee} from "../../src/base/BaseForwardee.sol";
import {UsesCore} from "../../src/base/UsesCore.sol";
import {ICore} from "../../src/interfaces/ICore.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../../src/libraries/FlashAccountantLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {createConcentratedPoolConfig} from "../../src/types/poolConfig.sol";
import {PositionId, createPositionId, BoundsTickSpacing} from "../../src/types/positionId.sol";
import {Locker} from "../../src/types/locker.sol";
import {SwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../../src/math/ticks.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @dev A forwarding locker pays optional quote funding in the same atomic lock.
contract LaunchCreator is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function create(ScheduledLaunch extension, ScheduledLaunch.LaunchConfig memory config)
        external
        payable
        returns (PoolKey memory)
    {
        return abi.decode(lock(abi.encode(extension, config, msg.sender)), (PoolKey));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        (ScheduledLaunch extension, ScheduledLaunch.LaunchConfig memory config, address payer) =
            abi.decode(data, (ScheduledLaunch, ScheduledLaunch.LaunchConfig, address));
        result = ACCOUNTANT.forward(address(extension), abi.encode(config));
        if (config.quoteAmount != 0) {
            if (config.quoteToken == address(0)) {
                SafeTransferLib.safeTransferETH(address(ACCOUNTANT), config.quoteAmount);
            } else {
                ACCOUNTANT.payFrom(payer, config.quoteToken, config.quoteAmount);
            }
        }
    }
}

contract CapacityLP is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(core) {}

    function fill(PoolKey memory key, PositionId positionId, uint128 liquidity) external {
        lock(abi.encode(key, positionId, liquidity, msg.sender));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (PoolKey memory key, PositionId positionId, uint128 liquidity, address payer) =
            abi.decode(data, (PoolKey, PositionId, uint128, address));
        PoolBalanceUpdate update =
            ICore(payable(address(ACCOUNTANT))).updatePosition(key, positionId, int128(liquidity));
        if (update.delta0() != 0) ACCOUNTANT.payFrom(payer, key.token0, uint128(update.delta0()));
        if (update.delta1() != 0) ACCOUNTANT.payFrom(payer, key.token1, uint128(update.delta1()));
        return "";
    }
}

contract ScheduledLaunchTest is FullTest {
    using CoreLib for *;

    ScheduledLaunch extension;
    LaunchCreator creator;
    address constant LOW_QUOTE = address(0x10000);
    address constant HIGH_QUOTE = address(type(uint160).max);
    uint128 constant SUPPLY = 1_000_000e18;
    uint64 constant START = 100;
    uint64 constant END = 1100;

    function setUp() public override {
        super.setUp();
        vm.warp(1);
        address target = address(uint160(scheduledLaunchCallPoints().toUint8()) << 152);
        deployCodeTo("ScheduledLaunch.sol", abi.encode(core), target);
        extension = ScheduledLaunch(target);
        creator = new LaunchCreator(core);
        deployCodeTo("TestToken.sol", abi.encode(address(this)), LOW_QUOTE);
        deployCodeTo("TestToken.sol", abi.encode(address(this)), HIGH_QUOTE);
        TestToken(LOW_QUOTE).approve(address(creator), type(uint256).max);
        TestToken(HIGH_QUOTE).approve(address(creator), type(uint256).max);
        TestToken(LOW_QUOTE).approve(address(router), type(uint256).max);
        TestToken(HIGH_QUOTE).approve(address(router), type(uint256).max);
    }

    function _config(address quote) internal view returns (ScheduledLaunch.LaunchConfig memory) {
        return ScheduledLaunch.LaunchConfig({
            owner: address(this),
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
            fee: 0
        });
    }

    function _create(bool tokenIs0) internal returns (PoolKey memory key) {
        key = creator.create(extension, _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE));
        assertEq(extension.getLaunch(key.toPoolId()).token == key.token0, tokenIs0);
    }

    function _quoteReserve(PoolKey memory key) internal view returns (uint128) {
        (uint128 r0, uint128 r1) =
            core.savedBalances(address(extension), key.token0, key.token1, PoolId.unwrap(key.toPoolId()));
        return extension.getLaunch(key.toPoolId()).token == key.token0 ? r1 : r0;
    }

    function _buy(PoolKey memory key, uint128 amount) internal returns (uint128 bought) {
        bool quoteIs1 = extension.getLaunch(key.toPoolId()).token == key.token0;
        PoolBalanceUpdate update = router.swapAllowPartialFill(key, quoteIs1, int128(amount), SqrtRatio.wrap(0), 0);
        bought = uint128(-(quoteIs1 ? update.delta0() : update.delta1()));
    }

    function testFuzz_createMetadataOwnerAndFunding(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
        MintableERC20 token = MintableERC20(launch.token);
        assertEq(launch.owner, address(this));
        assertEq(token.owner(), address(0));
        assertEq(token.name(), "Launch");
        assertEq(token.symbol(), "LAUNCH");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(core)), SUPPLY);
        assertEq(token.balanceOf(address(extension)), 0);
        assertEq(core.poolState(key.toPoolId()).tick(), 0);
        vm.expectRevert(Ownable.Unauthorized.selector);
        token.mint(address(this), 1);
    }

    function test_directInitializationAndForgedCallbacksRevert() public {
        PoolKey memory key = PoolKey(LOW_QUOTE, HIGH_QUOTE, createConcentratedPoolConfig(0, 100, address(extension)));
        vm.expectRevert(ScheduledLaunch.InitializationThroughForwardOnly.selector);
        core.initializePool(key, 0);
        vm.expectRevert(BaseForwardee.BaseForwardeeAccountantOnly.selector);
        extension.forwarded_2374103877(Locker.wrap(bytes32(0)));
        vm.expectRevert(BaseLocker.BaseLockerAccountantOnly.selector);
        extension.locked_6416899205(0);
        vm.expectRevert(UsesCore.CoreOnly.selector);
        extension.beforeSwap(Locker.wrap(bytes32(0)), key, SwapParameters.wrap(bytes32(0)));
    }

    function testFuzz_linearReleaseAndNoBuyers(bool tokenIs0, uint64 elapsed) public {
        PoolKey memory key = _create(tokenIs0);
        elapsed = uint64(bound(elapsed, 0, END - START));
        vm.warp(START + elapsed);
        uint128 expected = uint128(uint256(SUPPLY) * elapsed / (END - START));
        assertEq(extension.released(key.toPoolId()), expected);
        extension.advance(key);
        ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
        assertLe(launch.deployed, expected);
        assertApproxEqAbs(launch.deployed, expected, 1);
        assertEq(_quoteReserve(key), 0);
        assertEq(launch.complete, elapsed == END - START);
        uint128 deployed = launch.deployed;
        extension.advance(key);
        assertEq(extension.getLaunch(key.toPoolId()).deployed, deployed);
    }

    function test_preStartSwapRevertsAndAdvanceDoesNotRelease() public {
        PoolKey memory key = _create(true);
        extension.advance(key);
        assertEq(extension.released(key.toPoolId()), 0);
        vm.expectRevert(ScheduledLaunch.LaunchNotStarted.selector);
        router.swapAllowPartialFill(key, true, 1e18, SqrtRatio.wrap(0), 0);
    }

    function testFuzz_sellTowardTargetAndRetainQuote(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        uint128 bought = _buy(key, 10_000e18);
        assertGt(bought, 0);
        assertTrue(core.poolState(key.toPoolId()).sqrtRatio() != tickToSqrtRatio(0));
        vm.warp(START + 200);
        extension.advance(key);
        assertEq(SqrtRatio.unwrap(core.poolState(key.toPoolId()).sqrtRatio()), SqrtRatio.unwrap(tickToSqrtRatio(0)));
        assertGt(_quoteReserve(key), 0);
        assertEq(extension.getLaunch(key.toPoolId()).complete, false);
        assertLe(extension.getLaunch(key.toPoolId()).deployed, SUPPLY / 5);
    }

    function testFuzz_insufficientReleasedInventory(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        _buy(key, 50_000e18);
        vm.warp(START + 101);
        extension.advance(key);
        ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
        assertLe(launch.deployed, extension.released(key.toPoolId()));
        assertTrue(core.poolState(key.toPoolId()).sqrtRatio() != tickToSqrtRatio(0));
        vm.warp(END);
        extension.advance(key);
        assertTrue(extension.getLaunch(key.toPoolId()).complete);
    }

    function testFuzz_sellerPushesBelowTargetThenReleaseStillWorks(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.warp(START + 100);
        uint128 bought = _buy(key, 10_000e18);
        vm.warp(START + 200);
        extension.advance(key);
        address launchToken = extension.getLaunch(key.toPoolId()).token;
        MintableERC20(launchToken).approve(address(router), type(uint256).max);
        int32 below = tokenIs0 ? int32(-1000) : int32(1000);
        router.swapAllowPartialFill(key, !tokenIs0, int128(bought), tickToSqrtRatio(below), 0);
        assertEq(SqrtRatio.unwrap(core.poolState(key.toPoolId()).sqrtRatio()), SqrtRatio.unwrap(tickToSqrtRatio(below)));
        uint128 quoteBefore = _quoteReserve(key);
        uint128 deployedBefore = extension.getLaunch(key.toPoolId()).deployed;
        vm.warp(START + 300);
        extension.advance(key);
        assertEq(_quoteReserve(key), quoteBefore);
        assertGt(extension.getLaunch(key.toPoolId()).deployed, deployedBefore);
        assertEq(SqrtRatio.unwrap(core.poolState(key.toPoolId()).sqrtRatio()), SqrtRatio.unwrap(tickToSqrtRatio(below)));
    }

    function testFuzz_ownerWithdrawalAndPostCompletionNoOp(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        vm.expectRevert(ScheduledLaunch.LaunchNotComplete.selector);
        extension.withdraw(key, address(this));
        vm.warp(END);
        extension.advance(key);
        vm.prank(address(123));
        vm.expectRevert(ScheduledLaunch.OwnerOnly.selector);
        extension.withdraw(key, address(this));
        vm.expectRevert(ScheduledLaunch.InvalidRecipient.selector);
        extension.withdraw(key, address(0));
        bytes32 beforeState = keccak256(abi.encode(extension.getLaunch(key.toPoolId())));
        _buy(key, 1e18);
        extension.advance(key);
        assertEq(keccak256(abi.encode(extension.getLaunch(key.toPoolId()))), beforeState);
        ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
        extension.withdraw(key, address(this));
        assertEq(core.poolPositions(key.toPoolId(), address(extension), launch.positionId).liquidity, 0);
        assertApproxEqAbs(MintableERC20(launch.token).balanceOf(address(this)), SUPPLY, 2);
        extension.withdraw(key, address(this));
    }

    function testFuzz_optionalQuoteSeedAndIsolation(bool tokenIs0) public {
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.quoteAmount = 123e18;
        PoolKey memory first = creator.create(extension, config);
        config.quoteAmount = 456e18;
        PoolKey memory second = creator.create(extension, config);
        assertEq(_quoteReserve(first), 123e18);
        assertEq(_quoteReserve(second), 456e18);
        vm.warp(END);
        extension.advance(first);
        extension.withdraw(first, address(555));
        assertEq(_quoteReserve(first), 0);
        assertEq(_quoteReserve(second), 456e18);
        assertEq(extension.getLaunch(second.toPoolId()).deployed, 0);
        assertEq(TestToken(config.quoteToken).balanceOf(address(555)), 123e18);
    }

    function test_nativeQuote() public {
        ScheduledLaunch.LaunchConfig memory config = _config(address(0));
        config.quoteAmount = 1 ether;
        vm.deal(address(this), 10 ether);
        PoolKey memory key = creator.create{value: 1 ether}(extension, config);
        assertEq(_quoteReserve(key), 1 ether);
        vm.warp(END);
        extension.advance(key);
        extension.withdraw(key, address(555));
        assertEq(address(555).balance, 1 ether);
    }

    function testFuzz_targetOrientation(bool tokenIs0, int32 targetTick) public {
        targetTick = int32(bound(targetTick, -100_000, 100_000) / 100 * 100);
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.targetTick = targetTick;
        config.upperTick = targetTick + 100_000;
        PoolKey memory key = creator.create(extension, config);
        ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
        assertEq(launch.targetTick, tokenIs0 ? targetTick : -targetTick);
        vm.warp(END);
        extension.advance(key);
        assertApproxEqAbs(extension.getLaunch(key.toPoolId()).deployed, SUPPLY, 1);
    }

    function test_invalidConfigurations() public {
        ScheduledLaunch.LaunchConfig memory config = _config(HIGH_QUOTE);
        config.owner = address(0);
        vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
        creator.create(extension, config);
        config = _config(HIGH_QUOTE);
        config.endTime = config.startTime;
        vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
        creator.create(extension, config);
        config = _config(HIGH_QUOTE);
        config.totalSupply = 0;
        vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
        creator.create(extension, config);
        config = _config(HIGH_QUOTE);
        config.upperTick = config.targetTick;
        vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
        creator.create(extension, config);
        config = _config(HIGH_QUOTE);
        config.tickSpacing = 0;
        vm.expectRevert(ScheduledLaunch.InvalidLaunch.selector);
        creator.create(extension, config);
        config = _config(HIGH_QUOTE);
        config.targetTick = 1;
        vm.expectRevert(BoundsTickSpacing.selector);
        creator.create(extension, config);
    }

    function testFuzz_supplyAndExtremeTicks(bool tokenIs0, uint128 supply, int32 target) public {
        supply = uint128(bound(supply, 1, uint128(type(int128).max)));
        target = int32(bound(target, -887228, 886228) * 100);
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.totalSupply = supply;
        config.targetTick = target;
        config.upperTick = target + 100_000;
        PoolKey memory key = creator.create(extension, config);
        vm.warp(END);
        extension.advance(key);
        ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
        assertTrue(launch.complete);
        assertLe(launch.deployed, supply);
        extension.withdraw(key, address(this));
        assertApproxEqAbs(MintableERC20(launch.token).balanceOf(address(this)), supply, 2);
    }

    function testFuzz_tradingSequencePreservesReleaseAccounting(bool tokenIs0, uint256 seed) public {
        PoolKey memory key = _create(tokenIs0);
        address launchToken = extension.getLaunch(key.toPoolId()).token;
        MintableERC20(launchToken).approve(address(router), type(uint256).max);
        for (uint256 i = 1; i <= 12; i++) {
            vm.warp(START + i * 90);
            seed = uint256(keccak256(abi.encode(seed, i)));
            if (seed % 2 == 0) {
                _buy(key, uint128(seed % 10_000e18));
            } else {
                uint128 balance = uint128(MintableERC20(launchToken).balanceOf(address(this)));
                router.swapAllowPartialFill(
                    key, !tokenIs0, int128(balance / 2), tickToSqrtRatio(tokenIs0 ? int32(-1000) : int32(1000)), 0
                );
            }
            extension.advance(key);
            ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
            assertLe(launch.deployed, extension.released(key.toPoolId()));
            (uint128 r0, uint128 r1) =
                core.savedBalances(address(extension), key.token0, key.token1, PoolId.unwrap(key.toPoolId()));
            assertEq(tokenIs0 ? r0 : r1, SUPPLY - launch.deployed);
        }
        assertTrue(extension.getLaunch(key.toPoolId()).complete);
        extension.withdraw(key, address(this));
        // Each swap/deposit rounds independently; bound accumulated dust across the 12 steps.
        assertApproxEqAbs(MintableERC20(launchToken).balanceOf(address(this)), SUPPLY, 40);
    }

    function testFuzz_nonzeroFeesRemainWithdrawable(bool tokenIs0) public {
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.fee = uint64(uint256(1 << 64) / 100);
        PoolKey memory key = creator.create(extension, config);
        vm.warp(START + 100);
        _buy(key, 10_000e18);
        vm.warp(END);
        extension.advance(key);
        _buy(key, 1e18);
        extension.withdraw(key, address(this));
        assertApproxEqAbs(MintableERC20(extension.getLaunch(key.toPoolId()).token).balanceOf(address(this)), SUPPLY, 4);
    }

    function testFuzz_thirdPartyTickCapacityDoesNotBlockCompletion(bool tokenIs0) public {
        PoolKey memory key = _create(tokenIs0);
        CapacityLP lp = new CapacityLP(core);
        TestToken(tokenIs0 ? key.token1 : key.token0).approve(address(lp), type(uint256).max);
        PositionId positionId =
            createPositionId(bytes24(0), tokenIs0 ? int32(-100_000) : int32(0), tokenIs0 ? int32(0) : int32(100_000));
        lp.fill(key, positionId, key.config.concentratedMaxLiquidityPerTick());
        vm.warp(END);
        extension.advance(key);
        ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
        assertTrue(launch.complete);
        assertEq(launch.deployed, 0);
        extension.withdraw(key, address(this));
        assertEq(MintableERC20(launch.token).balanceOf(address(this)), SUPPLY);
        assertEq(
            core.poolPositions(key.toPoolId(), address(lp), positionId).liquidity,
            key.config.concentratedMaxLiquidityPerTick()
        );
    }

    function test_deployWithMinedHookPrefix() public {
        bytes32 initHash = keccak256(abi.encodePacked(type(ScheduledLaunch).creationCode, abi.encode(core)));
        uint256 salt;
        uint8 prefix = scheduledLaunchCallPoints().toUint8();
        while (true) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(salt), initHash))))
            );
            if (uint8(uint160(predicted) >> 152) == prefix) break;
            salt++;
        }
        ScheduledLaunch deployed = new ScheduledLaunch{salt: bytes32(salt)}(core);
        assertTrue(core.isExtensionRegistered(address(deployed)));
        assertLe(address(deployed).code.length, 24_576);
        PoolKey memory key = creator.create(deployed, _config(HIGH_QUOTE));
        assertEq(deployed.getLaunch(key.toPoolId()).owner, address(this));
    }

    function testFuzz_largeQuoteAmountsDoNotBlockSales(bool tokenIs0) public {
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.targetTick = 50_000_000;
        config.upperTick = 50_100_000;
        PoolKey memory key = creator.create(extension, config);
        vm.warp(START + 100);
        _buy(key, uint128(type(int128).max));
        _buy(key, uint128(type(int128).max));
        vm.warp(START + 200);
        extension.advance(key);
        assertGt(_quoteReserve(key), 0);
        vm.warp(END);
        extension.advance(key);
        assertTrue(extension.getLaunch(key.toPoolId()).complete);
    }

    function testFuzz_largePrincipalWithdrawsInChunks(bool tokenIs0) public {
        ScheduledLaunch.LaunchConfig memory config = _config(tokenIs0 ? HIGH_QUOTE : LOW_QUOTE);
        config.targetTick = 50_000_000;
        config.upperTick = 50_100_000;
        PoolKey memory key = creator.create(extension, config);
        vm.warp(END);
        extension.advance(key);
        for (uint256 i = 0; i < 3; i++) {
            _buy(key, uint128(type(int128).max));
        }
        ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
        extension.withdraw(key, address(this));
        assertGt(core.poolPositions(key.toPoolId(), address(extension), launch.positionId).liquidity, 0);
        for (uint256 i = 0; i < 4; i++) {
            extension.withdraw(key, address(this));
        }
        assertEq(core.poolPositions(key.toPoolId(), address(extension), launch.positionId).liquidity, 0);
        assertApproxEqAbs(MintableERC20(launch.token).balanceOf(address(this)), SUPPLY, 6);
    }

    function test_unfundedSeedRollsBackDeployment() public {
        ScheduledLaunch.LaunchConfig memory config = _config(HIGH_QUOTE);
        config.quoteAmount = 1;
        TestToken(HIGH_QUOTE).approve(address(creator), 0);
        uint64 nonce = vm.getNonce(address(extension));
        address predicted = vm.computeCreateAddress(address(extension), nonce);
        vm.expectRevert();
        creator.create(extension, config);
        assertEq(predicted.code.length, 0);
        assertEq(vm.getNonce(address(extension)), nonce);
    }
}
