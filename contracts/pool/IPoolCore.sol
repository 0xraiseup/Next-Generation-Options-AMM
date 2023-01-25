// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {IPoolBase} from "./IPoolBase.sol";
import {IPoolInternal} from "./IPoolInternal.sol";
import {Position} from "../libraries/Position.sol";

import {IPoolInternal} from "./IPoolInternal.sol";

interface IPoolCore is IPoolInternal {
    /// @notice Gives a quote for a trade
    /// @param size The number of contracts being traded
    /// @param isBuy Whether the taker is buying or selling
    /// @return The premium which has to be paid to complete the trade
    function getQuote(uint256 size, bool isBuy) external view returns (uint256);

    /// @notice Updates the claimable fees of a position and transfers the claimed
    ///         fees to the operator of the position. Then resets the claimable fees to
    ///         zero.
    /// @param p The position key
    function claim(Position.Key memory p) external;

    /// @notice Deposits a `position` (combination of owner/operator, price range, bid/ask collateral, and long/short contracts) into the pool.
    /// @param p The position key
    /// @param belowLower The normalized price of nearest existing tick below lower. The search is done off-chain, passed as arg and validated on-chain to save gas
    /// @param belowUpper The normalized price of nearest existing tick below upper. The search is done off-chain, passed as arg and validated on-chain to save gas
    /// @param size The position size to deposit
    /// @param maxSlippage Max slippage (Percentage with 18 decimals -> 1% = 1e16)
    function deposit(
        Position.Key memory p,
        uint256 belowLower,
        uint256 belowUpper,
        uint256 size,
        uint256 maxSlippage
    ) external;

    /// @notice Deposits a `position` (combination of owner/operator, price range, bid/ask collateral, and long/short contracts) into the pool.
    /// @param p The position key
    /// @param belowLower The normalized price of nearest existing tick below lower. The search is done off-chain, passed as arg and validated on-chain to save gas
    /// @param belowUpper The normalized price of nearest existing tick below upper. The search is done off-chain, passed as arg and validated on-chain to save gas
    /// @param size The position size to deposit
    /// @param maxSlippage Max slippage (Percentage with 18 decimals -> 1% = 1e16)
    /// @param isBidIfStrandedMarketPrice Whether this is a bid or ask order when the market price is stranded (This argument doesnt matter if market price is not stranded)
    function deposit(
        Position.Key memory p,
        uint256 belowLower,
        uint256 belowUpper,
        uint256 size,
        uint256 maxSlippage,
        bool isBidIfStrandedMarketPrice
    ) external;

    /// @notice Swap tokens and deposits a `position` (combination of owner/operator, price range, bid/ask collateral, and long/short contracts) into the pool.
    /// @param s The swap arguments
    /// @param p The position key
    /// @param belowLower The normalized price of nearest existing tick below lower. The search is done off-chain, passed as arg and validated on-chain to save gas
    /// @param belowUpper The normalized price of nearest existing tick below upper. The search is done off-chain, passed as arg and validated on-chain to save gas
    /// @param size The position size to deposit
    /// @param maxSlippage Max slippage (Percentage with 18 decimals -> 1% = 1e16)
    function swapAndDeposit(
        IPoolInternal.SwapArgs memory s,
        Position.Key memory p,
        uint256 belowLower,
        uint256 belowUpper,
        uint256 size,
        uint256 maxSlippage
    ) external payable;

    /// @notice Withdraws a `position` (combination of owner/operator, price range, bid/ask collateral, and long/short contracts) from the pool
    /// @param p The position key
    /// @param size The position size to withdraw
    /// @param maxSlippage Max slippage (Percentage with 18 decimals -> 1% = 1e16)
    function withdraw(
        Position.Key memory p,
        uint256 size,
        uint256 maxSlippage
    ) external;

    /// @notice Completes a trade of `size` on `side` via the AMM using the liquidity in the Pool.
    /// @param size The number of contracts being traded
    /// @param isBuy Whether the taker is buying or selling
    /// @return totalPremium The premium paid or received by the taker for the trade
    /// @return delta The net collateral / longs / shorts change for taker of the trade.
    function trade(
        uint256 size,
        bool isBuy
    ) external returns (uint256 totalPremium, Delta memory delta);

    /// @notice Swap tokens and completes a trade of `size` on `side` via the AMM using the liquidity in the Pool.
    /// @param s The swap arguments
    /// @param size The number of contracts being traded
    /// @param isBuy Whether the taker is buying or selling
    /// @return totalPremium The premium paid or received by the taker for the trade
    /// @return delta The net collateral / longs / shorts change for taker of the trade.
    /// @return swapOutAmount The amount of pool tokens resulting from the swap
    function swapAndTrade(
        IPoolInternal.SwapArgs memory s,
        uint256 size,
        bool isBuy
    )
        external
        payable
        returns (
            uint256 totalPremium,
            Delta memory delta,
            uint256 swapOutAmount
        );

    /// @notice Completes a trade of `size` on `side` via the AMM using the liquidity in the Pool, and swap the resulting collateral to another token
    /// @param s The swap arguments
    /// @param size The number of contracts being traded
    /// @param isBuy Whether the taker is buying or selling
    /// @return totalPremium The premium received by the taker of the trade
    /// @return delta The net collateral / longs / shorts change for taker of the trade.
    /// @return collateralReceived The amount of un-swapped collateral received from the trade.
    /// @return tokenOutReceived The final amount of `s.tokenOut` received from the trade and swap.
    function tradeAndSwap(
        IPoolInternal.SwapArgs memory s,
        uint256 size,
        bool isBuy
    )
        external
        returns (
            uint256 totalPremium,
            Delta memory delta,
            uint256 collateralReceived,
            uint256 tokenOutReceived
        );

    /// @notice Annihilate a pair of long + short option contracts to unlock the stored collateral.
    ///         NOTE: This function can be called post or prior to expiration.
    /// @param size The size to annihilate
    function annihilate(uint256 size) external;

    /// @notice Exercises all long options held by an `owner`, ignoring automatic settlement fees.
    /// @param holder The holder of the contracts
    function exercise(address holder) external returns (uint256);

    /// @notice Settles all short options held by an `owner`, ignoring automatic settlement fees.
    /// @param holder The holder of the contracts
    function settle(address holder) external returns (uint256);

    /// @notice Reconciles a user's `position` to account for settlement payouts post-expiration.
    /// @param p The position key
    function settlePosition(Position.Key memory p) external returns (uint256);

    /// @notice Get nearest ticks below `lower` and `upper`.
    ///         NOTE : If no tick between `lower` and `upper`, then the nearest tick below `upper`, will be `lower`
    /// @param lower The lower bound of the range
    /// @param upper The upper bound of the range
    /// @return nearestBelowLower The nearest tick below `lower`
    /// @return nearestBelowUpper The nearest tick below `upper`
    function getNearestTicksBelow(
        uint256 lower,
        uint256 upper
    )
        external
        view
        returns (uint256 nearestBelowLower, uint256 nearestBelowUpper);
}
