// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {ICore} from "./interfaces/ICore.sol";
import {
    IZeroSeedLaunch,
    ZERO_SEED_LAUNCH_CREATE,
    ZERO_SEED_LAUNCH_CLAIM_FEES
} from "./interfaces/extensions/IZeroSeedLaunch.sol";
import {IZeroSeedLaunchPeriphery} from "./interfaces/IZeroSeedLaunchPeriphery.sol";
import {CoreLib} from "./libraries/CoreLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {PoolKey} from "./types/poolKey.sol";
import {PoolId} from "./types/poolId.sol";

/// @title Zero-seed launch periphery
/// @notice Creates launches for users, records who owns each one, and pays out creator fees. The extension only
/// knows this contract as the controller; ownership lives here and is transferable.
/// @dev Permissionless and ownerless. Each action takes one Core lock, forwards to the extension and settles what the
/// extension left on the lock: nothing for creation, the two fee amounts for a claim. This contract never holds a
/// balance: it cannot receive ETH, and it refuses to be a fee recipient.
contract ZeroSeedLaunchPeriphery is IZeroSeedLaunchPeriphery, BaseLocker {
    using CoreLib for ICore;
    using FlashAccountantLib for *;

    uint256 private constant CALL_CREATE = 0;
    uint256 private constant CALL_CLAIM_FEES = 1;

    ICore private immutable CORE;
    IZeroSeedLaunch public immutable LAUNCH;

    mapping(PoolId => address) public launchOwner;

    constructor(ICore core, IZeroSeedLaunch launch) BaseLocker(core) {
        CORE = core;
        LAUNCH = launch;
    }

    /// @inheritdoc IZeroSeedLaunchPeriphery
    function create(IZeroSeedLaunch.LaunchParameters memory parameters)
        external
        returns (IZeroSeedLaunch.Installation memory installation)
    {
        parameters.salt = _ownerSalt(msg.sender, parameters.salt);
        installation = abi.decode(lock(abi.encode(CALL_CREATE, parameters)), (IZeroSeedLaunch.Installation));
        PoolId poolId = installation.poolKey.toPoolId();
        launchOwner[poolId] = msg.sender;
        emit LaunchOwnerChanged(poolId, address(0), msg.sender);
    }

    /// @inheritdoc IZeroSeedLaunchPeriphery
    function previewInstallation(address owner, IZeroSeedLaunch.LaunchParameters memory parameters)
        external
        view
        returns (IZeroSeedLaunch.Installation memory)
    {
        parameters.salt = _ownerSalt(owner, parameters.salt);
        return LAUNCH.previewInstallation(address(this), parameters);
    }

    /// @inheritdoc IZeroSeedLaunchPeriphery
    function claimFees(PoolKey memory poolKey, address recipient) external returns (uint128 amount0, uint128 amount1) {
        PoolId poolId = poolKey.toPoolId();
        if (launchOwner[poolId] != msg.sender) revert OwnerOnly();
        // Tokens sent to any of these are stranded: Core, the extension and this contract book nothing for a bare
        // transfer, and neither pool token can return a balance held at its own address. For a native quote the
        // zero address is also token0.
        if (
            recipient == address(0) || recipient == address(CORE) || recipient == address(LAUNCH)
                || recipient == address(this) || recipient == poolKey.token0 || recipient == poolKey.token1
        ) revert InvalidRecipient();
        (amount0, amount1) = abi.decode(lock(abi.encode(CALL_CLAIM_FEES, poolKey, recipient)), (uint128, uint128));
        emit LaunchFeesClaimed(poolId, msg.sender, recipient, amount0, amount1);
    }

    /// @inheritdoc IZeroSeedLaunchPeriphery
    function transferLaunch(PoolId poolId, address newOwner) external {
        if (launchOwner[poolId] != msg.sender) revert OwnerOnly();
        if (newOwner == address(0)) revert InvalidOwner();
        launchOwner[poolId] = newOwner;
        emit LaunchOwnerChanged(poolId, msg.sender, newOwner);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory) {
        uint256 callType = abi.decode(data, (uint256));
        if (callType == CALL_CREATE) {
            (, IZeroSeedLaunch.LaunchParameters memory parameters) =
                abi.decode(data, (uint256, IZeroSeedLaunch.LaunchParameters));
            return CORE.forward(address(LAUNCH), abi.encode(ZERO_SEED_LAUNCH_CREATE, parameters));
        }
        (, PoolKey memory poolKey, address recipient) = abi.decode(data, (uint256, PoolKey, address));
        bytes memory result = CORE.forward(address(LAUNCH), abi.encode(ZERO_SEED_LAUNCH_CLAIM_FEES, poolKey));
        (uint128 amount0, uint128 amount1) = abi.decode(result, (uint128, uint128));
        // Core pays native ETH with a plain call, so a reverting recipient fails the whole claim and a reentering one
        // finds the ledger already empty.
        if (amount0 != 0 || amount1 != 0) {
            ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, recipient, amount0, amount1);
        }
        return result;
    }

    function _ownerSalt(address owner, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }
}
