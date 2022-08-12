// SPDX-License-Identifier: BUSL-1.1
// For further clarification please see https://license.premia.legal

pragma solidity ^0.8.0;

import {OwnableStorage} from "@solidstate/contracts/access/ownable/OwnableStorage.sol";
import {ERC165Storage} from "@solidstate/contracts/introspection/ERC165Storage.sol";
import {Proxy} from "@solidstate/contracts/proxy/Proxy.sol";
import {IDiamondReadable} from "@solidstate/contracts/proxy/diamond/readable/IDiamondReadable.sol";
import {IERC20Metadata} from "@solidstate/contracts/token/ERC20/metadata/IERC20Metadata.sol";
import {IERC1155} from "@solidstate/contracts/token/ERC1155/IERC1155.sol";
import {IERC165} from "@solidstate/contracts/introspection/IERC165.sol";

import {PoolStorage} from "./PoolStorage.sol";

/**
 * @title Upgradeable proxy with centrally controlled Pool implementation
 */
contract PoolProxy is Proxy {
    using PoolStorage for PoolStorage.Layout;
    using ERC165Storage for ERC165Storage.Layout;

    address private immutable DIAMOND;

    constructor(
        address diamond,
        address base,
        address underlying,
        address baseOracle,
        address underlyingOracle,
        bool isCallPool
    ) {
        DIAMOND = diamond;
        OwnableStorage.layout().owner = msg.sender;

        {
            PoolStorage.Layout storage l = PoolStorage.layout();

            l.base = base;
            l.underlying = underlying;

            // ToDo : Add checks for oracle
            l.baseOracle = baseOracle;
            l.underlyingOracle = underlyingOracle;

            uint8 baseDecimals = IERC20Metadata(base).decimals();
            uint8 underlyingDecimals = IERC20Metadata(underlying).decimals();

            l.baseDecimals = baseDecimals;
            l.underlyingDecimals = underlyingDecimals;

            l.isCallPool = isCallPool;
        }

        {
            ERC165Storage.Layout storage l = ERC165Storage.layout();
            l.setSupportedInterface(type(IERC165).interfaceId, true);
            l.setSupportedInterface(type(IERC1155).interfaceId, true);
        }
    }

    function _getImplementation() internal view override returns (address) {
        return IDiamondReadable(DIAMOND).facetAddress(msg.sig);
    }
}