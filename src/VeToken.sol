// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {BaseLocker} from "./base/BaseLocker.sol";
import {
    Ve33Rewards,
    VE33_MAX_LOCK_DURATION,
    VE33_MOVE_LOCK,
    VE33_STAKE_LOCK,
    VE33_UNSTAKE_LOCK
} from "./extensions/Ve33Rewards.sol";
import {ICore} from "./interfaces/ICore.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {defaultFeeForTickSpacing} from "./math/tickSpacingFee.sol";
import {PoolKey} from "./types/poolKey.sol";

/// @notice Packed vote-escrow lock state.
/// @dev Bits 0..63 store the lock end timestamp. Bits 64..191 store the locked amount.
type Lock is bytes32;

using {lockAmount, lockEnd} for Lock global;

/// @notice Creates a packed lock value.
/// @param amount Amount of stake token locked.
/// @param end Timestamp when the lock can be withdrawn.
/// @return lock Packed lock value.
function createLockValue(uint128 amount, uint64 end) pure returns (Lock lock) {
    assembly ("memory-safe") {
        lock := or(shl(64, amount), end)
    }
}

/// @notice Returns the amount stored in a packed lock.
function lockAmount(Lock lock) pure returns (uint128 amount) {
    assembly ("memory-safe") {
        amount := shr(64, lock)
    }
}

/// @notice Returns the end timestamp stored in a packed lock.
function lockEnd(Lock lock) pure returns (uint64 end) {
    assembly ("memory-safe") {
        end := and(lock, 0xffffffffffffffff)
    }
}

