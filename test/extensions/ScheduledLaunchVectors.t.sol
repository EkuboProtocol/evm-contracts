// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// Conformance vectors for an off-chain launch pool model: the next forwarded swap as a function of
// (config, deployed, reserves, Core pool state, timestamp, params) -> (deltas, fee, post-state). The state
// inputs are exactly what LaunchCreated, the last LaunchAdvanced and Core's own events reveal.
//
// The committed file is checked on every run. Regenerate it after an intended behavior change with
//   WRITE_LAUNCH_VECTORS=true forge test --match-contract ScheduledLaunchVectorsTest

import {Vm} from "forge-std/Vm.sol";
import {ScheduledLaunchTest} from "./ScheduledLaunch.t.sol";
import {ScheduledLaunch} from "../../src/extensions/ScheduledLaunch.sol";
import {MintableERC20} from "../../src/MintableERC20.sol";
import {CoreLib} from "../../src/libraries/CoreLib.sol";
import {PoolKey} from "../../src/types/poolKey.sol";
import {PoolId} from "../../src/types/poolId.sol";
import {PoolState} from "../../src/types/poolState.sol";
import {PoolBalanceUpdate} from "../../src/types/poolBalanceUpdate.sol";
import {SwapParameters, createSwapParameters} from "../../src/types/swapParameters.sol";
import {SqrtRatio} from "../../src/types/sqrtRatio.sol";

