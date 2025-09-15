// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

import {LibString} from "solady/utils/LibString.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {MintableNFT} from "./MintableNFT.sol";

abstract contract BaseURIMintableNFT is MintableNFT, Ownable {
    string public baseUrl;

    constructor(address owner) {
        _initializeOwner(owner);
    }

    function setBaseUrl(string memory _baseUrl) external onlyOwner {
        baseUrl = _baseUrl;
    }

    function tokenURI(uint256 id) public view virtual override returns (string memory) {
        return string(abi.encodePacked(baseUrl, LibString.toString(id)));
    }
}
