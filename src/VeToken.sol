// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ERC721} from "solady/tokens/ERC721.sol";

interface IVeTokenObserver {
    function beforeLockUpdate(uint256 veId) external;
}

/// @notice Vote-escrow NFT backed by linear-decaying stake-token locks.
contract VeToken is ERC721 {
    uint256 public constant MAX_LOCK_DURATION = 4 * 365 days;

    address public immutable stakeToken;
    address public immutable lockObserver;

    struct Lock {
        uint128 amount;
        uint64 end;
    }

    mapping(uint256 => Lock) public locks;
    uint256 public nextVeId = 1;

    event LockCreated(uint256 indexed veId, address indexed owner, uint128 amount, uint64 end);
    event LockAmountIncreased(uint256 indexed veId, uint128 amount);
    event LockExtended(uint256 indexed veId, uint64 end);
    event LockWithdrawn(uint256 indexed veId, address indexed owner, uint128 amount);

    error InvalidLock();
    error NotAuthorizedForToken(address caller, uint256 id);

    constructor(address _stakeToken, address _lockObserver) {
        stakeToken = _stakeToken;
        lockObserver = _lockObserver;
    }

    function name() public pure override returns (string memory) {
        return "Vote Escrow";
    }

    function symbol() public pure override returns (string memory) {
        return "ve";
    }

    function tokenURI(uint256) public pure virtual override returns (string memory) {
        return "";
    }

    function isAuthorizedForNft(address account, uint256 id) public view returns (bool) {
        return _isApprovedOrOwner(account, id);
    }

    modifier authorizedForNft(uint256 id) {
        if (!isAuthorizedForNft(msg.sender, id)) revert NotAuthorizedForToken(msg.sender, id);
        _;
    }

    function createLock(uint128 amount, uint64 end) external returns (uint256 veId) {
        if (amount == 0 || end <= block.timestamp || end > block.timestamp + MAX_LOCK_DURATION) revert InvalidLock();

        veId = nextVeId++;
        locks[veId] = Lock({amount: amount, end: end});
        _mint(msg.sender, veId);

        SafeTransferLib.safeTransferFrom(stakeToken, msg.sender, address(this), amount);

        emit LockCreated(veId, msg.sender, amount, end);
    }

    function increaseLockAmount(uint256 veId, uint128 amount) external authorizedForNft(veId) {
        if (amount == 0 || locks[veId].end <= block.timestamp) revert InvalidLock();

        _notifyBeforeLockUpdate(veId);
        locks[veId].amount += amount;
        SafeTransferLib.safeTransferFrom(stakeToken, msg.sender, address(this), amount);

        emit LockAmountIncreased(veId, amount);
    }

    function extendLock(uint256 veId, uint64 end) external authorizedForNft(veId) {
        Lock storage userLock = locks[veId];
        if (userLock.amount == 0 || end <= userLock.end || end > block.timestamp + MAX_LOCK_DURATION) {
            revert InvalidLock();
        }

        _notifyBeforeLockUpdate(veId);
        userLock.end = end;

        emit LockExtended(veId, end);
    }

    function withdrawLock(uint256 veId) external authorizedForNft(veId) {
        Lock memory userLock = locks[veId];
        if (userLock.amount == 0 || block.timestamp < userLock.end) revert InvalidLock();

        _notifyBeforeLockUpdate(veId);
        delete locks[veId];
        _burn(veId);
        SafeTransferLib.safeTransfer(stakeToken, msg.sender, userLock.amount);

        emit LockWithdrawn(veId, msg.sender, userLock.amount);
    }

    function votingPower(uint256 veId) public view returns (uint256) {
        Lock memory userLock = locks[veId];
        if (block.timestamp >= userLock.end) return 0;

        unchecked {
            return (uint256(userLock.amount) * (userLock.end - block.timestamp)) / MAX_LOCK_DURATION;
        }
    }

    function _notifyBeforeLockUpdate(uint256 veId) private {
        address observer = lockObserver;
        if (observer != address(0)) IVeTokenObserver(observer).beforeLockUpdate(veId);
    }
}
