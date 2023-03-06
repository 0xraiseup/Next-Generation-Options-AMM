// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

/// @notice derived from https://github.com/Mean-Finance/oracles and
///         https://github.com/Mean-Finance/uniswap-v3-oracle
interface IUniswapV3AdapterInternal {
    /// @notice Thrown when trying to add an existing fee tier
    error UniswapV3Adapter__FeeTierExists(uint24 feeTier);

    /// @notice Thrown when the gas limit is so low that no pools can be initialized
    error UniswapV3Adapter__GasTooLow();

    /// @notice Thrown when trying to add an invalid fee tier
    error UniswapV3Adapter__InvalidFeeTier(uint24 feeTier);

    /// @notice Thrown when trying to set an invalid cardinality
    error UniswapV3Adapter__InvalidCardinalityPerMinute();

    /// @notice Thrown when trying to set an invalid gas cost per cardinality
    error UniswapV3Adapter__InvalidGasPerCardinality();

    /// @notice Thrown when trying to set an invalid gas cost to support a pools
    error UniswapV3Adapter__InvalidGasCostToSupportPool();

    /// @notice Thrown when current oberservation cardinality is below target cardinality
    error UniswapV3Adapter__ObservationCardinalityTooLow();

    /// @notice Emitted when a new period is set
    /// @param period The new period
    event PeriodChanged(uint32 period);

    /// @notice Emitted when a new cardinality per minute is set
    /// @param cardinalityPerMinute The new cardinality per minute
    event CardinalityPerMinuteChanged(uint8 cardinalityPerMinute);

    /// @notice Emitted when a new gas cost per cardinality is set
    /// @param gasPerCardinality The new gas per cardinality
    event GasPerCardinalityChanged(uint104 gasPerCardinality);

    /// @notice Emitted when a new gas cost to support pools is set
    /// @param gasCostToSupportPool The new gas cost
    event GasCostToSupportPoolChanged(uint112 gasCostToSupportPool);

    /// @notice Emitted when support is updated (added or modified) for a new pair
    /// @param tokenA One of the pair's tokens
    /// @param tokenB The other of the pair's tokens
    /// @param pools The pools that were prepared to support the pair
    event UpdatedPoolsForPair(address tokenA, address tokenB, address[] pools);
}
