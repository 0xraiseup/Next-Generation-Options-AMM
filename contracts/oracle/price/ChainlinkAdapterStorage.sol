// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity ^0.8.0;

import {IChainlinkAdapterInternal} from "./IChainlinkAdapterInternal.sol";

library ChainlinkAdapterStorage {
    bytes32 internal constant STORAGE_SLOT =
        keccak256("premia.contracts.storage.ChainlinkAdapter");

    struct Layout {
        mapping(bytes32 => IChainlinkAdapterInternal.PricingPath) pathForPair;
        mapping(bytes32 => address) feeds;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_SLOT;
        assembly {
            l.slot := slot
        }
    }

    function formatRoundId(
        uint16 phaseId,
        uint64 aggregatorRoundId
    ) internal pure returns (uint80) {
        return uint80((uint256(phaseId) << 64) | aggregatorRoundId);
    }

    function parseRoundId(
        uint256 roundId
    ) internal pure returns (uint16 phaseId, uint64 aggregatorRoundId) {
        phaseId = uint16(roundId >> 64);
        aggregatorRoundId = uint64(roundId);
    }
}