contract ScheduledLaunchVectorsTest is ScheduledLaunchTest {
    using CoreLib for *;

    string constant PATH = "test/vectors/scheduled-launch-swaps.json";
    bytes32 constant SWAPPED = keccak256("LaunchSwapped(bytes32,address,int128,int128,uint128,bool)");

    enum Quote {
        Token1,
        Token0,
        Native
    }

    struct Case {
        string name;
        Quote quote;
        // Optional earlier buy of quote at priorTime.
        uint128 priorBuy;
        uint64 priorTime;
        uint64 time;
        // Buy: quote in or launch token out. Sell: launch token in or quote out.
        bool buy;
        bool exactOut;
        // Exact-in amount, or exact-out amount as a positive number. Zero sells half the prior buy's output.
        uint128 amount;
    }

    function _cases() internal pure returns (Case[] memory c) {
        c = new Case[](23);
        uint256 n;
        for (uint256 i; i < 2; i++) {
            Quote q = i == 0 ? Quote.Token1 : Quote.Token0;
            string memory side = i == 0 ? "launch_token0" : "launch_token1";
            c[n++] = Case(string.concat(side, "_buy_exact_in"), q, 0, 0, START + 300, true, false, 1_000e18);
            c[n++] = Case(string.concat(side, "_buy_exact_out"), q, 0, 0, START + 300, true, true, 50_000e18);
            // A sell in the same second as a buy, before any further release.
            c[n++] =
                Case(string.concat(side, "_sell_exact_in"), q, 10_000e18, START + 300, START + 300, false, false, 0);
            c[n++] = Case(
                string.concat(side, "_sell_exact_out"), q, 10_000e18, START + 300, START + 300, false, true, 1_000e18
            );
            // The swap's advance releases inventory first, which sells back toward the target.
            c[n++] = Case(
                string.concat(side, "_sell_after_release"), q, 900_000e18, START + 100, START + 150, false, false, 0
            );
            // Nothing is offered below the target: the advance re-sells to the target and the sell fills zero.
            c[n++] = Case(
                string.concat(side, "_sell_at_target_fills_zero"),
                q,
                10_000e18,
                START + 100,
                START + 300,
                false,
                false,
                0
            );
            c[n++] =
                Case(string.concat(side, "_buy_partial_fill_range_top"), q, 0, 0, START + 100, true, false, 900_000e18);
            c[n++] = Case(string.concat(side, "_buy_first_second"), q, 0, 0, START, true, false, 1_000e18);
            c[n++] = Case(
                string.concat(side, "_buy_last_second"), q, 10_000e18, START + 100, END - 1, true, false, 1_000e18
            );
            c[n++] =
                Case(string.concat(side, "_sell_last_second"), q, 10_000e18, END - 1, END - 1, false, true, 1_000e18);
            c[n++] = Case(string.concat(side, "_buy_exact_out_last_second"), q, 0, 0, END - 1, true, true, 10_000e18);
        }
        c[n++] = Case("native_quote_buy_exact_in", Quote.Native, 0, 0, START + 300, true, false, 1e18);
        assert(n == c.length);
    }

    function test_vectors() public {
        Case[] memory cases = _cases();
        string memory json = "{\n  \"cases\": [\n";
        for (uint256 i; i < cases.length; i++) {
            uint256 snapshot = vm.snapshotState();
            json = string.concat(json, _run(cases[i]), i + 1 == cases.length ? "\n" : ",\n");
            vm.revertToState(snapshot);
        }
        json = string.concat(json, "  ]\n}\n");
        if (vm.envOr("WRITE_LAUNCH_VECTORS", false)) vm.writeFile(PATH, json);
        else assertEq(vm.readFile(PATH), json, "vectors changed; regenerate with WRITE_LAUNCH_VECTORS=true");
    }

    function _run(Case memory c) internal returns (string memory) {
        address quote = c.quote == Quote.Native ? address(0) : c.quote == Quote.Token0 ? LOW_QUOTE : HIGH_QUOTE;
        ScheduledLaunch.LaunchConfig memory config = _config(quote);
        vm.deal(address(this), 1_000 ether);
        vm.deal(address(actor), 1_000 ether);
        (PoolKey memory key, address token) = launchRouter.create(config);
        _track(token);
        MintableERC20(token).approve(address(actor), type(uint256).max);
        bool tokenIs0 = key.token0 == token;

        uint128 held;
        if (c.priorBuy != 0) {
            vm.warp(c.priorTime);
            held = _buy(key, c.priorBuy);
        }
        vm.warp(c.time);

        // Buys pay quote; exact-in amounts are positive and exact-out amounts negative.
        bool isToken1 = c.buy != c.exactOut ? tokenIs0 : !tokenIs0;
        uint128 amount = c.amount == 0 ? held / 2 : c.amount;
        SwapParameters params =
            createSwapParameters(SqrtRatio.wrap(0), c.exactOut ? -int128(amount) : int128(amount), isToken1, 0);

        string memory pre = _state(key);
        vm.recordLogs();
        PoolBalanceUpdate update = actor.swap(extension, key, params);
        _assertNoCustody();
        (uint128 fee, bool feeIsToken1) = _feeFromLogs(key);
        return string.concat(
            "    {\n      \"name\": \"",
            c.name,
            "\",\n      \"config\": ",
            _configJson(key, config, tokenIs0),
            ",\n      \"timestamp\": ",
            vm.toString(uint256(c.time)),
            ",\n      \"params\": ",
            _paramsJson(params),
            ",\n      \"pre\": ",
            pre,
            ",\n      \"result\": ",
            _resultJson(update, fee, feeIsToken1),
            ",\n      \"post\": ",
            _state(key),
            "\n    }"
        );
    }

    function _feeFromLogs(PoolKey memory key) internal returns (uint128 fee, bool feeIsToken1) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 count;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(extension) || logs[i].topics[0] != SWAPPED) continue;
            assertEq(logs[i].topics[1], PoolId.unwrap(key.toPoolId()));
            (,, fee, feeIsToken1) = abi.decode(logs[i].data, (int128, int128, uint128, bool));
            count++;
        }
        assertEq(count, 1, "one LaunchSwapped");
    }

    function _configJson(PoolKey memory key, ScheduledLaunch.LaunchConfig memory config, bool tokenIs0)
        internal
        view
        returns (string memory)
    {
        ScheduledLaunch.Launch memory launch = extension.getLaunch(key.toPoolId());
        return string.concat(
            "{\"token0\": \"",
            vm.toString(key.token0),
            "\", \"token1\": \"",
            vm.toString(key.token1),
            "\", \"launchTokenIs0\": ",
            vm.toString(tokenIs0),
            ", \"poolConfig\": \"",
            vm.toString(bytes32(abi.encode(key.config))),
            "\", ",
            _launchConfigJson(config),
            ", \"poolTargetTick\": ",
            vm.toString(int256(launch.targetTick)),
            ", \"positionTickLower\": ",
            vm.toString(int256(launch.positionId.tickLower())),
            ", \"positionTickUpper\": ",
            vm.toString(int256(launch.positionId.tickUpper())),
            "}"
        );
    }

    function _launchConfigJson(ScheduledLaunch.LaunchConfig memory config) internal pure returns (string memory) {
        return string.concat(
            "\"totalSupply\": \"",
            vm.toString(uint256(config.totalSupply)),
            "\", \"startTime\": ",
            vm.toString(uint256(config.startTime)),
            ", \"endTime\": ",
            vm.toString(uint256(config.endTime)),
            ", \"targetTick\": ",
            vm.toString(int256(config.targetTick)),
            ", \"upperTick\": ",
            vm.toString(int256(config.upperTick)),
            ", \"tickSpacing\": ",
            vm.toString(uint256(config.tickSpacing)),
            ", \"initialFee\": \"",
            vm.toString(uint256(config.initialFee)),
            "\", \"finalFee\": \"",
            vm.toString(uint256(config.finalFee)),
            "\""
        );
    }

    function _paramsJson(SwapParameters params) internal pure returns (string memory) {
        return string.concat(
            "{\"amount\": \"",
            vm.toString(int256(params.amount())),
            "\", \"isToken1\": ",
            vm.toString(params.isToken1()),
            ", \"sqrtRatioLimit\": \"",
            vm.toString(uint256(SqrtRatio.unwrap(params.sqrtRatioLimit()))),
            "\", \"skipAhead\": ",
            vm.toString(params.skipAhead()),
            "}"
        );
    }

    function _resultJson(PoolBalanceUpdate update, uint128 fee, bool feeIsToken1)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "{\"delta0\": \"",
            vm.toString(int256(update.delta0())),
            "\", \"delta1\": \"",
            vm.toString(int256(update.delta1())),
            "\", \"feeAmount\": \"",
            vm.toString(uint256(fee)),
            "\", \"feeIsToken1\": ",
            vm.toString(feeIsToken1),
            "}"
        );
    }

    /// @dev Launch state as the last LaunchAdvanced reports it, and Core pool state. The launch position is the
    /// only liquidity in the pool, so its liquidity fixes every initialized tick.
    function _state(PoolKey memory key) internal view returns (string memory) {
        PoolId id = key.toPoolId();
        ScheduledLaunch.Launch memory launch = extension.getLaunch(id);
        (uint128 reserve0, uint128 reserve1) = _balances(address(extension), key, PoolId.unwrap(id));
        PoolState state = core.poolState(id);
        uint128 position = core.poolPositions(id, address(extension), launch.positionId).liquidity;
        return string.concat(
            "{\"deployed\": \"",
            vm.toString(uint256(launch.deployed)),
            "\", \"reserve0\": \"",
            vm.toString(uint256(reserve0)),
            "\", \"reserve1\": \"",
            vm.toString(uint256(reserve1)),
            "\", \"sqrtRatio\": \"",
            vm.toString(uint256(SqrtRatio.unwrap(state.sqrtRatio()))),
            "\", \"tick\": ",
            vm.toString(int256(state.tick())),
            ", \"liquidity\": \"",
            vm.toString(uint256(state.liquidity())),
            "\", \"positionLiquidity\": \"",
            vm.toString(uint256(position)),
            "\"}"
        );
    }
}
