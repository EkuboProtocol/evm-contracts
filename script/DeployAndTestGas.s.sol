// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.30;

/**
 * @title DeployAndTestGas
 * @notice Script for deploying core contracts and performing test transactions for gas testing
 * @dev This script is designed to be run on a network fork for gas measurement purposes.
 *      It performs the following operations:
 *      1. Deploys Core, Positions, MEVCapture extension, Oracle extension, and MEVCaptureRouter contracts
 *      2. Deploys 2 test tokens (TestTokenA and TestTokenB)
 *      3. Creates 4 pools: ETH/token0, ETH/token1, token0/token1, and ETH/token0 with Oracle
 *      4. Adds liquidity to all pools
 *      5. Performs various swaps:
 *         - ETH for token0
 *         - ETH for token1
 *         - token0 for token1
 *         - ETH for token0 through Oracle pool
 *         - Multiple small swaps to initialize all slots
 *      6. Withdraws some of the paid ETH by swapping tokens back
 *
 * Usage:
 *   forge script script/DeployAndTestGas.s.sol:DeployAndTestGas --fork-url <RPC_URL> --broadcast
 *
 * For simulation only (no broadcasting):
 *   forge script script/DeployAndTestGas.s.sol:DeployAndTestGas --fork-url <RPC_URL>
 *
 * Note: Uses small amounts (max 0.1 ETH total) as requested for testing purposes.
 */
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {Core} from "../src/Core.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {IFlashAccountant} from "../src/interfaces/IFlashAccountant.sol";
import {Positions} from "../src/Positions.sol";
import {MEVCapture, mevCaptureCallPoints} from "../src/extensions/MEVCapture.sol";
import {MEVCaptureRouter} from "../src/MEVCaptureRouter.sol";
import {Oracle, oracleCallPoints} from "../src/extensions/Oracle.sol";
import {TWAMM, twammCallPoints} from "../src/extensions/TWAMM.sol";
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
import {NATIVE_TOKEN_ADDRESS, MIN_TICK, MAX_TICK} from "../src/math/constants.sol";
import {findExtensionSalt} from "./DeployCore.s.sol";
import {ERC20} from "solady/tokens/ERC20.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {BaseLocker} from "../src/base/BaseLocker.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";

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

