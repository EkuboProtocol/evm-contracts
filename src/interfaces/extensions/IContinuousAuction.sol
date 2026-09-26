// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

// Forward call types. Anything else forwarded to the extension is decoded as a swap.

// Derived as uint256(keccak256("IContinuousAuction#AUCTION_UPDATE_BID")).
uint256 constant AUCTION_UPDATE_BID = 0x817f5e04de1c259d8b6eaca3386e0fab91aec8a8657e71572d8c5f2b033922a0;

// Derived as uint256(keccak256("IContinuousAuction#AUCTION_COLLECT_RENT")).
uint256 constant AUCTION_COLLECT_RENT = 0x59308c7d9f911514d5a593cf4f67a5a4066857994114abb9f07d934f6dccfb59;

// Derived as uint256(keccak256("IContinuousAuction#AUCTION_COLLECT_SWAP_FEES")).
uint256 constant AUCTION_COLLECT_SWAP_FEES = 0x15e7ff97e5c7bab07b25155d01ffefbee02a6d26103cba0cf21e7f986f4a05e0;

// Salt of the extension's bid-token saved balance in Core. It holds every bid's funding, every credit not yet
// claimed, and rent that was never allocated. Derived as keccak256("IContinuousAuction#AUCTION_FUNDS_SAVED_BALANCE_ID").
bytes32 constant AUCTION_FUNDS_SAVED_BALANCE_ID = 0x63ad5d078f59774a80e391c898311fb84dc495cf7f8bb4d9caecae4ec41d417e;

// Second token of the bid-token saved-balance pair. The bid token must sort below it.
address constant AUCTION_SAVED_BALANCE_PAIR_TOKEN = address(type(uint160).max);

/// @notice Minimal interface of the continuous auction extension used by peripheries.
interface IContinuousAuction {
    function bidToken() external view returns (address);
}
