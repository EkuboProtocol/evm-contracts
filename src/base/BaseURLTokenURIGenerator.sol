// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Test} from "forge-std/Test.sol";
import {ITokenURIGenerator} from "../Positions.sol";
import {LibString} from "solady/utils/LibString.sol";

contract BaseURLTokenURIGenerator is ITokenURIGenerator {
    string public baseURL;

    constructor(string memory _baseURL) {
        baseURL = _baseURL;
    }

    function generateTokenURI(uint256 id) external view returns (string memory) {
        return string(abi.encodePacked(baseURL, LibString.toString(id)));
    }
}