/// @notice Script to deploy core contracts and perform test transactions for gas testing
/// @dev This script deploys Core, Positions, MEVRouter, and 2 tokens, then performs various operations
contract DeployAndTestGas is Script {
    // Use small amounts as requested (max 0.1 ETH)
    uint128 constant ETH_AMOUNT = 0.02 ether;
    uint128 constant TOKEN_AMOUNT = 1000 * 1e18;
    uint128 constant SWAP_AMOUNT = 0.005 ether;

    Core public core;
    Positions public positions;
    MEVCaptureRouter public router;
    TestToken public token0;
    TestToken public token1;
    TokenWrapperFactory public wrapperFactory;
    TokenWrapper public immediateWrapper;
    TokenWrapper public weekWrapper;
    TWAMM public twamm;
    WrapperHelper public wrapperHelper;

    function run() public {
        address deployer = vm.getWallets()[0];

        vm.startBroadcast();

        console2.log("=== Deploying Contracts ===");

        // 1. Deploy Core
        console2.log("Deploying Core...");
        core = new Core();
        console2.log("Core deployed at:", address(core));

        // 2. Deploy Positions
        console2.log("Deploying Positions...");
        positions = new Positions(core, deployer, 0, 1);
        console2.log("Positions deployed at:", address(positions));

        // 3. Deploy MEVCapture extension
        console2.log("Deploying MEVCapture extension...");
        bytes32 salt = bytes32(0);
        bytes32 mevCaptureInitCodeHash = keccak256(abi.encodePacked(type(MEVCapture).creationCode, abi.encode(core)));
        bytes32 mevCaptureSalt = findExtensionSalt(salt, mevCaptureInitCodeHash, mevCaptureCallPoints());
        MEVCapture mevCapture = new MEVCapture{salt: mevCaptureSalt}(core);
        console2.log("MEVCapture deployed at:", address(mevCapture));

        // 4. Deploy Oracle extension
        console2.log("Deploying Oracle extension...");
        bytes32 oracleInitCodeHash = keccak256(abi.encodePacked(type(Oracle).creationCode, abi.encode(core)));
        bytes32 oracleSalt = findExtensionSalt(salt, oracleInitCodeHash, oracleCallPoints());
        Oracle oracle = new Oracle{salt: oracleSalt}(core);
        console2.log("Oracle deployed at:", address(oracle));

        // 5. Deploy TWAMM extension
        console2.log("Deploying TWAMM extension...");
        bytes32 twammInitCodeHash = keccak256(abi.encodePacked(type(TWAMM).creationCode, abi.encode(core)));
        bytes32 twammSalt = findExtensionSalt(salt, twammInitCodeHash, twammCallPoints());
        twamm = new TWAMM{salt: twammSalt}(core);
        console2.log("TWAMM deployed at:", address(twamm));

        // 6. Deploy MEVCaptureRouter
        console2.log("Deploying MEVCaptureRouter...");
        router = new MEVCaptureRouter(core, address(mevCapture));
        console2.log("MEVCaptureRouter deployed at:", address(router));

        // 7. Deploy test tokens
        console2.log("Deploying test tokens...");
        token0 = new TestToken("Test Token A", "TTA", deployer);
        token1 = new TestToken("Test Token B", "TTB", deployer);
        console2.log("Token0 deployed at:", address(token0));
        console2.log("Token1 deployed at:", address(token1));

        // 8. Deploy WrapperHelper
        console2.log("Deploying WrapperHelper...");
        wrapperHelper = new WrapperHelper(core);
        console2.log("WrapperHelper deployed at:", address(wrapperHelper));

        // 9. Deploy TokenWrapperFactory
        console2.log("Deploying TokenWrapperFactory...");
        wrapperFactory = new TokenWrapperFactory(core);
        console2.log("TokenWrapperFactory deployed at:", address(wrapperFactory));

        // 10. Deploy TokenWrappers
        console2.log("Deploying immediate unlock TokenWrapper...");
        immediateWrapper = wrapperFactory.deployWrapper(IERC20(address(token0)), block.timestamp);
        console2.log("Immediate wrapper deployed at:", address(immediateWrapper));

        console2.log("Deploying 1-week unlock TokenWrapper...");
        weekWrapper = wrapperFactory.deployWrapper(IERC20(address(token0)), block.timestamp + 1 weeks);
        console2.log("Week wrapper deployed at:", address(weekWrapper));

        console2.log("Approving all contracts...");
        token0.approve(address(positions), type(uint256).max);
        token1.approve(address(positions), type(uint256).max);
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);
        token0.approve(address(wrapperHelper), type(uint256).max);
        immediateWrapper.approve(address(positions), type(uint256).max);
        weekWrapper.approve(address(positions), type(uint256).max);

        console2.log("\n=== Creating Pools and Positions ===");

        // 11. Create ETH/token0 pool
        console2.log("Creating ETH/token0 pool...");
        PoolKey memory ethToken0Pool = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: address(token0),
            config: createConcentratedPoolConfig(1 << 63, 100, address(0)) // 50% fee, tick spacing 100
        });
        core.initializePool(ethToken0Pool, 0);
        console2.log("ETH/token0 pool initialized");

        // 12. Create ETH/token1 pool
        console2.log("Creating ETH/token1 pool...");
        PoolKey memory ethToken1Pool = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: address(token1),
            config: createConcentratedPoolConfig(1 << 63, 100, address(0)) // 50% fee, tick spacing 100
        });
        core.initializePool(ethToken1Pool, 0);
        console2.log("ETH/token1 pool initialized");

        // 13. Create token0/token1 pool
        // Ensure tokens are sorted by address
        console2.log("Creating token0/token1 pool...");
        (address sortedToken0, address sortedToken1) =
            address(token0) < address(token1) ? (address(token0), address(token1)) : (address(token1), address(token0));
        PoolKey memory token0Token1Pool = PoolKey({
            token0: sortedToken0,
            token1: sortedToken1,
            config: createConcentratedPoolConfig(1 << 63, 100, address(0)) // 50% fee, tick spacing 100
        });
        core.initializePool(token0Token1Pool, 0);
        console2.log("token0/token1 pool initialized");

        // 14. Create ETH/token0 pool with Oracle extension
        console2.log("Creating ETH/token0 pool with Oracle extension...");
        PoolKey memory ethToken0OraclePool = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: address(token0),
            config: createFullRangePoolConfig(0, address(oracle)) // 0% fee, tick spacing 0 (both required by Oracle), Oracle extension
        });
        core.initializePool(ethToken0OraclePool, 0);
        console2.log("ETH/token0 Oracle pool initialized");

        // 15. Create ETH/token0 TWAMM pool
        console2.log("Creating ETH/token0 TWAMM pool...");
        PoolKey memory ethToken0TwammPool = PoolKey({
            token0: NATIVE_TOKEN_ADDRESS,
            token1: address(token0),
            config: createFullRangePoolConfig(1 << 62, address(twamm)) // 25% fee, TWAMM extension
        });
        core.initializePool(ethToken0TwammPool, 0);
        console2.log("ETH/token0 TWAMM pool initialized");

        // 16. Create token0/immediateWrapper pool
        console2.log("Creating token0/immediateWrapper pool...");
        (address sortedToken0Immediate, address sortedToken1Immediate) = address(token0) < address(immediateWrapper)
            ? (address(token0), address(immediateWrapper))
            : (address(immediateWrapper), address(token0));
        PoolKey memory token0ImmediatePool = PoolKey({
            token0: sortedToken0Immediate,
            token1: sortedToken1Immediate,
            config: createConcentratedPoolConfig(1 << 63, 100, address(0)) // 50% fee, tick spacing 100
        });
        // Initialize at price of 0.9 wrapped per unwrapped
        // price = 1.0001^tick, so tick = log(0.9) / log(1.0001) ≈ -1054
        // Round to nearest tick spacing multiple: -1100
        int32 tick09 = sortedToken0Immediate == address(token0) ? int32(-1100) : int32(1100);
        core.initializePool(token0ImmediatePool, tick09);
        console2.log("token0/immediateWrapper pool initialized");

        // 17. Create token0/weekWrapper pool
        console2.log("Creating token0/weekWrapper pool...");
        (address sortedToken0Week, address sortedToken1Week) = address(token0) < address(weekWrapper)
            ? (address(token0), address(weekWrapper))
            : (address(weekWrapper), address(token0));
        PoolKey memory token0WeekPool = PoolKey({
            token0: sortedToken0Week,
            token1: sortedToken1Week,
            config: createConcentratedPoolConfig(1 << 63, 100, address(0)) // 50% fee, tick spacing 100
        });
        int32 tick09Week = sortedToken0Week == address(token0) ? int32(-1100) : int32(1100);
        core.initializePool(token0WeekPool, tick09Week);
        console2.log("token0/weekWrapper pool initialized");

        // 18. Wrap some token0 to get wrapper tokens for liquidity
        console2.log("Wrapping tokens for liquidity provision...");
        wrapperHelper.wrap(immediateWrapper, deployer, TOKEN_AMOUNT);
        wrapperHelper.wrap(weekWrapper, deployer, TOKEN_AMOUNT);
        console2.log("Tokens wrapped");

        // 19. Add liquidity to ETH/token0 pool
        console2.log("Adding liquidity to ETH/token0 pool...");
        positions.mintAndDepositWithSalt{value: ETH_AMOUNT}(
            bytes32(uint256(0)),
            ethToken0Pool,
            -1000, // tickLower
            1000, // tickUpper
            ETH_AMOUNT,
            TOKEN_AMOUNT,
            0
        );
        console2.log("Liquidity added to ETH/token0 pool");

        // 20. Add liquidity to ETH/token1 pool
        console2.log("Adding liquidity to ETH/token1 pool...");
        positions.mintAndDepositWithSalt{value: ETH_AMOUNT}(
            bytes32(uint256(1)),
            ethToken1Pool,
            -1000, // tickLower
            1000, // tickUpper
            ETH_AMOUNT,
            TOKEN_AMOUNT,
            0
        );
        console2.log("Liquidity added to ETH/token1 pool");

        // 21. Add liquidity to token0/token1 pool
        console2.log("Adding liquidity to token0/token1 pool...");
        positions.mintAndDepositWithSalt(
            bytes32(uint256(2)),
            token0Token1Pool,
            -1000, // tickLower
            1000, // tickUpper
            TOKEN_AMOUNT,
            TOKEN_AMOUNT,
            0
        );
        console2.log("Liquidity added to token0/token1 pool");

        // 22. Add liquidity to ETH/token0 Oracle pool
        console2.log("Adding liquidity to ETH/token0 Oracle pool...");
        positions.mintAndDeposit{value: ETH_AMOUNT}(
            ethToken0OraclePool,
            MIN_TICK, // tickLower - full range required for Oracle
            MAX_TICK, // tickUpper - full range required for Oracle
            ETH_AMOUNT,
            TOKEN_AMOUNT,
            0
        );
        console2.log("Liquidity added to ETH/token0 Oracle pool");

        // 23. Add liquidity to ETH/token0 TWAMM pool
        console2.log("Adding liquidity to ETH/token0 TWAMM pool...");
        positions.mintAndDeposit{value: ETH_AMOUNT}(
            ethToken0TwammPool,
            MIN_TICK, // tickLower - full range required for TWAMM
            MAX_TICK, // tickUpper - full range required for TWAMM
            ETH_AMOUNT,
            TOKEN_AMOUNT,
            0
        );
        console2.log("Liquidity added to ETH/token0 TWAMM pool");

        // 24. Add liquidity to token0/immediateWrapper pool
        console2.log("Adding liquidity to token0/immediateWrapper pool...");
        positions.mintAndDepositWithSalt(
            bytes32(uint256(4)),
            token0ImmediatePool,
            -1000, // tickLower
            1000, // tickUpper
            TOKEN_AMOUNT,
            TOKEN_AMOUNT,
            0
        );
        console2.log("Liquidity added to token0/immediateWrapper pool");

        // 25. Add liquidity to token0/weekWrapper pool
        console2.log("Adding liquidity to token0/weekWrapper pool...");
        positions.mintAndDepositWithSalt(
            bytes32(uint256(5)),
            token0WeekPool,
            -1000, // tickLower
            1000, // tickUpper
            TOKEN_AMOUNT,
            TOKEN_AMOUNT,
            0
        );
        console2.log("Liquidity added to token0/weekWrapper pool");

        // 26. Create token0/token1 stableswap pool with amplification 13
        console2.log("Creating token0/token1 stableswap pool (amplification 13)...");
        PoolKey memory stableswapPool = PoolKey({
            token0: sortedToken0,
            token1: sortedToken1,
            config: createStableswapPoolConfig(1 << 62, 13, 0, address(0)) // 25% fee, amplification 13, centered at tick 0
        });
        core.initializePool(stableswapPool, 0);
        console2.log("Stableswap pool initialized");

        // 27. Add liquidity to stableswap pool
        console2.log("Adding liquidity to stableswap pool...");
        (int32 stableLower, int32 stableUpper) = stableswapActiveLiquidityTickRange(stableswapPool.config);
        positions.mintAndDepositWithSalt(
            bytes32(uint256(3)), stableswapPool, stableLower, stableUpper, TOKEN_AMOUNT, TOKEN_AMOUNT, 0
        );
        console2.log("Liquidity added to stableswap pool");

        console2.log("\n=== Performing Swaps ===");

        // 28. Swap ETH for token0
        console2.log("Swapping ETH for token0...");
        PoolBalanceUpdate balanceUpdate1 = router.swap{value: SWAP_AMOUNT}(
            ethToken0Pool,
            createSwapParameters({
                _isToken1: false,
                _amount: int128(SWAP_AMOUNT),
                _sqrtRatioLimit: SqrtRatio.wrap(0),
                _skipAhead: 0
            }),
            type(int256).min
        );
        console2.log("Swap 1 - delta0:", uint128(balanceUpdate1.delta0()), "delta1:", uint128(-balanceUpdate1.delta1()));

        // 29. Swap ETH for token1
        console2.log("Swapping ETH for token1...");
        PoolBalanceUpdate balanceUpdate2 = router.swap{value: SWAP_AMOUNT}(
            ethToken1Pool,
            createSwapParameters({
                _isToken1: false,
                _amount: int128(SWAP_AMOUNT),
                _sqrtRatioLimit: SqrtRatio.wrap(0),
                _skipAhead: 0
            }),
            type(int256).min
        );
        console2.log("Swap 2 - delta0:", uint128(balanceUpdate2.delta0()), "delta1:", uint128(-balanceUpdate2.delta1()));

        // 30. Swap ETH for token0 through Oracle pool
        console2.log("Swapping ETH for token0 through Oracle pool...");
        PoolBalanceUpdate balanceUpdateOracle = router.swap{value: SWAP_AMOUNT}(
            ethToken0OraclePool,
            createSwapParameters({
                _isToken1: false,
                _amount: int128(SWAP_AMOUNT),
                _sqrtRatioLimit: SqrtRatio.wrap(0),
                _skipAhead: 0
            }),
            type(int256).min
        );
        console2.log(
            "Oracle swap - delta0:",
            uint128(balanceUpdateOracle.delta0()),
            "delta1:",
            uint128(-balanceUpdateOracle.delta1())
        );

        // 31. Swap token0 for ETH through Oracle pool
        console2.log("Swapping token0 for ETH through Oracle pool...");
        uint128 oracleSwapBackAmount = uint128(-balanceUpdateOracle.delta1()) / 2;
        PoolBalanceUpdate balanceUpdateOracleBack = router.swap(
            ethToken0OraclePool,
            createSwapParameters({
                _isToken1: true, // isToken1 = true (swapping token1, which is token0)
                _amount: int128(oracleSwapBackAmount),
                _sqrtRatioLimit: SqrtRatio.wrap(0),
                _skipAhead: 0
            }),
            type(int256).min
        );
        console2.log(
            "Oracle swap back - delta0:",
            uint128(-balanceUpdateOracleBack.delta0()),
            "delta1:",
            uint128(balanceUpdateOracleBack.delta1())
        );

        // 32. Swap token0 for token1
        console2.log("Swapping token0 for token1...");
        uint128 token0SwapAmount = uint128(-balanceUpdate1.delta1()) / 2; // Use half of received token0
        // Determine which token we're swapping and set isToken1 accordingly
        bool isToken1Swap = address(token0) == token0Token1Pool.token1;
        PoolBalanceUpdate balanceUpdate3 = router.swap(
            token0Token1Pool,
            createSwapParameters({
                _isToken1: isToken1Swap,
                _amount: int128(token0SwapAmount),
                _sqrtRatioLimit: SqrtRatio.wrap(0),
                _skipAhead: 0
            }),
            type(int256).min
        );
        console2.log("Swap 3 - delta0:", uint128(balanceUpdate3.delta0()), "delta1:", uint128(-balanceUpdate3.delta1()));

        // 33. Swap token0 for token1 in stableswap pool
        console2.log("Swapping token0 for token1 in stableswap pool...");
        uint128 stableSwapAmount = TOKEN_AMOUNT / 100; // 1% of liquidity
        PoolBalanceUpdate balanceUpdateStable = router.swap(
            stableswapPool,
            createSwapParameters({
                _isToken1: isToken1Swap,
                _amount: int128(stableSwapAmount),
                _sqrtRatioLimit: SqrtRatio.wrap(0),
                _skipAhead: 0
            }),
            type(int256).min
        );
        console2.log(
            "Stableswap - delta0:",
            uint128(balanceUpdateStable.delta0()),
            "delta1:",
            uint128(-balanceUpdateStable.delta1())
        );

        // 34. Swap token1 for token0 in stableswap pool
        console2.log("Swapping token1 for token0 in stableswap pool...");
        PoolBalanceUpdate balanceUpdateStableBack = router.swap(
            stableswapPool,
            createSwapParameters({
                _isToken1: !isToken1Swap,
                _amount: int128(stableSwapAmount),
                _sqrtRatioLimit: SqrtRatio.wrap(0),
                _skipAhead: 0
            }),
            type(int256).min
        );
        console2.log(
            "Stableswap back - delta0:",
            uint128(-balanceUpdateStableBack.delta0()),
            "delta1:",
            uint128(balanceUpdateStableBack.delta1())
        );

        // 35. Multiple swaps to initialize all slots
        console2.log("Performing multiple small swaps to initialize slots...");
        for (uint256 i = 0; i < 5; i++) {
            uint128 smallSwapAmount = SWAP_AMOUNT / 10;

            // Swap ETH for token0
            router.swap{value: smallSwapAmount}(
                ethToken0Pool,
                createSwapParameters({
                    _isToken1: false,
                    _amount: int128(smallSwapAmount),
                    _sqrtRatioLimit: SqrtRatio.wrap(0),
                    _skipAhead: 0
                }),
                type(int256).min
            );

            // Swap ETH for token1
            router.swap{value: smallSwapAmount}(
                ethToken1Pool,
                createSwapParameters({
                    _isToken1: false,
                    _amount: int128(smallSwapAmount),
                    _sqrtRatioLimit: SqrtRatio.wrap(0),
                    _skipAhead: 0
                }),
                type(int256).min
            );

            console2.log("Completed swap iteration", i + 1);
        }

        console2.log("\n=== Withdrawing ETH ===");

        // 36. Withdraw paid ETH by swapping tokens back
        // Note: Due to fees, we won't get back exactly what we put in
        console2.log("Swapping token0 back to ETH...");
        uint128 token0Balance = uint128(token0.balanceOf(deployer));
        if (token0Balance > 0) {
            // Only swap back a portion to avoid running out of liquidity
            uint128 swapBackAmount = token0Balance / 2;
            PoolBalanceUpdate balanceUpdateToken0Back = router.swap(
                ethToken0Pool,
                createSwapParameters({
                    _isToken1: true,
                    _amount: int128(swapBackAmount),
                    _sqrtRatioLimit: SqrtRatio.wrap(0),
                    _skipAhead: 0
                }),
                type(int256).min
            );
            console2.log("Swapped token0 for ETH - amount:", swapBackAmount);
            console2.log("Received ETH:", uint128(-balanceUpdateToken0Back.delta0()));
        }

        console2.log("Swapping token1 back to ETH...");
        uint128 token1Balance = uint128(token1.balanceOf(deployer));
        if (token1Balance > 0) {
            // Only swap back a portion to avoid running out of liquidity
            uint128 swapBackAmount = token1Balance / 2;
            PoolBalanceUpdate balanceUpdate = router.swap(
                ethToken1Pool,
                createSwapParameters({
                    _isToken1: true,
                    _amount: int128(swapBackAmount),
                    _sqrtRatioLimit: SqrtRatio.wrap(0),
                    _skipAhead: 0
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
