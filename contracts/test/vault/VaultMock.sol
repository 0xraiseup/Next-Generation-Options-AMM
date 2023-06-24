// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {UD60x18} from "@prb/math/UD60x18.sol";

import {IPoolFactory} from "../../factory/IPoolFactory.sol";
import {Vault} from "../../vault/Vault.sol";

contract VaultMock is Vault {
    UD60x18 public utilisation = UD60x18.wrap(0);

    constructor(address vaultMining) Vault(vaultMining) {}

    function getUtilisation() public view override returns (UD60x18) {
        return utilisation;
    }

    function setUtilisation(UD60x18 value) external {
        utilisation = value;
    }

    function mint(address account, uint256 amount) public {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) public {
        _burn(account, amount);
    }

    function _totalAssets() internal view override returns (uint256) {
        return _totalSupply();
    }

    function updateSettings(bytes memory settings) external {}

    function getQuote(
        IPoolFactory.PoolKey calldata poolKey,
        UD60x18 size,
        bool isBuy,
        address taker
    ) external view returns (uint256 premium) {
        return 0;
    }

    function trade(
        IPoolFactory.PoolKey calldata poolKey,
        UD60x18 size,
        bool isBuy,
        uint256 premiumLimit,
        address referrer
    ) external {}
}
