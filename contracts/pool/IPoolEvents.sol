// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {IPoolInternal} from "./IPoolInternal.sol";

import {UD60x18} from "@prb/math/src/UD60x18.sol";

interface IPoolEvents {
    event Deposit(
        address indexed owner,
        uint256 indexed tokenId,
        UD60x18 collateral,
        UD60x18 longs,
        UD60x18 shorts,
        UD60x18 lastFeeRate,
        UD60x18 claimableFees,
        UD60x18 marketPrice,
        UD60x18 liquidityRate,
        UD60x18 currentTick
    );

    event Withdrawal(
        address indexed owner,
        uint256 indexed tokenId,
        UD60x18 collateral,
        UD60x18 longs,
        UD60x18 shorts,
        UD60x18 lastFeeRate,
        UD60x18 claimableFees,
        UD60x18 marketPrice,
        UD60x18 liquidityRate,
        UD60x18 currentTick
    );

    event ClaimFees(
        address indexed owner,
        uint256 indexed tokenId,
        UD60x18 feesClaimed,
        UD60x18 lastFeeRate
    );

    event ClaimProtocolFees(address indexed feeReceiver, UD60x18 feesClaimed);

    event FillQuote(
        bytes32 indexed tradeQuoteHash,
        address indexed user,
        address indexed provider,
        UD60x18 contractSize,
        IPoolInternal.Delta deltaMaker,
        IPoolInternal.Delta deltaTaker,
        UD60x18 premium,
        UD60x18 protocolFee,
        bool isBuy
    );

    event WriteFrom(
        address indexed underwriter,
        address indexed longReceiver,
        UD60x18 contractSize,
        UD60x18 collateral,
        UD60x18 protocolFee
    );

    event Trade(
        address indexed user,
        UD60x18 contractSize,
        IPoolInternal.Delta delta,
        UD60x18 premium,
        UD60x18 takerFee,
        UD60x18 protocolFee,
        UD60x18 marketPrice,
        UD60x18 liquidityRate,
        UD60x18 currentTick,
        bool isBuy
    );

    event Exercise(
        address indexed holder,
        UD60x18 contractSize,
        UD60x18 exerciseValue,
        UD60x18 spot,
        UD60x18 fee
    );

    event Settle(
        address indexed user,
        UD60x18 contractSize,
        UD60x18 exerciseValue,
        UD60x18 spot,
        UD60x18 fee
    );

    event Annihilate(address indexed owner, UD60x18 contractSize, uint256 fee);

    event SettlePosition(
        address indexed owner,
        uint256 indexed tokenId,
        UD60x18 contractSize,
        UD60x18 collateral,
        UD60x18 exerciseValue,
        UD60x18 feesClaimed,
        UD60x18 spot,
        UD60x18 fee
    );

    event TransferPosition(
        address indexed owner,
        address indexed receiver,
        uint256 srcTokenId,
        uint256 destTokenId
    );

    event CancelTradeQuote(address indexed provider, bytes32 tradeQuoteHash);
}
