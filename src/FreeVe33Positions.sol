// SPDX-License-Identifier: ekubo-license-v1.eth
pragma solidity =0.8.33;

import {BaseVe33Positions} from "./base/BaseVe33Positions.sol";
import {Ve33} from "./extensions/Ve33.sol";
import {ICore} from "./interfaces/ICore.sol";
import {PoolKey} from "./types/poolKey.sol";

/// @notice Ve33 positions implementation that does not charge protocol fees on claimed rewards.
contract FreeVe33Positions is BaseVe33Positions {
    constructor(ICore core, Ve33 ve33, address owner) BaseVe33Positions(core, ve33, owner) {}

    /// @inheritdoc BaseVe33Positions
    function _computeClaimRewardsProtocolFee(PoolKey memory, uint128) internal pure override returns (uint128) {
        return 0;
    }
}
