// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {FullTest} from "./FullTest.sol";
import {DeploySTONX} from "../script/DeploySTONX.s.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {BaseNonfungibleToken} from "../src/base/BaseNonfungibleToken.sol";
import {Ve33, ve33CallPoints} from "../src/extensions/Ve33.sol";
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
import {Ve33EmissionRateConfig} from "../src/types/ve33EmissionRateConfig.sol";
import {VePoolSwapFeeState} from "../src/types/vePoolSwapFeeState.sol";

contract DeploySTONXHarness is DeploySTONX {
    function setPositionsMetadata(Ve33Positions positions) external {
        positions.setMetadata("Ekubo STONX Positions", "stonxPO", "https://prod-api.ekubo.org/positions/");
    }

    function initialize(
        MintableERC20 stonx,
        Ve33 ve33,
        VeToken veToken,
        Ve33Positions positions,
        Ve33EmissionRateScheduler scheduler,
        ICore core,
        address usdg,
        address governance
    ) external returns (PoolKey memory poolKey, uint256 positionId, uint256 veId, uint128 scheduledAmount) {
        poolKey = _stonxPoolKey(address(stonx), usdg, address(ve33));
        positionId = _seedLiquidity(stonx, positions, poolKey, usdg, address(this), governance, bytes32(0));
        veId = _stakeAndVote(stonx, veToken, core, poolKey, bytes32(0));
        positions.transferOwnership(governance);
        scheduledAmount = _configureAndStartScheduler(stonx, scheduler, governance);
    }
}

contract DeploySTONXTest is FullTest {
    using CoreLib for *;
    using Ve33Lib for Ve33;

    uint128 private constant STONX_AMOUNT = 333_333e18;
    uint128 private constant USDG_AMOUNT = 333_333e6;
    int32 private constant POSITION_TICK_LOWER = -88_722_432;
    int32 private constant POSITION_TICK_UPPER = 88_722_432;
    uint64 private constant SWAP_FEE = uint64((uint256(type(uint64).max) * 30) / 10_000);
    uint160 private constant EMISSION_RATE = uint160(uint256(333_333e15) * (1 << 32) / 1 days);

    DeploySTONXHarness private deployer;
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

        deployer = new DeploySTONXHarness();
        stonx = new MintableERC20(address(this), "Ekubo Stock Liquidity Token", "STONX");
        address ve33Address = address(uint160(ve33CallPoints().toUint8()) << 152);
        deployCodeTo("Ve33.sol:Ve33", abi.encode(core, stonx), ve33Address);
        ve33 = Ve33(payable(ve33Address));

        metadata = new VeTokenMetadata("Ekubo Stock Liquidity Token", "STONX", 18, address(stonx));
        veToken = new VeToken(core, ve33, metadata, "Vote-Escrow STONX", "veSTONX");
        ve33Positions = new Ve33Positions(core, ve33, address(deployer));
        deployer.setPositionsMetadata(ve33Positions);
        periphery = new Ve33Periphery(core, ve33);
        dataFetcher = new Ve33DataFetcher(ve33);
        scheduler = new Ve33EmissionRateScheduler(address(deployer), core, ve33);

        stonx.mint(address(deployer), STONX_AMOUNT);
        stonx.mint(address(deployer), STONX_AMOUNT);
        stonx.transferOwnership(address(deployer));
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
        usdg.mint(address(deployer), USDG_AMOUNT);

        uint256 positionId;
        uint256 veId;
        uint128 scheduledAmount;
        PoolKey memory poolKey;
        (poolKey, positionId, veId, scheduledAmount) =
            deployer.initialize(stonx, ve33, veToken, ve33Positions, scheduler, core, usdgAddress, owner);
        PoolId poolId = poolKey.toPoolId();

        _assertDeploymentOwnership(positionId, veId);
        _assertPositionAndPoolState(poolKey, poolId, positionId, usdg);
        _assertStakeAndVoteState(poolId, veId);
        _assertEmissionState(scheduledAmount);
        _assertEmissionsReachPosition(poolKey, positionId);
    }

    function _assertDeploymentOwnership(uint256 positionId, uint256 veId) private view {
        assertEq(positionId, ve33Positions.saltToId(address(deployer), bytes32(0)));
        assertEq(veId, veToken.saltToId(address(deployer), bytes32(0)));
        assertEq(stonx.owner(), address(scheduler));
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

    function _assertEmissionState(uint128 scheduledAmount) private view {
        Ve33EmissionRateConfig config = scheduler.config();

        assertGt(scheduledAmount, 0);
        assertEq(config.targetRate(), EMISSION_RATE);
        assertEq(config.scheduleDuration(), 3 days);
        assertEq(ve33.emissionRate(), EMISSION_RATE);
        assertEq(stonx.totalSupply(), uint256(STONX_AMOUNT) * 2 + scheduledAmount);
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
