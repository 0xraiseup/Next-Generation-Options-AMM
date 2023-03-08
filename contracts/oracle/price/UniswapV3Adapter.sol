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

    /// @inheritdoc IOracleAdapter
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

        uint104 _gasPerCardinality = l.gasPerCardinality;
        uint112 _gasCostToSupportPool = l.gasCostToSupportPool;

        uint16 targetCardinality = uint16(
            (l.period * l.cardinalityPerMinute) / 60
        ) + 1;

        for (uint256 i; i < pools.length; i++) {
            address pool = pools[i];

            (
                bool increaseCardinality,
                bool gasCostExceedsGasLeft
            ) = _tryIncreaseCardinality(
                    pool,
                    targetCardinality,
                    _gasPerCardinality,
                    _gasCostToSupportPool
                );

            if (increaseCardinality && gasCostExceedsGasLeft) {
                // If the cardinality cannot be increased due to gas cost, then break
                break;
            }

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

    /// @inheritdoc IOracleAdapter
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

    /// @inheritdoc IUniswapV3Adapter
    function factory() external view returns (IUniswapV3Factory) {
        return UNISWAP_V3_FACTORY;
    }

    /// @inheritdoc IUniswapV3Adapter
    function period() external view returns (uint32) {
        return UniswapV3AdapterStorage.layout().period;
    }

    /// @inheritdoc IUniswapV3Adapter
    function cardinalityPerMinute() external view returns (uint8) {
        return UniswapV3AdapterStorage.layout().cardinalityPerMinute;
    }

    /// @inheritdoc IUniswapV3Adapter
    function gasPerCardinality() external view returns (uint104) {
        return UniswapV3AdapterStorage.layout().gasPerCardinality;
    }

    /// @inheritdoc IUniswapV3Adapter
    function gasCostToSupportPool() external view returns (uint112) {
        return UniswapV3AdapterStorage.layout().gasCostToSupportPool;
    }

    /// @inheritdoc IUniswapV3Adapter
    function supportedFeeTiers() external view returns (uint24[] memory) {
        return UniswapV3AdapterStorage.layout().feeTiers;
    }

    /// @inheritdoc IUniswapV3Adapter
    function setPeriod(uint32 newPeriod) external onlyOwner {
        UniswapV3AdapterStorage.layout().period = newPeriod;
        emit PeriodChanged(newPeriod);
    }

    /// @inheritdoc IUniswapV3Adapter
    function setCardinalityPerMinute(
        uint8 _cardinalityPerMinute
    ) external onlyOwner {
        if (_cardinalityPerMinute == 0)
            revert UniswapV3Adapter__InvalidCardinalityPerMinute();

        UniswapV3AdapterStorage
            .layout()
            .cardinalityPerMinute = _cardinalityPerMinute;

        emit CardinalityPerMinuteChanged(_cardinalityPerMinute);
    }

    /// @inheritdoc IUniswapV3Adapter
    function setGasPerCardinality(
        uint104 _gasPerCardinality
    ) external onlyOwner {
        if (_gasPerCardinality == 0)
            revert UniswapV3Adapter__InvalidGasPerCardinality();

        UniswapV3AdapterStorage.layout().gasPerCardinality = _gasPerCardinality;
        emit GasPerCardinalityChanged(_gasPerCardinality);
    }

    /// @inheritdoc IUniswapV3Adapter
    function setGasCostToSupportPool(
        uint112 _gasCostToSupportPool
    ) external onlyOwner {
        if (_gasCostToSupportPool == 0)
            revert UniswapV3Adapter__InvalidGasCostToSupportPool();

        UniswapV3AdapterStorage
            .layout()
            .gasCostToSupportPool = _gasCostToSupportPool;

        emit GasCostToSupportPoolChanged(_gasCostToSupportPool);
    }

    /// @inheritdoc IUniswapV3Adapter
    function insertFeeTier(uint24 feeTier) external onlyOwner {
        if (UNISWAP_V3_FACTORY.feeAmountTickSpacing(feeTier) == 0)
            revert UniswapV3Adapter__InvalidFeeTier(feeTier);

        uint24[] storage feeTiers = UniswapV3AdapterStorage.layout().feeTiers;
        uint256 feeTiersLength = feeTiers.length;

        for (uint256 i; i < feeTiersLength; i++) {
            if (feeTiers[i] == feeTier)
                revert UniswapV3Adapter__FeeTierExists(feeTier);
        }

        feeTiers.push(feeTier);
    }
}
