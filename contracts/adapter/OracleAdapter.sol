// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.19;

import {Multicall} from "@solidstate/contracts/utils/Multicall.sol";
import {SafeCast} from "@solidstate/contracts/utils/SafeCast.sol";

import {IOracleAdapter} from "./IOracleAdapter.sol";

/// @title Base oracle adapter implementation, which suppoprts access control multi-call and ERC165
abstract contract OracleAdapter is IOracleAdapter, Multicall {
    using SafeCast for int8;

    function _keyForUnsortedPair(
        address tokenA,
        address tokenB
    ) internal pure returns (bytes32) {
        (address sortedA, address sortedTokenB) = _sortTokens(tokenA, tokenB);
        return _keyForSortedPair(sortedA, sortedTokenB);
    }

    /// @dev Expects `tokenA` and `tokenB` to be sorted
    function _keyForSortedPair(
        address tokenA,
        address tokenB
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(tokenA, tokenB));
    }

    function _scale(
        uint256 amount,
        int8 factor
    ) internal pure returns (uint256) {
        if (factor == 0) return amount;

        if (factor < 0) {
            return amount / (10 ** (-factor).toUint256());
        } else {
            return amount * (10 ** factor.toUint256());
        }
    }

    function _sortTokens(
        address tokenA,
        address tokenB
    ) internal pure returns (address _tokenA, address _tokenB) {
        (_tokenA, _tokenB) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
    }

    function _resizeArray(address[] memory array, uint256 size) internal pure {
        if (array.length == size) return;
        if (array.length < size)
            revert OracleAdapter__ArrayCannotExpand(array.length, size);

        assembly {
            mstore(array, size)
        }
    }

    function _resizeArray(uint8[] memory array, uint256 size) internal pure {
        if (array.length == size) return;
        if (array.length < size)
            revert OracleAdapter__ArrayCannotExpand(array.length, size);

        assembly {
            mstore(array, size)
        }
    }

    function _ensureTargetNonZero(uint256 target) internal view {
        if (target == 0 || target > block.timestamp)
            revert OracleAdapter__InvalidTarget(target, block.timestamp);
    }

    function _ensurePricePositive(int256 price) internal pure {
        if (price <= 0) revert OracleAdapter__InvalidPrice(price);
    }
}
