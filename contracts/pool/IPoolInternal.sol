// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {IPosition} from "../libraries/IPosition.sol";
import {IPricing} from "../libraries/IPricing.sol";
import {Position} from "../libraries/Position.sol";

interface IPoolInternal is IPosition, IPricing {
    error Pool__AboveQuoteSize();
    error Pool__AboveMaxSlippage();
    error Pool__InsufficientAskLiquidity();
    error Pool__InsufficientBidLiquidity();
    error Pool__InvalidAssetUpdate();
    error Pool__InvalidBelowPrice();
    error Pool__InvalidQuoteNonce();
    error Pool__InvalidQuoteSignature();
    error Pool__InvalidQuoteTaker();
    error Pool__InvalidRange();
    error Pool__InvalidReconciliation();
    error Pool__InvalidTransfer();
    error Pool__InvalidSwapTokenIn();
    error Pool__InvalidSwapTokenOut();
    error Pool__LongOrShortMustBeZero();
    error Pool__NotAuthorized();
    error Pool__NotEnoughSwapOutput();
    error Pool__NotEnoughTokens();
    error Pool__OppositeSides();
    error Pool__OptionExpired();
    error Pool__OptionNotExpired();
    error Pool__OutOfBoundsPrice();
    error Pool__PositionDoesNotExist();
    error Pool__PositionCantHoldLongAndShort();
    error Pool__QuoteExpired();
    error Pool__TickDeltaNotZero();
    error Pool__TickNotFound();
    error Pool__TickOutOfRange();
    error Pool__TickWidthInvalid();
    error Pool__ZeroSize();

    struct SwapArgs {
        // token to pass in to swap (Must be poolToken for `tradeAndSwap`)
        address tokenIn;
        // Token result from the swap (Must be poolToken for `swapAndDeposit` / `swapAndTrade`)
        address tokenOut;
        // amount of tokenIn to trade
        uint256 amountInMax;
        //min amount out to be used to purchase
        uint256 amountOutMin;
        // exchange address to call to execute the trade
        address callee;
        // address for which to set allowance for the trade
        address allowanceTarget;
        // data to execute the trade
        bytes data;
        // address to which refund excess tokens
        address refundAddress;
    }

    struct TradeQuote {
        address provider;
        address taker;
        uint256 price;
        uint256 size;
        bool isBuy;
        uint256 nonce;
        uint256 deadline;
    }

    struct Delta {
        int256 collateral;
        int256 longs;
        int256 shorts;
    }

    struct TradeArgsInternal {
        // The account doing the trade
        address user;
        // The number of contracts being traded
        uint256 size;
        // Whether the taker is buying or selling
        bool isBuy;
        // Amount already credited before the _trade function call. In case of a `swapAndTrade` this would be the amount resulting from the swap
        uint256 creditAmount;
        // Whether to transfer collateral to user or not if collateral value is positive. Should be false if that collateral is used for a swap
        bool transferCollateralToUser;
    }

    struct DepositArgsInternal {
        // The normalized price of nearest existing tick below lower. The search is done off-chain, passed as arg and validated on-chain to save gas
        uint256 belowLower;
        // The normalized price of nearest existing tick below upper. The search is done off-chain, passed as arg and validated on-chain to save gas
        uint256 belowUpper;
        // The position size to deposit
        uint256 size;
        // Max slippage (Percentage with 18 decimals -> 1% = 1e16)
        uint256 maxSlippage;
        // Collateral amount already credited before the _deposit function call. In case of a `swapAndDeposit` this would be the amount resulting from the swap
        uint256 collateralCredit;
        // The address to which refund excess credit
        address refundAddress;
        // Whether this is a bid or ask order when the market price is stranded (This argument doesnt matter if market price is not stranded)
        bool isBidIfStrandedMarketPrice;
    }

    struct FillQuoteArgsInternal {
        // The user filling the quote
        address user;
        // The size to fill from the quote
        uint256 size;
        // secp256k1 'v' value
        uint8 v;
        // secp256k1 'r' value
        bytes32 r;
        // secp256k1 's' value
        bytes32 s;
    }

    struct FillQuoteVarsInternal {
        uint256 premium;
        uint256 takerFee;
        uint256 protocolFee;
        uint256 makerRebate;
        uint256 premiumTaker;
        uint256 premiumMaker;
    }
}
