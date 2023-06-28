// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {UD60x18} from "@prb/math/UD60x18.sol";

import {IOptionPS} from "../optionPS/IOptionPS.sol";
import {IProxyManager} from "../../proxy/IProxyManager.sol";

interface IOptionPSFactory is IProxyManager {
    event ProxyDeployed(address indexed base, address indexed quote, bool isCall, address proxy);

    struct OptionPSArgs {
        address base;
        address quote;
        bool isCall;
    }

    function isProxyDeployed(address proxy) external view returns (bool);

    function getProxyAddress(OptionPSArgs calldata args) external view returns (address, bool);

    function deployProxy(OptionPSArgs calldata args) external returns (address);
}
