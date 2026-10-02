// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ScheduledLaunch} from "./extensions/ScheduledLaunch.sol";
import {LockedLaunchLiquidity} from "./LockedLaunchLiquidity.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolId} from "./types/poolId.sol";
import {PoolState} from "./types/poolState.sol";
import {PoolBalanceUpdate} from "./types/poolBalanceUpdate.sol";
import {SwapParameters} from "./types/swapParameters.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Creates, trades and funds ScheduledLaunch pools on behalf of msg.sender.
/// @dev msg.sender pays every amount owed. Native surplus is refunded to msg.sender before each call
/// returns. The router holds no tokens or approvals between calls.
contract LaunchRouter is BaseLocker {
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_CREATE = 0;
    uint256 private constant CALL_TYPE_SWAP = 1;
    uint256 private constant CALL_TYPE_FUND = 2;
    uint256 private constant CALL_TYPE_QUOTE = 3;

    ScheduledLaunch public immutable EXTENSION;
    LockedLaunchLiquidity public immutable LIQUIDITY;

    error DeadlineExpired(uint256 deadline);
    error InvalidRecipient();
    error PartialSwapsDisallowed();
    error SlippageCheckFailed(int256 expectedAmount, int256 calculatedAmount);
    error QuoteReturnValue(PoolBalanceUpdate balanceUpdate);

    /// @notice Records who paid for a routed launch action. Recipient is the launch owner for create,
    /// the output recipient for swap, and the liquidity contract for fund.
    event LaunchRouted(PoolId indexed poolId, address indexed payer, address indexed recipient);

    constructor(ICore core, ScheduledLaunch extension) BaseLocker(core) {
        EXTENSION = extension;
        LIQUIDITY = extension.LIQUIDITY();
    }

    modifier ensure(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        _;
        if (address(this).balance != 0) SafeTransferLib.safeTransferETH(msg.sender, address(this).balance);
    }

    /// @notice Creates a launch, paying config.quoteAmount of config.quoteToken from msg.sender.
    function create(ScheduledLaunch.LaunchConfig memory config, uint256 deadline)
        external
        payable
        ensure(deadline)
        returns (PoolKey memory key, address token)
    {
        key = abi.decode(lock(abi.encode(CALL_TYPE_CREATE, msg.sender, config)), (PoolKey));
        token = key.token0 == config.quoteToken ? key.token1 : key.token0;
        emit LaunchRouted(key.toPoolId(), msg.sender, config.owner);
    }

    /// @notice Swaps against a launch pool. Buys stop at the top of the launch range.
    /// @param calculatedAmountThreshold Lower bound on the fee-inclusive calculated amount from the swapper's
    /// side: minimum output for exact input, negated maximum input for exact output.
    /// @dev Exact-input swaps may fill partially and are bounded by minimum output. Exact-output swaps must fill.
    function swap(
        PoolKey memory key,
        SwapParameters params,
        int256 calculatedAmountThreshold,
        address recipient,
        uint256 deadline
    ) external payable ensure(deadline) returns (PoolBalanceUpdate update) {
        if (recipient == address(0)) revert InvalidRecipient();
        update = abi.decode(
            lock(abi.encode(CALL_TYPE_SWAP, msg.sender, key, params, calculatedAmountThreshold, recipient)),
            (PoolBalanceUpdate)
        );
        emit LaunchRouted(key.toPoolId(), msg.sender, recipient);
    }

    /// @notice Runs the same forwarded swap as `swap` and reverts it. Call through eth_call.
    /// @return update Fee-inclusive pool-perspective deltas.
    /// @return fee Creator fee rate charged at this block, as a 0.64 fixed-point fraction.
    function quote(PoolKey memory key, SwapParameters params) external returns (PoolBalanceUpdate update, uint64 fee) {
        bytes memory revertData =
            lockAndExpectRevert(abi.encode(CALL_TYPE_QUOTE, address(0), key, params, int256(0), address(0)));
        bytes4 sig;
        assembly ("memory-safe") {
            sig := mload(add(revertData, 32))
        }
        if (sig != QuoteReturnValue.selector || revertData.length != 36) {
            assembly ("memory-safe") {
                revert(add(revertData, 32), mload(revertData))
            }
        }
        assembly ("memory-safe") {
            update := mload(add(revertData, 36))
        }
        fee = EXTENSION.feeAt(key.toPoolId());
    }

    /// @notice Adds counterpart assets to a launch's locked principal, paid by msg.sender. Funds are never
    /// withdrawable; they are deposited by the next migration.
    function fund(PoolId launchId, uint128 amount0, uint128 amount1, uint256 deadline)
        external
        payable
        ensure(deadline)
    {
        lock(abi.encode(CALL_TYPE_FUND, msg.sender, launchId, amount0, amount1));
        emit LaunchRouted(launchId, msg.sender, address(LIQUIDITY));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));
        if (callType == CALL_TYPE_CREATE) {
            (, address payer, ScheduledLaunch.LaunchConfig memory config) =
                abi.decode(data, (uint256, address, ScheduledLaunch.LaunchConfig));
            result = ACCOUNTANT.forward(address(EXTENSION), abi.encode(uint8(0), config));
            _pay(payer, config.quoteToken, config.quoteAmount);
        } else if (callType == CALL_TYPE_FUND) {
            (, address payer, PoolId launchId, uint128 amount0, uint128 amount1) =
                abi.decode(data, (uint256, address, PoolId, uint128, uint128));
            ACCOUNTANT.forward(address(LIQUIDITY), abi.encode(uint8(1), launchId, amount0, amount1));
            PoolKey memory terminal = LIQUIDITY.getTerminal(launchId).poolKey;
            _pay(payer, terminal.token0, amount0);
            _pay(payer, terminal.token1, amount1);
        } else {
            (
                ,
                address payer,
                PoolKey memory key,
                SwapParameters params,
                int256 calculatedAmountThreshold,
                address recipient
            ) = abi.decode(data, (uint256, address, PoolKey, SwapParameters, int256, address));
            (PoolBalanceUpdate update,) = abi.decode(
                ACCOUNTANT.forward(address(EXTENSION), abi.encode(uint8(1), key, params)),
                (PoolBalanceUpdate, PoolState)
            );
            if (callType == CALL_TYPE_QUOTE) revert QuoteReturnValue(update);
            _checkSlippage(params, update, calculatedAmountThreshold);
            _settle(payer, recipient, key.token0, update.delta0());
            _settle(payer, recipient, key.token1, update.delta1());
            result = abi.encode(update);
        }
    }

    function _checkSlippage(SwapParameters params, PoolBalanceUpdate update, int256 threshold) private pure {
        (int256 calculated, int128 specified) = params.isToken1()
            ? (-int256(update.delta0()), update.delta1())
            : (-int256(update.delta1()), update.delta0());
        if (params.isExactOut() && specified != params.amount()) revert PartialSwapsDisallowed();
        if (calculated < threshold) revert SlippageCheckFailed(threshold, calculated);
    }

    function _settle(address payer, address recipient, address token, int128 delta) private {
        if (delta < 0) ACCOUNTANT.withdraw(token, recipient, uint128(-delta));
        else _pay(payer, token, uint128(delta));
    }

    function _pay(address payer, address token, uint128 amount) private {
        if (amount == 0) return;
        if (token == NATIVE_TOKEN_ADDRESS) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount);
        else ACCOUNTANT.payFrom(payer, token, amount);
    }
}
