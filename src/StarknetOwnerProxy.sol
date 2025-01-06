// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

interface IStarknetMessaging {
    function consumeMessageFromL2(
        uint256 fromAddress,
        uint256[] calldata payload
    ) external returns (bytes32);
}

contract StarknetOwnerProxy {
    error MessageExpired(uint64 expiration);
    error InvalidTarget();
    error InsufficientBalance();
    error CallFailed(bytes data);

    IStarknetMessaging public immutable l2MessageBridge;
    uint256 public immutable l2Owner;

    constructor(IStarknetMessaging _l2MessageBridge, uint256 _l2Owner) {
        l2MessageBridge = _l2MessageBridge;
        l2Owner = _l2Owner;
    }

    // Call this to get the payload for a particular call
    function getPayload(
        uint64 expiration,
        address target,
        uint256 value,
        bytes32[] calldata parameters
    ) public pure returns (uint256[] memory) {
        // Create payload for L2 message consumption
        // Each bytes32 needs 2 slots (high and low), plus we need 3 slots for target, value, and expiration
        uint256[] memory payload = new uint256[](3 + parameters.length * 2);

        // Store basic parameters
        payload[0] = uint256(uint160(target));
        payload[1] = value;
        payload[2] = expiration;

        // Copy parameters to payload, splitting each bytes32 into high and low components
        for (uint256 i = 0; i < parameters.length; i++) {
            uint256 parameterValue = uint256(parameters[i]);

            // Split into high and low components
            uint256 lowBits = parameterValue & type(uint128).max;
            uint256 highBits = parameterValue >> 128;

            // Store high and low components in consecutive slots, high bits first
            payload[3 + i * 2] = highBits;
            payload[3 + i * 2 + 1] = lowBits;
        }

        return payload;
    }

    function execute(
        uint64 expiration,
        address target,
        uint256 value,
        bytes32[] calldata parameters
    ) external returns (bytes memory) {
        if (expiration != 0 && block.timestamp > expiration)
            revert MessageExpired(expiration);
        if (target == address(0) || target == address(this))
            revert InvalidTarget();
        if (address(this).balance < value) revert InsufficientBalance();

        // Consume message from L2. This will fail if the message has not been sent from L2.
        l2MessageBridge.consumeMessageFromL2(
            l2Owner,
            getPayload(expiration, target, value, parameters)
        );

        // Create calldata for target contract by combining high and low components
        bytes memory callData = new bytes(parameters.length * 32);
        for (uint256 i = 0; i < parameters.length; i++) {
            bytes32 parameter = parameters[i];
            assembly {
                mstore(add(add(callData, 32), mul(i, 32)), parameter)
            }
        }

        // Make the call to the target contract
        (bool success, bytes memory result) = target.call{value: value}(
            callData
        );
        if (!success) revert CallFailed(result);
        return result;
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
