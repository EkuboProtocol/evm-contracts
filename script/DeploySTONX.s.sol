// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {deployExtension, deployIfNeeded} from "./DeployAll.s.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {Ve33, ve33CallPoints} from "../src/extensions/Ve33.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {Ve33DataFetcher} from "../src/lens/Ve33DataFetcher.sol";
import {sqrtRatioToTick} from "../src/math/ticks.sol";
import {nextValidTime} from "../src/math/time.sol";
import {Ve33EmissionRateScheduler} from "../src/Ve33EmissionRateScheduler.sol";
import {Ve33Periphery} from "../src/Ve33Periphery.sol";
import {Ve33Positions} from "../src/Ve33Positions.sol";
import {VeToken} from "../src/VeToken.sol";
import {VeTokenMetadata} from "../src/VeTokenMetadata.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {createConcentratedPoolConfig} from "../src/types/poolConfig.sol";
import {toSqrtRatio} from "../src/types/sqrtRatio.sol";

/// @notice Stateful, VM-independent deployment coordinator for the STONX Ve33 system.
/// @dev Each phase can be submitted separately. The operator must reuse this contract to resume a deployment.
contract STONXDeployment {
    using CoreLib for *;

    uint128 public constant LIQUIDITY_TOKEN_AMOUNT = 333_333e18;
    uint128 public constant LIQUIDITY_USDG_AMOUNT = 333_333e6;
    uint128 public constant BENEFICIARY_TOKEN_AMOUNT = 333_333e18;
    uint32 public constant TICK_SPACING = 1024;
    int32 public constant POSITION_TICK_LOWER = -88_722_432;
    int32 public constant POSITION_TICK_UPPER = 88_722_432;
    uint64 public constant SWAP_FEE = uint64((uint256(type(uint64).max) * 30) / 10_000);
    uint128 public constant INITIAL_EMISSION_AMOUNT = 333_333e18;
    uint32 public constant INITIAL_EMISSION_DURATION = 100 days;
    uint32 public constant EMISSION_SCHEDULE_DURATION = 3 days;
    uint128 public constant SCHEDULER_DAILY_EMISSION_AMOUNT = 333_333e15;
    uint160 public constant SCHEDULER_EMISSION_RATE =
        uint160((uint256(SCHEDULER_DAILY_EMISSION_AMOUNT) << 32) / 1 days);

    ICore public immutable core;
    address public immutable usdg;
    address public immutable operator;
    address public immutable governance;
    bytes32 public immutable salt;
    bytes32 public immutable nftSalt;

    MintableERC20 public stonx;
    Ve33 public ve33;
    VeTokenMetadata public metadata;
    VeToken public veToken;
    Ve33Positions public positions;
    Ve33Periphery public periphery;
    Ve33DataFetcher public dataFetcher;
    Ve33EmissionRateScheduler public scheduler;

    PoolKey private _poolKey;
    uint256 public positionId;
    uint256 public veId;
    uint128 public scheduledAmount;
    bool public liquidityInitialized;
    bool public incentivesInitialized;
    bool public emissionsInitialized;

    error NotOperator(address caller);
    error MissingDeployment();
    error PoolHasNoLiquidity();
    error NoEmissionsScheduled();
    error UnexpectedScheduledEmissionAmount(uint128 expected, uint128 actual);
    error USDGNotFullySpent(uint128 spent);

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator(msg.sender);
        _;
    }

    constructor(ICore core_, address usdg_, address operator_, address governance_, bytes32 salt_, bytes32 nftSalt_) {
        core = core_;
        usdg = usdg_;
        operator = operator_;
        governance = governance_;
        salt = salt_;
        nftSalt = nftSalt_;
    }

    function deployStakeToken(bytes calldata initCode) external onlyOperator returns (MintableERC20 deployed) {
        deployed = stonx;
        if (address(deployed) != address(0)) return deployed;

        (address deployedAddress,) = deployIfNeeded(initCode, salt, address(0), "STONX");
        deployed = MintableERC20(deployedAddress);
        stonx = deployed;
    }

    function deployVe33(bytes calldata initCode) external onlyOperator returns (Ve33 deployed) {
        deployed = ve33;
        if (address(deployed) != address(0)) return deployed;
        if (address(stonx) == address(0)) revert MissingDeployment();

        (address deployedAddress,) = deployExtension(initCode, salt, ve33CallPoints(), address(0), "Ve33");
        deployed = Ve33(payable(deployedAddress));
        ve33 = deployed;
        _poolKey = _stonxPoolKey(address(stonx), usdg, deployedAddress);
    }

    function deployVeTokenMetadata(bytes calldata initCode) external onlyOperator returns (VeTokenMetadata deployed) {
        deployed = metadata;
        if (address(deployed) != address(0)) return deployed;
        if (address(ve33) == address(0)) revert MissingDeployment();

        (address metadataAddress,) = deployIfNeeded(initCode, salt, address(0), "VeTokenMetadata");
        deployed = VeTokenMetadata(metadataAddress);
        metadata = deployed;
    }

    function deployVeToken(bytes calldata initCode) external onlyOperator returns (VeToken deployed) {
        deployed = veToken;
        if (address(deployed) != address(0)) return deployed;
        if (address(ve33) == address(0)) revert MissingDeployment();

        if (address(metadata) == address(0)) revert MissingDeployment();

        (address deployedAddress,) = deployIfNeeded(initCode, salt, address(0), "VeToken");
        deployed = VeToken(payable(deployedAddress));
        veToken = deployed;
    }

    function deployPositions(bytes calldata initCode) external onlyOperator returns (Ve33Positions deployed) {
        deployed = positions;
        if (address(deployed) != address(0)) return deployed;
        if (address(ve33) == address(0)) revert MissingDeployment();

        bool didDeploy;
        address deployedAddress;
        (deployedAddress, didDeploy) = deployIfNeeded(initCode, salt, address(0), "Ve33Positions");
        deployed = Ve33Positions(payable(deployedAddress));
        positions = deployed;
        if (didDeploy) {
            deployed.setMetadata("Ekubo STONX Positions", "stonxPO", "https://prod-api.ekubo.org/positions/");
        }
    }

    function deployPeriphery(bytes calldata initCode) external onlyOperator returns (Ve33Periphery deployed) {
        deployed = periphery;
        if (address(deployed) != address(0)) return deployed;
        if (address(ve33) == address(0)) revert MissingDeployment();

        (address deployedAddress,) = deployIfNeeded(initCode, salt, address(0), "Ve33Periphery");
        deployed = Ve33Periphery(payable(deployedAddress));
        periphery = deployed;
    }

    function deployDataFetcher(bytes calldata initCode) external onlyOperator returns (Ve33DataFetcher deployed) {
        deployed = dataFetcher;
        if (address(deployed) != address(0)) return deployed;
        if (address(ve33) == address(0)) revert MissingDeployment();

        (address deployedAddress,) = deployIfNeeded(initCode, salt, address(0), "Ve33DataFetcher");
        deployed = Ve33DataFetcher(deployedAddress);
        dataFetcher = deployed;
    }

    function deployScheduler(bytes calldata initCode)
        external
        onlyOperator
        returns (Ve33EmissionRateScheduler deployed)
    {
        deployed = scheduler;
        if (address(deployed) != address(0)) return deployed;
        if (address(ve33) == address(0)) revert MissingDeployment();

        (address deployedAddress,) = deployIfNeeded(initCode, salt, address(0), "Ve33EmissionRateScheduler");
        deployed = Ve33EmissionRateScheduler(payable(deployedAddress));
        scheduler = deployed;
    }

    function initializeLiquidity() external onlyOperator returns (uint256 id) {
        if (liquidityInitialized) return positionId;
        if (address(positions) == address(0)) revert MissingDeployment();

        stonx.mint(address(this), LIQUIDITY_TOKEN_AMOUNT);
        stonx.approve(address(positions), LIQUIDITY_TOKEN_AMOUNT);
        SafeTransferLib.safeTransferFrom(usdg, operator, address(this), LIQUIDITY_USDG_AMOUNT);
        IERC20(usdg).approve(address(positions), LIQUIDITY_USDG_AMOUNT);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(positions.maybeInitializePool, (_poolKey, initialTick(address(stonx), usdg)));
        calls[1] = abi.encodeCall(
            positions.mintAndDepositWithSalt,
            (
                nftSalt,
                _poolKey,
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
        (id,, amount0, amount1) = abi.decode(results[1], (uint256, uint128, uint128, uint128));
        uint128 usdgSpent = address(stonx) < usdg ? amount1 : amount0;
        if (usdgSpent != LIQUIDITY_USDG_AMOUNT) revert USDGNotFullySpent(usdgSpent);

        positionId = id;
        liquidityInitialized = true;
        positions.transferFrom(address(this), governance, id);
    }

    function initializeVe33Incentives() external onlyOperator returns (uint256 id) {
        if (incentivesInitialized) return veId;
        if (address(veToken) == address(0)) revert MissingDeployment();
        if (core.poolState(_poolKey.toPoolId()).liquidity() == 0) revert PoolHasNoLiquidity();

        stonx.mint(address(this), BENEFICIARY_TOKEN_AMOUNT);
        stonx.approve(address(veToken), BENEFICIARY_TOKEN_AMOUNT);
        id = veToken.stakeAndVote(
            BENEFICIARY_TOKEN_AMOUNT,
            uint64(block.timestamp + veToken.MAX_STAKE_DURATION()),
            nftSalt,
            _poolKey,
            SWAP_FEE
        );

        veId = id;
        incentivesInitialized = true;
        veToken.transferFrom(address(this), operator, id);
    }

    function initializeEmissions() external onlyOperator returns (uint128 amount) {
        if (emissionsInitialized) return scheduledAmount;
        if (address(periphery) == address(0) || address(scheduler) == address(0)) revert MissingDeployment();

        uint64 emissionEnd =
            uint64(nextValidTime(block.timestamp, block.timestamp + uint256(INITIAL_EMISSION_DURATION) - 1));
        uint160 emissionRate = uint160((uint256(INITIAL_EMISSION_AMOUNT) << 32) / (emissionEnd - block.timestamp));

        stonx.mint(address(this), INITIAL_EMISSION_AMOUNT);
        stonx.approve(address(periphery), INITIAL_EMISSION_AMOUNT);
        amount = periphery.scheduleEmissions(0, emissionEnd, emissionRate);
        if (amount == 0) revert NoEmissionsScheduled();
        if (amount != INITIAL_EMISSION_AMOUNT) {
            revert UnexpectedScheduledEmissionAmount(INITIAL_EMISSION_AMOUNT, amount);
        }

        scheduler.setConfig(SCHEDULER_EMISSION_RATE, EMISSION_SCHEDULE_DURATION);
        stonx.transferOwnership(address(scheduler));
        scheduler.transferOwnership(governance);
        positions.transferOwnership(governance);

        scheduledAmount = amount;
        emissionsInitialized = true;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function _stonxPoolKey(address stonx_, address usdg_, address ve33_) private pure returns (PoolKey memory key) {
        (key.token0, key.token1) = stonx_ < usdg_ ? (stonx_, usdg_) : (usdg_, stonx_);
        key.config = createConcentratedPoolConfig({_fee: 0, _tickSpacing: TICK_SPACING, _extension: ve33_});
    }

    function initialTick(address stonx_, address usdg_) public pure returns (int32 tick) {
        uint256 sqrtRatioX128 = stonx_ < usdg_ ? (uint256(1) << 128) / 1e6 : (uint256(1) << 128) * 1e6;
        tick = sqrtRatioToTick(toSqrtRatio(sqrtRatioX128, true));
        if (stonx_ < usdg_) ++tick;
    }
}

/// @title DeploySTONX
/// @notice Thin Forge wrapper that deploys and executes the VM-independent STONX deployment coordinator.
contract DeploySTONX is Script {
    uint256 internal constant RHC_CHAIN_ID = 4663;
    uint256 internal constant RHC_TESTNET_CHAIN_ID = 46630;
    address internal constant DEFAULT_CORE_ADDRESS = 0x00000000000014aA86C5d3c41765bb24e11bd701;
    address internal constant DEFAULT_USDG_ADDRESS = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant DEFAULT_GOVERNANCE_ADDRESS = 0xcd87828F4f279D3C5fD7af531370298964B5EAAb;
    bytes32 internal constant DEFAULT_DEPLOYMENT_SALT =
        0x28f4114b40904ad1cfbb42175a55ad64187c1b299773bd6318baa292375cf0dd;

    error InvalidChainId(uint256 chainId);

    function run() public {
        if (block.chainid != RHC_CHAIN_ID && block.chainid != RHC_TESTNET_CHAIN_ID) {
            revert InvalidChainId(block.chainid);
        }

        bytes32 salt = vm.envOr("SALT", DEFAULT_DEPLOYMENT_SALT);
        bytes32 nftSalt = vm.envOr("NFT_SALT", bytes32(0));
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(DEFAULT_CORE_ADDRESS))));
        address operator = vm.getWallets()[0];
        address usdg = vm.envOr("USDG_ADDRESS", DEFAULT_USDG_ADDRESS);
        address governance = vm.envOr("GOVERNANCE_ADDRESS", DEFAULT_GOVERNANCE_ADDRESS);

        vm.startBroadcast();

        (address deploymentAddress,) = deployIfNeeded(
            abi.encodePacked(
                type(STONXDeployment).creationCode, abi.encode(core, usdg, operator, governance, salt, nftSalt)
            ),
            salt,
            address(0),
            "STONXDeployment"
        );
        STONXDeployment deployment = STONXDeployment(deploymentAddress);

        MintableERC20 stonx = deployment.deployStakeToken(
            abi.encodePacked(
                type(MintableERC20).creationCode, abi.encode(deploymentAddress, "Ekubo Stock Liquidity Token", "STONX")
            )
        );
        Ve33 ve33 = deployment.deployVe33(abi.encodePacked(type(Ve33).creationCode, abi.encode(core, stonx)));
        VeTokenMetadata metadata = deployment.deployVeTokenMetadata(
            abi.encodePacked(
                type(VeTokenMetadata).creationCode,
                abi.encode("Ekubo Stock Liquidity Token", "STONX", uint8(18), address(stonx))
            )
        );
        deployment.deployVeToken(
            abi.encodePacked(
                type(VeToken).creationCode, abi.encode(core, ve33, metadata, "Vote-Escrow STONX", "veSTONX")
            )
        );
        deployment.deployPositions(
            abi.encodePacked(type(Ve33Positions).creationCode, abi.encode(core, ve33, deploymentAddress))
        );
        deployment.deployPeriphery(abi.encodePacked(type(Ve33Periphery).creationCode, abi.encode(core, ve33)));
        deployment.deployDataFetcher(abi.encodePacked(type(Ve33DataFetcher).creationCode, abi.encode(ve33)));
        deployment.deployScheduler(
            abi.encodePacked(type(Ve33EmissionRateScheduler).creationCode, abi.encode(deploymentAddress, core, ve33))
        );
        IERC20(usdg).approve(deploymentAddress, deployment.LIQUIDITY_USDG_AMOUNT());
        deployment.initializeLiquidity();
        deployment.initializeVe33Incentives();
        deployment.initializeEmissions();

        console2.log("STONXDeployment", deploymentAddress);
        console2.log("STONX", address(deployment.stonx()));
        console2.log("STONX/USDG Ve33 position", deployment.positionId());
        console2.log("STONX VeToken stake", deployment.veId());
        console2.log("Ve33EmissionRateScheduler", address(deployment.scheduler()));
        console2.log("Initial scheduled emissions", deployment.scheduledAmount());

        vm.stopBroadcast();
    }
}
