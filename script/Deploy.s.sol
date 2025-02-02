// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script} from "forge-std/Script.sol";
import {Core} from "../src/Core.sol";
import {Positions} from "../src/Positions.sol";
import {SimpleSwapper, SimpleQuoter} from "../src/SimpleSwapper.sol";
import {Oracle, oracleCallPoints} from "../src/extensions/Oracle.sol";
import {BaseURLTokenURIGenerator} from "../src/BaseURLTokenURIGenerator.sol";
import {PriceFetcher} from "../src/lens/PriceFetcher.sol";
import {CoreDataFetcher} from "../src/lens/CoreDataFetcher.sol";
import {TokenDataFetcher} from "../src/lens/TokenDataFetcher.sol";
import {CallPoints} from "../src/types/callPoints.sol";
import {TestToken} from "../test/TestToken.sol";
import {MAX_TICK_SPACING} from "../src/math/ticks.sol";

import {SlippageChecker} from "../src/base/SlippageChecker.sol";
import {Router, RouteNode, TokenAmount} from "../src/Router.sol";
import {NATIVE_TOKEN_ADDRESS} from "../src/interfaces/IFlashAccountant.sol";
import {PositionKey, Bounds, maxBounds} from "../src/types/positionKey.sol";
import {PoolKey} from "../src/types/poolKey.sol";

function getCreate2Address(address deployer, bytes32 salt, bytes32 initCodeHash) pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
}

address constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

function findExtensionSalt(bytes32 initCodeHash, CallPoints memory callPoints) pure returns (bytes32 salt) {
    uint8 startingByte = callPoints.toUint8();

    unchecked {
        while (true) {
            uint8 predictedStartingByte =
                uint8(uint160(getCreate2Address(DETERMINISTIC_DEPLOYER, salt, initCodeHash)) >> 152);

            if (predictedStartingByte == startingByte) {
                break;
            }

            salt = bytes32(uint256(salt) + 1);
        }
    }
}

