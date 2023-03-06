// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {SafeOwnable} from "@solidstate/contracts/access/ownable/SafeOwnable.sol";
import {SafeCast} from "@solidstate/contracts/utils/SafeCast.sol";

import {IUniswapV3Adapter} from "./IUniswapV3Adapter.sol";
import {IOracleAdapter, OracleAdapter} from "./OracleAdapter.sol";
import {IUniswapV3Factory, UniswapV3AdapterInternal} from "./UniswapV3AdapterInternal.sol";
import {UniswapV3AdapterStorage} from "./UniswapV3AdapterStorage.sol";

/// @notice derived from https://github.com/Mean-Finance/oracles and
///         https://github.com/Mean-Finance/uniswap-v3-oracle
contract UniswapV3Adapter is
    IUniswapV3Adapter,
    OracleAdapter,
    SafeOwnable,
    UniswapV3AdapterInternal
{
    using SafeCast for uint256;
    using UniswapV3AdapterStorage for UniswapV3AdapterStorage.Layout;

    constructor(
        IUniswapV3Factory uniswapV3Factory
    ) UniswapV3AdapterInternal(uniswapV3Factory) {}

    /// @inheritdoc IOracleAdapter
    function isPairSupported(
        address tokenA,
        address tokenB
    ) external view returns (bool isCached, bool hasPath) {
        isCached = _poolsForPair(tokenA, tokenB).length > 0;
        hasPath = _getAllPoolsForPair(tokenA, tokenB).length > 0;
    }

    function upsertPair(address tokenA, address tokenB) external {
        address[] memory pools = _getPoolsSortedByLiquidity(tokenA, tokenB);

        if (pools.length == 0)
            revert OracleAdapter__PairCannotBeSupported(tokenA, tokenB);

        UniswapV3AdapterStorage.Layout storage l = UniswapV3AdapterStorage
            .layout();

        // Load to mem to avoid multiple storage reads
        address[] storage cachedPools = _poolsForPair(tokenA, tokenB);

        uint256 cachedPoolsLength = cachedPools.length;
        uint256 preparedPoolCount;

        uint104 gasCostPerCardinality = l.gasPerCardinality;
        uint112 gasCostToSupportPool = l.gasCostToSupportPool;

        uint16 targetCardinality = uint16(
            (l.period * l.cardinalityPerMinute) / 60
        ) + 1;

        for (uint256 i; i < pools.length; i++) {
            address pool = pools[i];

            _increaseCardinality(
                pool,
                targetCardinality,
                gasCostPerCardinality,
                gasCostToSupportPool
            );

            if (preparedPoolCount < cachedPoolsLength) {
                // Rewrite storage
                cachedPools[preparedPoolCount++] = pool;
            } else {
                // If I have more pools than before, then push
                cachedPools.push(pool);
                preparedPoolCount++;
            }
        }

        if (preparedPoolCount == 0) revert UniswapV3Adapter__GasTooLow();

        // If I have less pools than before, then remove the extra pools
        for (uint256 i = preparedPoolCount; i < cachedPoolsLength; i++) {
            cachedPools.pop();
        }

        emit UpdatedPoolsForPair(tokenA, tokenB, cachedPools);
    }

    /// @inheritdoc IOracleAdapter
    function quote(
        address tokenIn,
        address tokenOut
    ) external view returns (uint256) {
        return _quoteFrom(tokenIn, tokenOut, 0);
    }

    function quoteFrom(
        address tokenIn,
        address tokenOut,
        uint256 target
    ) external view returns (uint256) {
        _ensureTargetNonZero(target);
        return _quoteFrom(tokenIn, tokenOut, target.toUint32());
    }

    /// @inheritdoc IUniswapV3Adapter
    function poolsForPair(
        address tokenA,
        address tokenB
    ) external view returns (address[] memory) {
        return _poolsForPair(tokenA, tokenB);
    }

    // TODO: Natspec
    // /// @inheritdoc IUniswapV3Adapter
    function supportedFeeTiers() external view returns (uint24[] memory) {
        return UniswapV3AdapterStorage.layout().knownFeeTiers;
    }

    /// @inheritdoc IUniswapV3Adapter
    function setPeriod(uint32 newPeriod) external onlyOwner {
        UniswapV3AdapterStorage.layout().period = newPeriod;
        emit PeriodChanged(newPeriod);
    }

    /// @inheritdoc IUniswapV3Adapter
    function setCardinalityPerMinute(
        uint8 cardinalityPerMinute
    ) external onlyOwner {
        if (cardinalityPerMinute == 0)
            revert UniswapV3Adapter__InvalidCardinalityPerMinute();

        UniswapV3AdapterStorage
            .layout()
            .cardinalityPerMinute = cardinalityPerMinute;

        emit CardinalityPerMinuteChanged(cardinalityPerMinute);
    }

    /// @inheritdoc IUniswapV3Adapter
    function setGasPerCardinality(
        uint104 gasPerCardinality
    ) external onlyOwner {
        if (gasPerCardinality == 0)
            revert UniswapV3Adapter__InvalidGasPerCardinality();

        UniswapV3AdapterStorage.layout().gasPerCardinality = gasPerCardinality;
        emit GasPerCardinalityChanged(gasPerCardinality);
    }

    /// @inheritdoc IUniswapV3Adapter
    function setGasCostToSupportPool(
        uint112 gasCostToSupportPool
    ) external onlyOwner {
        if (gasCostToSupportPool == 0)
            revert UniswapV3Adapter__InvalidGasCostToSupportPool();

        UniswapV3AdapterStorage
            .layout()
            .gasCostToSupportPool = gasCostToSupportPool;

        emit GasCostToSupportPoolChanged(gasCostToSupportPool);
    }

    /// @inheritdoc IUniswapV3Adapter
    function insertFeeTier(uint24 feeTier) external onlyOwner {
        if (UNISWAP_V3_FACTORY.feeAmountTickSpacing(feeTier) == 0)
            revert UniswapV3Adapter__InvalidFeeTier(feeTier);

        UniswapV3AdapterStorage.Layout storage l = UniswapV3AdapterStorage
            .layout();

        uint24[] storage knownFeeTiers = l.knownFeeTiers;
        uint256 knownFeeTiersLength = knownFeeTiers.length;

        for (uint256 i; i < knownFeeTiersLength; i++) {
            if (knownFeeTiers[i] == feeTier)
                revert UniswapV3Adapter__FeeTierExists(feeTier);
        }

        knownFeeTiers.push(feeTier);
    }
}
