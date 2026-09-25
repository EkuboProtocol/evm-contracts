// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseLocker} from "./base/BaseLocker.sol";
import {PayableMulticallable} from "./base/PayableMulticallable.sol";
import {ContinuousAuction} from "./extensions/ContinuousAuction.sol";
import {ICore} from "./interfaces/ICore.sol";
import {ContinuousAuctionLib} from "./libraries/ContinuousAuctionLib.sol";
import {FlashAccountantLib} from "./libraries/FlashAccountantLib.sol";
import {NATIVE_TOKEN_ADDRESS} from "./math/constants.sol";
import {PoolKey} from "./types/poolKey.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Token-settling periphery for continuous-auction bidders.
/// @dev The extension accounts bids and fees as Core saved balances during `forward`; this contract is the
/// locker that pays or withdraws the corresponding tokens. Bids are keyed by this contract and a salt derived
/// from the caller, so each caller controls its own bids. Native bid tokens are paid from ETH sent to this
/// contract in the same call; batch `refundNativeToken()` in a multicall to recover any excess.
contract AuctionPeriphery is PayableMulticallable, BaseLocker {
    using FlashAccountantLib for *;

    uint256 private constant CALL_TYPE_UPDATE_BID = 0;
    uint256 private constant CALL_TYPE_COLLECT_SWAP_FEES = 1;

    ICore private immutable CORE_REF;
    ContinuousAuction public immutable auction;
    address public immutable bidToken;

    constructor(ICore core, ContinuousAuction _auction) BaseLocker(core) {
        CORE_REF = core;
        auction = _auction;
        bidToken = _auction.bidToken();
    }

    receive() external payable {}

    /// @notice The salt this contract forwards for a caller's salt.
    function bidderSalt(address owner, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(owner, salt));
    }

    /// @notice The bidder identity the extension keys a caller's bid by.
    function bidderId(address owner, bytes32 salt) external view returns (bytes32) {
        return ContinuousAuctionLib.bidderId(address(this), bidderSalt(owner, salt));
    }

    /// @notice Sets the caller's bid on the pool from the next second on. Rate zero removes it and withdraws
    /// any credit. See ContinuousAuction for the rules.
    /// @return delta Bid-token amount paid (positive) or withdrawn to recipient (negative).
    function updateBid(
        PoolKey memory poolKey,
        bytes32 salt,
        uint96 rate,
        uint64 end,
        address executor,
        uint32 fee,
        address recipient
    ) external payable returns (int256 delta) {
        delta = abi.decode(
            lock(abi.encode(CALL_TYPE_UPDATE_BID, msg.sender, salt, poolKey, rate, end, executor, fee, recipient)),
            (int256)
        );
    }

    /// @notice Collects the swap fees earned by the caller's bid on the pool to recipient.
    function collectSwapFees(PoolKey memory poolKey, bytes32 salt, address recipient)
        external
        payable
        returns (uint128 amount0, uint128 amount1)
    {
        (amount0, amount1) = abi.decode(
            lock(abi.encode(CALL_TYPE_COLLECT_SWAP_FEES, msg.sender, salt, poolKey, recipient)), (uint128, uint128)
        );
    }

    /// @inheritdoc BaseLocker
    function handleLockData(uint256, bytes memory data) internal override returns (bytes memory result) {
        uint256 callType = abi.decode(data, (uint256));

        if (callType == CALL_TYPE_UPDATE_BID) {
            (
                ,
                address owner,
                bytes32 salt,
                PoolKey memory poolKey,
                uint96 rate,
                uint64 end,
                address executor,
                uint32 fee,
                address recipient
            ) = abi.decode(data, (uint256, address, bytes32, PoolKey, uint96, uint64, address, uint32, address));

            int256 delta = ContinuousAuctionLib.updateBid(
                CORE_REF, address(auction), poolKey, bidderSalt(owner, salt), rate, end, executor, fee
            );
            if (delta > 0) {
                if (bidToken == NATIVE_TOKEN_ADDRESS) {
                    SafeTransferLib.safeTransferETH(address(ACCOUNTANT), uint256(delta));
                } else {
                    ACCOUNTANT.payFrom(owner, bidToken, uint256(delta));
                }
            } else if (delta < 0) {
                ACCOUNTANT.withdraw(bidToken, recipient, SafeCastLib.toUint128(uint256(-delta)));
            }
            result = abi.encode(delta);
        } else if (callType == CALL_TYPE_COLLECT_SWAP_FEES) {
            (, address owner, bytes32 salt, PoolKey memory poolKey, address recipient) =
                abi.decode(data, (uint256, address, bytes32, PoolKey, address));

            (uint128 amount0, uint128 amount1) =
                ContinuousAuctionLib.collectSwapFees(CORE_REF, address(auction), poolKey, bidderSalt(owner, salt));
            ACCOUNTANT.withdrawTwo(poolKey.token0, poolKey.token1, recipient, amount0, amount1);
            result = abi.encode(amount0, amount1);
        } else {
            revert();
        }
    }
}
