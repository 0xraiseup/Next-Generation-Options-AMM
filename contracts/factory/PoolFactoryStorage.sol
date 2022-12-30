// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

// ToDo : Remove ?
library PoolFactoryStorage {
    using PoolFactoryStorage for PoolFactoryStorage.Layout;

    bytes32 internal constant STORAGE_SLOT =
        keccak256("premia.contracts.storage.PoolFactory");

    struct Layout {
        address feeRecipient;
        //        mapping(address => mapping(address => mapping(address => mapping(address => mapping(bool => address))))) pools;
        //        address[] poolList;
        //        mapping(address => bool) isPool;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }
}