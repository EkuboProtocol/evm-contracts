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
import {isTimeValid, nextValidTime} from "../src/math/time.sol";
import {Ve33Periphery} from "../src/Ve33Periphery.sol";
import {Ve33Positions} from "../src/Ve33Positions.sol";
import {VeToken} from "../src/VeToken.sol";
import {VeTokenMetadata} from "../src/VeTokenMetadata.sol";
import {PoolId} from "../src/types/poolId.sol";
import {PoolKey} from "../src/types/poolKey.sol";
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
        Ve33Periphery periphery,
        ICore core,
        address usdg,
        address governance
    )
        external
        returns (
            PoolKey memory poolKey,
            uint256 positionId,
            uint256 veId,
            uint64 emissionStart,
            uint64 emissionEnd,
            uint160 emissionRate,
            uint128 scheduledAmount,
            uint256 remainingStonx
        )
    {
        poolKey = _stonxPoolKey(address(stonx), usdg, address(ve33));
        positionId = _seedLiquidity(stonx, positions, poolKey, usdg, address(this), governance, bytes32(0));
        veId = _stakeAndVote(stonx, veToken, core, poolKey, address(this), bytes32(0));
        positions.transferOwnership(governance);
        (emissionStart, emissionEnd, emissionRate, scheduledAmount) = _scheduleInitialEmissions(stonx, periphery);
        remainingStonx = _transferRemainingStonxAndOwnership(stonx, address(this), governance);
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
    uint32 private constant INITIAL_EMISSION_DURATION = 100 days;
    uint32 private constant INITIAL_EMISSION_END_BUFFER = 6 days;

    ConfigureSTONXHarness private deployer;
    MintableERC20 private stonx;
    Ve33 private ve33;
    VeTokenMetadata private metadata;
    VeToken private veToken;
    Ve33Positions private ve33Positions;
    Ve33Periphery private periphery;
    Ve33DataFetcher private dataFetcher;

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

        stonx.mint(address(deployer), STONX_AMOUNT * 3);
        stonx.transferOwnership(address(deployer));
    }

    function test_initializeWhenSTONXIsToken0() public {
        _testInitialize(address(type(uint160).max - 1));
    }

    function test_initializeWhenSTONXIsToken1() public {
        _testInitialize(address(0x10000));
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

    function testFuzz_initialEmissionTimesUseEndBufferAndClosestStart(uint64 currentTimeSeed) public view {
        uint256 currentTime = bound(uint256(currentTimeSeed), 1, uint256(type(uint64).max) - type(uint32).max);
        (uint64 emissionStart, uint64 emissionEnd) = deployer.initialEmissionTimes(currentTime);
        uint256 realStartTime = emissionStart == 0 ? currentTime : emissionStart;
        uint256 latestStartTime =
            emissionEnd > INITIAL_EMISSION_DURATION ? uint256(emissionEnd) - INITIAL_EMISSION_DURATION : 0;
        uint256 targetDuration = INITIAL_EMISSION_DURATION - INITIAL_EMISSION_END_BUFFER;

        assertEq(
            emissionEnd,
            nextValidTime(currentTime, currentTime + targetDuration - 1),
            "first valid end at or after 94 days"
        );
        assertTrue(isTimeValid(currentTime, emissionEnd), "valid end");
        assertGe(uint256(emissionEnd) - realStartTime, targetDuration, "at least 94 days");
        if (emissionStart != 0) {
            assertGt(emissionStart, currentTime, "future start");
            assertTrue(isTimeValid(currentTime, emissionStart), "valid start");
            assertGe(uint256(emissionEnd) - emissionStart, INITIAL_EMISSION_DURATION, "future start preserves 100 days");
        }

        uint256 followingStart = nextValidTime(currentTime, emissionStart == 0 ? currentTime : emissionStart);
        assertTrue(followingStart == 0 || followingStart > latestStartTime, "greatest valid start");

        uint256 duration = uint256(emissionEnd) - realStartTime;
        uint160 emissionRate = uint160((uint256(INITIAL_EMISSION_AMOUNT) << 32) / duration);
        uint256 requiredAmount = (duration * emissionRate + type(uint32).max) >> 32;
        assertEq(requiredAmount, INITIAL_EMISSION_AMOUNT, "exact funded amount");
    }

    function test_initialEmissionTimesAtPlannedLaunch() public view {
        (uint64 emissionStart, uint64 emissionEnd) = deployer.initialEmissionTimes(1_785_504_600);

        assertEq(emissionStart, 0, "immediate start");
        assertEq(emissionEnd, 1_794_113_536, "first valid end at or after 94 days");
    }

    function _testInitialize(address usdgAddress) private {
        deployCodeTo("MintableERC20.sol:MintableERC20", abi.encode(address(this), "USDG", "USDG", 6), usdgAddress);
        MintableERC20 usdg = MintableERC20(usdgAddress);
        assertEq(usdg.decimals(), 6);
        usdg.mint(address(deployer), USDG_AMOUNT);

        PoolKey memory poolKey;
        uint256 positionId;
        uint256 veId;
        uint64 emissionStart;
        uint64 emissionEnd;
        uint160 emissionRate;
        uint128 scheduledAmount;
        uint256 remainingStonx;
        uint64 scheduleTime = uint64(block.timestamp);
        (poolKey, positionId, veId, emissionStart, emissionEnd, emissionRate, scheduledAmount, remainingStonx) =
            deployer.initialize(stonx, ve33, veToken, ve33Positions, periphery, core, usdgAddress, owner);
        PoolId poolId = poolKey.toPoolId();

        _assertDeploymentOwnership(positionId, veId, remainingStonx);
        _assertPositionAndPoolState(poolKey, poolId, positionId, usdg);
        _assertStakeAndVoteState(poolId, veId);
        _assertEmissionState(scheduleTime, emissionStart, emissionEnd, emissionRate, scheduledAmount);
        _assertEmissionsStart(emissionStart, emissionRate);
        _assertEmissionsReachPosition(poolKey, positionId);
    }

    function _assertDeploymentOwnership(uint256 positionId, uint256 veId, uint256 remainingStonx) private view {
        assertEq(positionId, ve33Positions.saltToId(address(deployer), bytes32(0)));
        assertEq(veId, veToken.saltToId(address(deployer), bytes32(0)));
        assertEq(stonx.owner(), owner);
        assertEq(stonx.balanceOf(owner), remainingStonx);
        assertEq(ve33Positions.owner(), owner);
        assertEq(ve33Positions.ownerOf(positionId), owner);
        assertEq(veToken.ownerOf(veId), address(deployer));

        assertEq(address(veToken.ve33()), address(ve33));
        assertEq(address(veToken.metadata()), address(metadata));
        assertEq(address(ve33Positions.ve33()), address(ve33));
        assertEq(address(periphery.ve33()), address(ve33));
        assertEq(address(dataFetcher.VE33_EXTENSION()), address(ve33));
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
        assertEq(stonx.balanceOf(address(deployer)), 0);
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

    function _assertEmissionState(
        uint64 scheduleTime,
        uint64 emissionStart,
        uint64 emissionEnd,
        uint160 emissionRate,
        uint128 scheduledAmount
    ) private view {
        uint256 realStartTime = emissionStart == 0 ? scheduleTime : emissionStart;
        (uint128 savedStakeAndEmissions,) = core.savedBalances(
            address(ve33), address(stonx), address(type(uint160).max), VE33_STAKE_TOKEN_SAVED_BALANCE_ID
        );

        assertEq(scheduledAmount, INITIAL_EMISSION_AMOUNT);
        assertEq(savedStakeAndEmissions, STONX_AMOUNT + scheduledAmount);
        assertEq(
            emissionEnd,
            nextValidTime(
                scheduleTime, uint256(scheduleTime) + INITIAL_EMISSION_DURATION - INITIAL_EMISSION_END_BUFFER - 1
            )
        );
        assertGe(uint256(emissionEnd) - realStartTime, INITIAL_EMISSION_DURATION - INITIAL_EMISSION_END_BUFFER);
        assertTrue(isTimeValid(scheduleTime, emissionEnd));
        if (emissionStart != 0) {
            assertTrue(isTimeValid(scheduleTime, emissionStart));
            assertGe(uint256(emissionEnd) - emissionStart, INITIAL_EMISSION_DURATION);
        }
        assertEq(
            emissionRate, uint160((uint256(INITIAL_EMISSION_AMOUNT) << 32) / (uint256(emissionEnd) - realStartTime))
        );
        assertEq(stonx.totalSupply(), uint256(STONX_AMOUNT) * 3);
        assertEq(stonx.balanceOf(address(deployer)), 0);

        if (emissionStart == 0) {
            assertEq(ve33.emissionRate(), emissionRate);
            (uint64 nextTime, int256 nextDelta) = ve33.nextEmissionRateChangeTime(scheduleTime);
            assertEq(nextTime, emissionEnd);
            assertEq(nextDelta, -int256(uint256(emissionRate)));
        } else {
            assertEq(ve33.emissionRate(), 0);
            (uint64 nextTime, int256 nextDelta) = ve33.nextEmissionRateChangeTime(scheduleTime);
            assertEq(nextTime, emissionStart);
            assertEq(nextDelta, int256(uint256(emissionRate)));
            (nextTime, nextDelta) = ve33.nextEmissionRateChangeTime(emissionStart);
            assertEq(nextTime, emissionEnd);
            assertEq(nextDelta, -int256(uint256(emissionRate)));
        }
    }

    function _assertEmissionsStart(uint64 emissionStart, uint160 emissionRate) private {
        if (emissionStart == 0) {
            assertEq(ve33.emissionRate(), emissionRate);
            return;
        }

        vm.warp(emissionStart - 1);
        ve33.accrueEmissions();
        assertEq(ve33.emissionRate(), 0);

        vm.warp(emissionStart);
        ve33.accrueEmissions();
        assertEq(ve33.emissionRate(), emissionRate);
    }

    function _assertEmissionsReachPosition(PoolKey memory poolKey, uint256 positionId) private {
        vm.warp(block.timestamp + 1 days);
        uint256 governanceBalanceBefore = stonx.balanceOf(owner);

        vm.expectRevert(
            abi.encodeWithSelector(BaseNonfungibleToken.NotUnauthorizedForToken.selector, address(this), positionId)
        );
        ve33Positions.claimRewards(positionId, poolKey, POSITION_TICK_LOWER, POSITION_TICK_UPPER, address(this));

        // Governance owns the position NFT and is the only initially authorized reward claimant.
        vm.prank(owner);
        uint256 claimed =
            ve33Positions.claimRewards(positionId, poolKey, POSITION_TICK_LOWER, POSITION_TICK_UPPER, owner);

        assertGt(claimed, 0);
        assertEq(stonx.balanceOf(owner), governanceBalanceBefore + claimed);
    }
}