contract DeployScript is Script {
    error UnrecognizedChainId(uint256 chainId);

    function generateTestData(Positions positions, Router router, Oracle oracle, address usdc, address eurc) private {
        TestToken token = new TestToken(vm.getWallets()[0]);

        token.approve(address(router), type(uint256).max);
        token.approve(address(positions), type(uint256).max);
        // it is assumed this address has some quantity of oracle token and usdc/eurc already
        TestToken(usdc).approve(address(positions), type(uint256).max);
        TestToken(eurc).approve(address(positions), type(uint256).max);
        TestToken(oracle.oracleToken()).approve(address(positions), type(uint256).max);

        uint256 baseSalt = uint256(keccak256(abi.encode(token)));

        // 30 basis points fee, 0.6% tick spacing, starting price of 5k, 0.01 ETH
        PoolKey memory poolKey = createPool(
            baseSalt++,
            positions,
            NATIVE_TOKEN_ADDRESS,
            address(token),
            uint128((uint256(30) << 128) / 10_000),
            5982,
            address(0),
            8517197,
            10000000000000000,
            50000000000000000000
        );

        // 2 example swaps, back and forth, twice, to demonstrate gas usage
        for (uint256 i = 0; i < 2; i++) {
            bytes[] memory swapCalls = new bytes[](4);
            swapCalls[0] =
                abi.encodeWithSelector(SlippageChecker.recordBalanceForSlippageCheck.selector, address(poolKey.token1));
            swapCalls[1] = abi.encodeWithSelector(
                Router.swap.selector, RouteNode(poolKey, 0, 0), TokenAmount(address(poolKey.token0), 100000)
            );
            swapCalls[2] = abi.encodeWithSelector(SlippageChecker.refundNativeToken.selector);
            swapCalls[3] = abi.encodeWithSelector(
                SlippageChecker.checkMinimumOutputReceived.selector, address(poolKey.token1), (100000 * 5000) / 2
            );
            router.multicall{value: 100000}(swapCalls);

            swapCalls = new bytes[](3);
            swapCalls[0] =
                abi.encodeWithSelector(SlippageChecker.recordBalanceForSlippageCheck.selector, address(poolKey.token0));
            swapCalls[1] = abi.encodeWithSelector(
                Router.swap.selector, RouteNode(poolKey, 0, 0), TokenAmount(address(poolKey.token1), 100000 * 5000)
            );
            swapCalls[2] = abi.encodeWithSelector(
                SlippageChecker.checkMinimumOutputReceived.selector, address(poolKey.token0), 100000 / 2
            );
            router.multicall(swapCalls);
        }

        // 100 basis points fee, 2% tick spacing, starting price of 10k, 0.03 ETH
        createPool(
            baseSalt++,
            positions,
            NATIVE_TOKEN_ADDRESS,
            address(token),
            uint128((uint256(100) << 128) / 10_000),
            19802,
            address(0),
            8517197,
            30000000000000000,
            300000000000000000000
        );

        createPool(
            baseSalt++,
            positions,
            NATIVE_TOKEN_ADDRESS,
            oracle.oracleToken(),
            0,
            MAX_TICK_SPACING,
            address(oracle),
            4605172,
            0.01e18,
            1e18
        );

        createPool(
            baseSalt++,
            positions,
            oracle.oracleToken(),
            address(token),
            0,
            MAX_TICK_SPACING,
            address(oracle),
            4605172,
            1e18,
            100e18
        );

        createPool(
            baseSalt++,
            positions,
            oracle.oracleToken(),
            usdc,
            0,
            MAX_TICK_SPACING,
            address(oracle),
            // 1 USDC / oracle token == 10**6 / 10**18 = log base 1.000001 of 1e-12 = -27631034
            -27631034,
            1e18,
            1e6
        );

        createPool(
            baseSalt++,
            positions,
            oracle.oracleToken(),
            eurc,
            0,
            MAX_TICK_SPACING,
            address(oracle),
            // 2 EURC / oracle token == 2 * 10**6 / 10**18 = log base 1.000001 of 2e-12 = -26937887
            -26937887,
            1e18,
            2e6
        );
    }

    function createPool(
        uint256 salt,
        Positions positions,
        address tokenA,
        address tokenB,
        uint128 fee,
        uint32 tickSpacing,
        address extension,
        int32 startingTick,
        uint128 maxAmount0,
        uint128 maxAmount1
    ) private returns (PoolKey memory poolKey) {
        (tokenA, tokenB, startingTick, maxAmount0, maxAmount1) = tokenA < tokenB
            ? (tokenA, tokenB, startingTick, maxAmount0, maxAmount1)
            : (tokenB, tokenA, -startingTick, maxAmount1, maxAmount0);
        poolKey = PoolKey({token0: tokenA, token1: tokenB, fee: fee, tickSpacing: tickSpacing, extension: extension});

        Bounds memory bounds = maxBounds(tickSpacing);

        bool isETH = tokenA == NATIVE_TOKEN_ADDRESS;
        bytes[] memory calls = isETH ? new bytes[](3) : new bytes[](2);

        calls[0] = abi.encodeWithSelector(Positions.maybeInitializePool.selector, poolKey, startingTick);
        calls[1] = abi.encodeWithSelector(
            Positions.mintAndDepositWithSalt.selector, salt, poolKey, bounds, maxAmount0, maxAmount1, 0
        );
        if (isETH) {
            calls[2] = abi.encodeWithSelector(SlippageChecker.refundNativeToken.selector);
        }

        positions.multicall{value: isETH ? maxAmount0 : 0}(calls);
    }

    function run() public {
        string memory baseUrl;
        address oracleToken;
        address owner;
        address usdc;
        address eurc;
        if (block.chainid == 1) {
            baseUrl = vm.envOr("BASE_URL", string("https://eth-mainnet-api.ekubo.org/positions/nft/"));
            oracleToken = vm.envOr("ORACLE_TOKEN", address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f));
            owner = vm.envOr("OWNER", address(0x1E0EF4162e42C9bF820c307218c4E41cCcA6E9CC));
            usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
            eurc = 0x1aBaEA1f7C830bD89Acc67eC4af516284b1bC33c;
        } else if (block.chainid == 11155111) {
            baseUrl = vm.envOr("BASE_URL", string("https://eth-sepolia-api.ekubo.org/positions/nft/"));
            oracleToken = vm.envOr("ORACLE_TOKEN", address(0x618C25b11a5e9B5Ad60B04bb64FcBdfBad7621d1));
            owner = vm.envOr("OWNER", address(0x36e3FDC259A4a8b0775D25b3f9396e0Ea6E110a5));
            usdc = 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238;
            eurc = 0x08210F9170F89Ab7658F0B5E3fF39b0E03C594D4;
        } else {
            revert UnrecognizedChainId(block.chainid);
        }

        vm.startBroadcast();
        Core core = new Core{salt: 0x0}(owner);
        BaseURLTokenURIGenerator tokenURIGenerator = new BaseURLTokenURIGenerator(owner, baseUrl);
        Positions positions = new Positions{salt: 0x0}(core, tokenURIGenerator);
        Router router = new Router{salt: 0x0}(core);
        Oracle oracle = new Oracle{
            salt: findExtensionSalt(
                keccak256(abi.encodePacked(type(Oracle).creationCode, abi.encode(core, oracleToken))), oracleCallPoints()
            )
        }(core, oracleToken);

        new PriceFetcher(oracle);
        new CoreDataFetcher(core);
        new SimpleSwapper(core);
        new SimpleQuoter(core);
        new TokenDataFetcher();

        if (vm.envOr("CREATE_TEST_DATA", false)) {
            generateTestData(positions, router, oracle, usdc, eurc);
        }

        vm.stopBroadcast();
    }
}
