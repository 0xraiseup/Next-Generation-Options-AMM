// SPDX-License-Identifier: LGPL-3.0-or-later
// For terms and conditions regarding commercial use please see https://license.premia.blue
pragma solidity ^0.8.19;

import {UD60x18} from "@prb/math/UD60x18.sol";

import {IPoolFactoryEvents} from "./IPoolFactoryEvents.sol";

interface IPoolFactory is IPoolFactoryEvents {
    error PoolFactory__IdenticalAddresses();
    error PoolFactory__OptionExpired(uint256 maturity);
    error PoolFactory__OptionMaturityExceedsMax(uint256 maturity);
    error PoolFactory__OptionMaturityNot8UTC(uint256 maturity);
    error PoolFactory__OptionMaturityNotFriday(uint256 maturity);
    error PoolFactory__OptionMaturityNotLastFriday(uint256 maturity);
    error PoolFactory__OptionStrikeEqualsZero();
    error PoolFactory__OptionStrikeInvalid(UD60x18 strike, UD60x18 strikeInterval);
    error PoolFactory__PoolAlreadyDeployed(address poolAddress);
    error PoolFactory__TransferNativeTokenFailed();
    error PoolFactory__ZeroAddress();

    struct PoolKey {
        // Address of base token
        address base;
        // Address of quote token
        address quote;
        // Address of oracle adapter
        address oracleAdapter;
        // The strike of the option (18 decimals)
        UD60x18 strike;
        // The maturity timestamp of the option
        uint256 maturity;
        // Whether the pool is for call or put options
        bool isCallPool;
    }

    /// @notice Returns whether the given address is a pool
    /// @param contractAddress The address to check
    /// @return Whether the given address is a pool
    function isPool(address contractAddress) external view returns (bool);

    /// @notice Returns the address of a valid pool, and whether it has been deployed. If the pool configuration is invalid
    ///         the transaction will revert.
    /// @param k The pool key
    /// @return pool The pool address
    /// @return isDeployed Whether the pool has been deployed
    function getPoolAddress(PoolKey calldata k) external view returns (address pool, bool isDeployed);

    /// @notice Deploy a new option pool
    /// @param k The pool key
    /// @return poolAddress The address of the deployed pool
    function deployPool(PoolKey calldata k) external payable returns (address poolAddress);

    /// @notice DEPRECATED: Calculates the initialization fee for a pool
    /// @param k The pool key
    /// @return The initialization fee (18 decimals)
    function initializationFee(PoolKey calldata k) external view returns (UD60x18);
}
