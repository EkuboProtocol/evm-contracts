// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.31;

/**
 * @title CreateTestTransactions
 * @notice Uses previously deployed protocol contracts to stand up pools, run swaps, and exercise gas-heavy flows.
 * @dev Requires the following environment variables that should point at the contracts deployed by DeployAll (or equivalent):
 *      CORE_ADDRESS, POSITIONS_ADDRESS, ORACLE_ADDRESS, TWAMM_ADDRESS, MEV_CAPTURE_ADDRESS,
 *      ORDERS_ADDRESS, INCENTIVES_ADDRESS, TOKEN_WRAPPER_FACTORY_ADDRESS.
 */
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Core} from "../src/Core.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IFlashAccountant} from "../src/interfaces/IFlashAccountant.sol";
import {Positions} from "../src/Positions.sol";
import {MEVCapture} from "../src/extensions/MEVCapture.sol";
import {MEVCaptureRouter} from "../src/MEVCaptureRouter.sol";
import {Oracle} from "../src/extensions/Oracle.sol";
import {TWAMM} from "../src/extensions/TWAMM.sol";
import {Orders} from "../src/Orders.sol";
import {Incentives} from "../src/Incentives.sol";
import {TokenWrapper} from "../src/TokenWrapper.sol";
import {TokenWrapperFactory} from "../src/TokenWrapperFactory.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {
    createConcentratedPoolConfig,
    createFullRangePoolConfig,
    createStableswapPoolConfig,
    stableswapActiveLiquidityTickRange
} from "../src/types/poolConfig.sol";
import {createSwapParameters} from "../src/types/swapParameters.sol";
import {SqrtRatio} from "../src/types/sqrtRatio.sol";
import {tickToSqrtRatio} from "../src/math/ticks.sol";
import {NATIVE_TOKEN_ADDRESS, MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";
import {DropKey} from "../src/types/dropKey.sol";

contract WrapperHelper is BaseLocker {
    using FlashAccountantLib for *;

    constructor(ICore core) BaseLocker(IFlashAccountant(payable(address(core)))) {}

    function wrap(TokenWrapper wrapper, address recipient, uint128 amount) external {
        lock(abi.encode(wrapper, msg.sender, recipient, int256(uint256(amount))));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        (TokenWrapper wrapper, address payer, address recipient, int256 amount) =
            abi.decode(data, (TokenWrapper, address, address, int256));

        // Create the deltas by forwarding to the wrapper
        ACCOUNTANT.forward(address(wrapper), abi.encode(amount));

        // Withdraw wrapped tokens to recipient
        if (uint128(uint256(amount)) > 0) {
            ACCOUNTANT.withdraw(address(wrapper), recipient, uint128(uint256(amount)));
        }

        // Pay the underlying token from the payer
        if (uint256(amount) != 0) {
            ACCOUNTANT.payFrom(payer, address(wrapper.UNDERLYING_TOKEN()), uint256(amount));
        }

        return "";
    }
}

contract TestToken is ERC20 {
    string private _name;
    string private _symbol;

    constructor(string memory __name, string memory __symbol, address recipient) {
        _name = __name;
        _symbol = __symbol;
        _mint(recipient, type(uint128).max);
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }
}

/// @notice Script to exercise pools and swaps using already-deployed protocol contracts
contract CreateTestTransactions is Script {
    uint128 constant ETH_AMOUNT = 0.0000001 ether;
    uint128 constant TOKEN_AMOUNT = 1000 * 1e18;
    uint128 constant SWAP_AMOUNT = 0.00000001 ether;
    int32 constant DEFAULT_LOWER_TICK = -1000;
    int32 constant DEFAULT_UPPER_TICK = 1000;

    Core public core;
    Positions public positions;
    Oracle public oracleExtension;
    TWAMM public twammExtension;
    Orders public orders;
    Incentives public incentives;
    TokenWrapperFactory public wrapperFactory;
    MEVCapture public mevCapture;

    MEVCaptureRouter public router;
    TestToken public token0;
    TestToken public token1;
    TokenWrapper public immediateWrapper;
    TokenWrapper public weekWrapper;
    WrapperHelper public wrapperHelper;

    function run() public {
        address deployer = vm.getWallets()[0];

        core = Core(payable(vm.envAddress("CORE_ADDRESS")));
        positions = Positions(vm.envAddress("POSITIONS_ADDRESS"));
        oracleExtension = Oracle(vm.envAddress("ORACLE_ADDRESS"));
        twammExtension = TWAMM(vm.envAddress("TWAMM_ADDRESS"));
        mevCapture = MEVCapture(vm.envAddress("MEV_CAPTURE_ADDRESS"));
        orders = Orders(vm.envAddress("ORDERS_ADDRESS"));
        incentives = Incentives(vm.envAddress("INCENTIVES_ADDRESS"));
        wrapperFactory = TokenWrapperFactory(vm.envAddress("TOKEN_WRAPPER_FACTORY_ADDRESS"));

        vm.startBroadcast();

        console2.log("Using Core at:", address(core));
        console2.log("Using Positions at:", address(positions));
        console2.log("Oracle extension at:", address(oracleExtension));
        console2.log("TWAMM extension at:", address(twammExtension));
        console2.log("MEVCapture at:", address(mevCapture));
        console2.log("Orders at:", address(orders));
        console2.log("Incentives at:", address(incentives));
        console2.log("TokenWrapperFactory at:", address(wrapperFactory));

        console2.log("\n=== Deploying Test Contracts ===");

        console2.log("Deploying MEVCaptureRouter...");
        router = new MEVCaptureRouter(core, address(mevCapture));
        console2.log("MEVCaptureRouter deployed at:", address(router));

        console2.log("Deploying test tokens...");
        token0 = new TestToken("Test Token A", "TTA", deployer);
        token1 = new TestToken("Test Token B", "TTB", deployer);
        console2.log("Token0 deployed at:", address(token0));
        console2.log("Token1 deployed at:", address(token1));

        console2.log("Deploying WrapperHelper...");
        wrapperHelper = new WrapperHelper(core);
        console2.log("WrapperHelper deployed at:", address(wrapperHelper));

        console2.log("Deploying TokenWrappers...");
        immediateWrapper = wrapperFactory.deployWrapper(IERC20(address(token0)), block.timestamp);
        weekWrapper = wrapperFactory.deployWrapper(IERC20(address(token0)), block.timestamp + 1 weeks);
        console2.log("Immediate wrapper deployed at:", address(immediateWrapper));
        console2.log("Week wrapper deployed at:", address(weekWrapper));

        console2.log("Approving all contracts...");
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(wrapperHelper), type(uint256).max);
        token0.approve(address(incentives), type(uint256).max);
        immediateWrapper.approve(address(positions), type(uint256).max);
        weekWrapper.approve(address(positions), type(uint256).max);

        console2.log("\n=== Funding Incentive Drop ===");
        DropKey memory dropKey = DropKey({
            owner: deployer,
            token: address(token0),
            root: keccak256(abi.encodePacked("CREATE_TEST_TRANSACTIONS_DROP", block.chainid))
        });
        uint128 dropFundingAmount = TOKEN_AMOUNT / 50;
        incentives.fund(dropKey, dropFundingAmount);
        console2.log("Funded incentive drop with:", dropFundingAmount);

        console2.log("\n=== Creating Pools and Positions ===");

        console2.log("Creating ETH/token0 pool...");
        PoolKey memory ethToken0Pool = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: address(token0),
            config: createConcentratedPoolConfig(1 << 63, 100, address(0))
        });
        core.initializePool(ethToken0Pool, 0);

        console2.log("Creating ETH/token1 pool...");
        PoolKey memory ethToken1Pool = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: address(token1),
            config: createConcentratedPoolConfig(1 << 63, 100, address(0))
        });
        core.initializePool(ethToken1Pool, 0);

        console2.log("Creating token0/token1 pool...");
        (address sortedToken0, address sortedToken1) =
            address(token0) < address(token1) ? (address(token0), address(token1)) : (address(token1), address(token0));
        PoolKey memory token0Token1Pool = PoolKey({
            token0: sortedToken0, token1: sortedToken1, config: createConcentratedPoolConfig(1 << 63, 100, address(0))
        });
        core.initializePool(token0Token1Pool, 0);

        console2.log("Creating ETH/token0 pool with Oracle extension...");
        PoolKey memory ethToken0OraclePool = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: address(token0),
            config: createFullRangePoolConfig(0, address(oracleExtension))
        });
        core.initializePool(ethToken0OraclePool, 0);

        console2.log("Creating ETH/token0 TWAMM pool...");
        PoolKey memory ethToken0TwammPool = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: address(token0),
            config: createFullRangePoolConfig(1 << 62, address(twammExtension))
        });
        core.initializePool(ethToken0TwammPool, 0);

        console2.log("Creating token0/immediateWrapper pool...");
        (address sortedToken0Immediate, address sortedToken1Immediate) = address(token0) < address(immediateWrapper)
            ? (address(token0), address(immediateWrapper))
            : (address(immediateWrapper), address(token0));
        PoolKey memory token0ImmediatePool = PoolKey({
            token0: sortedToken0Immediate,
            token1: sortedToken1Immediate,
            config: createConcentratedPoolConfig(1 << 63, 100, address(0))
        });
        int32 tick09 = sortedToken0Immediate == address(token0) ? int32(-1100) : int32(1100);
        core.initializePool(token0ImmediatePool, tick09);

        console2.log("Creating token0/weekWrapper pool...");
        (address sortedToken0Week, address sortedToken1Week) = address(token0) < address(weekWrapper)
            ? (address(token0), address(weekWrapper))
            : (address(weekWrapper), address(token0));
        PoolKey memory token0WeekPool = PoolKey({
            token0: sortedToken0Week,
            token1: sortedToken1Week,
            config: createConcentratedPoolConfig(1 << 63, 100, address(0))
        });
        int32 tick09Week = sortedToken0Week == address(token0) ? int32(-1100) : int32(1100);
        core.initializePool(token0WeekPool, tick09Week);

        console2.log("Wrapping tokens for liquidity provision...");
        wrapperHelper.wrap(immediateWrapper, deployer, TOKEN_AMOUNT);
        wrapperHelper.wrap(weekWrapper, deployer, TOKEN_AMOUNT);

        console2.log("Adding liquidity to ETH/token0 pool...");
        positions.mintAndDepositWithSalt{value: ETH_AMOUNT}(
            bytes32(uint256(0)), ethToken0Pool, -1000, 1000, ETH_AMOUNT, TOKEN_AMOUNT, 0
        );

        console2.log("Adding liquidity to ETH/token1 pool...");
        positions.mintAndDepositWithSalt{value: ETH_AMOUNT}(
            bytes32(uint256(1)), ethToken1Pool, -1000, 1000, ETH_AMOUNT, TOKEN_AMOUNT, 0
        );

        console2.log("Adding liquidity to token0/token1 pool...");
        positions.mintAndDepositWithSalt(
            bytes32(uint256(2)), token0Token1Pool, -1000, 1000, TOKEN_AMOUNT, TOKEN_AMOUNT, 0
        );

        console2.log("Adding liquidity to ETH/token0 Oracle pool...");
        positions.mintAndDeposit{value: ETH_AMOUNT}(
            ethToken0OraclePool, MIN_TICK, MAX_TICK, ETH_AMOUNT, TOKEN_AMOUNT, 0
        );

        console2.log("Adding liquidity to ETH/token0 TWAMM pool...");
        positions.mintAndDeposit{value: ETH_AMOUNT}(ethToken0TwammPool, MIN_TICK, MAX_TICK, ETH_AMOUNT, TOKEN_AMOUNT, 0);

        console2.log("Adding liquidity to token0/immediateWrapper pool...");
        positions.mintAndDepositWithSalt(
            bytes32(uint256(4)), token0ImmediatePool, -1000, 1000, TOKEN_AMOUNT, TOKEN_AMOUNT, 0
        );

        console2.log("Adding liquidity to token0/weekWrapper pool...");
        positions.mintAndDepositWithSalt(
            bytes32(uint256(5)), token0WeekPool, -1000, 1000, TOKEN_AMOUNT, TOKEN_AMOUNT, 0
        );

        console2.log("Creating token0/token1 stableswap pool...");
        PoolKey memory stableswapPool = PoolKey({
            token0: sortedToken0, token1: sortedToken1, config: createStableswapPoolConfig(1 << 62, 13, 0, address(0))
        });
        core.initializePool(stableswapPool, 0);

        console2.log("Adding liquidity to stableswap pool...");
        (int32 stableLower, int32 stableUpper) = stableswapActiveLiquidityTickRange(stableswapPool.config);
        positions.mintAndDepositWithSalt(
            bytes32(uint256(3)), stableswapPool, stableLower, stableUpper, TOKEN_AMOUNT, TOKEN_AMOUNT, 0
        );

        SqrtRatio defaultLowerLimit = tickToSqrtRatio(DEFAULT_LOWER_TICK);
        SqrtRatio defaultUpperLimit = tickToSqrtRatio(DEFAULT_UPPER_TICK);
        SqrtRatio stableLowerLimit = tickToSqrtRatio(stableLower);
        SqrtRatio stableUpperLimit = tickToSqrtRatio(stableUpper);

        console2.log("\n=== Performing Swaps ===");

        console2.log("Swapping ETH for token0...");
        PoolBalanceUpdate balanceUpdate1 = router.swap{value: SWAP_AMOUNT}(
            ethToken0Pool,
            createSwapParameters({
                _isToken1: false, _amount: int128(SWAP_AMOUNT), _sqrtRatioLimit: defaultLowerLimit, _skipAhead: 0
            }),
            type(int256).min
        );

        console2.log("Swapping ETH for token1...");
        router.swap{value: SWAP_AMOUNT}(
            ethToken1Pool,
            createSwapParameters({
                _isToken1: false, _amount: int128(SWAP_AMOUNT), _sqrtRatioLimit: defaultLowerLimit, _skipAhead: 0
            }),
            type(int256).min
        );

        console2.log("Swapping ETH for token0 through Oracle pool...");
        PoolBalanceUpdate balanceUpdateOracle = router.swap{value: SWAP_AMOUNT}(
            ethToken0OraclePool,
            createSwapParameters({
                _isToken1: false, _amount: int128(SWAP_AMOUNT), _sqrtRatioLimit: defaultLowerLimit, _skipAhead: 0
            }),
            type(int256).min
        );

        console2.log("Swapping token0 for ETH through Oracle pool...");
        uint128 oracleSwapBackAmount = uint128(-balanceUpdateOracle.delta1()) / 2;
        router.swap(
            ethToken0OraclePool,
            createSwapParameters({
                _isToken1: true,
                _amount: int128(oracleSwapBackAmount),
                _sqrtRatioLimit: defaultUpperLimit,
                _skipAhead: 0
            }),
            type(int256).min
        );

        console2.log("Swapping token0 for token1...");
        uint128 token0SwapAmount = uint128(-balanceUpdate1.delta1()) / 2;
        bool isToken1Swap = address(token0) == token0Token1Pool.token1;
        router.swap(
            token0Token1Pool,
            createSwapParameters({
                _isToken1: isToken1Swap,
                _amount: int128(token0SwapAmount),
                _sqrtRatioLimit: isToken1Swap ? defaultUpperLimit : defaultLowerLimit,
                _skipAhead: 0
            }),
            type(int256).min
        );

        console2.log("Swapping token0 for token1 in stableswap pool...");
        uint128 stableSwapAmount = TOKEN_AMOUNT / 100;
        router.swap(
            stableswapPool,
            createSwapParameters({
                _isToken1: isToken1Swap,
                _amount: int128(stableSwapAmount),
                _sqrtRatioLimit: isToken1Swap ? stableUpperLimit : stableLowerLimit,
                _skipAhead: 0
            }),
            type(int256).min
        );

        console2.log("Swapping token1 for token0 in stableswap pool...");
        router.swap(
            stableswapPool,
            createSwapParameters({
                _isToken1: !isToken1Swap,
                _amount: int128(stableSwapAmount),
                _sqrtRatioLimit: !isToken1Swap ? stableUpperLimit : stableLowerLimit,
                _skipAhead: 0
            }),
            type(int256).min
        );

        console2.log("Performing multiple small swaps to initialize slots...");
        for (uint256 i = 0; i < 5; i++) {
            uint128 smallSwapAmount = SWAP_AMOUNT / 10;

            router.swap{value: smallSwapAmount}(
                ethToken0Pool,
                createSwapParameters({
                    _isToken1: false,
                    _amount: int128(smallSwapAmount),
                    _sqrtRatioLimit: defaultLowerLimit,
                    _skipAhead: 0
                }),
                type(int256).min
            );

            router.swap{value: smallSwapAmount}(
                ethToken1Pool,
                createSwapParameters({
                    _isToken1: false,
                    _amount: int128(smallSwapAmount),
                    _sqrtRatioLimit: defaultLowerLimit,
                    _skipAhead: 0
                }),
                type(int256).min
            );

            console2.log("Completed swap iteration", i + 1);
        }

        console2.log("\n=== Withdrawing ETH ===");

        console2.log("Swapping token0 back to ETH...");
        uint128 token0Balance = uint128(token0.balanceOf(deployer));
        if (token0Balance > 0) {
            uint128 swapBackAmount = token0Balance / 2;
            PoolBalanceUpdate balanceUpdateToken0Back = router.swap(
                ethToken0Pool,
                createSwapParameters({
                    _isToken1: true, _amount: int128(swapBackAmount), _sqrtRatioLimit: defaultUpperLimit, _skipAhead: 0
                }),
                type(int256).min
            );
            console2.log("Swapped token0 for ETH - amount:", swapBackAmount);
            console2.log("Received ETH:", uint128(-balanceUpdateToken0Back.delta0()));
        }

        console2.log("Swapping token1 back to ETH...");
        uint128 token1Balance = uint128(token1.balanceOf(deployer));
        if (token1Balance > 0) {
            uint128 swapBackAmount = token1Balance / 2;
            PoolBalanceUpdate balanceUpdate = router.swap(
                ethToken1Pool,
                createSwapParameters({
                    _isToken1: true, _amount: int128(swapBackAmount), _sqrtRatioLimit: defaultUpperLimit, _skipAhead: 0
                }),
                type(int256).min
            );
            console2.log("Swapped token1 for ETH - amount:", swapBackAmount);
            console2.log("Received ETH:", uint128(-balanceUpdate.delta0()));
        }

        uint256 finalEthBalance = deployer.balance;
        console2.log("\n=== Test Complete ===");
        console2.log("Final ETH balance:", finalEthBalance);

        vm.stopBroadcast();
    }
}
