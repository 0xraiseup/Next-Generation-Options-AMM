// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {OwnableInternal} from "@solidstate/contracts/access/ownable/OwnableInternal.sol";

import {IOptionPSFactory} from "./IOptionPSFactory.sol";
import {OptionPSProxy} from "./OptionPSProxy.sol";
import {OptionPSFactoryStorage} from "./OptionPSFactoryStorage.sol";
import {IProxyManager} from "../../proxy/IProxyManager.sol";
import {ProxyManager} from "../../proxy/ProxyManager.sol";

contract OptionPSFactory is IOptionPSFactory, ProxyManager {
    using OptionPSFactoryStorage for OptionPSArgs;
    using OptionPSFactoryStorage for OptionPSFactoryStorage.Layout;

    function isProxyDeployed(address proxy) external view returns (bool) {
        return OptionPSFactoryStorage.layout().isProxyDeployed[proxy];
    }

    function getProxyAddress(OptionPSArgs calldata args) external view returns (address proxy, bool) {
        OptionPSFactoryStorage.Layout storage l = OptionPSFactoryStorage.layout();
        proxy = l.proxyByKey[args.keyHash()];
        return (proxy, l.isProxyDeployed[proxy]);
    }

    function deployProxy(OptionPSArgs calldata args) external returns (address proxy) {
        proxy = address(
            new OptionPSProxy(
                IProxyManager(address(this)),
                args.base,
                args.quote,
                args.isCall,
                args.priceRepository,
                args.exerciseDuration
            )
        );

        OptionPSFactoryStorage.Layout storage l = OptionPSFactoryStorage.layout();

        l.proxyByKey[args.keyHash()] = proxy;
        l.isProxyDeployed[proxy] = true;

        emit ProxyDeployed(args.base, args.quote, args.isCall, args.priceRepository, args.exerciseDuration, proxy);
    }
}
