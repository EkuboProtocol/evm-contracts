// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {DeployVe33, Ve33Deployment} from "./DeployVe33.s.sol";
import {deployIfNeeded} from "./DeployAll.s.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {Ve33} from "../src/extensions/Ve33.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {Ve33EmissionRateScheduler} from "../src/Ve33EmissionRateScheduler.sol";
import {Ve33Positions} from "../src/Ve33Positions.sol";
import {VeToken} from "../src/VeToken.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {sqrtRatioToTick} from "../src/math/ticks.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {createConcentratedPoolConfig} from "../src/types/poolConfig.sol";
import {SqrtRatio, toSqrtRatio} from "../src/types/sqrtRatio.sol";

/// @title DeploySTONX
/// @notice Deploys and configures the STONX Ve33 system on RHC or RHC testnet.
contract DeploySTONX is DeployVe33 {
    using CoreLib for *;

    uint256 internal constant RHC_CHAIN_ID = 4663;
    uint256 internal constant RHC_TESTNET_CHAIN_ID = 46630;

    address internal constant DEFAULT_USDG_ADDRESS = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant DEFAULT_GOVERNANCE_ADDRESS = 0xcd87828F4f279D3C5fD7af531370298964B5EAAb;

    uint128 internal constant LIQUIDITY_TOKEN_AMOUNT = 333_333e18;
    uint128 internal constant LIQUIDITY_USDG_AMOUNT = 333_333e6;
    uint128 internal constant DEPLOYER_TOKEN_AMOUNT = 333_333e18;
    uint32 internal constant TICK_SPACING = 1024;
    // Outermost usable ticks within Core's global bounds for this tick spacing.
    int32 internal constant POSITION_TICK_LOWER = -88_722_432;
    int32 internal constant POSITION_TICK_UPPER = 88_722_432;
    uint64 internal constant SWAP_FEE = uint64((uint256(type(uint64).max) * 30) / 10_000);
    uint32 internal constant EMISSION_SCHEDULE_DURATION = 3 days;
    uint160 internal constant EMISSION_RATE = uint160(uint256(333_333e15) * (1 << 32) / 1 days);

    error InvalidChainId(uint256 chainId);
    error PoolHasNoLiquidity();
    error NoEmissionsScheduled();
    error USDGNotFullySpent(uint128 spent);

    function run() public override {
        if (block.chainid != RHC_CHAIN_ID && block.chainid != RHC_TESTNET_CHAIN_ID) {
            revert InvalidChainId(block.chainid);
        }

        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(DEFAULT_CORE_ADDRESS))));
        address deployer = vm.getWallets()[0];
        address usdg = vm.envOr("USDG_ADDRESS", DEFAULT_USDG_ADDRESS);
        address governance = vm.envOr("GOVERNANCE_ADDRESS", DEFAULT_GOVERNANCE_ADDRESS);

        vm.startBroadcast();

        Ve33Deployment memory deployment = _deployVe33(core, deployer, salt);
        MintableERC20 stonx = MintableERC20(deployment.stakeToken);

        stonx.mint(deployer, DEPLOYER_TOKEN_AMOUNT);
        stonx.mint(deployer, LIQUIDITY_TOKEN_AMOUNT);

        PoolKey memory poolKey = _stonxPoolKey(address(stonx), usdg, address(deployment.ve33));
        uint256 positionId = _seedLiquidity(stonx, deployment.positions, poolKey, usdg, deployer, governance);
        uint256 veId = _stakeAndVote(stonx, deployment.veToken, core, poolKey);
        deployment.positions.transferOwnership(governance);
        (address schedulerAddress, uint128 scheduledAmount) =
            _deployScheduler(stonx, deployment.ve33, core, salt, deployer, governance);

        console2.log("STONX", address(stonx));
        console2.log("STONX/USDG Ve33 position", positionId);
        console2.log("STONX VeToken stake", veId);
        console2.log("Ve33EmissionRateScheduler", schedulerAddress);
        console2.log("Initial scheduled emissions", scheduledAmount);

        vm.stopBroadcast();
    }

    function _seedLiquidity(
        MintableERC20 stonx,
        Ve33Positions positions,
        PoolKey memory poolKey,
        address usdg,
        address deployer,
        address governance
    ) internal returns (uint256 positionId) {
        int32 poolInitialTick = this.initialTick(address(stonx), usdg);
        (, SqrtRatio sqrtRatio) = positions.maybeInitializePool(poolKey, poolInitialTick);

        stonx.approve(address(positions), LIQUIDITY_TOKEN_AMOUNT);
        IERC20(usdg).approve(address(positions), LIQUIDITY_USDG_AMOUNT);

        uint128 amount0;
        uint128 amount1;
        (positionId,, amount0, amount1) = positions.mintAndDeposit(
            poolKey,
            POSITION_TICK_LOWER,
            POSITION_TICK_UPPER,
            address(stonx) < usdg ? LIQUIDITY_TOKEN_AMOUNT : LIQUIDITY_USDG_AMOUNT,
            address(stonx) < usdg ? LIQUIDITY_USDG_AMOUNT : LIQUIDITY_TOKEN_AMOUNT,
            sqrtRatio
        );

        uint128 usdgSpent = address(stonx) < usdg ? amount1 : amount0;
        if (usdgSpent != LIQUIDITY_USDG_AMOUNT) revert USDGNotFullySpent(usdgSpent);
        positions.transferFrom(deployer, governance, positionId);
    }

    function _stakeAndVote(MintableERC20 stonx, VeToken veToken, ICore core, PoolKey memory poolKey)
        internal
        returns (uint256 veId)
    {
        if (core.poolState(poolKey.toPoolId()).liquidity() == 0) revert PoolHasNoLiquidity();

        stonx.approve(address(veToken), DEPLOYER_TOKEN_AMOUNT);
        veId = veToken.stakeMaxDuration(DEPLOYER_TOKEN_AMOUNT);
        veToken.vote(veId, poolKey, SWAP_FEE);
    }

    function _deployScheduler(
        MintableERC20 stonx,
        Ve33 ve33,
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
        scheduledAmount = _configureAndStartScheduler(stonx, scheduler, governance);
    }

    function _configureAndStartScheduler(MintableERC20 stonx, Ve33EmissionRateScheduler scheduler, address governance)
        internal
        returns (uint128 scheduledAmount)
    {
        scheduler.setConfig(EMISSION_RATE, EMISSION_SCHEDULE_DURATION);
        scheduler.transferOwnership(governance);
        stonx.transferOwnership(address(scheduler));
        scheduledAmount = scheduler.mintAndSchedule();
        if (scheduledAmount == 0) revert NoEmissionsScheduled();
    }

    function _stakeToken(address owner, bytes32 salt)
        internal
        override
        returns (address stakeToken, string memory name, string memory symbol, uint8 decimals)
    {
        name = "Ekubo Stock Liquidity Token";
        symbol = "STONX";
        decimals = 18;
        (stakeToken,) = deployIfNeeded(
            abi.encodePacked(type(MintableERC20).creationCode, abi.encode(owner, name, symbol)),
            salt,
            address(0),
            "STONX"
        );
    }

    function _defaultPositionsName() internal pure override returns (string memory) {
        return "Ekubo STONX Positions";
    }

    function _defaultPositionsSymbol() internal pure override returns (string memory) {
        return "stonxPO";
    }

    function _defaultVeTokenName(string memory) internal pure override returns (string memory) {
        return "Vote-Escrow STONX";
    }

    function _stonxPoolKey(address stonx, address usdg, address ve33) internal pure returns (PoolKey memory poolKey) {
        (poolKey.token0, poolKey.token1) = stonx < usdg ? (stonx, usdg) : (usdg, stonx);
        poolKey.config = createConcentratedPoolConfig({_fee: 0, _tickSpacing: TICK_SPACING, _extension: ve33});
    }

    function initialTick(address stonx, address usdg) external pure returns (int32 tick) {
        uint256 sqrtRatioX128 = stonx < usdg ? (uint256(1) << 128) / 1e6 : (uint256(1) << 128) * 1e6;
        tick = sqrtRatioToTick(toSqrtRatio(sqrtRatioX128, true));

        // Round toward the USDG-limiting side so the position spends the full configured USDG amount.
        if (stonx < usdg) ++tick;
    }
}
