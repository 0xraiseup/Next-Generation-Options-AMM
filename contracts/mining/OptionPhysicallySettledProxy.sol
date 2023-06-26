// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {UD60x18} from "@prb/math/UD60x18.sol";
import {OwnableStorage} from "@solidstate/contracts/access/ownable/OwnableStorage.sol";
import {IERC1155} from "@solidstate/contracts/interfaces/IERC1155.sol";
import {IERC165} from "@solidstate/contracts/interfaces/IERC165.sol";
import {ERC165BaseInternal} from "@solidstate/contracts/introspection/ERC165/base/ERC165BaseInternal.sol";
import {Proxy} from "@solidstate/contracts/proxy/Proxy.sol";
import {IERC20Metadata} from "@solidstate/contracts/token/ERC20/metadata/IERC20Metadata.sol";

import {IProxyUpgradeableOwnable} from "../proxy/IProxyUpgradeableOwnable.sol";
import {OptionPhysicallySettledStorage} from "./OptionPhysicallySettledStorage.sol";

contract OptionPhysicallySettledProxy is Proxy, ERC165BaseInternal {
    address private immutable PROXY;

    constructor(
        address proxy,
        address base,
        address quote,
        bool isCall,
        address priceRepository,
        uint256 exerciseDuration
    ) {
        PROXY = proxy;
        OwnableStorage.layout().owner = msg.sender;

        OptionPhysicallySettledStorage.Layout storage l = OptionPhysicallySettledStorage.layout();

        l.isCall = isCall;
        l.baseDecimals = IERC20Metadata(base).decimals();
        l.quoteDecimals = IERC20Metadata(quote).decimals();

        l.base = base;
        l.quote = quote;

        l.priceRepository = priceRepository;
        l.exerciseDuration = exerciseDuration;

        _setSupportsInterface(type(IERC165).interfaceId, true);
        _setSupportsInterface(type(IERC1155).interfaceId, true);
    }

    function _getImplementation() internal view override returns (address) {
        return IProxyUpgradeableOwnable(PROXY).getImplementation();
    }

    receive() external payable {}
}