/// @notice Compatibility wrapper over Ve33Rewards lock accounting.
/// @dev This contract intentionally does not implement ERC721 transfer or approval logic.
contract VeToken is BaseLocker {
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_STAKE_LOCK = 0;
    uint256 private constant CALL_TYPE_UNSTAKE_LOCK = 1;
    uint256 private constant CALL_TYPE_MOVE_LOCK = 2;

    Ve33Rewards public immutable ve33Rewards;
    address public immutable stakeToken;

    string private _name;
    string private _symbol;

    mapping(uint256 => address) public lockOwners;
    mapping(uint256 => bytes32) public lockSalts;
    mapping(uint256 => uint64) public lockEndTimes;

    uint256 public nextVeId = 1;

    event LockCreated(uint256 indexed veId, address indexed owner, uint128 amount, uint64 end);
    event LockAmountIncreased(uint256 indexed veId, uint128 amount);
    event LockExtended(uint256 indexed veId, uint64 end);
    event LockUnstaked(uint256 indexed veId, address indexed owner, uint128 amount);

    error InvalidLock();
    error NotAuthorizedForToken(address caller, uint256 id);

    constructor(ICore core, Ve33Rewards _ve33Rewards) BaseLocker(core) {
        ve33Rewards = _ve33Rewards;
        stakeToken = _ve33Rewards.stakeToken();
        _name = string.concat("Vote Escrow ", IERC20(stakeToken).name());
        _symbol = string.concat("ve", IERC20(stakeToken).symbol());
    }

    receive() external payable {}

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function tokenURI(uint256) public pure virtual returns (string memory) {
        return "";
    }

    function MAX_LOCK_DURATION() external pure returns (uint256) {
        return VE33_MAX_LOCK_DURATION;
    }

    function ownerOf(uint256 id) public view returns (address owner) {
        owner = lockOwners[id];
        if (owner == address(0)) revert InvalidLock();
    }

    function isAuthorizedForNft(address account, uint256 id) public view returns (bool) {
        return lockOwners[id] == account;
    }

    modifier authorizedForLock(uint256 id) {
        if (!isAuthorizedForNft(msg.sender, id)) revert NotAuthorizedForToken(msg.sender, id);
        _;
    }

    function locks(uint256 id) public view returns (Lock) {
        uint64 endTime = lockEndTimes[id];
        return createLockValue(ve33Rewards.lockAmounts(address(this), lockSalts[id], endTime), endTime);
    }

    function createLock(uint128 amount, uint64 end) external returns (uint256 veId) {
        veId = nextVeId++;
        bytes32 salt = bytes32(veId);
        lockOwners[veId] = msg.sender;
        lockSalts[veId] = salt;
        lockEndTimes[veId] = end;

        lock(abi.encode(CALL_TYPE_STAKE_LOCK, msg.sender, salt, end, amount));

        emit LockCreated(veId, msg.sender, amount, end);
    }

    function increaseLockAmount(uint256 veId, uint128 amount) external authorizedForLock(veId) {
        lock(abi.encode(CALL_TYPE_STAKE_LOCK, msg.sender, lockSalts[veId], lockEndTimes[veId], amount));

        emit LockAmountIncreased(veId, amount);
    }

    function extendLock(uint256 veId, uint64 end) external authorizedForLock(veId) {
        uint64 currentEnd = lockEndTimes[veId];
        if (end <= currentEnd) revert InvalidLock();

        bytes32 salt = lockSalts[veId];
        uint128 amount = ve33Rewards.lockAmounts(address(this), salt, currentEnd);
        lock(abi.encode(CALL_TYPE_MOVE_LOCK, salt, currentEnd, salt, end, amount));
        lockEndTimes[veId] = end;

        emit LockExtended(veId, end);
    }

    function withdrawLock(uint256 veId) external authorizedForLock(veId) {
        bytes32 salt = lockSalts[veId];
        uint64 endTime = lockEndTimes[veId];
        uint128 amount = ve33Rewards.lockAmounts(address(this), salt, endTime);
        lock(abi.encode(CALL_TYPE_UNSTAKE_LOCK, salt, endTime, amount, msg.sender));

        delete lockOwners[veId];
        delete lockSalts[veId];
        delete lockEndTimes[veId];

        emit LockUnstaked(veId, msg.sender, amount);
    }

    function votingPower(uint256 veId) public view returns (uint256) {
        return ve33Rewards.votingPower(
            Ve33Rewards.LockKey({owner: address(this), salt: lockSalts[veId], endTime: lockEndTimes[veId]})
        );
    }

    function lockKey(uint256 veId) public view returns (Ve33Rewards.LockKey memory) {
        return Ve33Rewards.LockKey({owner: address(this), salt: lockSalts[veId], endTime: lockEndTimes[veId]});
    }

    function vote(uint256 veId, PoolKey[] calldata poolKeys, uint256[] calldata weights, uint64[] calldata swapFees)
        external
        authorizedForLock(veId)
    {
        ve33Rewards.vote(lockKey(veId), poolKeys, weights, swapFees);
    }

    function voteWithTickSpacing(
        uint256 veId,
        PoolKey[] calldata poolKeys,
        uint256[] calldata weights,
        uint32[] calldata tickSpacings
    ) external authorizedForLock(veId) {
        uint64[] memory swapFees = new uint64[](tickSpacings.length);
        for (uint256 i = 0; i < tickSpacings.length; i++) {
            swapFees[i] = defaultFeeForTickSpacing(tickSpacings[i]);
        }
        ve33Rewards.vote(lockKey(veId), poolKeys, weights, swapFees);
    }

    function claimPoolFees(uint256 veId, PoolKey memory poolKey) external returns (uint128 amount0, uint128 amount1) {
        address owner = ownerOf(veId);
        (amount0, amount1) = ve33Rewards.claimPoolFees(lockKey(veId), poolKey);
        _transferToken(poolKey.token0, owner, amount0);
        _transferToken(poolKey.token1, owner, amount1);
    }

    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_STAKE_LOCK) {
            (, address owner, bytes32 salt, uint64 endTime, uint128 amount) =
                abi.decode(data, (uint256, address, bytes32, uint64, uint128));
            result = ACCOUNTANT.forward(address(ve33Rewards), abi.encode(VE33_STAKE_LOCK, salt, endTime, amount));
            uint128 staked = abi.decode(result, (uint128));
            if (staked != 0) ACCOUNTANT.payFrom(owner, stakeToken, staked);
        } else if (callType == CALL_TYPE_UNSTAKE_LOCK) {
            (, bytes32 salt, uint64 endTime, uint128 amount, address recipient) =
                abi.decode(data, (uint256, bytes32, uint64, uint128, address));
            result = ACCOUNTANT.forward(address(ve33Rewards), abi.encode(VE33_UNSTAKE_LOCK, salt, endTime, amount));
            uint128 unstaked = abi.decode(result, (uint128));
            if (unstaked != 0) ACCOUNTANT.withdraw(stakeToken, recipient, unstaked);
        } else if (callType == CALL_TYPE_MOVE_LOCK) {
            (, bytes32 fromSalt, uint64 fromEndTime, bytes32 toSalt, uint64 toEndTime, uint128 amount) =
                abi.decode(data, (uint256, bytes32, uint64, bytes32, uint64, uint128));
            result = ACCOUNTANT.forward(
                address(ve33Rewards), abi.encode(VE33_MOVE_LOCK, fromSalt, fromEndTime, toSalt, toEndTime, amount)
            );
        } else {
            revert();
        }
    }

    function _transferToken(address token, address recipient, uint128 amount) private {
        if (amount != 0) {
            if (token == NATIVE_TOKEN_ADDRESS) {
                SafeTransferLib.safeTransferETH(recipient, amount);
            } else {
                SafeTransferLib.safeTransfer(token, recipient, amount);
            }
        }
    }
}
