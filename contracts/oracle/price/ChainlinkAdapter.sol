// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {SafeOwnable} from "@solidstate/contracts/access/ownable/SafeOwnable.sol";

import {ChainlinkAdapterInternal, ChainlinkAdapterStorage} from "./ChainlinkAdapterInternal.sol";
import {IChainlinkAdapter} from "./IChainlinkAdapter.sol";
import {IOracleAdapter, OracleAdapter} from "./OracleAdapter.sol";

/// @notice derived from https://github.com/Mean-Finance/oracles
contract ChainlinkAdapter is
    ChainlinkAdapterInternal,
    IChainlinkAdapter,
    OracleAdapter,
    SafeOwnable
{
    using ChainlinkAdapterStorage for ChainlinkAdapterStorage.Layout;

    constructor(
        address _wrappedNativeToken,
        address _wrappedBTCToken
    ) ChainlinkAdapterInternal(_wrappedNativeToken, _wrappedBTCToken) {}

    /// @inheritdoc IOracleAdapter
    function isPairSupported(
        address tokenA,
        address tokenB
    ) external view returns (bool isCached, bool hasPath) {
        (
            PricingPath path,
            address mappedTokenA,
            address mappedTokenB
        ) = _pathForPair(tokenA, tokenB, true);

        isCached = path != PricingPath.NONE;

        if (isCached) return (isCached, true);

        hasPath =
            _determinePricingPath(mappedTokenA, mappedTokenB) !=
            PricingPath.NONE;
    }

    /// @inheritdoc IOracleAdapter
    function upsertPair(address tokenA, address tokenB) external {
        _upsertPair(tokenA, tokenB);
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
        return _quoteFrom(tokenIn, tokenOut, target);
    }

    /// @inheritdoc IChainlinkAdapter
    function pathForPair(
        address tokenA,
        address tokenB
    ) external view returns (PricingPath) {
        (PricingPath path, , ) = _pathForPair(tokenA, tokenB, false);
        return path;
    }

    /// @inheritdoc IChainlinkAdapter
    function batchRegisterFeedMappings(
        FeedMappingArgs[] memory args
    ) external onlyOwner {
        for (uint256 i = 0; i < args.length; i++) {
            address token = _tokenToDenomination(args[i].token);
            address denomination = args[i].denomination;

            if (token == denomination)
                revert OracleAdapter__TokensAreSame(token, denomination);

            if (token == address(0) || denomination == address(0))
                revert OracleAdapter__ZeroAddress();

            bytes32 keyForPair = _keyForUnsortedPair(token, denomination);
            ChainlinkAdapterStorage.layout().feeds[keyForPair] = args[i].feed;
        }

        emit FeedMappingsRegistered(args);
    }

    /// @inheritdoc IChainlinkAdapter
    function feed(
        address tokenA,
        address tokenB
    ) external view returns (address) {
        (address mappedTokenA, address mappedTokenB) = _mapToDenomination(
            tokenA,
            tokenB
        );

        return _feed(mappedTokenA, mappedTokenB);
    }
}