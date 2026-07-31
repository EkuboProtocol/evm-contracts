// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {Script} from "forge-std/Script.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {MintableERC20} from "../src/MintableERC20.sol";
import {Ve33} from "../src/extensions/Ve33.sol";
import {ICore} from "../src/interfaces/ICore.sol";
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
    address internal constant DEFAULT_VE33_ADDRESS = 0xD18685a514E59b06d59824e16Db07e73345d9953;
    address internal constant DEFAULT_USDG_ADDRESS = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant DEFAULT_VE33_PERIPHERY_ADDRESS = 0x1D834b70c33FAceBdB05af3C9C78da396f5d0E26;
    address internal constant DEFAULT_VE33_POSITIONS_ADDRESS = 0xdA38ac72CE7220c4dd7719d114ef94eDadb8f068;
    address internal constant DEFAULT_VE_TOKEN_ADDRESS = 0x9d7008E169D040B6c0140eb92E7cA82B12643497;
    address internal constant DEFAULT_GOVERNANCE_ADDRESS = 0xcd87828F4f279D3C5fD7af531370298964B5EAAb;

    uint128 internal constant LIQUIDITY_TOKEN_AMOUNT = 333_333e18;
    uint128 internal constant LIQUIDITY_USDG_AMOUNT = 333_333e6;
    uint128 internal constant STAKE_TOKEN_AMOUNT = 333_333e18;
    uint128 internal constant INITIAL_EMISSION_AMOUNT = 333_333e18;
    uint128 internal constant REQUIRED_STONX_AMOUNT =
        LIQUIDITY_TOKEN_AMOUNT + STAKE_TOKEN_AMOUNT + INITIAL_EMISSION_AMOUNT;
    uint32 internal constant TICK_SPACING = 1024;
    // Outermost usable ticks within Core's global bounds for this tick spacing.
    int32 internal constant POSITION_TICK_LOWER = -88_722_432;
    int32 internal constant POSITION_TICK_UPPER = 88_722_432;
    uint64 internal constant SWAP_FEE = 0;
    uint32 internal constant INITIAL_EMISSION_DURATION = 100 days;

    error PoolHasNoLiquidity();
    error NoValidEmissionTime();
    error NoEmissionsScheduled();
    error UnexpectedScheduledEmissionAmount(uint128 expected, uint128 actual);
    error USDGNotFullySpent(uint128 spent);
    error InvalidStonxOwner(address expected, address actual);
    error UnsupportedDecimalDifference(uint256 difference);

    function run() public {
        bytes32 nftSalt = vm.envOr("NFT_SALT", bytes32(0));
        ICore core = ICore(payable(vm.envOr("CORE_ADDRESS", payable(DEFAULT_CORE_ADDRESS))));
        address deployer = vm.getWallets()[0];
        Ve33 ve33 = Ve33(payable(vm.envOr("VE33_ADDRESS", payable(DEFAULT_VE33_ADDRESS))));
        MintableERC20 stonx = MintableERC20(ve33.stakeToken());
        address usdg = vm.envOr("USDG_ADDRESS", DEFAULT_USDG_ADDRESS);
        address governance = vm.envOr("GOVERNANCE_ADDRESS", DEFAULT_GOVERNANCE_ADDRESS);
        StonxVe33System memory system = _loadVe33System(ve33);

        address stonxOwner = stonx.owner();
        if (stonxOwner != deployer) revert InvalidStonxOwner(deployer, stonxOwner);

        vm.startBroadcast();

        assert(stonx.balanceOf(deployer) >= REQUIRED_STONX_AMOUNT);

        PoolKey memory poolKey = _stonxPoolKey(address(stonx), usdg, address(system.ve33));
        uint256 positionId = _seedLiquidity(stonx, system.positions, poolKey, usdg, deployer, governance, nftSalt);
        uint256 veId = _stakeAndVote(stonx, system.veToken, core, poolKey, deployer, nftSalt);
        system.positions.transferOwnership(governance);
        (uint64 emissionStart, uint64 emissionEnd, uint160 emissionRate, uint128 scheduledAmount) =
            _scheduleInitialEmissions(stonx, system.periphery);
        uint256 remainingStonx = _transferRemainingStonxAndOwnership(stonx, deployer, governance);

        console2.log("STONX", address(stonx));
        console2.log("STONX/USDG Ve33 position", positionId);
        console2.log("STONX VeToken stake", veId);
        console2.log("Initial scheduled emissions", scheduledAmount);
        console2.log("Remaining deployer STONX transferred to governance", remainingStonx);
        console2.log("Initial emissions start timestamp", emissionStart);
        console2.log("Initial emissions end timestamp", emissionEnd);
        console2.log(
            "Initial emissions duration (seconds)",
            emissionEnd - (emissionStart == 0 ? uint64(block.timestamp) : emissionStart)
        );
        console2.log("Initial Q32 emissions rate", emissionRate);
        console2.log("Initial daily STONX emissions", uint256(1 days) * emissionRate / (uint256(1) << 32) / 1e18);
        console2.log("Initial daily STONX emissions (wei)", uint256(1 days) * emissionRate / (uint256(1) << 32));

        vm.stopBroadcast();
    }

    function _loadVe33System(Ve33 ve33) internal returns (StonxVe33System memory system) {
        system.ve33 = ve33;
        system.veToken = VeToken(payable(vm.envOr("VE_TOKEN_ADDRESS", payable(DEFAULT_VE_TOKEN_ADDRESS))));
        system.positions =
            Ve33Positions(payable(vm.envOr("VE33_POSITIONS_ADDRESS", payable(DEFAULT_VE33_POSITIONS_ADDRESS))));
        system.periphery =
            Ve33Periphery(payable(vm.envOr("VE33_PERIPHERY_ADDRESS", payable(DEFAULT_VE33_PERIPHERY_ADDRESS))));
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

    function _stakeAndVote(
        MintableERC20 stonx,
        VeToken veToken,
        ICore core,
        PoolKey memory poolKey,
        address deployer,
        bytes32 nftSalt
    ) internal returns (uint256 veId) {
        if (core.poolState(poolKey.toPoolId()).liquidity() == 0) revert PoolHasNoLiquidity();

        stonx.approve(address(veToken), STAKE_TOKEN_AMOUNT);

        veId = veToken.saltToId(deployer, nftSalt);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature(
            "stakeForDuration(uint128,uint32,bytes32)",
            STAKE_TOKEN_AMOUNT,
            uint32(veToken.MAX_STAKE_DURATION()),
            nftSalt
        );
        calls[1] = abi.encodeCall(veToken.vote, (veId, poolKey, SWAP_FEE));
        veToken.multicall(calls);
    }

    function _scheduleInitialEmissions(MintableERC20 stonx, Ve33Periphery periphery)
        internal
        returns (uint64 emissionStart, uint64 emissionEnd, uint160 emissionRate, uint128 scheduledAmount)
    {
        (emissionStart, emissionEnd) = initialEmissionTimes(block.timestamp);
        uint256 realStartTime = emissionStart == 0 ? block.timestamp : emissionStart;
        emissionRate = uint160((uint256(INITIAL_EMISSION_AMOUNT) << 32) / (uint256(emissionEnd) - realStartTime));

        stonx.approve(address(periphery), INITIAL_EMISSION_AMOUNT);
        scheduledAmount = periphery.scheduleEmissions(emissionStart, emissionEnd, emissionRate);
        if (scheduledAmount == 0) revert NoEmissionsScheduled();
        if (scheduledAmount != INITIAL_EMISSION_AMOUNT) {
            revert UnexpectedScheduledEmissionAmount(INITIAL_EMISSION_AMOUNT, scheduledAmount);
        }
    }

    /// @notice Returns the shortest Ve33-valid interval whose real duration is at least 100 days.
    /// @dev The end is the first valid time at or after `currentTime + 100 days`. The start is the greatest valid time
    ///      no later than 100 days before that end. Zero represents an immediate start when no future valid time fits.
    function initialEmissionTimes(uint256 currentTime) public pure returns (uint64 emissionStart, uint64 emissionEnd) {
        uint256 endTime = nextValidTime(currentTime, currentTime + uint256(INITIAL_EMISSION_DURATION) - 1);
        if (endTime == 0) revert NoValidEmissionTime();
        emissionEnd = uint64(endTime);

        uint256 latestStartTime = endTime - INITIAL_EMISSION_DURATION;
        uint256 candidate = nextValidTime(currentTime, currentTime);
        while (candidate != 0 && candidate <= latestStartTime) {
            emissionStart = uint64(candidate);
            candidate = nextValidTime(currentTime, candidate);
        }
    }

    function _transferRemainingStonxAndOwnership(MintableERC20 stonx, address deployer, address governance)
        internal
        returns (uint256 remainingStonx)
    {
        remainingStonx = stonx.balanceOf(deployer);
        if (remainingStonx != 0) SafeTransferLib.safeTransfer(address(stonx), governance, remainingStonx);
        stonx.transferOwnership(governance);
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
