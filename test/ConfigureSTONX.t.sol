// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {ConfigureSTONX} from "../script/ConfigureSTONX.s.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {BaseNonfungibleToken} from "../src/base/BaseNonfungibleToken.sol";
import {Ve33, VE33_STAKE_TOKEN_SAVED_BALANCE_ID, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {Ve33Lib} from "../src/libraries/Ve33Lib.sol";
import {Ve33DataFetcher} from "../src/lens/Ve33DataFetcher.sol";
import {Ve33EmissionRateScheduler} from "../src/Ve33EmissionRateScheduler.sol";
import {Ve33Periphery} from "../src/Ve33Periphery.sol";
import {Ve33Positions} from "../src/Ve33Positions.sol";
import {VeToken} from "../src/VeToken.sol";
import {VeTokenMetadata} from "../src/VeTokenMetadata.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {ScheduledVe33EmissionRateConfig} from "../src/types/scheduledVe33EmissionRateConfig.sol";
import {Ve33EmissionRateConfig} from "../src/types/ve33EmissionRateConfig.sol";
import {VePoolSwapFeeState} from "../src/types/vePoolSwapFeeState.sol";

contract ConfigureSTONXHarness is ConfigureSTONX {
    function setPositionsMetadata(Ve33Positions positions) external {
        positions.setMetadata("Ekubo STONX Positions", "stonxPO", "https://prod-api.ekubo.org/positions/");
    }

    function initialize(
        MintableERC20 stonx,
        Ve33 ve33,
        VeToken veToken,
        Ve33Positions positions,
        ICore core,
        address usdg,
        address governance
    ) external returns (PoolKey memory poolKey, uint256 positionId, uint256 veId) {
        poolKey = _stonxPoolKey(address(stonx), usdg, address(ve33));
        positionId = _seedLiquidity(stonx, positions, poolKey, usdg, address(this), governance, bytes32(0));
        veId = _stakeAndVote(stonx, veToken, core, poolKey, address(this), bytes32(0));
        positions.transferOwnership(governance);
    }

    function configureScheduler(Ve33EmissionRateScheduler scheduler, address governance)
        external
        returns (uint64 emissionStart, uint64 emissionEnd)
    {
        (emissionStart, emissionEnd) = _initialEmissionTimes();
        _configureScheduler(scheduler, governance, emissionStart, emissionEnd);
    }
}

/// @notice Tests the post-deployment STONX configuration flow.
contract ConfigureSTONXTest is FullTest {
    using CoreLib for *;
    using Ve33Lib for Ve33;

    uint128 private constant STONX_AMOUNT = 333_333e18;
    uint128 private constant USDG_AMOUNT = 333_333e6;
    int32 private constant POSITION_TICK_LOWER = -88_722_432;
    int32 private constant POSITION_TICK_UPPER = 88_722_432;
    uint64 private constant SWAP_FEE = 0;
    uint128 private constant INITIAL_EMISSION_AMOUNT = 333_333e18;
    uint128 private constant INITIAL_DAILY_EMISSION_AMOUNT = 333_333e16;
    uint64 private constant INITIAL_EMISSION_START = 1_785_513_600;
    uint64 private constant INITIAL_EMISSION_END = 1_794_153_600;
    uint32 private constant INITIAL_EMISSION_DURATION = 100 days;
    uint160 private constant INITIAL_EMISSION_RATE =
        uint160(((uint256(INITIAL_DAILY_EMISSION_AMOUNT) << 32) + 1 days - 1) / 1 days);
    uint32 private constant EMISSION_SCHEDULE_DURATION = 1 weeks;
    uint128 private constant SCHEDULER_DAILY_EMISSION_AMOUNT = 333_333e15;
    uint160 private constant SCHEDULER_EMISSION_RATE =
        uint160(((uint256(SCHEDULER_DAILY_EMISSION_AMOUNT) << 32) + 1 days - 1) / 1 days);

    ConfigureSTONXHarness private deployer;
    MintableERC20 private stonx;
    Ve33 private ve33;
    VeTokenMetadata private metadata;
    VeToken private veToken;
    Ve33Positions private ve33Positions;
    Ve33Periphery private periphery;
    Ve33DataFetcher private dataFetcher;
    Ve33EmissionRateScheduler private scheduler;

    function setUp() public override {
        super.setUp();

        deployer = new ConfigureSTONXHarness();
        stonx = new MintableERC20(address(this), "Ekubo Stock Liquidity Token", "STONX", 18);
        address ve33Address = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol:Ve33", abi.encode(core, stonx), ve33Address);
        ve33 = Ve33(payable(ve33Address));

        metadata = new VeTokenMetadata("Ekubo Stock Liquidity Token", "STONX", 18, address(stonx));
        veToken = new VeToken(core, ve33, metadata, "Vote-Escrow STONX", "veSTONX");
        ve33Positions = new Ve33Positions(core, ve33, address(deployer));
        deployer.setPositionsMetadata(ve33Positions);
        periphery = new Ve33Periphery(core, ve33);
        dataFetcher = new Ve33DataFetcher(core, ve33);
        scheduler = new Ve33EmissionRateScheduler(address(deployer), core, ve33);

        stonx.mint(address(deployer), STONX_AMOUNT * 3);
        stonx.transferOwnership(address(deployer));
    }

    function test_initializeWhenSTONXIsToken0() public {
        this.assertInitialize(address(type(uint160).max - 1));
    }

    function test_initializeWhenSTONXIsToken1() public {
        this.assertInitialize(address(0x10000));
    }

    function test_initialTickFor18DecimalSTONXAnd6DecimalUSDG() public view {
        assertEq(deployer.initialTick(address(1), 18, address(2), 6), -27_631_034);
        assertEq(deployer.initialTick(address(2), 18, address(1), 6), 27_631_034);
    }

    function testFuzz_initialTickTracksOneToOneHumanPrice(uint8 stonxDecimals, uint8 usdgDecimals, bool stonxIsToken0)
        public
        view
    {
        stonxDecimals = uint8(bound(stonxDecimals, 0, 38));
        usdgDecimals = uint8(bound(usdgDecimals, 0, 38));

        address stonxAddress = stonxIsToken0 ? address(1) : address(2);
        address usdgAddress = stonxIsToken0 ? address(2) : address(1);
        int32 tick = deployer.initialTick(stonxAddress, stonxDecimals, usdgAddress, usdgDecimals);

        int256 decimals0 = int256(uint256(stonxIsToken0 ? stonxDecimals : usdgDecimals));
        int256 decimals1 = int256(uint256(stonxIsToken0 ? usdgDecimals : stonxDecimals));
        int256 approximateOneToOneTick = (decimals1 - decimals0) * 2_302_586;
        assertApproxEqAbs(int256(tick), approximateOneToOneTick, 11);
    }

    function test_initialTickRejectsUnsupportedDecimalDifference() public {
        vm.expectRevert(abi.encodeWithSelector(ConfigureSTONX.UnsupportedDecimalDifference.selector, 39));
        deployer.initialTick(address(1), 39, address(2), 0);
    }

    function assertInitialize(address usdgAddress) external {
        vm.warp(INITIAL_EMISSION_START - 1 days);

        deployCodeTo("MintableERC20.sol:MintableERC20", abi.encode(address(this), "USDG", "USDG", 6), usdgAddress);
        MintableERC20 usdg = MintableERC20(usdgAddress);
        assertEq(usdg.decimals(), 6);
        usdg.mint(address(deployer), USDG_AMOUNT);

        uint256 positionId;
        uint256 veId;
        uint64 emissionStart;
        uint64 emissionEnd;
        PoolKey memory poolKey;
        (poolKey, positionId, veId) = deployer.initialize(stonx, ve33, veToken, ve33Positions, core, usdgAddress, owner);
        (emissionStart, emissionEnd) = deployer.configureScheduler(scheduler, owner);
        PoolId poolId = poolKey.toPoolId();

        _assertDeploymentOwnership(positionId, veId);
        _assertPositionAndPoolState(poolKey, poolId, positionId, usdg);
        _assertStakeAndVoteState(poolId, veId);
        _assertEmissionConfig(emissionStart, emissionEnd);
        _scheduleInitialEmissions(emissionStart, emissionEnd);
        _assertEmissionsReachPosition(poolKey, positionId);
    }

    function _assertDeploymentOwnership(uint256 positionId, uint256 veId) private view {
        assertEq(positionId, ve33Positions.saltToId(address(deployer), bytes32(0)));
        assertEq(veId, veToken.saltToId(address(deployer), bytes32(0)));
        assertEq(stonx.owner(), address(deployer));
        assertEq(scheduler.owner(), owner);
        assertEq(ve33Positions.owner(), owner);
        assertEq(ve33Positions.ownerOf(positionId), owner);
        assertEq(veToken.ownerOf(veId), address(deployer));

        assertEq(address(veToken.ve33()), address(ve33));
        assertEq(address(veToken.metadata()), address(metadata));
        assertEq(address(ve33Positions.ve33()), address(ve33));
        assertEq(address(periphery.ve33()), address(ve33));
        assertEq(address(dataFetcher.VE33_EXTENSION()), address(ve33));
        assertEq(address(scheduler.ve33()), address(ve33));
        assertEq(address(scheduler.core()), address(core));
        assertEq(scheduler.stakeToken(), address(stonx));
        assertEq(veToken.stakeToken(), address(stonx));
        assertEq(ve33Positions.stakeToken(), address(stonx));
        assertEq(periphery.stakeToken(), address(stonx));

        assertEq(stonx.name(), "Ekubo Stock Liquidity Token");
        assertEq(stonx.symbol(), "STONX");
        assertEq(stonx.decimals(), 18);
        assertEq(veToken.name(), "Vote-Escrow STONX");
        assertEq(veToken.symbol(), "veSTONX");
        assertEq(ve33Positions.name(), "Ekubo STONX Positions");
        assertEq(ve33Positions.symbol(), "stonxPO");
        assertEq(ve33Positions.baseUrl(), "https://prod-api.ekubo.org/positions/");
    }

    function _assertPositionAndPoolState(PoolKey memory poolKey, PoolId poolId, uint256 positionId, MintableERC20 usdg)
        private
        view
    {
        (uint128 positionLiquidity,,) =
            ve33Positions.getPositionLiquidity(positionId, poolKey, POSITION_TICK_LOWER, POSITION_TICK_UPPER);

        assertGt(positionLiquidity, 0);
        assertGt(core.poolState(poolId).liquidity(), 0);
        assertEq(usdg.balanceOf(address(deployer)), 0);
        assertLe(stonx.balanceOf(address(deployer)), STONX_AMOUNT);
    }

    function _assertStakeAndVoteState(PoolId poolId, uint256 veId) private view {
        (uint128 stakeAmount, uint64 stakeEndTime) = veToken.stakes(veId);
        (PoolId votedPoolId, uint128 voteWeight, uint64 votedSwapFee, uint128 claimable0, uint128 claimable1) =
            veToken.voteState(veId);
        VePoolSwapFeeState poolVoteState = ve33.poolSwapFeeState(poolId);

        assertEq(stakeAmount, STONX_AMOUNT);
        assertEq(stakeEndTime, block.timestamp + veToken.MAX_STAKE_DURATION());
        assertEq(PoolId.unwrap(votedPoolId), PoolId.unwrap(poolId));
        assertEq(voteWeight, STONX_AMOUNT);
        assertEq(votedSwapFee, SWAP_FEE);
        assertEq(claimable0, 0);
        assertEq(claimable1, 0);
        assertEq(poolVoteState.totalWeight(), STONX_AMOUNT);
        assertEq(poolVoteState.swapFee(), SWAP_FEE);
        assertEq(ve33.poolFeeWeightSum(poolId), uint192(uint256(STONX_AMOUNT) * SWAP_FEE));
        assertEq(ve33.totalVoteWeight(), STONX_AMOUNT);
    }

    function _assertEmissionConfig(uint64 emissionStart, uint64 emissionEnd) private view {
        Ve33EmissionRateConfig config = scheduler.config().emissionRateConfig();
        (uint128 savedStakeAndEmissions,) = core.savedBalances(
            address(ve33), address(stonx), address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID
        );
        (uint64 nextVe33EmissionTime, int256 nextVe33RateDelta) = ve33.nextEmissionRateChangeTime(block.timestamp);
        ScheduledVe33EmissionRateConfig initialScheduledConfig = scheduler.scheduledConfigs(emissionStart);
        ScheduledVe33EmissionRateConfig ongoingScheduledConfig = scheduler.scheduledConfigs(emissionEnd);

        assertEq(emissionStart, INITIAL_EMISSION_START);
        assertEq(emissionEnd, INITIAL_EMISSION_END);
        assertEq(emissionEnd - emissionStart, INITIAL_EMISSION_DURATION);
        assertEq(savedStakeAndEmissions, STONX_AMOUNT);
        assertEq(config.minEmissionsRate(), INITIAL_EMISSION_RATE);
        assertEq(config.scheduleDuration(), EMISSION_SCHEDULE_DURATION);
        assertEq(scheduler.config().nextConfigTime(), emissionEnd);
        assertEq(scheduler.lastScheduledTime(), emissionStart);
        assertGe(scheduler.emissionEnd(), emissionStart);
        assertEq(initialScheduledConfig.emissionRateConfig().minEmissionsRate(), 0);
        assertEq(initialScheduledConfig.emissionRateConfig().scheduleDuration(), 0);
        assertEq(initialScheduledConfig.nextConfigTime(), 0);
        assertEq(ongoingScheduledConfig.emissionRateConfig().minEmissionsRate(), SCHEDULER_EMISSION_RATE);
        assertEq(ongoingScheduledConfig.emissionRateConfig().scheduleDuration(), EMISSION_SCHEDULE_DURATION);
        assertEq(ongoingScheduledConfig.nextConfigTime(), 0);
        assertEq(ve33.emissionRate(), 0);
        assertEq(nextVe33EmissionTime, 0);
        assertEq(nextVe33RateDelta, 0);
        assertEq((uint256(INITIAL_EMISSION_DURATION) * INITIAL_EMISSION_RATE) >> 32, INITIAL_EMISSION_AMOUNT);
        assertEq((uint256(1 days) * INITIAL_EMISSION_RATE) >> 32, INITIAL_DAILY_EMISSION_AMOUNT);
        assertEq((uint256(1 days) * SCHEDULER_EMISSION_RATE) >> 32, SCHEDULER_DAILY_EMISSION_AMOUNT);
        assertEq(stonx.balanceOf(address(scheduler)), INITIAL_EMISSION_AMOUNT);
        assertEq(stonx.totalSupply(), uint256(STONX_AMOUNT) * 3);
    }

    function _scheduleInitialEmissions(uint64 emissionStart, uint64 emissionEnd) private {
        vm.warp(emissionStart);
        uint256 totalPaid = scheduler.scheduleEmissions();
        for (uint256 week = 1; week < 14; week++) {
            vm.warp(emissionStart + week * 1 weeks);
            totalPaid += scheduler.scheduleEmissions();
        }

        vm.warp(emissionStart + 14 weeks);
        totalPaid += scheduler.scheduleEmissions();

        (uint128 savedStakeAndEmissions,) = core.savedBalances(
            address(ve33), address(stonx), address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID
        );

        assertEq(totalPaid, INITIAL_EMISSION_AMOUNT);
        assertEq(stonx.balanceOf(address(scheduler)), 0);
        assertEq(stonx.totalSupply(), uint256(STONX_AMOUNT) * 3);
        assertEq(stonx.owner(), address(deployer));
        assertEq(savedStakeAndEmissions, STONX_AMOUNT + INITIAL_EMISSION_AMOUNT);
        assertEq(scheduler.lastScheduledTime(), emissionEnd);
        assertEq(scheduler.config().emissionRateConfig().minEmissionsRate(), SCHEDULER_EMISSION_RATE);
        assertEq(scheduler.config().nextConfigTime(), 0);
        assertEq(scheduler.rateRemainder(), 0);
        assertLe(scheduler.emissionEnd(), emissionEnd);
    }

    function _assertEmissionsReachPosition(PoolKey memory poolKey, uint256 positionId) private {
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(
            abi.encodeWithSelector(BaseNonfungibleToken.NotUnauthorizedForToken.selector, address(this), positionId)
        );
        ve33Positions.claimRewards(positionId, poolKey, POSITION_TICK_LOWER, POSITION_TICK_UPPER, address(this));

        // Governance owns the position NFT and is the only initially authorized reward claimant.
        vm.prank(owner);
        uint256 claimed =
            ve33Positions.claimRewards(positionId, poolKey, POSITION_TICK_LOWER, POSITION_TICK_UPPER, owner);

        assertGt(claimed, 0);
        assertEq(stonx.balanceOf(owner), claimed);
    }
}
