// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {OwnableInternal} from "@solidstate/contracts/access/ownable/OwnableInternal.sol";
import {EnumerableSet} from "@solidstate/contracts/data/EnumerableSet.sol";
import {SafeCast} from "@solidstate/contracts/utils/SafeCast.sol";

import {IVolatilityOracle} from "./IVolatilityOracle.sol";
import {VolatilityOracleStorage} from "./VolatilityOracleStorage.sol";

import {UD60x18} from "@prb/math/UD60x18.sol";
import {SD59x18} from "@prb/math/SD59x18.sol";

/// @title Premia volatility surface oracle contract for liquid markets.
contract VolatilityOracle is IVolatilityOracle, OwnableInternal {
    using VolatilityOracleStorage for VolatilityOracleStorage.Layout;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeCast for uint256;

    SD59x18 internal constant ZERO = SD59x18.wrap(0);
    SD59x18 internal constant ONE = SD59x18.wrap(1e18);
    SD59x18 internal constant TWO = SD59x18.wrap(2e18);

    uint256 private constant DECIMALS = 12;

    event UpdateParameters(
        address indexed token,
        bytes32 tau,
        bytes32 theta,
        bytes32 psi,
        bytes32 rho
    );

    struct Params {
        SD59x18[] tau;
        SD59x18[] theta;
        SD59x18[] psi;
        SD59x18[] rho;
    }

    struct SliceInfo {
        SD59x18 theta;
        SD59x18 psi;
        SD59x18 rho;
    }

    /// @inheritdoc IVolatilityOracle
    function addWhitelistedRelayers(
        address[] memory accounts
    ) external onlyOwner {
        VolatilityOracleStorage.Layout storage l = VolatilityOracleStorage
            .layout();

        for (uint256 i = 0; i < accounts.length; i++) {
            l.whitelistedRelayers.add(accounts[i]);
        }
    }

    /// @inheritdoc IVolatilityOracle
    function removeWhitelistedRelayers(
        address[] memory accounts
    ) external onlyOwner {
        VolatilityOracleStorage.Layout storage l = VolatilityOracleStorage
            .layout();

        for (uint256 i = 0; i < accounts.length; i++) {
            l.whitelistedRelayers.remove(accounts[i]);
        }
    }

    /// @inheritdoc IVolatilityOracle
    function getWhitelistedRelayers() external view returns (address[] memory) {
        VolatilityOracleStorage.Layout storage l = VolatilityOracleStorage
            .layout();

        uint256 length = l.whitelistedRelayers.length();
        address[] memory result = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            result[i] = l.whitelistedRelayers.at(i);
        }

        return result;
    }

    /// @inheritdoc IVolatilityOracle
    function formatParams(
        int256[5] memory params
    ) external pure returns (bytes32 result) {
        return VolatilityOracleStorage.formatParams(params);
    }

    /// @inheritdoc IVolatilityOracle
    function parseParams(
        bytes32 input
    ) external pure returns (int256[] memory params) {
        return VolatilityOracleStorage.parseParams(input);
    }

    /// @inheritdoc IVolatilityOracle
    function updateParams(
        address[] memory tokens,
        bytes32[] memory tau,
        bytes32[] memory theta,
        bytes32[] memory psi,
        bytes32[] memory rho
    ) external {
        uint256 length = tokens.length;

        if (
            length != tau.length ||
            length != theta.length ||
            length != psi.length ||
            length != rho.length
        ) revert IVolatilityOracle.VolatilityOracle__ArrayLengthMismatch();

        VolatilityOracleStorage.Layout storage l = VolatilityOracleStorage
            .layout();

        if (!l.whitelistedRelayers.contains(msg.sender))
            revert IVolatilityOracle.VolatilityOracle__RelayerNotWhitelisted();

        for (uint256 i = 0; i < length; i++) {
            l.parameters[tokens[i]] = VolatilityOracleStorage.Update({
                updatedAt: block.timestamp,
                tau: tau[i],
                theta: theta[i],
                psi: psi[i],
                rho: rho[i]
            });

            emit UpdateParameters(tokens[i], tau[i], theta[i], psi[i], rho[i]);
        }
    }

    /// @inheritdoc IVolatilityOracle
    function getParams(
        address token
    ) external view returns (VolatilityOracleStorage.Update memory) {
        VolatilityOracleStorage.Layout storage l = VolatilityOracleStorage
            .layout();
        return l.parameters[token];
    }

    /// @inheritdoc IVolatilityOracle
    function getParamsUnpacked(
        address token
    ) external view returns (VolatilityOracleStorage.Params memory) {
        VolatilityOracleStorage.Layout storage l = VolatilityOracleStorage
            .layout();
        VolatilityOracleStorage.Update memory packed = l.getParams(token);
        VolatilityOracleStorage.Params memory params = VolatilityOracleStorage
            .Params({
                tau: VolatilityOracleStorage.parseParams(packed.tau),
                theta: VolatilityOracleStorage.parseParams(packed.theta),
                psi: VolatilityOracleStorage.parseParams(packed.psi),
                rho: VolatilityOracleStorage.parseParams(packed.rho)
            });
        return params;
    }

    /// @notice Finds the interval a particular value is located in.
    /// @param arr The array of cutoff points that define the intervals
    /// @param value The value to find the interval for
    /// @return The interval index that corresponds the value
    function _findInterval(
        SD59x18[] memory arr,
        SD59x18 value
    ) internal pure returns (uint256) {
        uint256 low = 0;
        uint256 high = arr.length;
        uint256 m;
        uint256 result;

        while ((high - low) > 1) {
            m = (uint256)((low + high) / 2);

            if (arr[m] <= value) {
                low = m;
            } else {
                high = m;
            }
        }

        if (arr[low] <= value) {
            result = low;
        }

        return result;
    }

    /// @notice Convert an int256[] array to a SD59x18[] array
    /// @param src The array to be converted
    /// @return The input array converted to a SD59x18[] array
    function _toArray59x18(
        int256[] memory src
    ) internal pure returns (SD59x18[] memory) {
        SD59x18[] memory tgt = new SD59x18[](src.length);
        for (uint256 i = 0; i < src.length; i++) {
            // Convert parameters in DECIMALS to an SD59x18
            tgt[i] = SD59x18.wrap(src[i] * 1e6);
        }
        return tgt;
    }

    function _weightedAvg(
        SD59x18 lam,
        SD59x18 value1,
        SD59x18 value2
    ) internal pure returns (SD59x18) {
        return (ONE - lam) * value1 + (lam * value2);
    }

    /// @inheritdoc IVolatilityOracle
    function getVolatility(
        address token,
        UD60x18 spot,
        UD60x18 strike,
        UD60x18 timeToMaturity
    ) external view returns (UD60x18) {
        VolatilityOracleStorage.Layout storage l = VolatilityOracleStorage
            .layout();
        VolatilityOracleStorage.Update memory packed = l.getParams(token);

        Params memory params = Params({
            tau: _toArray59x18(VolatilityOracleStorage.parseParams(packed.tau)),
            theta: _toArray59x18(
                VolatilityOracleStorage.parseParams(packed.theta)
            ),
            psi: _toArray59x18(VolatilityOracleStorage.parseParams(packed.psi)),
            rho: _toArray59x18(VolatilityOracleStorage.parseParams(packed.rho))
        });

        // Number of tau
        uint256 n = params.tau.length;

        // Log Moneyness
        SD59x18 k = (strike.intoSD59x18() / spot.intoSD59x18()).ln();

        // Compute total implied variance
        SliceInfo memory info;
        SD59x18 lam;

        SD59x18 _timeToMaturity = timeToMaturity.intoSD59x18();

        // Short-Term Extrapolation
        if (_timeToMaturity < params.tau[0]) {
            lam = _timeToMaturity / params.tau[0];

            info = SliceInfo({
                theta: lam * params.theta[0],
                psi: lam * params.psi[0],
                rho: params.rho[0]
            });
        }
        // Long-term extrapolation
        else if (_timeToMaturity >= params.tau[n - 1]) {
            SD59x18 u = _timeToMaturity - params.tau[n - 1];
            u = u * (params.theta[n - 1] - params.theta[n - 2]);
            u = u / (params.tau[n - 1] - params.tau[n - 2]);

            info = SliceInfo({
                theta: params.theta[n - 1] + u,
                psi: params.psi[n - 1],
                rho: params.rho[n - 1]
            });
        }
        // Interpolation between tau[0] to tau[n - 1]
        else {
            uint256 i = _findInterval(params.tau, _timeToMaturity);

            lam = _timeToMaturity - params.tau[i];
            lam = lam / (params.tau[i + 1] - params.tau[i]);

            info = SliceInfo({
                theta: _weightedAvg(lam, params.theta[i], params.theta[i + 1]),
                psi: _weightedAvg(lam, params.psi[i], params.psi[i + 1]),
                rho: ZERO
            });
            info.rho =
                _weightedAvg(
                    lam,
                    params.rho[i] * params.psi[i],
                    params.rho[i + 1] * params.psi[i + 1]
                ) /
                info.psi;
        }

        SD59x18 phi = info.psi / info.theta;
        SD59x18 term = (phi * k + info.rho).pow(TWO) +
            (ONE - info.rho.pow(TWO));
        SD59x18 w = info.theta / TWO;
        w = w * (ONE + info.rho * phi * k + term.sqrt());

        return (w / _timeToMaturity).sqrt().intoUD60x18();
    }
}