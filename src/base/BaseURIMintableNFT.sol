// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {LibString} from "solady/utils/LibString.sol";
import {Ownable} from "solady/auth/Ownable.sol";

import {MintableNFT} from "./MintableNFT.sol";

abstract contract BaseURIMintableNFT is MintableNFT, Ownable {
    string public baseURL;

    constructor(address owner) {
        _initializeOwner(owner);
    }

    function setBaseURL(string memory _baseURL) external onlyOwner {
        baseURL = _baseURL;
    }

    function tokenURI(uint256 id) public view virtual override returns (string memory) {
        return string(abi.encodePacked(baseURL, LibString.toString(id)));
    }
}
