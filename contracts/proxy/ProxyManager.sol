// SPDX-License-Identifier: LicenseRef-P3-DUAL
// For terms and conditions regarding commercial use please see https://license.premia.blue
pragma solidity ^0.8.19;

import {OwnableInternal} from "@solidstate/contracts/access/ownable/OwnableInternal.sol";

import {ProxyManagerStorage} from "./ProxyManagerStorage.sol";
import {IProxyManager} from "./IProxyManager.sol";

contract ProxyManager is IProxyManager, OwnableInternal {
    function getManagedProxyImplementation() external view returns (address) {
        return ProxyManagerStorage.layout().managedProxyImplementation;
    }

    function setManagedProxyImplementation(address implementation) external onlyOwner {
        ProxyManagerStorage.layout().managedProxyImplementation = implementation;
        emit ManagedImplementationSet(implementation);
    }
}
