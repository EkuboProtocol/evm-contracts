// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {ERC721} from "solady/tokens/ERC721.sol";
import {Core, ILocker} from "./Core.sol";

// This functionality is externalized so it can be upgraded later, e.g. to change the URL or generate the URI on-chain
interface ITokenURIGenerator {
    function generateTokenURI(uint256 id) external view returns (string memory);
}

contract Positions is ILocker, ERC721 {
    ITokenURIGenerator public immutable tokenURIGenerator;
    Core public immutable core;

    constructor(Core _core, ITokenURIGenerator _tokenURIGenerator) {
        core = _core;
        tokenURIGenerator = _tokenURIGenerator;
    }

    function name() public pure override returns (string memory) {
        return "Ekubo Positions";
    }

    function symbol() public pure override returns (string memory) {
        return "ekuPo";
    }

    function tokenURI(uint256 id) public view override returns (string memory) {
        return tokenURIGenerator.generateTokenURI(id);
    }

    error NotCore();

    function locked(uint256, bytes calldata) external view returns (bytes memory) {
        if (msg.sender != address(core)) revert NotCore();
        return hex"";
    }
}
