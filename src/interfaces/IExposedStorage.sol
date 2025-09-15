// SPDX-License-Identifier: Ekubo-DAO-SRL-1.0
pragma solidity =0.8.28;

// Exposes all the storage of a contract via view methods.
// Absent https://eips.ethereum.org/EIPS/eip-2330 this makes it easier to access specific pieces of state in the inheriting contract.
interface IExposedStorage {
    // Loads each slot after the function selector from the contract's storage and returns all of them.
    function sload() external view;
    // Loads each slot after the function selector from the contract's transient storage and returns all of them.
    function tload() external view;
}
