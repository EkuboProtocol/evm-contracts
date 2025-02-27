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
import {PoolKey, PositionKey, Bounds, maxBounds} from "../src/types/keys.sol";

interface IPositions {
    function withdraw(uint256 id, PoolKey memory poolKey, Bounds memory bounds, uint128 liquidity)
        external
        payable
        returns (uint128 amount0, uint128 amount1);
}

contract PullLiquidityScript is Script {
    function withdraw(Positions positions, uint256 id, PoolKey memory poolKey, Bounds memory bounds)
        internal
        view
        returns (bytes memory)
    {
        (uint128 liquidity,,,,) = positions.getPositionFeesAndLiquidity(id, poolKey, bounds);
        return abi.encodeWithSelector(IPositions.withdraw.selector, id, poolKey, bounds, liquidity);
    }

    function run() public {
        Positions p = Positions(0x4e541FfB7Afda7D2fF20204F6128c7B84Efc204F);

        vm.startBroadcast();

        bytes[] memory calls = new bytes[](22);

        calls[0] = withdraw({
            positions: p,
            id: 278654942660419,
            poolKey: PoolKey({
                token0: address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f),
                token1: address(0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2),
                fee: 0x0,
                tickSpacing: 0xaa8ed,
                extension: 0x51ee1902db6D5640163506b9e178A21Ff027282c
            }),
            bounds: Bounds(-88722835, 88722835)
        });
        calls[1] = withdraw({
            positions: p,
            id: 80191607238165,
            poolKey: PoolKey({
                token0: address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f),
                token1: address(0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72),
                fee: 0x0,
                tickSpacing: 0xaa8ed,
                extension: 0x51ee1902db6D5640163506b9e178A21Ff027282c
            }),
            bounds: Bounds(-88722835, 88722835)
        });
        calls[2] = withdraw({
            positions: p,
            id: 175835691812526,
            poolKey: PoolKey({
                token0: address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f),
                token1: address(0xae78736Cd615f374D3085123A210448E74Fc6393),
                fee: 0x0,
                tickSpacing: 0xaa8ed,
                extension: 0x51ee1902db6D5640163506b9e178A21Ff027282c
            }),
            bounds: Bounds(-88722835, 88722835)
        });
        calls[3] = withdraw({
            positions: p,
            id: 23957664300586,
            poolKey: PoolKey({
                token0: address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f),
                token1: address(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf),
                fee: 0x0,
                tickSpacing: 0xaa8ed,
                extension: 0x51ee1902db6D5640163506b9e178A21Ff027282c
            }),
            bounds: Bounds(-88722835, 88722835)
        });
        calls[4] = withdraw({
            positions: p,
            id: 108530360948222,
            poolKey: PoolKey({
                token0: address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f),
                token1: address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0),
                fee: 0x0,
                tickSpacing: 0xaa8ed,
                extension: 0x51ee1902db6D5640163506b9e178A21Ff027282c
            }),
            bounds: Bounds(-88722835, 88722835)
        });
        calls[5] = withdraw({
            positions: p,
            id: 71176384055866,
            poolKey: PoolKey({
                token0: address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f),
                token1: address(0x6B175474E89094C44Da98b954EedeAC495271d0F),
                fee: 0x0,
                tickSpacing: 0xaa8ed,
                extension: 0x51ee1902db6D5640163506b9e178A21Ff027282c
            }),
            bounds: Bounds(-88722835, 88722835)
        });
        calls[6] = withdraw({
            positions: p,
            id: 108574617226047,
            poolKey: PoolKey({
                token0: address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f),
                token1: address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599),
                fee: 0x0,
                tickSpacing: 0xaa8ed,
                extension: 0x51ee1902db6D5640163506b9e178A21Ff027282c
            }),
            bounds: Bounds(-88722835, 88722835)
        });
        calls[7] = withdraw({
            positions: p,
            id: 54319705127801,
            poolKey: PoolKey({
                token0: address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f),
                token1: address(0xCa14007Eff0dB1f8135f4C25B34De49AB0d42766),
                fee: 0x0,
                tickSpacing: 0xaa8ed,
                extension: 0x51ee1902db6D5640163506b9e178A21Ff027282c
            }),
            bounds: Bounds(-88722835, 88722835)
        });
        calls[8] = withdraw({
            positions: p,
            id: 96575058538612,
            poolKey: PoolKey({
                token0: address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f),
                token1: address(0xdAC17F958D2ee523a2206206994597C13D831ec7),
                fee: 0x0,
                tickSpacing: 0xaa8ed,
                extension: 0x51ee1902db6D5640163506b9e178A21Ff027282c
            }),
            bounds: Bounds(-88722835, 88722835)
        });
        calls[9] = withdraw({
            positions: p,
            id: 194777244350113,
            poolKey: PoolKey({
                token0: address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f),
                token1: address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48),
                fee: 0x0,
                tickSpacing: 0xaa8ed,
                extension: 0x51ee1902db6D5640163506b9e178A21Ff027282c
            }),
            bounds: Bounds(-88722835, 88722835)
        });
        calls[10] = withdraw({
            positions: p,
            id: 224301516552125,
            poolKey: PoolKey({
                token0: address(0xeeeeee000000),
                token1: address(0x04C46E830Bb56ce22735d5d8Fc9CB90309317d0f),
                fee: 0x0,
                tickSpacing: 0xaa8ed,
                extension: 0x51ee1902db6D5640163506b9e178A21Ff027282c
            }),
            bounds: Bounds(-88722835, 88722835)
        });

        calls[11] = abi.encodeWithSelector(Positions.burn.selector, 278654942660419);
        calls[12] = abi.encodeWithSelector(Positions.burn.selector, 80191607238165);
        calls[13] = abi.encodeWithSelector(Positions.burn.selector, 175835691812526);
        calls[14] = abi.encodeWithSelector(Positions.burn.selector, 23957664300586);
        calls[15] = abi.encodeWithSelector(Positions.burn.selector, 108530360948222);
        calls[16] = abi.encodeWithSelector(Positions.burn.selector, 71176384055866);
        calls[17] = abi.encodeWithSelector(Positions.burn.selector, 108574617226047);
        calls[18] = abi.encodeWithSelector(Positions.burn.selector, 54319705127801);
        calls[19] = abi.encodeWithSelector(Positions.burn.selector, 96575058538612);
        calls[20] = abi.encodeWithSelector(Positions.burn.selector, 194777244350113);
        calls[21] = abi.encodeWithSelector(Positions.burn.selector, 224301516552125);

        p.multicall(calls);

        vm.stopBroadcast();
    }
}
