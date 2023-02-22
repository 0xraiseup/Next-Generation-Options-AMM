// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@solidstate/contracts/token/ERC4626/base/ERC4626BaseStorage.sol";
import "@solidstate/contracts/token/ERC4626/SolidStateERC4626.sol";
import {IERC20} from "@solidstate/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@solidstate/contracts/utils/SafeERC20.sol";
import {SafeCast} from "@solidstate/contracts/utils/SafeCast.sol";
import {OwnableInternal} from "@solidstate/contracts/access/ownable/OwnableInternal.sol";
import {EnumerableSet} from "@solidstate/contracts/data/EnumerableSet.sol";
import {DoublyLinkedList} from "@solidstate/contracts/data/DoublyLinkedList.sol";
import {AggregatorInterface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorInterface.sol";

import "./IUnderwriterVault.sol";
import {UnderwriterVaultStorage} from "./UnderwriterVaultStorage.sol";
import {IVolatilityOracle} from "../../oracle/IVolatilityOracle.sol";
import {OptionMath} from "../../libraries/OptionMath.sol";
import {IPoolFactory} from "../../factory/IPoolFactory.sol";
import {IPool} from "../../pool/IPool.sol";

import "hardhat/console.sol";
import {UD60x18} from "../../libraries/prbMath/UD60x18.sol";
import {SD59x18} from "../../libraries/prbMath/SD59x18.sol";

contract UnderwriterVault is
    IUnderwriterVault,
    SolidStateERC4626,
    OwnableInternal
{
    using DoublyLinkedList for DoublyLinkedList.Uint256List;
    using EnumerableSet for EnumerableSet.UintSet;
    using UnderwriterVaultStorage for UnderwriterVaultStorage.Layout;
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using UD60x18 for uint256;
    using SD59x18 for int256;

    address internal immutable IV_ORACLE_ADDR;
    address internal immutable FACTORY_ADDR;

    constructor(address oracleAddress, address factoryAddress) {
        IV_ORACLE_ADDR = oracleAddress;
        FACTORY_ADDR = factoryAddress;
    }

    function setVariable(uint256 value) external onlyOwner {
        UnderwriterVaultStorage.layout().variable = value;
    }

    function _asset() internal view virtual override returns (address) {
        return ERC4626BaseStorage.layout().asset;
    }

    function _totalAssets() internal view override returns (uint256) {
        // total assets = deposits + premiums + spreads
        return UnderwriterVaultStorage.layout().totalAssets;
    }

    function _totalLockedSpread() internal view returns (uint256) {
        // total assets = deposits + premiums + spreads
        return UnderwriterVaultStorage.layout().totalLockedSpread;
    }

    function _getSpotPrice(address oracle) internal view returns (uint256) {
        // TODO: Add spot price validation
        int256 price = AggregatorInterface(oracle).latestAnswer();
        if (price < 0) revert Vault__ZeroPrice();
        return price.toUint256();
    }

    function _getTotalFairValue() internal view returns (uint256) {
        uint256 spot;
        uint256 strike;
        uint256 timeToMaturity;
        int256 sigma;
        uint256 price;
        uint256 size;

        UnderwriterVaultStorage.Layout storage l = UnderwriterVaultStorage
            .layout();
        uint256 current = l.minMaturity;
        uint256 total = 0;

        while (current <= l.maxMaturity) {
            for (
                uint256 i = 0;
                i < l.maturityToStrikes[current].length();
                i++
            ) {
                strike = l.maturityToStrikes[current].at(i);
                if (block.timestamp < current) {
                    spot = _getSpotPrice(l.priceOracle);
                    uint256 secondsToExpiration = current - block.timestamp;
                    uint256 secondsInAYear = 365 * 24 * 60 * 60;
                    timeToMaturity = secondsToExpiration.div(secondsInAYear);
                    sigma = IVolatilityOracle(IV_ORACLE_ADDR).getVolatility(
                        _asset(),
                        spot,
                        strike,
                        timeToMaturity
                    );
                } else {
                    spot = _getSpotPrice(l.priceOracle);
                    timeToMaturity = 0;
                    sigma = 1;
                }

                price = OptionMath.blackScholesPrice(
                    spot,
                    strike,
                    timeToMaturity,
                    uint256(sigma),
                    0,
                    l.isCall
                );

                size = l.positionSizes[current][strike];

                total = total + price.mul(size).div(spot);
            }

            current = l.maturities.next(current);
        }

        return total;
    }

    function _getTotalLockedSpread() internal view returns (uint256) {
        UnderwriterVaultStorage.Layout storage l = UnderwriterVaultStorage
            .layout();
        uint256 last = l.lastMaturity;
        uint256 next = l.maturities.next(last);

        uint256 lastSpreadUnlockUpdate = l.lastSpreadUnlockUpdate;
        uint256 spreadUnlockingRate = l.spreadUnlockingRate;
        // TODO: double check handling of negative total locked spread
        uint256 totalLockedSpread = l.totalLockedSpread;

        while (block.timestamp >= next) {
            totalLockedSpread -=
                (next - lastSpreadUnlockUpdate) *
                spreadUnlockingRate;
            spreadUnlockingRate -= l.spreadUnlockingTicks[next];
            lastSpreadUnlockUpdate = next;
            last = next;
            next = l.maturities.next(last);
        }
        totalLockedSpread -=
            (block.timestamp - lastSpreadUnlockUpdate) *
            spreadUnlockingRate;
        return totalLockedSpread;
    }

    function _availableAssets() internal view returns (uint256) {
        UnderwriterVaultStorage.Layout storage l = UnderwriterVaultStorage
            .layout();
        return l.totalAssets - _getTotalLockedSpread() - l.totalLockedAssets;
    }

    function _getPricePerShare() internal view returns (uint256) {
        // TODO: change function to view once hydrated
        UnderwriterVaultStorage.Layout storage l = UnderwriterVaultStorage
            .layout();

        return
            (l.totalAssets - _getTotalLockedSpread() - _getTotalFairValue())
                .div(_totalSupply());
    }

    /// @notice updates total spread in storage to be able to compute the price per share
    function _updateState() internal {
        UnderwriterVaultStorage.Layout storage l = UnderwriterVaultStorage
            .layout();

        uint256 last = l.minMaturity;
        uint256 next = l.maturities.next(last);

        uint256 lastSpreadUnlockUpdate = l.lastSpreadUnlockUpdate;
        uint256 spreadUnlockingRate = l.spreadUnlockingRate;
        uint256 totalLockedSpread = l.totalLockedSpread;

        while (block.timestamp >= next) {
            totalLockedSpread -=
                (next - lastSpreadUnlockUpdate) *
                spreadUnlockingRate;
            spreadUnlockingRate -= l.spreadUnlockingTicks[next];
            lastSpreadUnlockUpdate = next;
            last = next;
            next = l.maturities.next(last);
        }
        totalLockedSpread -=
            (block.timestamp - lastSpreadUnlockUpdate) *
            spreadUnlockingRate;

        l.totalLockedSpread = totalLockedSpread;
        l.spreadUnlockingRate = spreadUnlockingRate;
        l.lastSpreadUnlockUpdate = block.timestamp;
    }

    function _convertToShares(
        uint256 assetAmount
    ) internal view override returns (uint256 shareAmount) {
        uint256 supply = _totalSupply();

        if (supply == 0) {
            shareAmount = assetAmount;
        } else {
            uint256 totalAssets = _totalAssets();
            if (totalAssets == 0) {
                shareAmount = assetAmount;
            } else {
                shareAmount = assetAmount.div(_getPricePerShare());
            }
        }
    }

    function _convertToAssets(
        uint256 shareAmount
    ) internal view virtual override returns (uint256 assetAmount) {
        uint256 supply = _totalSupply();

        if (supply == 0) {
            // if the total shares that were minted is zero, we should revert
            assetAmount = shareAmount;
        } else {
            assetAmount = shareAmount * _getPricePerShare();
        }
    }

    function _maxWithdraw(
        address owner
    ) internal view virtual override returns (uint256) {
        if (owner == address(0)) {
            revert Vault__AddressZero();
        }
        return _availableAssets();
    }

    function _maxRedeem(
        address owner
    ) internal view virtual override returns (uint256) {
        return _convertToShares(_maxWithdraw(owner));
    }

    function _previewDeposit(
        uint256 assetAmount
    ) internal view virtual override returns (uint256) {
        return _convertToShares(assetAmount);
    }

    function _previewMint(
        uint256 shareAmount
    ) internal view virtual override returns (uint256) {
        return _convertToAssets(shareAmount);
    }

    function _previewWithdraw(
        uint256 assetAmount
    ) internal view virtual override returns (uint256 shareAmount) {
        uint256 supply = _totalSupply();

        if (supply == 0) {
            shareAmount = assetAmount;
        } else {
            uint256 totalAssets = _totalAssets();

            if (totalAssets == 0) {
                shareAmount = assetAmount;
            } else {
                shareAmount =
                    (assetAmount * supply + totalAssets - 1) /
                    totalAssets;
            }
        }
    }

    function _afterDeposit(
        address receiver,
        uint256 assetAmount,
        uint256 shareAmount
    ) internal virtual override {
        if (receiver == address(0)) {
            revert Vault__AddressZero();
        }
        if (assetAmount == 0) {
            revert Vault__ZeroAsset();
        }
        if (shareAmount == 0) {
            revert Vault__ZEROShares();
        }
        UnderwriterVaultStorage.layout().totalAssets += assetAmount;
    }

    function _beforeWithdraw(
        address owner,
        uint256 assetAmount,
        uint256 shareAmount
    ) internal virtual override {
        if (owner == address(0)) {
            revert Vault__AddressZero();
        }
        if (assetAmount == 0) {
            revert Vault__ZeroAsset();
        }
        if (shareAmount == 0) {
            revert Vault__ZEROShares();
        }
    }

    function _isValidListing(
        uint256 strike,
        uint256 maturity,
        uint256 sigma
    ) internal view returns (bool) {
        UnderwriterVaultStorage.Layout storage l = UnderwriterVaultStorage
            .layout();

        if (strike == 0) {
            revert Vault__AddressZero();
            //TODO: should just return false
        }
        if (maturity == 0) {
            revert Vault__MaturityZero();
            //TODO: should just return false
        }

        // generate struct to grab pool address
        IPoolFactory.PoolKey memory _poolKey;
        _poolKey.base = l.base;
        _poolKey.quote = l.quote;
        _poolKey.baseOracle = l.priceOracle;
        _poolKey.quoteOracle = l.quoteOracle;
        _poolKey.strike = strike;
        _poolKey.maturity = uint64(maturity);
        _poolKey.isCallPool = l.isCall;

        address listingAddr = IPoolFactory(FACTORY_ADDR).getPoolAddress(
            _poolKey
        );

        // NOTE: query returns address(0) if no listing exists
        if (listingAddr == address(0)) {
            revert Vault__OptionPoolNotListed();
            //TODO: should just return false
        }

        if (sigma == 0) {
            revert Vault__ZeroVol();
        }

        //TODO: check the delta and dte are within our vault trading range
        //TODO: get implied volatility (for delta)
        //TODO: get delta of option ( .10 < l.delta < .70)
        //TODO: calculate DTE (< 30 days)

        return true;
    }

    function _addListing(uint256 strike, uint256 maturity) internal {
        UnderwriterVaultStorage.Layout storage l = UnderwriterVaultStorage
            .layout();

        // Insert maturity if it doesn't exist
        if (!l.maturities.contains(maturity)) {
            uint256 before = l.maturities.prev(maturity);
            l.maturities.insertAfter(before, maturity);
        }

        // Insert strike into the set of strikes for given maturity
        l.maturityToStrikes[maturity].add(strike);

        // Set new max maturity for doublylinkedlist
        if (maturity > l.maxMaturity) {
            l.maxMaturity = maturity;
        }
    }

    function _handleTradeFees(
        uint256 premium,
        uint256 spread,
        uint256 size,
        uint256 timeToMaturity
    ) internal {
        UnderwriterVaultStorage.Layout storage l = UnderwriterVaultStorage
            .layout();
        // below code could belong to the _handleTradeFees function
        l.totalLockedSpread += spread;
        uint256 spreadRate = spread / timeToMaturity;
        // TODO: we need to update totalLockedSpread before updating the spreadUnlockingRate (!)
        // TODO: otherwise there will be an inconsistency and too much spread will be deducted since lastSpreadUpdate
        // TODO: call _updateState()
        l.spreadUnlockingRate += spreadRate;

        l.totalAssets += premium + spread;
        l.totalLockedAssets += size;
    }

    function _getFactoryAddress(
        uint256 strike,
        uint256 maturity
    ) internal view returns (address) {
        UnderwriterVaultStorage.Layout storage l = UnderwriterVaultStorage
            .layout();

        // generate struct to grab pool address
        IPoolFactory.PoolKey memory _poolKey;
        _poolKey.base = l.base;
        _poolKey.quote = l.quote;
        _poolKey.baseOracle = l.priceOracle;
        _poolKey.quoteOracle = l.quoteOracle;
        _poolKey.strike = strike;
        _poolKey.maturity = uint64(maturity);
        _poolKey.isCallPool = l.isCall;

        address listingAddr = IPoolFactory(FACTORY_ADDR).getPoolAddress(
            _poolKey
        );

        return listingAddr;
    }

    /// @inheritdoc IUnderwriterVault
    function buy(
        uint256 strike,
        uint256 maturity,
        uint256 size
    ) external returns (uint256) {
        UnderwriterVaultStorage.Layout storage l = UnderwriterVaultStorage
            .layout();

        // Validate listing
        // Check if not expired
        if (block.timestamp >= maturity) revert Vault__OptionExpired();

        // Check if the vault has sufficient funds
        uint256 availableAssets = _availableAssets();

        if (size >= availableAssets) revert Vault__InsufficientFunds();

        // Compute premium and the spread collected
        uint256 spotPrice = _getSpotPrice(l.priceOracle);

        // TODO: check if Dte need to be converted for getVolatility()
        uint256 timeToMaturity = maturity - block.timestamp;

        // TODO: check to see if getVol should return uint instead of int256?
        int256 sigma = IVolatilityOracle(IV_ORACLE_ADDR).getVolatility(
            _asset(),
            spotPrice,
            strike,
            timeToMaturity
        );

        //TODO: remove once getvolatility() is uint256
        uint256 volAnnualized = uint256(sigma);

        // Check if this listing is supported by the vault.
        if (!_isValidListing(strike, maturity, volAnnualized))
            revert Vault__OptionPoolNotSupported();
        else _addListing(strike, maturity);

        uint256 price = OptionMath.blackScholesPrice(
            spotPrice,
            strike,
            timeToMaturity,
            volAnnualized,
            0,
            l.isCall
        );

        uint256 premium = size * uint256(price);

        // TODO: enso / professors function call do determine the spread
        // TODO: embed the trading fee into the spread (requires calculating fee)
        uint256 spread = 0;

        // TODO: call mint function to receive shorts + longs

        // Handle the premiums and spread capture generated
        _handleTradeFees(premium, spread, size, timeToMaturity);

        return premium;
    }

    /// @inheritdoc IUnderwriterVault
    function settle() external pure override returns (uint256) {
        //TODO: remove pure when hydrated
        return 0;
    }
}
