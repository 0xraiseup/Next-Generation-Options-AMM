// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {UD60x18} from "@prb/math/UD60x18.sol";

import {OwnableStorage} from "@solidstate/contracts/access/ownable/OwnableStorage.sol";
import {IERC1155} from "@solidstate/contracts/interfaces/IERC1155.sol";
import {IERC165} from "@solidstate/contracts/interfaces/IERC165.sol";
import {ERC165BaseInternal} from "@solidstate/contracts/introspection/ERC165/base/ERC165BaseInternal.sol";
import {Proxy} from "@solidstate/contracts/proxy/Proxy.sol";
import {IDiamondReadable} from "@solidstate/contracts/proxy/diamond/readable/IDiamondReadable.sol";
import {IERC20Metadata} from "@solidstate/contracts/token/ERC20/metadata/IERC20Metadata.sol";
import {AddressUtils} from "@solidstate/contracts/utils/AddressUtils.sol";

import {DoublyLinkedListUD60x18, DoublyLinkedList} from "../libraries/DoublyLinkedListUD60x18.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {ReentrancyGuardExtended} from "../utils/ReentrancyGuardExtended.sol";

import {PoolStorage} from "./PoolStorage.sol";

/// @title Upgradeable proxy with centrally controlled Pool implementation
contract PoolProxy is Proxy, ERC165BaseInternal, ReentrancyGuardExtended {
    using AddressUtils for address;
    using DoublyLinkedListUD60x18 for DoublyLinkedList.Bytes32List;
    using PoolStorage for PoolStorage.Layout;

    address private immutable DIAMOND;

    constructor(
        address diamond,
        address base,
        address quote,
        address oracleAdapter,
        UD60x18 strike,
        uint256 maturity,
        bool isCallPool
    ) {
        DIAMOND = diamond;
        OwnableStorage.layout().owner = msg.sender;

        {
            PoolStorage.Layout storage l = PoolStorage.layout();

            l.base = base;
            l.quote = quote;

            l.oracleAdapter = oracleAdapter;

            l.strike = strike;
            l.maturity = maturity;

            uint8 baseDecimals = IERC20Metadata(base).decimals();
            uint8 quoteDecimals = IERC20Metadata(quote).decimals();

            l.baseDecimals = baseDecimals;
            l.quoteDecimals = quoteDecimals;

            l.isCallPool = isCallPool;

            l.tickIndex.push(Pricing.MIN_TICK_PRICE);
            l.tickIndex.push(Pricing.MAX_TICK_PRICE);

            l.currentTick = Pricing.MIN_TICK_PRICE;
            l.marketPrice = Pricing.MIN_TICK_PRICE;
        }

        _setSupportsInterface(type(IERC165).interfaceId, true);
        _setSupportsInterface(type(IERC1155).interfaceId, true);
    }

    fallback() external payable override {
        bool locked = _lockReentrancyGuard(msg.data);

        //

        address implementation = _getImplementation();

        if (!implementation.isContract()) revert Proxy__ImplementationIsNotContract();

        bool result;
        assembly {
            calldatacopy(0, 0, calldatasize())
            result := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
        }

        //

        if (locked) {
            _unlockReentrancyGuard();
        }

        //

        assembly {
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    function _getImplementation() internal view override returns (address) {
        return IDiamondReadable(DIAMOND).facetAddress(msg.sig);
    }
}
