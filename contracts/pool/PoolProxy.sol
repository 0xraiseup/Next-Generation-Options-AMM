// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {OwnableStorage} from "@solidstate/contracts/access/ownable/OwnableStorage.sol";
import {DoublyLinkedList} from "@solidstate/contracts/data/DoublyLinkedList.sol";
import {IERC1155} from "@solidstate/contracts/interfaces/IERC1155.sol";
import {IERC165} from "@solidstate/contracts/interfaces/IERC165.sol";
import {ERC165BaseInternal} from "@solidstate/contracts/introspection/ERC165/base/ERC165BaseInternal.sol";
import {Proxy} from "@solidstate/contracts/proxy/Proxy.sol";
import {IDiamondReadable} from "@solidstate/contracts/proxy/diamond/readable/IDiamondReadable.sol";
import {IERC20Metadata} from "@solidstate/contracts/token/ERC20/metadata/IERC20Metadata.sol";
import {SafeCast} from "@solidstate/contracts/utils/SafeCast.sol";

import {OptionMath} from "../libraries/OptionMath.sol";
import {Pricing} from "../libraries/Pricing.sol";

import {IPoolInternal} from "./IPoolInternal.sol";
import {PoolStorage} from "./PoolStorage.sol";

/// @title Upgradeable proxy with centrally controlled Pool implementation
contract PoolProxy is Proxy, ERC165BaseInternal {
    using DoublyLinkedList for DoublyLinkedList.Uint256List;
    using PoolStorage for PoolStorage.Layout;
    using SafeCast for uint256;

    address private immutable DIAMOND;

    constructor(
        address diamond,
        address base,
        address underlying,
        address baseOracle,
        address underlyingOracle,
        uint256 strike,
        uint64 maturity,
        bool isCallPool
    ) {
        DIAMOND = diamond;
        OwnableStorage.layout().owner = msg.sender;

        {
            PoolStorage.Layout storage l = PoolStorage.layout();

            l.base = base;
            l.underlying = underlying;

            // TODO : Add checks for oracle
            l.baseOracle = baseOracle;
            l.underlyingOracle = underlyingOracle;

            l.strike = strike;
            l.maturity = maturity;

            _ensureOptionStrikeIsValid(l);
            _ensureOptionStrikeInterval(l);

            uint8 baseDecimals = IERC20Metadata(base).decimals();
            uint8 underlyingDecimals = IERC20Metadata(underlying).decimals();

            l.baseDecimals = baseDecimals;
            l.underlyingDecimals = underlyingDecimals;

            l.isCallPool = isCallPool;

            l.tickIndex.push(Pricing.MIN_TICK_PRICE);
            l.tickIndex.push(Pricing.MAX_TICK_PRICE);

            l.currentTick = Pricing.MIN_TICK_PRICE;
        }

        _setSupportsInterface(type(IERC165).interfaceId, true);
        _setSupportsInterface(type(IERC1155).interfaceId, true);
    }

    function _getImplementation() internal view override returns (address) {
        return IDiamondReadable(DIAMOND).facetAddress(msg.sig);
    }

    function _ensureOptionStrikeIsValid(
        PoolStorage.Layout storage l
    ) internal view {
        int256 basePrice = PoolStorage.getSpotPrice(l.baseOracle);
        int256 underlyingPrice = PoolStorage.getSpotPrice(l.underlyingOracle);

        int256 spot = (underlyingPrice * 1e18) / basePrice;
        int256 strikeInterval = OptionMath.calculateStrikeInterval(spot);

        if (l.strike.toInt256() % strikeInterval != 0)
            revert IPoolInternal.Pool__OptionStrikeIntervalInvalid();
    }
}
