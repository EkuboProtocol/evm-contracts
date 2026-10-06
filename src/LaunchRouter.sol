// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {ICore} from "./interfaces/ICore.sol";
import {BaseLocker} from "./base/BaseLocker.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {ScheduledLaunch} from "./extensions/ScheduledLaunch.sol";
import {LockedLaunchLiquidity} from "./LockedLaunchLiquidity.sol";
import {LAUNCH_CREATE, LAUNCH_FUND, LAUNCH_CLAIM_FEES} from "./interfaces/extensions/IScheduledLaunch.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolId} from "./types/poolId.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Creation, funding and fee-claim periphery for ScheduledLaunch. Swaps go through any router's standard
/// forwarded swap; this contract has no swap or quote path.
/// @dev Non-upgradeable, no admin, and holds nothing between calls: every call settles inside its own lock. It is
/// the owner of record of every launch it creates and releases that launch's fees only to the recorded creator.
contract LaunchRouter is BaseLocker {
    using FlashAccountantLib for *;

    uint8 private constant ACTION_CREATE = 0;
    uint8 private constant ACTION_FUND = 1;
    uint8 private constant ACTION_CLAIM = 2;

    ScheduledLaunch public immutable EXTENSION;
    LockedLaunchLiquidity public immutable LIQUIDITY;

    /// @notice Caller of `create` for each launch created here, the only account that may claim its fees.
    mapping(PoolId launchId => address) public creator;

    error CreatorOnly();
    error InvalidPayment();
    error InvalidRecipient();

    event LaunchCreatedBy(PoolId indexed launchId, address indexed creator);

    constructor(ICore core, ScheduledLaunch extension) BaseLocker(core) {
        EXTENSION = extension;
        LIQUIDITY = extension.LIQUIDITY();
    }

    /// @notice Creates a launch with this contract as owner of record; config.owner is ignored.
    function create(ScheduledLaunch.LaunchConfig memory config) external returns (PoolKey memory key, address token) {
        config.owner = address(this);
        (key, token) = abi.decode(lock(abi.encode(ACTION_CREATE, config)), (PoolKey, address));
        creator[key.toPoolId()] = msg.sender;
        emit LaunchCreatedBy(key.toPoolId(), msg.sender);
    }

    /// @notice Adds exact amounts to a migrated launch's locked principal, paid by msg.sender: msg.value must
    /// equal amount0 for a native token0 and be zero otherwise; ERC-20 amounts are pulled by transferFrom.
    function fund(PoolId launchId, uint128 amount0, uint128 amount1) external payable {
        lock(abi.encode(ACTION_FUND, abi.encode(launchId, amount0, amount1, msg.sender, msg.value)));
    }

    /// @notice Withdraws the launch's creator fees from both contracts to `recipient`. Creator only.
    function claimFees(PoolKey memory key, address recipient) external returns (uint128 amount0, uint128 amount1) {
        if (creator[key.toPoolId()] != msg.sender) revert CreatorOnly();
        if (recipient == address(0)) revert InvalidRecipient();
        (amount0, amount1) = abi.decode(lock(abi.encode(ACTION_CLAIM, abi.encode(key, recipient))), (uint128, uint128));
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        uint8 action = abi.decode(data, (uint8));
        if (action == ACTION_CREATE) {
            (, ScheduledLaunch.LaunchConfig memory config) = abi.decode(data, (uint8, ScheduledLaunch.LaunchConfig));
            return ACCOUNTANT.forward(address(EXTENSION), abi.encode(LAUNCH_CREATE, config));
        }
        (, bytes memory args) = abi.decode(data, (uint8, bytes));
        if (action == ACTION_FUND) {
            _fund(args);
            return "";
        }
        return _claim(args);
    }

    function _fund(bytes memory args) private {
        (PoolId launchId, uint128 amount0, uint128 amount1, address payer, uint256 value) =
            abi.decode(args, (PoolId, uint128, uint128, address, uint256));
        PoolKey memory key = LIQUIDITY.getTerminal(launchId).poolKey;
        ACCOUNTANT.forward(address(LIQUIDITY), abi.encode(LAUNCH_FUND, launchId, amount0, amount1));
        bool native = key.token0 == NATIVE_TOKEN_ADDRESS;
        if (value != (native ? amount0 : 0)) revert InvalidPayment();
        if (amount0 != 0) {
            if (native) SafeTransferLib.safeTransferETH(address(ACCOUNTANT), amount0);
            else ACCOUNTANT.payFrom(payer, key.token0, amount0);
        }
        if (amount1 != 0) ACCOUNTANT.payFrom(payer, key.token1, amount1);
    }

    /// @dev Locked principal fees exist only after migration starts, when the terminal records this owner.
    function _claim(bytes memory args) private returns (bytes memory) {
        (PoolKey memory key, address recipient) = abi.decode(args, (PoolKey, address));
        (uint128 amount0, uint128 amount1) = abi.decode(
            ACCOUNTANT.forward(address(EXTENSION), abi.encode(LAUNCH_CLAIM_FEES, key, recipient)), (uint128, uint128)
        );
        PoolId launchId = key.toPoolId();
        if (LIQUIDITY.getTerminal(launchId).owner == address(this)) {
            (uint128 locked0, uint128 locked1) = abi.decode(
                ACCOUNTANT.forward(address(LIQUIDITY), abi.encode(LAUNCH_CLAIM_FEES, launchId, recipient)),
                (uint128, uint128)
            );
            amount0 += locked0;
            amount1 += locked1;
        }
        ACCOUNTANT.withdrawTwo(key.token0, key.token1, recipient, amount0, amount1);
        return abi.encode(amount0, amount1);
    }
}
