// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.19;

import {Denominations} from "@chainlink/contracts/src/v0.8/Denominations.sol";
import {UD60x18} from "@prb/math/UD60x18.sol";
import {SafeCast} from "@solidstate/contracts/utils/SafeCast.sol";

import {ONE} from "../../libraries/Constants.sol";
import {AggregatorProxyInterface} from "../../vendor/AggregatorProxyInterface.sol";

import {OracleAdapterInternal} from "../OracleAdapterInternal.sol";
import {FeedRegistry} from "../FeedRegistry.sol";
import {ETH_DECIMALS, FOREX_DECIMALS, Tokens} from "../Tokens.sol";

import {IChainlinkAdapterInternal} from "./IChainlinkAdapterInternal.sol";
import {ChainlinkAdapterStorage} from "./ChainlinkAdapterStorage.sol";

abstract contract ChainlinkAdapterInternal is
    IChainlinkAdapterInternal,
    OracleAdapterInternal,
    FeedRegistry
{
    using ChainlinkAdapterStorage for ChainlinkAdapterStorage.Layout;
    using ChainlinkAdapterStorage for IChainlinkAdapterInternal.PricingPath;
    using ChainlinkAdapterStorage for address;
    using SafeCast for int256;
    using Tokens for address;

    /// @dev If a fresh price is unavailable the adapter will wait the duration of
    ///      MAX_DELAY before returning the stale price
    uint256 internal constant MAX_DELAY = 12 hours;
    /// @dev If the difference between target and last update is greater than the
    ///      PRICE_STALE_THRESHOLD, the price is considered stale
    uint256 internal constant PRICE_STALE_THRESHOLD = 25 hours;

    constructor(
        address _wrappedNativeToken,
        address _wrappedBTCToken
    ) FeedRegistry(_wrappedNativeToken, _wrappedBTCToken) {}

    function _quoteFrom(
        address tokenIn,
        address tokenOut,
        uint256 target
    ) internal view returns (UD60x18) {
        (
            PricingPath path,
            address mappedTokenIn,
            address mappedTokenOut
        ) = _pricingPath(tokenIn, tokenOut, false);

        if (path == PricingPath.NONE) {
            path = _determinePricingPath(mappedTokenIn, mappedTokenOut);

            if (path == PricingPath.NONE)
                revert OracleAdapter__PairNotSupported(tokenIn, tokenOut);
        }
        if (path <= PricingPath.TOKEN_ETH) {
            return _getDirectPrice(path, mappedTokenIn, mappedTokenOut, target);
        } else if (path <= PricingPath.TOKEN_ETH_TOKEN) {
            return
                _getPriceSameBase(path, mappedTokenIn, mappedTokenOut, target);
        } else if (path <= PricingPath.A_ETH_USD_B) {
            return
                _getPriceDifferentBases(
                    path,
                    mappedTokenIn,
                    mappedTokenOut,
                    target
                );
        } else {
            return _getPriceWBTCPrice(mappedTokenIn, mappedTokenOut, target);
        }
    }

    function _pricingPath(
        address tokenA,
        address tokenB,
        bool sortTokens
    )
        internal
        view
        returns (PricingPath path, address mappedTokenA, address mappedTokenB)
    {
        (mappedTokenA, mappedTokenB) = _mapToDenomination(tokenA, tokenB);

        (address sortedA, address sortedB) = mappedTokenA.sortTokens(
            mappedTokenB
        );

        path = ChainlinkAdapterStorage.layout().pricingPath[
            sortedA.keyForSortedPair(sortedB)
        ];

        if (sortTokens) {
            mappedTokenA = sortedA;
            mappedTokenB = sortedB;
        }
    }

    /// @dev Handles prices when the pair is either ETH/USD, token/ETH or token/USD
    function _getDirectPrice(
        PricingPath path,
        address tokenIn,
        address tokenOut,
        uint256 target
    ) internal view returns (UD60x18) {
        UD60x18 price;

        if (path == PricingPath.ETH_USD) {
            price = _getETHUSD(target);
        } else if (path == PricingPath.TOKEN_USD) {
            price = _getPriceAgainstUSD(
                tokenOut.isUSD() ? tokenIn : tokenOut,
                target
            );
        } else if (path == PricingPath.TOKEN_ETH) {
            price = _getPriceAgainstETH(
                tokenOut.isETH() ? tokenIn : tokenOut,
                target
            );
        }

        bool invert = tokenIn.isUSD() ||
            (path == PricingPath.TOKEN_ETH && tokenIn.isETH());

        return invert ? price.inv() : price;
    }

    /// @dev Handles prices when both tokens share the same base (either ETH or USD)
    function _getPriceSameBase(
        PricingPath path,
        address tokenIn,
        address tokenOut,
        uint256 target
    ) internal view returns (UD60x18) {
        int8 factor = PricingPath.TOKEN_USD_TOKEN == path
            ? int8(ETH_DECIMALS - FOREX_DECIMALS)
            : int8(0);

        address base = path == PricingPath.TOKEN_USD_TOKEN
            ? Denominations.USD
            : Denominations.ETH;

        uint256 tokenInToBase = _fetchQuote(tokenIn, base, target);
        uint256 tokenOutToBase = _fetchQuote(tokenOut, base, target);

        UD60x18 adjustedTokenInToBase = UD60x18.wrap(
            _scale(tokenInToBase, factor)
        );
        UD60x18 adjustedTokenOutToBase = UD60x18.wrap(
            _scale(tokenOutToBase, factor)
        );

        return adjustedTokenInToBase / adjustedTokenOutToBase;
    }

    /// @dev Handles prices when one of the tokens uses ETH as the base, and the other USD
    function _getPriceDifferentBases(
        PricingPath path,
        address tokenIn,
        address tokenOut,
        uint256 target
    ) internal view returns (UD60x18) {
        UD60x18 adjustedEthToUSDPrice = _getETHUSD(target);

        bool isTokenInUSD = (path == PricingPath.A_USD_ETH_B &&
            tokenIn < tokenOut) ||
            (path == PricingPath.A_ETH_USD_B && tokenIn > tokenOut);

        if (isTokenInUSD) {
            UD60x18 adjustedTokenInToUSD = _getPriceAgainstUSD(tokenIn, target);
            UD60x18 tokenOutToETH = _getPriceAgainstETH(tokenOut, target);
            return adjustedTokenInToUSD / adjustedEthToUSDPrice / tokenOutToETH;
        } else {
            UD60x18 tokenInToETH = _getPriceAgainstETH(tokenIn, target);

            UD60x18 adjustedTokenOutToUSD = _getPriceAgainstUSD(
                tokenOut,
                target
            );

            return
                (tokenInToETH * adjustedEthToUSDPrice) / adjustedTokenOutToUSD;
        }
    }

    /// @dev Handles prices when the pair is token/WBTC
    function _getPriceWBTCPrice(
        address tokenIn,
        address tokenOut,
        uint256 target
    ) internal view returns (UD60x18) {
        bool isTokenInWBTC = tokenIn == WRAPPED_BTC_TOKEN;

        UD60x18 adjustedWBTCToUSDPrice = _getWBTCBTC(target) *
            _getBTCUSD(target);

        UD60x18 adjustedTokenToUSD = _getPriceAgainstUSD(
            !isTokenInWBTC ? tokenIn : tokenOut,
            target
        );

        UD60x18 price = adjustedWBTCToUSDPrice / adjustedTokenToUSD;
        return !isTokenInWBTC ? price.inv() : price;
    }

    /// @dev Expects `tokenA` and `tokenB` to be sorted
    function _determinePricingPath(
        address tokenA,
        address tokenB
    ) internal view virtual returns (PricingPath) {
        if (tokenA == tokenB)
            revert OracleAdapter__TokensAreSame(tokenA, tokenB);

        bool isTokenAUSD = tokenA.isUSD();
        bool isTokenBUSD = tokenB.isUSD();
        bool isTokenAETH = tokenA.isETH();
        bool isTokenBETH = tokenB.isETH();
        bool isTokenAWBTC = tokenA == WRAPPED_BTC_TOKEN;
        bool isTokenBWBTC = tokenB == WRAPPED_BTC_TOKEN;

        if ((isTokenAETH && isTokenBUSD) || (isTokenAUSD && isTokenBETH)) {
            return PricingPath.ETH_USD;
        }

        address srcToken;
        ConversionType conversionType;
        PricingPath preferredPath;
        PricingPath fallbackPath;

        bool wbtcUSDFeedExists = _feedExists(
            isTokenAWBTC ? tokenA : tokenB,
            Denominations.USD
        );

        if ((isTokenAWBTC || isTokenBWBTC) && !wbtcUSDFeedExists) {
            // If one of the token is WBTC and there is no WBTC/USD feed, we want to convert the other token to WBTC
            // Note: If there is a WBTC/USD feed the preferred path is TOKEN_USD, TOKEN_USD_TOKEN, or A_USD_ETH_B
            srcToken = isTokenAWBTC ? tokenB : tokenA;
            conversionType = ConversionType.TO_BTC;
            // PricingPath used are same, but effective path slightly differs because of the 2 attempts in `_tryToFindPath`
            preferredPath = PricingPath.TOKEN_USD_BTC_WBTC; // Token -> USD -> BTC -> WBTC
            fallbackPath = PricingPath.TOKEN_USD_BTC_WBTC; // Token -> BTC -> WBTC
        } else if (isTokenBUSD) {
            // If tokenB is USD, we want to convert tokenA to USD
            srcToken = tokenA;
            conversionType = ConversionType.TO_USD;
            preferredPath = PricingPath.TOKEN_USD;
            fallbackPath = PricingPath.A_ETH_USD_B; // USD -> B is skipped, if B == USD
        } else if (isTokenAUSD) {
            // If tokenA is USD, we want to convert tokenB to USD
            srcToken = tokenB;
            conversionType = ConversionType.TO_USD;
            preferredPath = PricingPath.TOKEN_USD;
            fallbackPath = PricingPath.A_USD_ETH_B; // A -> USD is skipped, if A == USD
        } else if (isTokenBETH) {
            // If tokenB is ETH, we want to convert tokenA to ETH
            srcToken = tokenA;
            conversionType = ConversionType.TO_ETH;
            preferredPath = PricingPath.TOKEN_ETH;
            fallbackPath = PricingPath.A_USD_ETH_B; // B -> ETH is skipped, if B == ETH
        } else if (isTokenAETH) {
            // If tokenA is ETH, we want to convert tokenB to ETH
            srcToken = tokenB;
            conversionType = ConversionType.TO_ETH;
            preferredPath = PricingPath.TOKEN_ETH;
            fallbackPath = PricingPath.A_ETH_USD_B; // A -> ETH is skipped, if A == ETH
        } else if (_feedExists(tokenA, Denominations.USD)) {
            // If tokenA has a USD feed, we want to convert tokenB to USD, and then use tokenA USD feed to effectively convert tokenB -> tokenA
            srcToken = tokenB;
            conversionType = ConversionType.TO_USD_TO_TOKEN;
            preferredPath = PricingPath.TOKEN_USD_TOKEN;
            fallbackPath = PricingPath.A_USD_ETH_B;
        } else if (_feedExists(tokenA, Denominations.ETH)) {
            // If tokenA has an ETH feed, we want to convert tokenB to ETH, and then use tokenA ETH feed to effectively convert tokenB -> tokenA
            srcToken = tokenB;
            conversionType = ConversionType.TO_ETH_TO_TOKEN;
            preferredPath = PricingPath.TOKEN_ETH_TOKEN;
            fallbackPath = PricingPath.A_ETH_USD_B;
        } else {
            return PricingPath.NONE;
        }

        return
            _tryToFindPath(
                srcToken,
                conversionType,
                preferredPath,
                fallbackPath
            );
    }

    function _tryToFindPath(
        address token,
        ConversionType conversionType,
        PricingPath preferredPath,
        PricingPath fallbackPath
    ) internal view returns (PricingPath) {
        address firstQuote;
        address secondQuote;

        if (conversionType == ConversionType.TO_BTC) {
            firstQuote = Denominations.USD;
            secondQuote = Denominations.BTC;
        } else if (conversionType == ConversionType.TO_USD) {
            firstQuote = Denominations.USD;
            secondQuote = Denominations.ETH;
        } else if (conversionType == ConversionType.TO_ETH) {
            firstQuote = Denominations.ETH;
            secondQuote = Denominations.USD;
        } else if (conversionType == ConversionType.TO_USD_TO_TOKEN) {
            firstQuote = Denominations.USD;
            secondQuote = Denominations.ETH;
        } else if (conversionType == ConversionType.TO_ETH_TO_TOKEN) {
            firstQuote = Denominations.ETH;
            secondQuote = Denominations.USD;
        }

        if (_feedExists(token, firstQuote)) {
            return preferredPath;
        } else if (_feedExists(token, secondQuote)) {
            return fallbackPath;
        } else {
            return PricingPath.NONE;
        }
    }

    function _fetchQuote(
        address base,
        address quote,
        uint256 target
    ) internal view returns (uint256) {
        return
            target == 0
                ? _fetchLatestQuote(base, quote)
                : _fetchQuoteFrom(base, quote, target);
    }

    function _fetchLatestQuote(
        address base,
        address quote
    ) internal view returns (uint256) {
        address feed = _feed(base, quote);
        (, int256 price, , , ) = _latestRoundData(feed);
        _ensurePricePositive(price);
        return price.toUint256();
    }

    function _fetchQuoteFrom(
        address base,
        address quote,
        uint256 target
    ) internal view returns (uint256) {
        address feed = _feed(base, quote);

        (
            uint80 roundId,
            int256 price,
            ,
            uint256 updatedAt,

        ) = _latestRoundData(feed);

        (uint16 phaseId, uint64 aggregatorRoundId) = ChainlinkAdapterStorage
            .parseRoundId(roundId);

        int256 previousPrice = price;
        uint256 previousUpdatedAt = updatedAt;

        // if the last observation is after the target skip loop
        if (target >= updatedAt) aggregatorRoundId = 0;

        while (aggregatorRoundId > 0) {
            roundId = ChainlinkAdapterStorage.formatRoundId(
                phaseId,
                --aggregatorRoundId
            );

            (, price, , updatedAt, ) = _getRoundData(feed, roundId);

            if (target >= updatedAt) {
                uint256 previousUpdateDistance = previousUpdatedAt - target;
                uint256 currentUpdateDistance = target - updatedAt;

                if (previousUpdateDistance < currentUpdateDistance) {
                    price = previousPrice;
                    updatedAt = previousUpdatedAt;
                }

                break;
            }

            previousPrice = price;
            previousUpdatedAt = updatedAt;
        }

        _ensurePriceAfterTargetIsFresh(target, updatedAt);
        _ensurePricePositive(price);
        return price.toUint256();
    }

    function _latestRoundData(
        address feed
    ) internal view returns (uint80, int256, uint256, uint256, uint80) {
        try AggregatorProxyInterface(feed).latestRoundData() returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            return (roundId, answer, startedAt, updatedAt, answeredInRound);
        } catch Error(string memory reason) {
            revert(reason);
        } catch (bytes memory data) {
            revert ChainlinkAdapter__LatestRoundDataCallReverted(data);
        }
    }

    function _getRoundData(
        address feed,
        uint80 roundId
    ) internal view returns (uint80, int256, uint256, uint256, uint80) {
        try AggregatorProxyInterface(feed).getRoundData(roundId) returns (
            uint80 _roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            return (_roundId, answer, startedAt, updatedAt, answeredInRound);
        } catch Error(string memory reason) {
            revert(reason);
        } catch (bytes memory data) {
            revert ChainlinkAdapter__GetRoundDataCallReverted(data);
        }
    }

    function _aggregator(
        address tokenA,
        address tokenB
    ) internal view returns (address[] memory aggregator) {
        address feed = _feed(tokenA, tokenB);
        aggregator = new address[](1);
        aggregator[0] = AggregatorProxyInterface(feed).aggregator();
    }

    function _aggregatorDecimals(
        address aggregator
    ) internal view returns (uint8) {
        return AggregatorProxyInterface(aggregator).decimals();
    }

    function _getPriceAgainstUSD(
        address token,
        uint256 target
    ) internal view returns (UD60x18) {
        return
            token.isUSD()
                ? ONE
                : UD60x18.wrap(
                    _scale(
                        _fetchQuote(token, Denominations.USD, target),
                        int8(ETH_DECIMALS - FOREX_DECIMALS)
                    )
                );
    }

    function _getPriceAgainstETH(
        address token,
        uint256 target
    ) internal view returns (UD60x18) {
        return
            token.isETH()
                ? ONE
                : UD60x18.wrap(_fetchQuote(token, Denominations.ETH, target));
    }

    function _getETHUSD(uint256 target) internal view returns (UD60x18) {
        return
            UD60x18.wrap(
                _scale(
                    _fetchQuote(Denominations.ETH, Denominations.USD, target),
                    int8(ETH_DECIMALS - FOREX_DECIMALS)
                )
            );
    }

    function _getBTCUSD(uint256 target) internal view returns (UD60x18) {
        return
            UD60x18.wrap(
                _scale(
                    _fetchQuote(Denominations.BTC, Denominations.USD, target),
                    int8(ETH_DECIMALS - FOREX_DECIMALS)
                )
            );
    }

    function _getWBTCBTC(uint256 target) internal view returns (UD60x18) {
        return
            UD60x18.wrap(
                _scale(
                    _fetchQuote(WRAPPED_BTC_TOKEN, Denominations.BTC, target),
                    int8(ETH_DECIMALS - FOREX_DECIMALS)
                )
            );
    }

    function _ensurePriceAfterTargetIsFresh(
        uint256 target,
        uint256 updatedAt
    ) internal view {
        if (
            target >= updatedAt &&
            block.timestamp - target < MAX_DELAY &&
            target - updatedAt >= PRICE_STALE_THRESHOLD
        ) {
            // revert if 12 hours has not passed and price is stale
            revert ChainlinkAdapter__PriceAfterTargetIsStale();
        }
    }
}