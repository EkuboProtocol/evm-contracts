// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseForwardee} from "../src/base/BaseForwardee.sol";
import {ICore} from "../src/interfaces/ICore.sol";
import {CoreLib} from "../src/libraries/CoreLib.sol";
import {FlashAccountantLib} from "../src/libraries/FlashAccountantLib.sol";
import {Locker} from "../src/types/locker.sol";
import {PoolBalanceUpdate} from "../src/types/poolBalanceUpdate.sol";
import {PoolKey} from "../src/types/poolKey.sol";
import {PoolState} from "../src/types/poolState.sol";
import {SwapParameters} from "../src/types/swapParameters.sol";

struct ForwardedSwapRoute {
    PoolKey poolKey;
    SwapParameters params;
    bool useExtension;
    bool reverseResult;
    bool returnInvalidTokens;
    bool misreportDeltas;
}

/// @notice Test router that leaves swap debts on the original Core locker.
contract ForwardedSwapRouter is BaseForwardee {
    using CoreLib for *;
    using FlashAccountantLib for *;

    ICore private immutable CORE;

    constructor(ICore core) BaseForwardee(core) {
        CORE = core;
    }

    function handleForwardData(Locker, bytes memory data) internal override returns (bytes memory result) {
        ForwardedSwapRoute memory route = abi.decode(data, (ForwardedSwapRoute));
        if (route.returnInvalidTokens) {
            return abi.encode(address(1), address(2), int256(0), int256(0));
        }

        PoolBalanceUpdate balanceUpdate;
        if (route.useExtension) {
            (balanceUpdate,) = abi.decode(
                CORE.forward(route.poolKey.config.extension(), abi.encode(route.poolKey, route.params)),
                (PoolBalanceUpdate, PoolState)
            );
        } else {
            (balanceUpdate,) = CORE.swap(0, route.poolKey, route.params);
        }

        address specifiedToken = route.params.isToken1() ? route.poolKey.token1 : route.poolKey.token0;
        address calculatedToken = route.params.isToken1() ? route.poolKey.token0 : route.poolKey.token1;
        int256 specifiedDelta =
            route.params.isToken1() ? int256(balanceUpdate.delta1()) : int256(balanceUpdate.delta0());
        int256 calculatedDelta =
            route.params.isToken1() ? int256(balanceUpdate.delta0()) : int256(balanceUpdate.delta1());

        if (route.misreportDeltas) return abi.encode(specifiedToken, calculatedToken, int256(0), int256(0));
        if (route.reverseResult) {
            return abi.encode(calculatedToken, specifiedToken, calculatedDelta, specifiedDelta);
        }
        result = abi.encode(specifiedToken, calculatedToken, specifiedDelta, calculatedDelta);
    }
}
