// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ITokenURIGenerator} from "./interfaces/ITokenURIGenerator.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Ownable} from "solady/auth/Ownable.sol";

contract BaseURLTokenURIGenerator is Ownable, ITokenURIGenerator {
    string public baseURL;
    address public replacementContract;

    constructor(address owner, string memory _baseURL) {
        _initializeOwner(owner);
        baseURL = _baseURL;
    }

    function setBaseURL(string memory _baseURL) external onlyOwner {
        baseURL = _baseURL;
    }

    function setReplacementContract(address _replacementContract) external onlyOwner {
        replacementContract = _replacementContract;
    }

    function generateTokenURI(uint256 id) external view returns (string memory) {
        // for upgradeability we just point to a new address
        if (replacementContract != address(0)) {
            return ITokenURIGenerator(replacementContract).generateTokenURI(id);
        }
        return string(abi.encodePacked(baseURL, LibString.toString(id)));
    }
}
