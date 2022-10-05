// SPDX-License-Identifier: BUSL-1.1
// For further clarification please see https://license.premia.legal

pragma solidity ^0.8.0;

import {LinkedList} from "../libraries/LinkedList.sol";
import {Math} from "./Math.sol";
import {WadMath} from "./WadMath.sol";

import {PoolStorage} from "../pool/PoolStorage.sol";

/**
 * @notice This class implements the methods necessary for computing price movements within a tick range.
 *         Warnings
 *         --------
 *         This class should not be used for computations that span multiple ticks.
 *         Instead, the user should use the methods of this class to simplify
 *         computations for more complex price calculations.
 */
library PricingCurve {
    using LinkedList for LinkedList.List;
    using PoolStorage for PoolStorage.Layout;
    using WadMath for uint256;

    error PricingCurve__InvalidQuantityArgs();

    struct Args {
        uint256 liquidityRate; // Amount of liquidity
        uint256 minTickDistance; // The minimum distance between two ticks
        uint256 lower; // The normalized price of the lower bound of the range
        uint256 upper; // The normalized price of the upper bound of the range
        PoolStorage.Side tradeSide; // The direction of the trade
    }

    function fromPool(PoolStorage.Layout storage l, PoolStorage.Side tradeSide)
        internal
        view
        returns (PricingCurve.Args memory)
    {
        uint256 currentTick = l.tick;

        return
            Args(
                l.liquidityRate,
                l.minTickDistance(),
                currentTick,
                l.tickIndex.getNextNode(currentTick),
                tradeSide
            );
    }

    function liquidityForRange(Args memory args)
        internal
        pure
        returns (uint256)
    {
        // ToDo : Check that precision is enough
        return
            args.liquidityRate.mulWad(
                (args.upper - args.lower) * (1e18 / args.minTickDistance)
            );
    }

    /**
     * @notice Computes quantity needed to reach `price` from the current
     *         lower/upper tick coming from the buy/sell direction.
     *         |=======q=======|
     *         |--------------------------------------|
     *         L               ^                      U
     *                       Price
     * @param args The main PricingCurve arguments
     * @param targetPrice The target price
     * @return The quantity needed to reach `price` from the lower/upper tick coming from the buy/sell direction
     */
    function quantity(Args memory args, uint256 targetPrice)
        internal
        pure
        returns (uint256)
    {
        if (
            args.lower > targetPrice ||
            targetPrice > args.upper ||
            args.lower == args.upper
        ) revert PricingCurve__InvalidQuantityArgs();

        uint256 proportion = args.tradeSide == PoolStorage.Side.BUY
            ? (targetPrice - args.lower) / (args.upper - args.lower)
            : (args.upper - targetPrice) / (args.upper - args.lower);

        return liquidityForRange(args).mulWad(proportion);
    }

    /**
     * @notice Calculates the max trade size within the current tick range using the quantity function.
     * @param args The main PricingCurve arguments
     * @param marketPrice The current normalized market price
     * @return The maximum trade size within the current tick range
     */
    function maxTradeSize(Args memory args, uint256 marketPrice)
        internal
        pure
        returns (uint256)
    {
        uint256 targetPrice = args.tradeSide == PoolStorage.Side.BUY
            ? args.upper
            : args.lower;

        return
            Math.abs(
                int256(quantity(args, targetPrice)) -
                    int256(quantity(args, marketPrice))
            );
    }

    /**
     * @notice Computes price reached from the current lower/upper tick after
     *         buying/selling `trade_size` amount of contracts.
     * @param args The main PricingCurve arguments
     * @param size The size of the trade (number of contracts).
     * @return The price reached from the current lower/upper tick after buying/selling `trade_size` amount of contracts.
     */
    function price(Args memory args, uint256 size)
        internal
        pure
        returns (uint256)
    {
        uint256 liquidity = liquidityForRange(args);
        bool isBuy = args.tradeSide == PoolStorage.Side.BUY;

        // ToDo : Check for rounding errors which might make this condition always false
        if (liquidity == 0) return isBuy ? args.lower : args.upper;

        uint256 proportion = size.divWad(liquidity);

        return
            isBuy
                ? args.lower + (args.upper - args.lower).mulWad(proportion)
                : args.upper - (args.upper - args.lower).mulWad(proportion);
    }

    /**
     * @notice Gets the next market price within a tick range
     * @param args The main PricingCurve arguments
     * @param marketPrice The normalized market price
     */
    function nextPrice(
        Args memory args,
        uint256 marketPrice,
        uint256 size
    ) internal pure returns (uint256) {
        return price(args, size + quantity(args, marketPrice));
    }
}
