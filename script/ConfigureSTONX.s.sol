// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Script} from "forge-std/Script.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {deployIfNeeded} from "./DeployAll.s.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {Ve33} from "../src/extensions/Ve33.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Ve33EmissionRateScheduler} from "../src/Ve33EmissionRateScheduler.sol";
import {Ve33Periphery} from "../src/Ve33Periphery.sol";
import {Ve33Positions} from "../src/Ve33Positions.sol";
import {VeToken} from "../src/VeToken.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {sqrtRatioToTick} from "../src/math/ticks.sol";
import {nextValidTime} from "../src/math/time.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {createConcentratedPoolConfig} from "../src/types/poolConfig.sol";
import {toSqrtRatio} from "../src/types/sqrtRatio.sol";

struct StonxVe33System {
    Ve33 ve33;
    VeToken veToken;
    Ve33Positions positions;
    Ve33Periphery periphery;
}

/// @title ConfigureSTONX
/// @notice Configures an already-deployed STONX Ve33 system.
contract ConfigureSTONX is Script {
    using CoreLib for *;

    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant SQRT_TEN_X128 = 0x3298b075b4b6a5240945790619b37fd4a;
    uint256 internal constant MAX_DECIMAL_DIFFERENCE = 38;

    address internal constant DEFAULT_CORE_ADDRESS = 0x00000000000014aA86C5d3c41765bb24e11bd701;
    bytes32 internal constant DEFAULT_DEPLOYMENT_SALT =
        0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;
    address internal constant DEFAULT_GOVERNANCE_ADDRESS = 0xcd87828F4f279D3C5fD7af531370298964B5EAAb;

    uint128 internal constant LIQUIDITY_TOKEN_AMOUNT = 333_333e18;
    uint128 internal constant LIQUIDITY_USDG_AMOUNT = 333_333e6;
    uint128 internal constant DEPLOYER_TOKEN_AMOUNT = 333_333e18;
    uint32 internal constant TICK_SPACING = 1024;
    // Outermost usable ticks within Core's global bounds for this tick spacing.
    int32 internal constant POSITION_TICK_LOWER = -88_722_432;
    int32 internal constant POSITION_TICK_UPPER = 88_722_432;
    uint64 internal constant SWAP_FEE = uint64((uint256(type(uint64).max) * 30) / 10_000);
    uint128 internal constant INITIAL_EMISSION_AMOUNT = 333_333e18;
    uint32 internal constant INITIAL_EMISSION_DURATION = 100 days;
    uint32 internal constant EMISSION_SCHEDULE_DURATION = 3 days;
    uint128 internal constant SCHEDULER_DAILY_EMISSION_AMOUNT = 333_333e15;
    uint160 internal constant SCHEDULER_EMISSION_RATE =
        uint160((uint256(SCHEDULER_DAILY_EMISSION_AMOUNT) << 32) / 1 days);

    error PoolHasNoLiquidity();
    error NoEmissionsScheduled();
    error UnexpectedScheduledEmissionAmount(uint128 expected, uint128 actual);
    error USDGNotFullySpent(uint128 spent);
    error InvalidStonxOwner(address expected, address actual);
    error UnsupportedDecimalDifference(uint256 difference);

    function run() public {
        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        bytes32 nftSalt = vm.envOr("NFT_SALT", bytes32(0));
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(DEFAULT_CORE_ADDRESS))));
        address deployer = vm.getWallets()[0];
        Ve33 ve33 = Ve33(payable(vm.envAddress("VE33_ADDRESS")));
        MintableERC20 stonx = MintableERC20(ve33.stakeToken());
        address usdg = vm.envAddress("USDG_ADDRESS");
        address governance = vm.envOr("GOVERNANCE_ADDRESS", DEFAULT_GOVERNANCE_ADDRESS);
        StonxVe33System memory system = _loadVe33System(ve33);

        address stonxOwner = stonx.owner();
        if (stonxOwner != deployer) revert InvalidStonxOwner(deployer, stonxOwner);

        vm.startBroadcast();

        stonx.mint(deployer, DEPLOYER_TOKEN_AMOUNT);
        stonx.mint(deployer, LIQUIDITY_TOKEN_AMOUNT);

        PoolKey memory poolKey = _stonxPoolKey(address(stonx), usdg, address(system.ve33));
        uint256 positionId = _seedLiquidity(stonx, system.positions, poolKey, usdg, deployer, governance, nftSalt);
        uint256 veId = _stakeAndVote(stonx, system.veToken, core, poolKey, nftSalt);
        system.positions.transferOwnership(governance);
        (address schedulerAddress, uint128 scheduledAmount) =
            _deployScheduler(stonx, system.ve33, system.periphery, core, salt, deployer, governance);

        console2.log("STONX", address(stonx));
        console2.log("STONX/USDG Ve33 position", positionId);
        console2.log("STONX VeToken stake", veId);
        console2.log("Ve33EmissionRateScheduler", schedulerAddress);
        console2.log("Initial scheduled emissions", scheduledAmount);

        vm.stopBroadcast();
    }

    function _loadVe33System(Ve33 ve33) internal returns (StonxVe33System memory system) {
        system.ve33 = ve33;
        system.veToken = VeToken(payable(vm.envAddress("VE_TOKEN_ADDRESS")));
        system.positions = Ve33Positions(payable(vm.envAddress("VE33_POSITIONS_ADDRESS")));
        system.periphery = Ve33Periphery(payable(vm.envAddress("VE33_PERIPHERY_ADDRESS")));
    }

    function _seedLiquidity(
        MintableERC20 stonx,
        Ve33Positions positions,
        PoolKey memory poolKey,
        address usdg,
        address deployer,
        address governance,
        bytes32 nftSalt
    ) internal returns (uint256 positionId) {
        stonx.approve(address(positions), LIQUIDITY_TOKEN_AMOUNT);
        IERC20(usdg).approve(address(positions), LIQUIDITY_USDG_AMOUNT);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(
            positions.maybeInitializePool,
            (poolKey, initialTick(address(stonx), stonx.decimals(), usdg, IERC20(usdg).decimals()))
        );
        calls[1] = abi.encodeCall(
            positions.mintAndDepositWithSalt,
            (
                nftSalt,
                poolKey,
                POSITION_TICK_LOWER,
                POSITION_TICK_UPPER,
                address(stonx) < usdg ? LIQUIDITY_TOKEN_AMOUNT : LIQUIDITY_USDG_AMOUNT,
                address(stonx) < usdg ? LIQUIDITY_USDG_AMOUNT : LIQUIDITY_TOKEN_AMOUNT,
                0
            )
        );

        bytes[] memory results = positions.multicall(calls);
        uint128 amount0;
        uint128 amount1;
        (positionId,, amount0, amount1) = abi.decode(results[1], (uint256, uint128, uint128, uint128));

        uint128 usdgSpent = address(stonx) < usdg ? amount1 : amount0;
        if (usdgSpent != LIQUIDITY_USDG_AMOUNT) revert USDGNotFullySpent(usdgSpent);
        positions.transferFrom(deployer, governance, positionId);
    }

    function _stakeAndVote(MintableERC20 stonx, VeToken veToken, ICore core, PoolKey memory poolKey, bytes32 nftSalt)
        internal
        returns (uint256 veId)
    {
        if (core.poolState(poolKey.toPoolId()).liquidity() == 0) revert PoolHasNoLiquidity();

        stonx.approve(address(veToken), DEPLOYER_TOKEN_AMOUNT);
        veId = veToken.stakeAndVote(
            DEPLOYER_TOKEN_AMOUNT, uint64(block.timestamp + veToken.MAX_STAKE_DURATION()), nftSalt, poolKey, SWAP_FEE
        );
    }

    function _deployScheduler(
        MintableERC20 stonx,
        Ve33 ve33,
        Ve33Periphery periphery,
        ICore core,
        bytes32 salt,
        address deployer,
        address governance
    ) internal returns (address schedulerAddress, uint128 scheduledAmount) {
        (schedulerAddress,) = deployIfNeeded(
            abi.encodePacked(type(Ve33EmissionRateScheduler).creationCode, abi.encode(deployer, core, ve33)),
            salt,
            address(0),
            "Ve33EmissionRateScheduler"
        );
        Ve33EmissionRateScheduler scheduler = Ve33EmissionRateScheduler(payable(schedulerAddress));
        scheduledAmount = _scheduleInitialEmissions(stonx, periphery, deployer);
        _configureScheduler(stonx, scheduler, governance);
    }

    function _scheduleInitialEmissions(MintableERC20 stonx, Ve33Periphery periphery, address emissionFunder)
        internal
        returns (uint128 scheduledAmount)
    {
        uint64 emissionEnd =
            uint64(nextValidTime(block.timestamp, block.timestamp + uint256(INITIAL_EMISSION_DURATION) - 1));
        uint160 emissionRate = uint160((uint256(INITIAL_EMISSION_AMOUNT) << 32) / (emissionEnd - block.timestamp));

        stonx.mint(emissionFunder, INITIAL_EMISSION_AMOUNT);
        stonx.approve(address(periphery), INITIAL_EMISSION_AMOUNT);
        scheduledAmount = periphery.scheduleEmissions(0, emissionEnd, emissionRate);
        if (scheduledAmount == 0) revert NoEmissionsScheduled();
        if (scheduledAmount != INITIAL_EMISSION_AMOUNT) {
            revert UnexpectedScheduledEmissionAmount(INITIAL_EMISSION_AMOUNT, scheduledAmount);
        }
    }

    function _configureScheduler(MintableERC20 stonx, Ve33EmissionRateScheduler scheduler, address governance)
        internal
    {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(scheduler.setConfig, (SCHEDULER_EMISSION_RATE, EMISSION_SCHEDULE_DURATION));
        calls[1] = abi.encodeCall(scheduler.transferOwnership, (governance));

        stonx.transferOwnership(address(scheduler));
        scheduler.multicall(calls);
    }

    function _stonxPoolKey(address stonx, address usdg, address ve33) internal pure returns (PoolKey memory poolKey) {
        (poolKey.token0, poolKey.token1) = stonx < usdg ? (stonx, usdg) : (usdg, stonx);
        poolKey.config = createConcentratedPoolConfig({_fee: 0, _tickSpacing: TICK_SPACING, _extension: ve33});
    }

    function initialTick(address stonx, uint8 stonxDecimals, address usdg, uint8 usdgDecimals)
        public
        pure
        returns (int32 tick)
    {
        bool stonxIsToken0 = stonx < usdg;
        uint256 decimals0 = stonxIsToken0 ? stonxDecimals : usdgDecimals;
        uint256 decimals1 = stonxIsToken0 ? usdgDecimals : stonxDecimals;
        uint256 decimalDifference = decimals0 > decimals1 ? decimals0 - decimals1 : decimals1 - decimals0;
        if (decimalDifference > MAX_DECIMAL_DIFFERENCE) {
            revert UnsupportedDecimalDifference(decimalDifference);
        }

        uint256 sqrtRatioX128;
        uint256 integerScale = 10 ** (decimalDifference / 2);
        if (decimals1 >= decimals0) {
            sqrtRatioX128 = Q128 * integerScale;
            if (decimalDifference % 2 != 0) {
                sqrtRatioX128 = FixedPointMathLib.fullMulDiv(sqrtRatioX128, SQRT_TEN_X128, Q128);
            }
        } else {
            sqrtRatioX128 = Q128 / integerScale;
            if (decimalDifference % 2 != 0) {
                sqrtRatioX128 = FixedPointMathLib.fullMulDiv(sqrtRatioX128, Q128, SQRT_TEN_X128);
            }
        }

        tick = sqrtRatioToTick(toSqrtRatio(sqrtRatioX128, true));

        // Round toward the USDG-limiting side so the position spends the full configured USDG amount.
        if (stonxIsToken0) ++tick;
    }
}
