// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {STONXDeployment} from "../script/DeploySTONX.s.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {BaseNonfungibleToken} from "../src/base/BaseNonfungibleToken.sol";
import {Ve33, VE33_STAKE_TOKEN_SAVED_BALANCE_ID} from "../src/extensions/Ve33.sol";
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
import {Ve33EmissionRateConfig} from "../src/types/ve33EmissionRateConfig.sol";
import {VePoolSwapFeeState} from "../src/types/vePoolSwapFeeState.sol";

contract DeploySTONXTest is FullTest {
    using CoreLib for *;
    using Ve33Lib for Ve33;

    uint128 private constant STONX_AMOUNT = 333_333e18;
    uint128 private constant USDG_AMOUNT = 333_333e6;
    int32 private constant POSITION_TICK_LOWER = -88_722_432;
    int32 private constant POSITION_TICK_UPPER = 88_722_432;
    uint64 private constant SWAP_FEE = uint64((uint256(type(uint64).max) * 30) / 10_000);
    uint128 private constant INITIAL_EMISSION_AMOUNT = 333_333e18;
    uint32 private constant INITIAL_EMISSION_DURATION = 100 days;
    uint128 private constant SCHEDULER_DAILY_EMISSION_AMOUNT = 333_333e15;
    uint160 private constant SCHEDULER_EMISSION_RATE =
        uint160((uint256(SCHEDULER_DAILY_EMISSION_AMOUNT) << 32) / 1 days);

    STONXDeployment private deployment;
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
    }

    function test_initializeWhenSTONXIsToken0() public {
        _testInitialize(address(type(uint160).max - 1));
    }

    function test_initializeWhenSTONXIsToken1() public {
        _testInitialize(address(0x10000));
    }

    function _testInitialize(address usdgAddress) private {
        deployCodeTo("MintableERC20.sol:MintableERC20", abi.encode(address(this), "USDG", "USDG"), usdgAddress);
        MintableERC20 usdg = MintableERC20(usdgAddress);
        usdg.mint(address(this), USDG_AMOUNT);

        deployment = new STONXDeployment(core, usdgAddress, address(this), owner, bytes32(0), bytes32(0));
        stonx = deployment.deployStakeToken(
            abi.encodePacked(
                type(MintableERC20).creationCode,
                abi.encode(address(deployment), "Ekubo Stock Liquidity Token", "STONX")
            )
        );
        ve33 = deployment.deployVe33(abi.encodePacked(type(Ve33).creationCode, abi.encode(core, stonx)));
        metadata = deployment.deployVeTokenMetadata(
            abi.encodePacked(
                type(VeTokenMetadata).creationCode,
                abi.encode("Ekubo Stock Liquidity Token", "STONX", uint8(18), address(stonx))
            )
        );
        veToken = deployment.deployVeToken(
            abi.encodePacked(
                type(VeToken).creationCode, abi.encode(core, ve33, metadata, "Vote-Escrow STONX", "veSTONX")
            )
        );
        ve33Positions = deployment.deployPositions(
            abi.encodePacked(type(Ve33Positions).creationCode, abi.encode(core, ve33, address(deployment)))
        );
        periphery =
            deployment.deployPeriphery(abi.encodePacked(type(Ve33Periphery).creationCode, abi.encode(core, ve33)));
        dataFetcher =
            deployment.deployDataFetcher(abi.encodePacked(type(Ve33DataFetcher).creationCode, abi.encode(ve33)));
        scheduler = deployment.deployScheduler(
            abi.encodePacked(type(Ve33EmissionRateScheduler).creationCode, abi.encode(address(deployment), core, ve33))
        );

        usdg.approve(address(deployment), USDG_AMOUNT);
        uint256 positionId = deployment.initializeLiquidity();
        uint256 veId = deployment.initializeVe33Incentives();
        uint128 scheduledAmount = deployment.initializeEmissions();
        PoolKey memory poolKey = deployment.poolKey();
        PoolId poolId = poolKey.toPoolId();

        _assertStoredDeployment(positionId, veId, scheduledAmount);

        _assertDeploymentOwnership(positionId, veId);
        _assertPositionAndPoolState(poolKey, poolId, positionId, usdg);
        _assertStakeAndVoteState(poolId, veId);
        _assertEmissionState(scheduledAmount);
        _assertSchedulerInitiallyNoops();
        _assertEmissionsReachPosition(poolKey, positionId);
    }

    function _assertStoredDeployment(uint256 positionId, uint256 veId, uint128 scheduledAmount) private {
        assertEq(address(deployment.stonx()), address(stonx));
        assertEq(address(deployment.ve33()), address(ve33));
        assertEq(address(deployment.metadata()), address(metadata));
        assertEq(address(deployment.veToken()), address(veToken));
        assertEq(address(deployment.positions()), address(ve33Positions));
        assertEq(address(deployment.periphery()), address(periphery));
        assertEq(address(deployment.dataFetcher()), address(dataFetcher));
        assertEq(address(deployment.scheduler()), address(scheduler));
        assertEq(deployment.positionId(), positionId);
        assertEq(deployment.veId(), veId);
        assertEq(deployment.scheduledAmount(), scheduledAmount);
        assertTrue(deployment.liquidityInitialized());
        assertTrue(deployment.incentivesInitialized());
        assertTrue(deployment.emissionsInitialized());

        assertEq(address(deployment.deployStakeToken(bytes(""))), address(stonx));
        assertEq(address(deployment.deployVe33(bytes(""))), address(ve33));
        assertEq(deployment.initializeLiquidity(), positionId);
        assertEq(deployment.initializeVe33Incentives(), veId);
        assertEq(deployment.initializeEmissions(), scheduledAmount);
    }

    function _assertDeploymentOwnership(uint256 positionId, uint256 veId) private view {
        assertEq(positionId, ve33Positions.saltToId(address(deployment), bytes32(0)));
        assertEq(veId, veToken.saltToId(address(deployment), bytes32(0)));
        assertEq(stonx.owner(), address(scheduler));
        assertEq(scheduler.owner(), owner);
        assertEq(ve33Positions.owner(), owner);
        assertEq(ve33Positions.ownerOf(positionId), owner);
        assertEq(veToken.ownerOf(veId), address(this));

        assertEq(address(veToken.ve33()), address(ve33));
        assertEq(address(veToken.metadata()), address(metadata));
        assertEq(address(ve33Positions.ve33()), address(ve33));
        assertEq(address(periphery.ve33()), address(ve33));
        assertEq(address(dataFetcher.VE33_EXTENSION()), address(ve33));
        assertEq(address(scheduler.ve33()), address(ve33));
        assertEq(address(scheduler.core()), address(core));
        assertEq(address(scheduler.token()), address(stonx));
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
        assertEq(usdg.balanceOf(address(deployment)), 0);
        assertLe(stonx.balanceOf(address(deployment)), STONX_AMOUNT);
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

    function _assertEmissionState(uint128 scheduledAmount) private view {
        Ve33EmissionRateConfig config = scheduler.config();
        (uint64 emissionEnd, int256 rateDelta) = ve33.nextEmissionRateChangeTime(block.timestamp);
        uint160 initialEmissionRate = ve33.emissionRate();
        (uint128 savedStakeAndEmissions,) = core.savedBalances(
            address(ve33), address(stonx), address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID
        );

        assertEq(scheduledAmount, INITIAL_EMISSION_AMOUNT);
        assertEq(savedStakeAndEmissions, STONX_AMOUNT + scheduledAmount);
        assertEq(config.targetRate(), SCHEDULER_EMISSION_RATE);
        assertEq(config.scheduleDuration(), 3 days);
        assertGe(emissionEnd, block.timestamp + INITIAL_EMISSION_DURATION);
        assertEq(
            initialEmissionRate, uint160((uint256(INITIAL_EMISSION_AMOUNT) << 32) / (emissionEnd - block.timestamp))
        );
        assertEq(rateDelta, -int256(uint256(initialEmissionRate)));
        assertApproxEqAbs((uint256(SCHEDULER_EMISSION_RATE) * 1 days) >> 32, SCHEDULER_DAILY_EMISSION_AMOUNT, 1);
        assertEq(stonx.totalSupply(), uint256(STONX_AMOUNT) * 2 + scheduledAmount);
    }

    function _assertSchedulerInitiallyNoops() private {
        uint256 initialTimestamp = block.timestamp;
        uint256 initialSupply = stonx.totalSupply();
        (uint64 initialEmissionEnd,) = ve33.nextEmissionRateChangeTime(initialTimestamp);
        uint160 initialEmissionRate = ve33.emissionRate();

        assertEq(scheduler.mintAndSchedule(), 0);

        vm.warp(initialTimestamp + INITIAL_EMISSION_DURATION - 3 days);
        assertEq(scheduler.mintAndSchedule(), 0);
        assertEq(stonx.totalSupply(), initialSupply);
        assertEq(ve33.emissionRate(), initialEmissionRate);

        vm.warp(initialEmissionEnd);
        ve33.accrueEmissions();
        assertEq(ve33.emissionRate(), 0);

        assertGt(scheduler.mintAndSchedule(), 0);
        assertEq(ve33.emissionRate(), SCHEDULER_EMISSION_RATE);
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
