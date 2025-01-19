// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

// This functionality is externalized so it can be upgraded later, e.g. to change the URL or generate the URI on-chain
interface ITokenURIGenerator {
    function generateTokenURI(uint256 id) external view returns (string memory);
}
