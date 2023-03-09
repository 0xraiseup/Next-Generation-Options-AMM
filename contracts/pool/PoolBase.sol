// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {ERC165Base} from "@solidstate/contracts/introspection/ERC165/base/ERC165Base.sol";
import {ERC1155Base} from "@solidstate/contracts/token/ERC1155/base/ERC1155Base.sol";
import {ERC1155BaseInternal} from "@solidstate/contracts/token/ERC1155/base/ERC1155BaseInternal.sol";
import {ERC1155Enumerable} from "@solidstate/contracts/token/ERC1155/enumerable/ERC1155Enumerable.sol";
import {ERC1155EnumerableInternal} from "@solidstate/contracts/token/ERC1155/enumerable/ERC1155EnumerableInternal.sol";
import {IERC20Metadata} from "@solidstate/contracts/token/ERC20/metadata/IERC20Metadata.sol";
import {Multicall} from "@solidstate/contracts/utils/Multicall.sol";

import {Position} from "../libraries/Position.sol";

import {PoolStorage} from "./PoolStorage.sol";
import {IPoolBase} from "./IPoolBase.sol";

contract PoolBase is
    IPoolBase,
    ERC1155Base,
    ERC1155Enumerable,
    ERC165Base,
    Multicall
{
    constructor() {}

    /// @notice see IPoolBase; inheritance not possible due to linearization issues
    function name() external view returns (string memory) {
        PoolStorage.Layout storage l = PoolStorage.layout();

        // ToDo : Differentiate name if a pool already exists with other oracles for this pair ?

        return
            string(
                abi.encodePacked(
                    IERC20Metadata(l.base).symbol(),
                    " / ",
                    IERC20Metadata(l.quote).symbol(),
                    " - Premia Options Pool"
                )
            );
    }

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    )
        internal
        virtual
        override(ERC1155BaseInternal, ERC1155EnumerableInternal)
    {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);

        for (uint256 i; i < ids.length; i++) {
            if (ids[i] > PoolStorage.LONG)
                revert Pool__UseTransferPositionToTransferLPTokens();
        }
    }
}
