// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {Math} from "@solidstate/contracts/utils/Math.sol";
import {EIP712} from "@solidstate/contracts/cryptography/EIP712.sol";
import {ERC1155EnumerableInternal} from "@solidstate/contracts/token/ERC1155/enumerable/ERC1155Enumerable.sol";
import {ERC1155BaseStorage} from "@solidstate/contracts/token/ERC1155/base/ERC1155BaseStorage.sol";
import {SafeCast} from "@solidstate/contracts/utils/SafeCast.sol";
import {IERC20} from "@solidstate/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@solidstate/contracts/utils/SafeERC20.sol";
import {ECDSA} from "@solidstate/contracts/cryptography/ECDSA.sol";
import {EnumerableSet} from "@solidstate/contracts/data/EnumerableSet.sol";

import {UD60x18, ud} from "@prb/math/UD60x18.sol";
import {SD59x18} from "@prb/math/SD59x18.sol";

import {IOracleAdapter} from "../adapter/IOracleAdapter.sol";
import {IERC20Router} from "../router/IERC20Router.sol";
import {IPoolFactory} from "../factory/IPoolFactory.sol";
import {IUserSettings} from "../settings/IUserSettings.sol";
import {IVxPremia} from "../staking/IVxPremia.sol";
import {IVaultRegistry} from "../vault/IVaultRegistry.sol";

import {DoublyLinkedListUD60x18, DoublyLinkedList} from "../libraries/DoublyLinkedListUD60x18.sol";
import {Position} from "../libraries/Position.sol";
import {Pricing} from "../libraries/Pricing.sol";
import {PRBMathExtra} from "../libraries/PRBMathExtra.sol";
import {iZERO, ZERO, ONE, TWO, FIVE} from "../libraries/Constants.sol";

import {IReferral} from "../referral/IReferral.sol";

import {IPoolInternal} from "./IPoolInternal.sol";
import {IPoolEvents} from "./IPoolEvents.sol";
import {PoolStorage} from "./PoolStorage.sol";

contract PoolInternal is IPoolInternal, IPoolEvents, ERC1155EnumerableInternal {
    using SafeERC20 for IERC20;
    using DoublyLinkedListUD60x18 for DoublyLinkedList.Bytes32List;
    using EnumerableSet for EnumerableSet.UintSet;
    using PoolStorage for IERC20;
    using PoolStorage for IERC20Router;
    using PoolStorage for PoolStorage.Layout;
    using PoolStorage for QuoteRFQ;
    using Position for Position.KeyInternal;
    using Position for Position.OrderType;
    using Pricing for Pricing.Args;
    using SafeCast for uint256;
    using Math for int256;
    using ECDSA for bytes32;
    using PRBMathExtra for UD60x18;
    using PRBMathExtra for SD59x18;

    address internal immutable FACTORY;
    address internal immutable ROUTER;
    address internal immutable WRAPPED_NATIVE_TOKEN;
    address internal immutable FEE_RECEIVER;
    address internal immutable REFERRAL;
    address internal immutable SETTINGS;
    address internal immutable VAULT_REGISTRY;
    address internal immutable VXPREMIA;

    UD60x18 internal constant PROTOCOL_FEE_PERCENTAGE = UD60x18.wrap(0.5e18); // 50%
    UD60x18 internal constant PREMIUM_FEE_PERCENTAGE = UD60x18.wrap(0.03e18); // 3%
    UD60x18 internal constant COLLATERAL_FEE_PERCENTAGE = UD60x18.wrap(0.003e18); // 0.3%

    // Number of seconds required to pass before a deposit can be withdrawn (To prevent flash loans and JIT)
    uint256 internal constant WITHDRAWAL_DELAY = 60;

    bytes32 internal constant FILL_QUOTE_RFQ_TYPE_HASH =
        keccak256(
            "FillQuoteRFQ(address provider,address taker,uint256 price,uint256 size,bool isBuy,uint256 deadline,uint256 salt)"
        );

    constructor(
        address factory,
        address router,
        address wrappedNativeToken,
        address feeReceiver,
        address referral,
        address settings,
        address vaultRegistry,
        address vxPremia
    ) {
        FACTORY = factory;
        ROUTER = router;
        WRAPPED_NATIVE_TOKEN = wrappedNativeToken;
        FEE_RECEIVER = feeReceiver;
        REFERRAL = referral;
        SETTINGS = settings;
        VAULT_REGISTRY = vaultRegistry;
        VXPREMIA = vxPremia;
    }

    /// @notice Calculates the fee for a trade based on the `size` and `premium` of the trade.
    /// @param taker The taker of a trade
    /// @param size The size of a trade (number of contracts) (18 decimals)
    /// @param premium The total cost of option(s) for a purchase (18 decimals)
    /// @param isPremiumNormalized Whether the premium given is already normalized by strike or not (Ex: For a strike of
    ///        1500, and a premium of 750, the normalized premium would be 0.5)
    /// @param strike The strike of the option (18 decimals)
    /// @param isCallPool Whether the pool is a call pool or not
    /// @return The taker fee for an option trade denormalized. (18 decimals)
    function _takerFee(
        address taker,
        UD60x18 size,
        UD60x18 premium,
        bool isPremiumNormalized,
        UD60x18 strike,
        bool isCallPool
    ) internal view returns (UD60x18) {
        if (!isPremiumNormalized) {
            // Normalize premium
            premium = Position.collateralToContracts(premium, strike, isCallPool);
        }

        UD60x18 premiumFee = premium * PREMIUM_FEE_PERCENTAGE;
        UD60x18 notionalFee = size * COLLATERAL_FEE_PERCENTAGE;
        UD60x18 fee = PRBMathExtra.max(premiumFee, notionalFee);

        UD60x18 discount;
        if (taker != address(0)) discount = ud(IVxPremia(VXPREMIA).getDiscount(taker));
        if (discount > ZERO) fee = (ONE - discount) * fee;

        return Position.contractsToCollateral(fee, strike, isCallPool);
    }

    /// @notice Gives a quote for a trade
    /// @param taker The taker of the trade
    /// @param size The number of contracts being traded (18 decimals)
    /// @param isBuy Whether the taker is buying or selling
    /// @return totalNetPremium The premium which has to be paid to complete the trade (Net of fees) (poolToken decimals)
    /// @return totalTakerFee The taker fees to pay (Included in `premiumNet`) (poolToken decimals)
    function _getQuoteAMM(
        address taker,
        UD60x18 size,
        bool isBuy
    ) internal view returns (uint256 totalNetPremium, uint256 totalTakerFee) {
        PoolStorage.Layout storage l = PoolStorage.layout();

        _revertIfZeroSize(size);
        _revertIfOptionExpired(l);

        Pricing.Args memory pricing = Pricing.Args(
            l.liquidityRate,
            l.marketPrice,
            l.currentTick,
            l.tickIndex.next(l.currentTick),
            isBuy
        );

        QuoteAMMVarsInternal memory vars;
        vars.liquidity = pricing.liquidity();
        vars.maxSize = pricing.maxTradeSize();

        while (size > ZERO) {
            UD60x18 tradeSize = PRBMathExtra.min(size, vars.maxSize);

            UD60x18 nextPrice;
            // Compute next price
            if (vars.liquidity == ZERO || tradeSize == vars.maxSize) {
                nextPrice = isBuy ? pricing.upper : pricing.lower;
            } else {
                UD60x18 priceDelta = ((pricing.upper - pricing.lower) * tradeSize) / vars.liquidity;
                nextPrice = isBuy ? pricing.marketPrice + priceDelta : pricing.marketPrice - priceDelta;
            }

            if (tradeSize > ZERO) {
                UD60x18 premium = pricing.marketPrice.avg(nextPrice) * tradeSize;

                UD60x18 takerFee = _takerFee(taker, size, premium, true, l.strike, l.isCallPool);

                // Denormalize premium
                premium = Position.contractsToCollateral(premium, l.strike, l.isCallPool);

                vars.totalTakerFee = vars.totalTakerFee + takerFee;
                vars.totalPremium = vars.totalPremium + premium;
            }

            pricing.marketPrice = nextPrice;

            if (vars.maxSize >= size) {
                size = ZERO;
            } else {
                // Cross tick
                size = size - vars.maxSize;

                // Adjust liquidity rate
                pricing.liquidityRate = pricing.liquidityRate.add(l.ticks[isBuy ? pricing.upper : pricing.lower].delta);

                // Set new lower and upper bounds
                pricing.lower = isBuy ? pricing.upper : l.tickIndex.prev(pricing.lower);
                pricing.upper = l.tickIndex.next(pricing.lower);

                if (pricing.upper == ZERO) revert Pool__InsufficientLiquidity();

                // Compute new liquidity
                vars.liquidity = pricing.liquidity();
                vars.maxSize = pricing.maxTradeSize();
            }
        }

        return (
            l.toPoolTokenDecimals(
                isBuy ? vars.totalPremium + vars.totalTakerFee : vars.totalPremium - vars.totalTakerFee
            ),
            l.toPoolTokenDecimals(vars.totalTakerFee)
        );
    }

    /// @notice Returns amount of claimable fees from pending update of claimable fees for the position. This does not
    ///         include pData.claimableFees
    function _pendingClaimableFees(
        PoolStorage.Layout storage l,
        Position.KeyInternal memory p,
        Position.Data storage pData
    ) internal view returns (UD60x18 claimableFees, SD59x18 feeRate) {
        Tick memory lowerTick = _getTick(p.lower);
        Tick memory upperTick = _getTick(p.upper);

        feeRate = _rangeFeeRate(l, p.lower, p.upper, lowerTick.externalFeeRate, upperTick.externalFeeRate);

        claimableFees = _calculateClaimableFees(
            feeRate,
            pData.lastFeeRate,
            p.liquidityPerTick(
                _balanceOfUD60x18(p.owner, PoolStorage.formatTokenId(p.operator, p.lower, p.upper, p.orderType))
            )
        );
    }

    /// @notice Returns the amount of fees an LP can claim for a position (without claiming)
    function _calculateClaimableFees(
        SD59x18 feeRate,
        SD59x18 lastFeeRate,
        UD60x18 liquidityPerTick
    ) internal pure returns (UD60x18) {
        return (feeRate - lastFeeRate).intoUD60x18() * liquidityPerTick;
    }

    /// @notice Updates the amount of fees an LP can claim for a position (without claiming)
    function _updateClaimableFees(Position.Data storage pData, SD59x18 feeRate, UD60x18 liquidityPerTick) internal {
        pData.claimableFees =
            pData.claimableFees +
            _calculateClaimableFees(feeRate, pData.lastFeeRate, liquidityPerTick);

        // Reset the initial range rate of the position
        pData.lastFeeRate = feeRate;
    }

    /// @notice Updates the amount of fees an LP can claim for a position
    function _updateClaimableFees(
        PoolStorage.Layout storage l,
        Position.KeyInternal memory p,
        Position.Data storage pData
    ) internal {
        (UD60x18 claimableFees, SD59x18 feeRate) = _pendingClaimableFees(l, p, pData);

        pData.claimableFees = pData.claimableFees + claimableFees;
        pData.lastFeeRate = feeRate;
    }

    /// @notice Updates the claimable fees of a position and transfers the claimed fees to the operator of the position.
    ///         Then resets the claimable fees to zero.
    /// @param p The position to claim fees for
    /// @return claimedFees The amount of fees claimed (poolToken decimals)
    function _claim(Position.KeyInternal memory p) internal returns (uint256 claimedFees) {
        PoolStorage.Layout storage l = PoolStorage.layout();

        if (l.protocolFees > ZERO) _claimProtocolFees();

        Position.Data storage pData = l.positions[p.keyHash()];
        _updateClaimableFees(l, p, pData);
        UD60x18 _claimedFees = pData.claimableFees;

        pData.claimableFees = ZERO;
        IERC20(l.getPoolToken()).safeTransfer(p.operator, _claimedFees);

        emit ClaimFees(
            p.owner,
            PoolStorage.formatTokenId(p.operator, p.lower, p.upper, p.orderType),
            _claimedFees,
            pData.lastFeeRate
        );

        return l.toPoolTokenDecimals(_claimedFees);
    }

    /// @notice Claims the protocol fees and transfers them to the fee receiver
    function _claimProtocolFees() internal {
        PoolStorage.Layout storage l = PoolStorage.layout();
        UD60x18 claimedFees = l.protocolFees;

        if (claimedFees == ZERO) return;

        l.protocolFees = ZERO;
        IERC20(l.getPoolToken()).safeTransfer(FEE_RECEIVER, claimedFees);
        emit ClaimProtocolFees(FEE_RECEIVER, claimedFees);
    }

    /// @notice Deposits a `position` (combination of owner/operator, price range, bid/ask collateral, and long/short
    ///         contracts) into the pool.
    /// @param p The position key
    /// @param args The deposit parameters
    /// @return delta The amount of collateral / longs / shorts deposited
    function _deposit(
        Position.KeyInternal memory p,
        DepositArgsInternal memory args
    ) internal returns (Position.Delta memory delta) {
        return
            _deposit(
                p,
                args,
                // We default to isBid = true if orderType is long and isBid = false if orderType is short, so that
                // default behavior in case of stranded market price is to deposit collateral
                p.orderType.isLong()
            );
    }

    /// @notice Deposits a `position` (combination of owner/operator, price range, bid/ask collateral, and long/short
    ///         contracts) into the pool.
    /// @param p The position key
    /// @param args The deposit parameters
    /// @param isBidIfStrandedMarketPrice Whether this is a bid or ask order when the market price is stranded (This
    ///        argument doesnt matter if market price is not stranded)
    /// @return delta The amount of collateral / longs / shorts deposited
    function _deposit(
        Position.KeyInternal memory p,
        DepositArgsInternal memory args,
        bool isBidIfStrandedMarketPrice
    ) internal returns (Position.Delta memory delta) {
        PoolStorage.Layout storage l = PoolStorage.layout();

        // Set the market price correctly in case it's stranded
        if (_isMarketPriceStranded(l, p, isBidIfStrandedMarketPrice)) {
            l.marketPrice = _getStrandedMarketPriceUpdate(p, isBidIfStrandedMarketPrice);
        }

        _revertIfDepositWithdrawalAboveMaxSlippage(l.marketPrice, args.minMarketPrice, args.maxMarketPrice);
        _revertIfZeroSize(args.size);
        _revertIfOptionExpired(l);

        _revertIfRangeInvalid(p.lower, p.upper);
        _revertIfTickWidthInvalid(p.lower);
        _revertIfTickWidthInvalid(p.upper);
        _revertIfInvalidSize(p.lower, p.upper, args.size);

        uint256 tokenId = PoolStorage.formatTokenId(p.operator, p.lower, p.upper, p.orderType);

        delta = p.calculatePositionUpdate(_balanceOfUD60x18(p.owner, tokenId), args.size.intoSD59x18(), l.marketPrice);

        _transferTokens(
            l,
            p.operator,
            address(this),
            l.toPoolTokenDecimals(delta.collateral.intoUD60x18()),
            delta.longs.intoUD60x18(),
            delta.shorts.intoUD60x18()
        );

        Position.Data storage pData = l.positions[p.keyHash()];

        _depositFeeAndTicksUpdate(l, pData, p, args.belowLower, args.belowUpper, args.size, tokenId);

        pData.lastDeposit = block.timestamp;

        emit Deposit(
            p.owner,
            tokenId,
            delta.collateral.intoUD60x18(),
            delta.longs.intoUD60x18(),
            delta.shorts.intoUD60x18(),
            pData.lastFeeRate,
            pData.claimableFees,
            l.marketPrice,
            l.liquidityRate,
            l.currentTick
        );
    }

    /// @notice Handles fee/tick updates and mints LP token on deposit
    function _depositFeeAndTicksUpdate(
        PoolStorage.Layout storage l,
        Position.Data storage pData,
        Position.KeyInternal memory p,
        UD60x18 belowLower,
        UD60x18 belowUpper,
        UD60x18 size,
        uint256 tokenId
    ) internal {
        SD59x18 feeRate;
        {
            // If ticks dont exist they are created and inserted into the linked list
            Tick memory lowerTick = _getOrCreateTick(p.lower, belowLower);
            Tick memory upperTick = _getOrCreateTick(p.upper, belowUpper);

            feeRate = _rangeFeeRate(l, p.lower, p.upper, lowerTick.externalFeeRate, upperTick.externalFeeRate);
        }

        {
            UD60x18 initialSize = _balanceOfUD60x18(p.owner, tokenId);
            UD60x18 liquidityPerTick;

            if (initialSize > ZERO) {
                liquidityPerTick = p.liquidityPerTick(initialSize);

                _updateClaimableFees(pData, feeRate, liquidityPerTick);
            } else {
                pData.lastFeeRate = feeRate;
            }

            _mint(p.owner, tokenId, size);

            SD59x18 tickDelta = p.liquidityPerTick(_balanceOfUD60x18(p.owner, tokenId)).intoSD59x18() -
                liquidityPerTick.intoSD59x18();

            // Adjust tick deltas
            _updateTicks(p.lower, p.upper, l.marketPrice, tickDelta, initialSize == ZERO, false, p.orderType);
        }

        // Safeguard, should never happen
        if (
            feeRate !=
            _rangeFeeRate(l, p.lower, p.upper, l.ticks[p.lower].externalFeeRate, l.ticks[p.upper].externalFeeRate)
        ) revert Pool__InvalidTickUpdate();
    }

    /// @notice Withdraws a `position` (combination of owner/operator, price range, bid/ask collateral, and long/short
    ///         contracts) from the pool
    ///         Tx will revert if market price is not between `minMarketPrice` and `maxMarketPrice`.
    /// @param p The position key
    /// @param size The position size to withdraw (18 decimals)
    /// @param minMarketPrice Min market price, as normalized value. (If below, tx will revert) (18 decimals)
    /// @param maxMarketPrice Max market price, as normalized value. (If above, tx will revert) (18 decimals)
    /// @param transferCollateralToUser Whether to transfer collateral to user or not if collateral value is positive.
    ///        Should be false if that collateral is used for a swap
    /// @return delta The amount of collateral / longs / shorts withdrawn
    function _withdraw(
        Position.KeyInternal memory p,
        UD60x18 size,
        UD60x18 minMarketPrice,
        UD60x18 maxMarketPrice,
        bool transferCollateralToUser
    ) internal returns (Position.Delta memory delta) {
        PoolStorage.Layout storage l = PoolStorage.layout();
        _revertIfOptionExpired(l);

        _revertIfDepositWithdrawalAboveMaxSlippage(l.marketPrice, minMarketPrice, maxMarketPrice);
        _revertIfZeroSize(size);
        _revertIfRangeInvalid(p.lower, p.upper);
        _revertIfTickWidthInvalid(p.lower);
        _revertIfTickWidthInvalid(p.upper);
        _revertIfInvalidSize(p.lower, p.upper, size);

        Position.Data storage pData = l.positions[p.keyHash()];

        _revertIfWithdrawalDelayNotElapsed(pData);

        WithdrawVarsInternal memory vars;

        vars.tokenId = PoolStorage.formatTokenId(p.operator, p.lower, p.upper, p.orderType);
        vars.initialSize = _balanceOfUD60x18(p.owner, vars.tokenId);

        if (vars.initialSize == ZERO) revert Pool__PositionDoesNotExist(p.owner, vars.tokenId);

        vars.isFullWithdrawal = vars.initialSize == size;

        {
            Tick memory lowerTick = _getTick(p.lower);
            Tick memory upperTick = _getTick(p.upper);

            // Initialize variables before position update
            vars.liquidityPerTick = p.liquidityPerTick(vars.initialSize);
            SD59x18 feeRate = _rangeFeeRate(l, p.lower, p.upper, lowerTick.externalFeeRate, upperTick.externalFeeRate);

            // Update claimable fees
            _updateClaimableFees(pData, feeRate, vars.liquidityPerTick);
        }

        // Check whether it's a full withdrawal before updating the position

        {
            UD60x18 collateralToTransfer;
            if (vars.isFullWithdrawal) {
                UD60x18 feesClaimed = pData.claimableFees;
                // Claim all fees and remove the position completely
                collateralToTransfer = collateralToTransfer + feesClaimed;

                pData.claimableFees = ZERO;
                pData.lastFeeRate = iZERO;

                emit ClaimFees(p.owner, vars.tokenId, feesClaimed, iZERO);
            }

            delta = p.calculatePositionUpdate(vars.initialSize, -size.intoSD59x18(), l.marketPrice);

            delta.collateral = delta.collateral.abs();
            delta.longs = delta.longs.abs();
            delta.shorts = delta.shorts.abs();

            collateralToTransfer = collateralToTransfer + delta.collateral.intoUD60x18();

            _burn(p.owner, vars.tokenId, size);

            _transferTokens(
                l,
                address(this),
                p.operator,
                transferCollateralToUser ? l.toPoolTokenDecimals(collateralToTransfer) : 0,
                delta.longs.intoUD60x18(),
                delta.shorts.intoUD60x18()
            );
        }

        vars.tickDelta =
            p.liquidityPerTick(_balanceOfUD60x18(p.owner, vars.tokenId)).intoSD59x18() -
            vars.liquidityPerTick.intoSD59x18();

        _updateTicks(
            p.lower,
            p.upper,
            l.marketPrice,
            vars.tickDelta, // Adjust tick deltas (reverse of deposit)
            false,
            vars.isFullWithdrawal,
            p.orderType
        );

        emit Withdrawal(
            p.owner,
            vars.tokenId,
            delta.collateral.intoUD60x18(),
            delta.longs.intoUD60x18(),
            delta.shorts.intoUD60x18(),
            pData.lastFeeRate,
            pData.claimableFees,
            l.marketPrice,
            l.liquidityRate,
            l.currentTick
        );
    }

    /// @notice Handle transfer of collateral / longs / shorts on deposit or withdrawal
    ///         ===========================================================
    ///         WARNING:
    ///         `collateral` must be scaled to the collateral token decimals
    ///         ===========================================================
    function _transferTokens(
        PoolStorage.Layout storage l,
        address from,
        address to,
        uint256 collateral,
        UD60x18 longs,
        UD60x18 shorts
    ) internal {
        // Safeguard, should never happen
        if (longs > ZERO && shorts > ZERO) revert Pool__PositionCantHoldLongAndShort(longs, shorts);

        address poolToken = l.getPoolToken();

        if (from == address(this)) {
            IERC20(poolToken).safeTransfer(to, collateral);
        } else {
            IERC20Router(ROUTER).safeTransferFrom(poolToken, from, to, collateral);
        }

        if (longs + shorts > ZERO) {
            uint256 id = longs > ZERO ? PoolStorage.LONG : PoolStorage.SHORT;
            uint256 amount = longs > ZERO ? longs.unwrap() : shorts.unwrap();

            if (to == address(this)) {
                // We bypass the acceptance check by using `_transfer` instead of `_safeTransfer if transferring to the pool,
                // so that we do not have to blindly accept any transfer
                _transfer(address(this), from, to, id, amount, "");
            } else {
                _safeTransfer(address(this), from, to, id, amount, "");
            }
        }
    }

    /// @notice Transfers collateral + fees from `underwriter` and sends long/short tokens to both parties
    function _writeFrom(address underwriter, address longReceiver, UD60x18 size, address referrer) internal {
        if (
            msg.sender != underwriter &&
            !IUserSettings(SETTINGS).isActionAuthorized(underwriter, msg.sender, IUserSettings.Action.WriteFrom)
        ) revert Pool__ActionNotAuthorized(underwriter, msg.sender, IUserSettings.Action.WriteFrom);

        PoolStorage.Layout storage l = PoolStorage.layout();

        _revertIfZeroSize(size);
        _revertIfOptionExpired(l);

        UD60x18 collateral = Position.contractsToCollateral(size, l.strike, l.isCallPool);

        address taker = underwriter;
        if (IVaultRegistry(VAULT_REGISTRY).isVault(msg.sender)) {
            taker = longReceiver;
        }

        UD60x18 protocolFee = _takerFee(taker, size, ZERO, true, l.strike, l.isCallPool);

        IERC20Router(ROUTER).safeTransferFrom(l.getPoolToken(), underwriter, address(this), collateral + protocolFee);

        (UD60x18 primaryReferralRebate, UD60x18 secondaryReferralRebate) = IReferral(REFERRAL).getRebateAmounts(
            taker,
            referrer,
            protocolFee
        );

        _useReferral(l, taker, referrer, primaryReferralRebate, secondaryReferralRebate);
        l.protocolFees = l.protocolFees + protocolFee - (primaryReferralRebate + secondaryReferralRebate);

        _mint(underwriter, PoolStorage.SHORT, size);
        _mint(longReceiver, PoolStorage.LONG, size);

        emit WriteFrom(underwriter, longReceiver, taker, size, collateral, protocolFee);
    }

    /// @notice Completes a trade of `size` on `side` via the AMM using the liquidity in the Pool.
    /// @param args Trade parameters
    /// @return totalPremium The premium paid or received by the taker for the trade (poolToken decimals)
    /// @return delta The net collateral / longs / shorts change for taker of the trade.
    function _trade(
        TradeArgsInternal memory args
    ) internal returns (uint256 totalPremium, Position.Delta memory delta) {
        PoolStorage.Layout storage l = PoolStorage.layout();

        _revertIfZeroSize(args.size);
        _revertIfOptionExpired(l);

        TradeVarsInternal memory vars;

        {
            UD60x18 remaining = args.size;

            while (remaining > ZERO) {
                Pricing.Args memory pricing = _getPricing(l, args.isBuy);
                vars.maxSize = pricing.maxTradeSize();
                vars.tradeSize = PRBMathExtra.min(remaining, vars.maxSize);
                vars.oldMarketPrice = l.marketPrice;

                {
                    UD60x18 nextMarketPrice;
                    if (vars.tradeSize != vars.maxSize) {
                        nextMarketPrice = pricing.nextPrice(vars.tradeSize);
                    } else {
                        nextMarketPrice = args.isBuy ? pricing.upper : pricing.lower;
                    }

                    UD60x18 premium;

                    {
                        UD60x18 quoteAMMPrice = l.marketPrice.avg(nextMarketPrice);
                        premium = quoteAMMPrice * vars.tradeSize;
                    }

                    UD60x18 takerFee = _takerFee(args.user, vars.tradeSize, premium, true, l.strike, l.isCallPool);

                    // Denormalize premium
                    premium = Position.contractsToCollateral(premium, l.strike, l.isCallPool);

                    // Update price and liquidity variables
                    {
                        (UD60x18 primaryReferralRebate, UD60x18 secondaryReferralRebate) = IReferral(REFERRAL)
                            .getRebateAmounts(args.user, args.referrer, takerFee);

                        UD60x18 totalReferralRebate = primaryReferralRebate + secondaryReferralRebate;
                        vars.referral.totalRebate = vars.referral.totalRebate + totalReferralRebate;
                        vars.referral.primaryRebate = vars.referral.primaryRebate + primaryReferralRebate;
                        vars.referral.secondaryRebate = vars.referral.secondaryRebate + secondaryReferralRebate;

                        UD60x18 takerFeeSansRebate = takerFee - totalReferralRebate;
                        UD60x18 protocolFee = takerFeeSansRebate * PROTOCOL_FEE_PERCENTAGE;
                        UD60x18 makerRebate = takerFeeSansRebate - protocolFee;

                        _updateGlobalFeeRate(l, makerRebate);

                        vars.totalProtocolFees = vars.totalProtocolFees + protocolFee;
                        l.protocolFees = l.protocolFees + protocolFee;
                    }

                    // is_buy: taker has to pay premium + fees
                    // ~is_buy: taker receives premium - fees
                    vars.totalPremium = vars.totalPremium + (args.isBuy ? premium + takerFee : premium - takerFee);
                    vars.totalTakerFees = vars.totalTakerFees + takerFee;
                    l.marketPrice = nextMarketPrice;
                }

                UD60x18 dist = (l.marketPrice.intoSD59x18() - vars.oldMarketPrice.intoSD59x18()).abs().intoUD60x18();

                vars.shortDelta = vars.shortDelta + l.shortRate * (dist / PoolStorage.MIN_TICK_DISTANCE);
                vars.longDelta = vars.longDelta + l.longRate * (dist / PoolStorage.MIN_TICK_DISTANCE);

                if (vars.maxSize >= remaining) {
                    remaining = ZERO;
                } else {
                    // The trade will require crossing into the next tick range
                    if (args.isBuy && l.tickIndex.next(l.currentTick) >= Pricing.MAX_TICK_PRICE)
                        revert Pool__InsufficientAskLiquidity();

                    if (!args.isBuy && l.currentTick <= Pricing.MIN_TICK_PRICE) revert Pool__InsufficientBidLiquidity();

                    remaining = remaining - vars.tradeSize;
                    _cross(args.isBuy);
                }
            }
        }

        totalPremium = l.toPoolTokenDecimals(vars.totalPremium);

        _revertIfTradeAboveMaxSlippage(totalPremium, args.premiumLimit, args.isBuy);

        delta = _calculateAndUpdateUserAssets(
            l,
            args.user,
            vars.totalPremium,
            args.size,
            args.isBuy,
            args.transferCollateralToUser
        );

        _useReferral(l, args.user, args.referrer, vars.referral.primaryRebate, vars.referral.secondaryRebate);

        if (args.isBuy) {
            if (vars.shortDelta > ZERO) _mint(address(this), PoolStorage.SHORT, vars.shortDelta);
            if (vars.longDelta > ZERO) _burn(address(this), PoolStorage.LONG, vars.longDelta);
        } else {
            if (vars.longDelta > ZERO) _mint(address(this), PoolStorage.LONG, vars.longDelta);
            if (vars.shortDelta > ZERO) _burn(address(this), PoolStorage.SHORT, vars.shortDelta);
        }

        emit Trade(
            args.user,
            args.size,
            delta,
            args.isBuy ? vars.totalPremium - vars.totalTakerFees : vars.totalPremium,
            vars.totalTakerFees,
            vars.totalProtocolFees,
            l.marketPrice,
            l.liquidityRate,
            l.currentTick,
            vars.referral.totalRebate,
            args.isBuy
        );
    }

    /// @notice Returns the pricing arguments at the current tick
    function _getPricing(PoolStorage.Layout storage l, bool isBuy) internal view returns (Pricing.Args memory) {
        UD60x18 currentTick = l.currentTick;

        return Pricing.Args(l.liquidityRate, l.marketPrice, currentTick, l.tickIndex.next(currentTick), isBuy);
    }

    /// @notice Compute the change in short / long option contracts of an agent in order to transfer the contracts and
    ///         execute a trade
    function _getTradeDelta(
        address user,
        UD60x18 size,
        bool isBuy
    ) internal view returns (Position.Delta memory delta) {
        UD60x18 longs = _balanceOfUD60x18(user, PoolStorage.LONG);
        UD60x18 shorts = _balanceOfUD60x18(user, PoolStorage.SHORT);

        if (isBuy) {
            delta.shorts = -PRBMathExtra.min(shorts, size).intoSD59x18();
            delta.longs = size.intoSD59x18() + delta.shorts;
        } else {
            delta.longs = -PRBMathExtra.min(longs, size).intoSD59x18();
            delta.shorts = size.intoSD59x18() + delta.longs;
        }
    }

    // @notice Calculate the asset update for `user` and update the user's assets
    function _calculateAndUpdateUserAssets(
        PoolStorage.Layout storage l,
        address user,
        UD60x18 totalPremium,
        UD60x18 size,
        bool isBuy,
        bool transferCollateralToUser
    ) internal returns (Position.Delta memory delta) {
        delta = _calculateAssetsUpdate(l, user, totalPremium, size, isBuy);
        _updateUserAssets(l, user, delta, transferCollateralToUser);
    }

    /// @notice Calculate the asset update for `user`
    function _calculateAssetsUpdate(
        PoolStorage.Layout storage l,
        address user,
        UD60x18 totalPremium,
        UD60x18 size,
        bool isBuy
    ) internal view returns (Position.Delta memory delta) {
        delta = _getTradeDelta(user, size, isBuy);

        bool _isBuy = delta.longs > iZERO || delta.shorts < iZERO;

        UD60x18 shortCollateral = Position.contractsToCollateral(
            delta.shorts.abs().intoUD60x18(),
            l.strike,
            l.isCallPool
        );

        SD59x18 iShortCollateral = shortCollateral.intoSD59x18();
        if (delta.shorts < iZERO) {
            iShortCollateral = -iShortCollateral;
        }

        if (_isBuy) {
            delta.collateral = -PRBMathExtra.min(iShortCollateral, iZERO) - totalPremium.intoSD59x18();
        } else {
            delta.collateral = totalPremium.intoSD59x18() - PRBMathExtra.max(iShortCollateral, iZERO);
        }

        return delta;
    }

    /// @notice Execute a trade by transferring the net change in short and long option contracts and collateral to /
    ///         from an agent.
    function _updateUserAssets(
        PoolStorage.Layout storage l,
        address user,
        Position.Delta memory delta,
        bool transferCollateralToUser
    ) internal {
        if (
            (delta.longs == iZERO && delta.shorts == iZERO) ||
            (delta.longs > iZERO && delta.shorts > iZERO) ||
            (delta.longs < iZERO && delta.shorts < iZERO)
        ) revert Pool__InvalidAssetUpdate(delta.longs, delta.shorts);

        int256 deltaCollateral = l.toPoolTokenDecimals(delta.collateral);

        // Transfer collateral
        if (deltaCollateral < 0) {
            IERC20Router(ROUTER).safeTransferFrom(l.getPoolToken(), user, address(this), uint256(-deltaCollateral));
        } else if (deltaCollateral > 0 && transferCollateralToUser) {
            IERC20(l.getPoolToken()).safeTransfer(user, uint256(deltaCollateral));
        }

        // Transfer long
        if (delta.longs < iZERO) {
            _burn(user, PoolStorage.LONG, (-delta.longs).intoUD60x18());
        } else if (delta.longs > iZERO) {
            _mint(user, PoolStorage.LONG, delta.longs.intoUD60x18());
        }

        // Transfer short
        if (delta.shorts < iZERO) {
            _burn(user, PoolStorage.SHORT, (-delta.shorts).intoUD60x18());
        } else if (delta.shorts > iZERO) {
            _mint(user, PoolStorage.SHORT, delta.shorts.intoUD60x18());
        }
    }

    /// @notice Calculates the RFQ quote premium and fee
    function _calculateQuoteRFQPremiumAndFee(
        PoolStorage.Layout storage l,
        address taker,
        address referrer,
        UD60x18 size,
        UD60x18 price,
        bool isBuy
    ) internal view returns (PremiumAndFeeInternal memory r) {
        r.premium = price * size;
        r.protocolFee = _takerFee(taker, size, r.premium, true, l.strike, l.isCallPool);

        (UD60x18 primaryReferralRebate, UD60x18 secondaryReferralRebate) = IReferral(REFERRAL).getRebateAmounts(
            taker,
            referrer,
            r.protocolFee
        );

        r.referral.totalRebate = primaryReferralRebate + secondaryReferralRebate;
        r.referral.primaryRebate = primaryReferralRebate;
        r.referral.secondaryRebate = secondaryReferralRebate;

        r.protocolFee = r.protocolFee - r.referral.totalRebate;

        // Denormalize premium
        r.premium = Position.contractsToCollateral(r.premium, l.strike, l.isCallPool);

        r.premiumMaker = isBuy
            ? r.premium // Maker buying
            : r.premium - r.protocolFee; // Maker selling

        r.premiumTaker = !isBuy
            ? r.premium // Taker buying
            : r.premium - r.protocolFee; // Taker selling

        return r;
    }

    /// @notice Functionality to support the RFQ / OTC system. An LP can create a RFQ quote for which he will do an OTC
    ///         trade through the exchange. Takers can buy from / sell to the LP then partially or fully while having
    ///         the price guaranteed.
    /// @param args The fillQuoteRFQ parameters
    /// @param quoteRFQ The RFQ quote given by the provider
    /// @return premiumTaker The premium paid by the taker (poolToken decimals)
    /// @return deltaTaker The net collateral / longs / shorts change for taker of the trade.
    function _fillQuoteRFQ(
        FillQuoteRFQArgsInternal memory args,
        QuoteRFQ memory quoteRFQ
    ) internal returns (uint256 premiumTaker, Position.Delta memory deltaTaker) {
        if (args.size > quoteRFQ.size) revert Pool__AboveQuoteSize(args.size, quoteRFQ.size);

        bytes32 quoteRFQHash;
        PremiumAndFeeInternal memory premiumAndFee;
        Position.Delta memory deltaMaker;

        {
            PoolStorage.Layout storage l = PoolStorage.layout();
            quoteRFQHash = _quoteRFQHash(quoteRFQ);
            _revertIfQuoteRFQInvalid(l, args, quoteRFQ, quoteRFQHash);

            premiumAndFee = _calculateQuoteRFQPremiumAndFee(
                l,
                args.user,
                args.referrer,
                args.size,
                quoteRFQ.price,
                quoteRFQ.isBuy
            );

            // Update amount filled for this quote
            l.quoteRFQAmountFilled[quoteRFQ.provider][quoteRFQHash] =
                l.quoteRFQAmountFilled[quoteRFQ.provider][quoteRFQHash] +
                args.size;

            // Update protocol fees
            l.protocolFees = l.protocolFees + premiumAndFee.protocolFee;

            // Process trade taker
            deltaTaker = _calculateAndUpdateUserAssets(
                l,
                args.user,
                premiumAndFee.premiumTaker,
                args.size,
                !quoteRFQ.isBuy,
                args.transferCollateralToUser
            );

            _useReferral(
                l,
                args.user,
                args.referrer,
                premiumAndFee.referral.primaryRebate,
                premiumAndFee.referral.secondaryRebate
            );

            // Process trade maker
            deltaMaker = _calculateAndUpdateUserAssets(
                l,
                quoteRFQ.provider,
                premiumAndFee.premiumMaker,
                args.size,
                quoteRFQ.isBuy,
                true
            );
        }

        emit FillQuoteRFQ(
            quoteRFQHash,
            args.user,
            quoteRFQ.provider,
            args.size,
            deltaMaker,
            deltaTaker,
            premiumAndFee.premium,
            premiumAndFee.protocolFee,
            premiumAndFee.referral.totalRebate,
            !quoteRFQ.isBuy
        );

        return (PoolStorage.layout().toPoolTokenDecimals(premiumAndFee.premiumTaker), deltaTaker);
    }

    /// @notice Annihilate a pair of long + short option contracts to unlock the stored collateral.
    ///         ===========================================================
    ///         NOTE:
    ///         This function can be called post or prior to expiration.
    ///         ===========================================================
    function _annihilate(address owner, UD60x18 size) internal {
        if (
            msg.sender != owner &&
            !IUserSettings(SETTINGS).isActionAuthorized(owner, msg.sender, IUserSettings.Action.Annihilate)
        ) revert Pool__ActionNotAuthorized(owner, msg.sender, IUserSettings.Action.Annihilate);

        _revertIfZeroSize(size);

        PoolStorage.Layout storage l = PoolStorage.layout();

        _burn(owner, PoolStorage.SHORT, size);
        _burn(owner, PoolStorage.LONG, size);
        IERC20(l.getPoolToken()).safeTransfer(owner, Position.contractsToCollateral(size, l.strike, l.isCallPool));

        emit Annihilate(owner, size, 0);
    }

    /// @notice Transfer an LP position to another owner.
    ///         ===========================================================
    ///         NOTE:
    ///         This function can be called post or prior to expiration.
    ///         ===========================================================
    /// @param srcP The position key
    /// @param newOwner The new owner of the transferred liquidity
    /// @param newOperator The new operator of the transferred liquidity
    function _transferPosition(
        Position.KeyInternal memory srcP,
        address newOwner,
        address newOperator,
        UD60x18 size
    ) internal {
        if (srcP.owner == newOwner && srcP.operator == newOperator) revert Pool__InvalidTransfer();

        _revertIfZeroSize(size);
        _revertIfInvalidSize(srcP.lower, srcP.upper, size);

        PoolStorage.Layout storage l = PoolStorage.layout();

        Position.KeyInternal memory dstP = Position.KeyInternal({
            owner: newOwner,
            operator: newOperator,
            lower: srcP.lower,
            upper: srcP.upper,
            orderType: srcP.orderType,
            strike: srcP.strike,
            isCall: srcP.isCall
        });

        bytes32 srcKey = srcP.keyHash();

        uint256 srcTokenId = PoolStorage.formatTokenId(srcP.operator, srcP.lower, srcP.upper, srcP.orderType);

        uint256 dstTokenId = srcP.operator == newOperator
            ? srcTokenId
            : PoolStorage.formatTokenId(newOperator, srcP.lower, srcP.upper, srcP.orderType);

        UD60x18 balance = _balanceOfUD60x18(srcP.owner, srcTokenId);
        if (size > balance) revert Pool__NotEnoughTokens(balance, size);

        UD60x18 proportionTransferred = size.div(balance);

        Position.Data storage dstData = l.positions[dstP.keyHash()];
        Position.Data storage srcData = l.positions[srcKey];

        // Call function to update claimable fees, but do not claim them
        _updateClaimableFees(l, srcP, srcData);

        if (_balanceOf(newOwner, dstTokenId) > 0) {
            // Update claimable fees to reset the fee range rate
            _updateClaimableFees(l, dstP, dstData);
        } else {
            dstData.lastFeeRate = srcData.lastFeeRate;
        }

        {
            UD60x18 feesTransferred = proportionTransferred * srcData.claimableFees;
            dstData.claimableFees = dstData.claimableFees + feesTransferred;
            srcData.claimableFees = srcData.claimableFees - feesTransferred;
        }

        if (srcData.lastDeposit > dstData.lastDeposit) {
            dstData.lastDeposit = srcData.lastDeposit;
        }

        if (srcTokenId == dstTokenId) {
            _safeTransfer(address(this), srcP.owner, newOwner, srcTokenId, size.unwrap(), "");
        } else {
            _burn(srcP.owner, srcTokenId, size);
            _mint(newOwner, dstTokenId, size);
        }

        if (size == balance) delete l.positions[srcKey];

        emit TransferPosition(srcP.owner, newOwner, srcTokenId, dstTokenId);
    }

    /// @notice Calculates the exercise value of a position
    function _calculateExerciseValue(PoolStorage.Layout storage l, UD60x18 size) internal returns (UD60x18) {
        if (size == ZERO) return ZERO;

        UD60x18 settlementPrice = l.getSettlementPrice();
        UD60x18 strike = l.strike;
        bool isCall = l.isCallPool;

        UD60x18 intrinsicValue;
        if (isCall && settlementPrice > strike) {
            intrinsicValue = settlementPrice - strike;
        } else if (!isCall && settlementPrice < strike) {
            intrinsicValue = strike - settlementPrice;
        } else {
            return ZERO;
        }

        UD60x18 exerciseValue = size * intrinsicValue;

        if (isCall) {
            exerciseValue = exerciseValue / settlementPrice;
        }

        return exerciseValue;
    }

    /// @notice Calculates the collateral value of a position
    function _calculateCollateralValue(
        PoolStorage.Layout storage l,
        UD60x18 size,
        UD60x18 exerciseValue
    ) internal view returns (UD60x18) {
        return l.isCallPool ? size - exerciseValue : size * l.strike - exerciseValue;
    }

    /// @notice Handle operations that need to be done before exercising or settling
    function _beforeExerciseOrSettle(
        PoolStorage.Layout storage l,
        bool isLong,
        address holder
    ) internal returns (UD60x18 size, UD60x18 exerciseValue, UD60x18 collateral) {
        _revertIfOptionNotExpired(l);
        _removeInitFeeDiscount(l);
        if (l.protocolFees > ZERO) _claimProtocolFees();

        uint256 tokenId = isLong ? PoolStorage.LONG : PoolStorage.SHORT;
        size = _balanceOfUD60x18(holder, tokenId);
        exerciseValue = _calculateExerciseValue(l, size);

        if (size > ZERO) {
            collateral = _calculateCollateralValue(l, size, exerciseValue);
            _burn(holder, tokenId, size);
        }
    }

    /// @notice Exercises all long options held by an `owner`
    /// @param holder The holder of the contracts
    /// @param costPerHolder The cost charged by the authorized operator, per option holder (18 decimals)
    /// @return exerciseValue The amount of collateral resulting from the exercise, ignoring costs applied during
    ///         automatic exercise (poolToken decimals)
    /// @return success Whether the exercise was successful or not. This will be false if size to exercise size was zero
    function _exercise(address holder, UD60x18 costPerHolder) internal returns (uint256 exerciseValue, bool success) {
        PoolStorage.Layout storage l = PoolStorage.layout();

        (UD60x18 size, UD60x18 _exerciseValue, ) = _beforeExerciseOrSettle(l, true, holder);

        _revertIfCostExceedsPayout(costPerHolder, _exerciseValue);

        if (size == ZERO) return (0, false);

        exerciseValue = l.toPoolTokenDecimals(_exerciseValue);

        emit Exercise(msg.sender, holder, size, _exerciseValue, l.settlementPrice, ZERO, costPerHolder);

        if (costPerHolder > ZERO) {
            _exerciseValue = _exerciseValue - costPerHolder;
        }

        if (_exerciseValue > ZERO) {
            IERC20(l.getPoolToken()).safeTransfer(holder, _exerciseValue);
        }

        success = true;
    }

    /// @notice Settles all short options held by an `owner`
    /// @param holder The holder of the contracts
    /// @param costPerHolder The cost charged by the authorized operator, per option holder (18 decimals)
    /// @return collateral The amount of collateral resulting from the settlement, ignoring costs applied during
    ///         automatic settlement (poolToken decimals)
    /// @return success Whether the settlement was successful or not. This will be false if size to settle was zero
    function _settle(address holder, UD60x18 costPerHolder) internal returns (uint256 collateral, bool success) {
        PoolStorage.Layout storage l = PoolStorage.layout();

        (UD60x18 size, UD60x18 exerciseValue, UD60x18 _collateral) = _beforeExerciseOrSettle(l, false, holder);

        _revertIfCostExceedsPayout(costPerHolder, _collateral);

        if (size == ZERO) return (0, false);

        collateral = l.toPoolTokenDecimals(_collateral);

        emit Settle(msg.sender, holder, size, exerciseValue, l.settlementPrice, ZERO, costPerHolder);

        if (costPerHolder > ZERO) {
            _collateral = _collateral - costPerHolder;
        }

        if (_collateral > ZERO) {
            IERC20(l.getPoolToken()).safeTransfer(holder, _collateral);
        }

        success = true;
    }

    /// @notice Reconciles a user's `position` to account for settlement payouts post-expiration.
    /// @param p The position key
    /// @param costPerHolder The cost charged by the authorized operator, per position holder (18 decimals)
    /// @return collateral The amount of collateral resulting from the settlement, ignoring costs applied during
    ///         automatic settlement (poolToken decimals)
    /// @return success Whether the settlement was successful or not. This will be false if size to settle was zero
    function _settlePosition(
        Position.KeyInternal memory p,
        UD60x18 costPerHolder
    ) internal returns (uint256 collateral, bool success) {
        PoolStorage.Layout storage l = PoolStorage.layout();
        _revertIfOptionNotExpired(l);
        _removeInitFeeDiscount(l);

        if (l.protocolFees > ZERO) _claimProtocolFees();

        Position.Data storage pData = l.positions[p.keyHash()];

        SettlePositionVarsInternal memory vars;

        vars.tokenId = PoolStorage.formatTokenId(p.operator, p.lower, p.upper, p.orderType);

        vars.size = _balanceOfUD60x18(p.owner, vars.tokenId);
        if (vars.size == ZERO) {
            // Revert if costPerHolder > 0
            _revertIfCostExceedsPayout(costPerHolder, ZERO);
            return (0, false);
        }

        {
            // Update claimable fees
            SD59x18 feeRate = _rangeFeeRate(
                l,
                p.lower,
                p.upper,
                _getTick(p.lower).externalFeeRate,
                _getTick(p.upper).externalFeeRate
            );

            _updateClaimableFees(pData, feeRate, p.liquidityPerTick(vars.size));
        }

        // using the market price here is okay as the market price cannot be
        // changed through trades / deposits / withdrawals post-maturity.
        // changes to the market price are halted. thus, the market price
        // determines the amount of ask.
        // obviously, if the market was still liquid, the market price at
        // maturity should be close to the intrinsic value.

        {
            UD60x18 longs = p.long(vars.size, l.marketPrice);
            UD60x18 shorts = p.short(vars.size, l.marketPrice);

            vars.claimableFees = pData.claimableFees;
            vars.payoff = _calculateExerciseValue(l, ONE);

            vars.collateral = p.collateral(vars.size, l.marketPrice);
            vars.collateral = vars.collateral + longs * vars.payoff;

            vars.collateral = vars.collateral + shorts * ((l.isCallPool ? ONE : l.strike) - vars.payoff);

            vars.collateral = vars.collateral + vars.claimableFees;

            _burn(p.owner, vars.tokenId, vars.size);

            if (longs > ZERO) {
                _burn(address(this), PoolStorage.LONG, longs);
            }

            if (shorts > ZERO) {
                _burn(address(this), PoolStorage.SHORT, shorts);
            }
        }

        pData.claimableFees = ZERO;
        pData.lastFeeRate = iZERO;

        _revertIfCostExceedsPayout(costPerHolder, vars.collateral);

        collateral = l.toPoolTokenDecimals(vars.collateral);

        emit SettlePosition(
            msg.sender,
            p.owner,
            vars.tokenId,
            vars.size,
            vars.collateral - vars.claimableFees,
            vars.payoff,
            vars.claimableFees,
            l.settlementPrice,
            ZERO,
            costPerHolder
        );

        if (costPerHolder > ZERO) {
            vars.collateral = vars.collateral - costPerHolder;
        }

        if (vars.collateral > ZERO) {
            IERC20(l.getPoolToken()).safeTransfer(p.operator, vars.collateral);
        }

        success = true;
    }

    ////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////

    ////////////////
    // TickSystem //
    ////////////////
    /// @notice Returns the nearest tick below `lower` and the nearest tick below `upper`
    function _getNearestTicksBelow(
        UD60x18 lower,
        UD60x18 upper
    ) internal view returns (UD60x18 nearestBelowLower, UD60x18 nearestBelowUpper) {
        _revertIfRangeInvalid(lower, upper);
        Position.revertIfLowerGreaterOrEqualUpper(lower, upper);

        nearestBelowLower = _getNearestTickBelow(lower);
        nearestBelowUpper = _getNearestTickBelow(upper);

        // If no tick between `lower` and `upper`, then the nearest tick below `upper`, will be `lower`
        if (nearestBelowUpper == nearestBelowLower) {
            nearestBelowUpper = lower;
        }
    }

    /// @notice Gets the nearest tick that is less than or equal to `price`
    function _getNearestTickBelow(UD60x18 price) internal view returns (UD60x18) {
        PoolStorage.Layout storage l = PoolStorage.layout();

        UD60x18 left = l.currentTick;

        while (left != ZERO && left > price) {
            left = l.tickIndex.prev(left);
        }

        UD60x18 next = l.tickIndex.next(left);
        while (left != ZERO && next <= price && left != Pricing.MAX_TICK_PRICE) {
            left = next;
            next = l.tickIndex.next(left);
        }

        if (left == ZERO) revert Pool__TickNotFound(price);

        return left;
    }

    /// @notice Get a tick, reverts if tick is not found
    function _getTick(UD60x18 price) internal view returns (Tick memory) {
        (Tick memory tick, bool tickFound) = _tryGetTick(price);
        if (!tickFound) revert Pool__TickNotFound(price);

        return tick;
    }

    /// @notice Try to get tick, does not revert if tick is not found
    function _tryGetTick(UD60x18 price) internal view returns (Tick memory tick, bool tickFound) {
        _revertIfTickWidthInvalid(price);

        if (price < Pricing.MIN_TICK_PRICE || price > Pricing.MAX_TICK_PRICE) revert Pool__TickOutOfRange(price);

        PoolStorage.Layout storage l = PoolStorage.layout();

        if (l.tickIndex.contains(price)) return (l.ticks[price], true);

        return (Tick({delta: iZERO, externalFeeRate: ZERO, longDelta: iZERO, shortDelta: iZERO, counter: 0}), false);
    }

    /// @notice Creates a Tick for a given price, or returns the existing tick.
    /// @param price The price of the Tick (18 decimals)
    /// @param priceBelow The price of the nearest Tick below (18 decimals)
    /// @return tick The Tick for a given price
    function _getOrCreateTick(UD60x18 price, UD60x18 priceBelow) internal returns (Tick memory) {
        PoolStorage.Layout storage l = PoolStorage.layout();

        (Tick memory tick, bool tickFound) = _tryGetTick(price);

        if (tickFound) return tick;

        if (!l.tickIndex.contains(priceBelow) || l.tickIndex.next(priceBelow) <= price)
            revert Pool__InvalidBelowPrice(price, priceBelow);

        tick = Tick({
            delta: iZERO,
            externalFeeRate: price <= l.currentTick ? l.globalFeeRate : ZERO,
            longDelta: iZERO,
            shortDelta: iZERO,
            counter: 0
        });

        l.tickIndex.insertAfter(priceBelow, price);
        l.ticks[price] = tick;

        return tick;
    }

    /// @notice Removes a tick if it does not mark the beginning or the end of a range order.
    function _removeTickIfNotActive(UD60x18 price) internal {
        PoolStorage.Layout storage l = PoolStorage.layout();

        if (!l.tickIndex.contains(price)) return;

        Tick storage tick = l.ticks[price];

        if (
            price > Pricing.MIN_TICK_PRICE &&
            price < Pricing.MAX_TICK_PRICE &&
            // Can only remove an active tick if no active range order marks a starting / ending tick on this tick.
            tick.counter == 0
        ) {
            if (tick.delta != iZERO) revert Pool__TickDeltaNotZero(tick.delta);

            if (price == l.currentTick) {
                UD60x18 newCurrentTick = l.tickIndex.prev(price);

                if (newCurrentTick < Pricing.MIN_TICK_PRICE) revert Pool__TickOutOfRange(newCurrentTick);

                l.currentTick = newCurrentTick;
            }

            l.tickIndex.remove(price);
            delete l.ticks[price];
        }
    }

    /// @notice Updates the tick deltas following a deposit or withdrawal
    function _updateTicks(
        UD60x18 lower,
        UD60x18 upper,
        UD60x18 marketPrice,
        SD59x18 delta,
        bool isNewDeposit,
        bool isFullWithdrawal,
        Position.OrderType orderType
    ) internal {
        PoolStorage.Layout storage l = PoolStorage.layout();

        Tick storage lowerTick = l.ticks[lower];
        Tick storage upperTick = l.ticks[upper];

        if (isNewDeposit) {
            lowerTick.counter += 1;
            upperTick.counter += 1;
        }

        if (isFullWithdrawal) {
            lowerTick.counter -= 1;
            upperTick.counter -= 1;
        }

        // ===========================================================
        // Update the deltas, i.e. the net change in per tick liquidity, of the
        // referenced lower and upper tick, dependent on the current tick.
        //
        // Three cases need to be covered.
        //
        // Case 1: current tick is above the upper tick. Upper has not been
        // crossed, thus, upon a crossing, liquidity has to be injected at the
        // upper tick and withdrawn at the lower. The bar below the range shows the
        // possible current ticks that cover case 1.
        //
        //     0   lower                upper       1
        //     |    [---------------------]         |
        //                                [---------]
        //                                  current
        //
        // Case 2: current tick is below is lower. Lower has not benn crossed yet,
        // thus, upon a crossing, liquidity has to be injected at the lower tick
        // and withdrawn at the upper.
        //
        //     0        lower                 upper 1
        //     |          [---------------------]   |
        //     [---------)
        //           current
        //
        // Case 3: current tick is greater or equal to lower and below upper. Thus,
        // liquidity has already entered. Therefore, if the price crosses the
        // lower, it needs to be withdrawn. Furthermore, if it crosses the above
        // tick it also needs to be withdrawn. Note that since the current tick lies
        // within the lower and upper range the liquidity has to be adjusted by the
        // delta.
        //
        //     0        lower                 upper 1
        //     |          [---------------------]   |
        //                [---------------------)
        //                         current
        // ===========================================================

        if (upper <= l.currentTick) {
            lowerTick.delta = lowerTick.delta - delta;
            upperTick.delta = upperTick.delta + delta;

            if (orderType.isLong()) {
                lowerTick.longDelta = lowerTick.longDelta - delta;
                upperTick.longDelta = upperTick.longDelta + delta;
            } else {
                lowerTick.shortDelta = lowerTick.shortDelta - delta;
                upperTick.shortDelta = upperTick.shortDelta + delta;
            }
        } else if (lower > l.currentTick) {
            lowerTick.delta = lowerTick.delta + delta;
            upperTick.delta = upperTick.delta - delta;

            if (orderType.isLong()) {
                lowerTick.longDelta = lowerTick.longDelta + delta;
                upperTick.longDelta = upperTick.longDelta - delta;
            } else {
                lowerTick.shortDelta = lowerTick.shortDelta + delta;
                upperTick.shortDelta = upperTick.shortDelta - delta;
            }
        } else {
            lowerTick.delta = lowerTick.delta - delta;
            upperTick.delta = upperTick.delta - delta;
            l.liquidityRate = l.liquidityRate.add(delta);

            if (orderType.isLong()) {
                lowerTick.longDelta = lowerTick.longDelta - delta;
                upperTick.longDelta = upperTick.longDelta - delta;
                l.longRate = l.longRate.add(delta);
            } else {
                lowerTick.shortDelta = lowerTick.shortDelta - delta;
                upperTick.shortDelta = upperTick.shortDelta - delta;
                l.shortRate = l.shortRate.add(delta);
            }
        }

        // ===========================================================
        // After deposit / full withdrawal the current tick needs be reconciled. We
        // need cover two cases.
        //
        // Case 1. Deposit. Depositing liquidity in case the market price is
        // stranded shifts the market price to the upper tick in case of a bid-side
        // order or to the lower tick in case of an ask-side order.
        //
        // Ask-side order:
        //      current
        //     0   v                               1
        //     |   [-bid-]               [-ask-]   |
        //               ^
        //           market price
        //                 new current
        //                    v
        //                    [-new-ask-]
        //                    ^
        //             new market price
        //
        // Bid-side order:
        //      current
        //     0   v                               1
        //     |   [-bid-]               [-ask-]   |
        //               ^
        //           market price
        //                 new current
        //                    v
        //                    [new-bid]
        //                            ^
        //                     new market price
        //
        // Case 2. Full withdrawal of [R2] where the lower tick of [R2] is the
        // current tick causes the lower and upper tick of [R2] to be removed and
        // thus shifts the current tick to the lower of [R1]. Note that the market
        // price does not change. However, around the market price zero liquidity
        // is provided. Therefore, a buy / sell trade will result in the market
        // price snapping to the upper tick of [R1] or the lower tick of [R3] and a
        // crossing of the relevant tick.
        //
        //               current
        //     0            v                      1
        //     |   [R1]     [R2]    [R3]           |
        //                   ^
        //              market price
        //     new current
        //         v
        //     |   [R1]             [R3]           |
        //                   ^
        //              market price
        // ===========================================================

        if (delta > iZERO) {
            uint256 crossings;

            while (l.tickIndex.next(l.currentTick) < marketPrice) {
                _cross(true);
                crossings++;
            }

            while (l.currentTick > marketPrice) {
                _cross(false);
                crossings++;
            }

            if (crossings > 2) revert Pool__InvalidReconciliation(crossings);
        }

        emit UpdateTick(
            lower,
            l.tickIndex.prev(lower),
            l.tickIndex.next(lower),
            lowerTick.delta,
            lowerTick.externalFeeRate,
            lowerTick.longDelta,
            lowerTick.shortDelta,
            lowerTick.counter
        );

        emit UpdateTick(
            upper,
            l.tickIndex.prev(upper),
            l.tickIndex.next(upper),
            upperTick.delta,
            upperTick.externalFeeRate,
            upperTick.longDelta,
            upperTick.shortDelta,
            upperTick.counter
        );

        if (delta <= iZERO) {
            _removeTickIfNotActive(lower);
            _removeTickIfNotActive(upper);
        }
    }

    /// @notice Updates the global fee rate
    function _updateGlobalFeeRate(PoolStorage.Layout storage l, UD60x18 makerRebate) internal {
        if (l.liquidityRate == ZERO) return;
        l.globalFeeRate = l.globalFeeRate + (makerRebate / l.liquidityRate);
    }

    /// @notice Crosses the active tick either to the left if the LT is selling
    ///         to the pool. A cross is only executed if no bid or ask liquidity is
    ///         remaining within the active tick range.
    /// @param isBuy Whether the trade is a buy or a sell.
    function _cross(bool isBuy) internal {
        PoolStorage.Layout storage l = PoolStorage.layout();

        if (isBuy) {
            UD60x18 right = l.tickIndex.next(l.currentTick);
            if (right >= Pricing.MAX_TICK_PRICE) revert Pool__TickOutOfRange(right);
            l.currentTick = right;
        }

        Tick storage currentTick = l.ticks[l.currentTick];

        l.liquidityRate = l.liquidityRate.add(currentTick.delta);
        l.longRate = l.longRate.add(currentTick.longDelta);
        l.shortRate = l.shortRate.add(currentTick.shortDelta);

        // Flip the tick
        currentTick.delta = -currentTick.delta;
        currentTick.longDelta = -currentTick.longDelta;
        currentTick.shortDelta = -currentTick.shortDelta;

        currentTick.externalFeeRate = l.globalFeeRate - currentTick.externalFeeRate;

        emit UpdateTick(
            l.currentTick,
            l.tickIndex.prev(l.currentTick),
            l.tickIndex.next(l.currentTick),
            currentTick.delta,
            currentTick.externalFeeRate,
            currentTick.longDelta,
            currentTick.shortDelta,
            currentTick.counter
        );

        if (!isBuy) {
            if (l.currentTick <= Pricing.MIN_TICK_PRICE) revert Pool__TickOutOfRange(l.currentTick);
            l.currentTick = l.tickIndex.prev(l.currentTick);
        }
    }

    /// @notice Removes the initialization fee discount for the pool
    function _removeInitFeeDiscount(PoolStorage.Layout storage l) internal {
        if (l.initFeeDiscountRemoved) return;

        l.initFeeDiscountRemoved = true;

        IPoolFactory(FACTORY).removeDiscount(
            IPoolFactory.PoolKey(l.base, l.quote, l.oracleAdapter, l.strike, l.maturity, l.isCallPool)
        );
    }

    /// @notice Calculates the growth and exposure change between the lower and upper Ticks of a Position.
    /// ===========================================================
    ///                     l         ▼         u
    ///    ----|----|-------|xxxxxxxxxxxxxxxxxxx|--------|---------
    ///    => (global - external(l) - external(u))
    ///
    ///                ▼    l                   u
    ///    ----|----|-------|xxxxxxxxxxxxxxxxxxx|--------|---------
    ///    => (global - (global - external(l)) - external(u))
    ///
    ///                     l                   u    ▼
    ///    ----|----|-------|xxxxxxxxxxxxxxxxxxx|--------|---------
    ///    => (global - external(l) - (global - external(u)))
    /// ===========================================================
    function _rangeFeeRate(
        PoolStorage.Layout storage l,
        UD60x18 lower,
        UD60x18 upper,
        UD60x18 lowerTickExternalFeeRate,
        UD60x18 upperTickExternalFeeRate
    ) internal view returns (SD59x18) {
        UD60x18 aboveFeeRate = l.currentTick >= upper
            ? l.globalFeeRate - upperTickExternalFeeRate
            : upperTickExternalFeeRate;

        UD60x18 belowFeeRate = l.currentTick >= lower
            ? lowerTickExternalFeeRate
            : l.globalFeeRate - lowerTickExternalFeeRate;

        return l.globalFeeRate.intoSD59x18() - aboveFeeRate.intoSD59x18() - belowFeeRate.intoSD59x18();
    }

    /// @notice Gets the lower and upper bound of the stranded market area when it exists. In case the stranded market
    ///         area does not exist it will return the stranded market area the maximum tick price for both the lower
    ///         and the upper, in which case the market price is not stranded given any range order info order.
    /// @return lower Lower bound of the stranded market price area (Default : 1e18) (18 decimals)
    /// @return upper Upper bound of the stranded market price area (Default : 1e18) (18 decimals)
    function _getStrandedArea(PoolStorage.Layout storage l) internal view returns (UD60x18 lower, UD60x18 upper) {
        lower = Pricing.MAX_TICK_PRICE + ONE;
        upper = Pricing.MAX_TICK_PRICE + ONE;

        UD60x18 current = l.currentTick;
        UD60x18 right = l.tickIndex.next(current);

        if (l.liquidityRate == ZERO) {
            // applies whenever the pool is empty or the last active order that
            // was traversed by the price was withdrawn
            // the check is independent of the current market price
            lower = current;
            upper = right;
        } else if (
            -l.ticks[right].delta > iZERO &&
            l.liquidityRate == (-l.ticks[right].delta).intoUD60x18() &&
            right == l.marketPrice &&
            l.tickIndex.next(right) != ZERO
        ) {
            // ===========================================================
            // bid-bound market price check
            // liquidity_rate > 0
            //        market price
            //             v
            // |------[----]------|
            //        ^
            //     current
            // ===========================================================

            lower = right;
            upper = l.tickIndex.next(right);
        } else if (
            -l.ticks[current].delta > iZERO &&
            l.liquidityRate == (-l.ticks[current].delta).intoUD60x18() &&
            current == l.marketPrice &&
            l.tickIndex.prev(current) != ZERO
        ) {
            // ===========================================================
            //  ask-bound market price check
            //  liquidity_rate > 0
            //  market price
            //        v
            // |------[----]------|
            //        ^
            //     current
            // ===========================================================

            lower = l.tickIndex.prev(current);
            upper = current;
        }
    }

    /// @notice Returns true if the market price is stranded
    function _isMarketPriceStranded(
        PoolStorage.Layout storage l,
        Position.KeyInternal memory p,
        bool isBid
    ) internal view returns (bool) {
        (UD60x18 lower, UD60x18 upper) = _getStrandedArea(l);
        UD60x18 tick = isBid ? p.upper : p.lower;
        return lower <= tick && tick <= upper;
    }

    /// @notice In case the market price is stranded the market price needs to be set to the upper (lower) tick of the
    ///         bid (ask) order.
    function _getStrandedMarketPriceUpdate(Position.KeyInternal memory p, bool isBid) internal pure returns (UD60x18) {
        return isBid ? p.upper : p.lower;
    }

    /// @notice Revert if the tick width is invalid
    function _revertIfTickWidthInvalid(UD60x18 price) internal pure {
        if (price % Pricing.MIN_TICK_DISTANCE != ZERO) revert Pool__TickWidthInvalid(price);
    }

    /// @notice Returns the encoded RFQ quote hash
    function _quoteRFQHash(IPoolInternal.QuoteRFQ memory quoteRFQ) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                FILL_QUOTE_RFQ_TYPE_HASH,
                quoteRFQ.provider,
                quoteRFQ.taker,
                quoteRFQ.price,
                quoteRFQ.size,
                quoteRFQ.isBuy,
                quoteRFQ.deadline,
                quoteRFQ.salt
            )
        );

        return
            keccak256(
                abi.encodePacked(
                    "\x19\x01",
                    EIP712.calculateDomainSeparator(keccak256("Premia"), keccak256("1")),
                    structHash
                )
            );
    }

    /// @notice Returns the balance of `user` for `tokenId` as UD60x18
    function _balanceOfUD60x18(address user, uint256 tokenId) internal view returns (UD60x18) {
        return ud(_balanceOf(user, tokenId));
    }

    /// @notice Mints `amount` of `id` and assigns it to `account`
    function _mint(address account, uint256 id, UD60x18 amount) internal {
        _mint(account, id, amount.unwrap(), "");
    }

    /// @notice Burns `amount` of `id` assigned to `account`
    function _burn(address account, uint256 id, UD60x18 amount) internal {
        _burn(account, id, amount.unwrap());
    }

    /// @notice Applies the primary and secondary referral rebates, if total rebates are greater than zero
    function _useReferral(
        PoolStorage.Layout storage l,
        address user,
        address referrer,
        UD60x18 primaryReferralRebate,
        UD60x18 secondaryReferralRebate
    ) internal {
        UD60x18 totalReferralRebate = primaryReferralRebate + secondaryReferralRebate;
        if (totalReferralRebate == ZERO) return;

        address token = l.getPoolToken();
        IERC20(token).approve(REFERRAL, totalReferralRebate);
        IReferral(REFERRAL).useReferral(user, referrer, token, primaryReferralRebate, secondaryReferralRebate);
        IERC20(token).approve(REFERRAL, 0);
    }

    /// @notice Checks if the liquidity rate of the range results in a non-terminating decimal.
    function _isRateNonTerminating(UD60x18 lower, UD60x18 upper) internal pure returns (bool) {
        UD60x18 den = (upper - lower) / Pricing.MIN_TICK_DISTANCE;

        while (den % TWO == ZERO) {
            den = den / TWO;
        }

        while (den % FIVE == ZERO) {
            den = den / FIVE;
        }

        return den != ONE;
    }

    /// @notice Revert if the `lower` and `upper` tick range is invalid
    function _revertIfRangeInvalid(UD60x18 lower, UD60x18 upper) internal pure {
        if (
            lower == ZERO ||
            upper == ZERO ||
            lower >= upper ||
            lower < Pricing.MIN_TICK_PRICE ||
            upper > Pricing.MAX_TICK_PRICE ||
            _isRateNonTerminating(lower, upper)
        ) revert Pool__InvalidRange(lower, upper);
    }

    /// @notice Revert if `size` is zero
    function _revertIfZeroSize(UD60x18 size) internal pure {
        if (size == ZERO) revert Pool__ZeroSize();
    }

    /// @notice Revert if option is not expired
    function _revertIfOptionNotExpired(PoolStorage.Layout storage l) internal view {
        if (block.timestamp < l.maturity) revert Pool__OptionNotExpired();
    }

    /// @notice Revert if option is expired
    function _revertIfOptionExpired(PoolStorage.Layout storage l) internal view {
        if (block.timestamp >= l.maturity) revert Pool__OptionExpired();
    }

    /// @notice Revert if withdrawal delay has not elapsed
    function _revertIfWithdrawalDelayNotElapsed(Position.Data storage position) internal view {
        uint256 unlockTime = position.lastDeposit + WITHDRAWAL_DELAY;
        if (block.timestamp < unlockTime) revert Pool__WithdrawalDelayNotElapsed(unlockTime);
    }

    /// @notice Revert if `totalPremium` is exceeds max slippage
    function _revertIfTradeAboveMaxSlippage(uint256 totalPremium, uint256 premiumLimit, bool isBuy) internal pure {
        if (isBuy && totalPremium > premiumLimit) revert Pool__AboveMaxSlippage(totalPremium, 0, premiumLimit);
        if (!isBuy && totalPremium < premiumLimit)
            revert Pool__AboveMaxSlippage(totalPremium, premiumLimit, type(uint256).max);
    }

    function _revertIfInvalidSize(UD60x18 lower, UD60x18 upper, UD60x18 size) internal pure {
        UD60x18 numTicks = (upper - lower) / Pricing.MIN_TICK_PRICE;
        if ((size / numTicks) * numTicks != size) revert Pool__InvalidSize(lower, upper, size);
    }

    /// @notice Revert if `marketPrice` is below `minMarketPrice` or above `maxMarketPrice`
    function _revertIfDepositWithdrawalAboveMaxSlippage(
        UD60x18 marketPrice,
        UD60x18 minMarketPrice,
        UD60x18 maxMarketPrice
    ) internal pure {
        if (marketPrice > maxMarketPrice || marketPrice < minMarketPrice)
            revert Pool__AboveMaxSlippage(marketPrice.unwrap(), minMarketPrice.unwrap(), maxMarketPrice.unwrap());
    }

    /// @notice Returns true if RFQ quote and RFQ quote balance are valid
    function _areQuoteRFQAndBalanceValid(
        PoolStorage.Layout storage l,
        FillQuoteRFQArgsInternal memory args,
        QuoteRFQ memory quoteRFQ,
        bytes32 quoteRFQHash
    ) internal view returns (bool isValid, InvalidQuoteRFQError error) {
        (isValid, error) = _isQuoteRFQValid(l, args, quoteRFQ, quoteRFQHash, false);
        if (!isValid) {
            return (isValid, error);
        }
        return _isQuoteRFQBalanceValid(l, args, quoteRFQ);
    }

    /// @notice Revert if RFQ quote is invalid
    function _revertIfQuoteRFQInvalid(
        PoolStorage.Layout storage l,
        FillQuoteRFQArgsInternal memory args,
        QuoteRFQ memory quoteRFQ,
        bytes32 quoteRFQHash
    ) internal view {
        _isQuoteRFQValid(l, args, quoteRFQ, quoteRFQHash, true);
    }

    /// @notice Returns true if RFQ quote is valid
    function _isQuoteRFQValid(
        PoolStorage.Layout storage l,
        FillQuoteRFQArgsInternal memory args,
        QuoteRFQ memory quoteRFQ,
        bytes32 quoteRFQHash,
        bool revertIfInvalid
    ) internal view returns (bool, InvalidQuoteRFQError) {
        if (block.timestamp > quoteRFQ.deadline) {
            if (revertIfInvalid) revert Pool__QuoteRFQExpired();
            return (false, InvalidQuoteRFQError.QuoteRFQExpired);
        }

        UD60x18 filledAmount = l.quoteRFQAmountFilled[quoteRFQ.provider][quoteRFQHash];

        if (filledAmount.unwrap() == type(uint256).max) {
            if (revertIfInvalid) revert Pool__QuoteRFQCancelled();
            return (false, InvalidQuoteRFQError.QuoteRFQCancelled);
        }

        if (filledAmount + args.size > quoteRFQ.size) {
            if (revertIfInvalid) revert Pool__QuoteRFQOverfilled(filledAmount, args.size, quoteRFQ.size);
            return (false, InvalidQuoteRFQError.QuoteRFQOverfilled);
        }

        if (Pricing.MIN_TICK_PRICE > quoteRFQ.price || quoteRFQ.price > Pricing.MAX_TICK_PRICE) {
            if (revertIfInvalid) revert Pool__OutOfBoundsPrice(quoteRFQ.price);
            return (false, InvalidQuoteRFQError.OutOfBoundsPrice);
        }

        if (quoteRFQ.taker != address(0) && args.user != quoteRFQ.taker) {
            if (revertIfInvalid) revert Pool__InvalidQuoteRFQTaker();
            return (false, InvalidQuoteRFQError.InvalidQuoteRFQTaker);
        }

        address signer = ECDSA.recover(quoteRFQHash, args.signature.v, args.signature.r, args.signature.s);
        if (signer != quoteRFQ.provider) {
            if (revertIfInvalid) revert Pool__InvalidQuoteRFQSignature();
            return (false, InvalidQuoteRFQError.InvalidQuoteRFQSignature);
        }

        return (true, InvalidQuoteRFQError.None);
    }

    /// @notice Returns true if RFQ quote balance is valid
    function _isQuoteRFQBalanceValid(
        PoolStorage.Layout storage l,
        FillQuoteRFQArgsInternal memory args,
        QuoteRFQ memory quoteRFQ
    ) internal view returns (bool, InvalidQuoteRFQError) {
        PremiumAndFeeInternal memory premiumAndFee = _calculateQuoteRFQPremiumAndFee(
            l,
            args.user,
            address(0),
            args.size,
            quoteRFQ.price,
            quoteRFQ.isBuy
        );

        Position.Delta memory delta = _calculateAssetsUpdate(
            l,
            args.user,
            premiumAndFee.premium,
            args.size,
            quoteRFQ.isBuy
        );

        if (
            (delta.longs == iZERO && delta.shorts == iZERO) ||
            (delta.longs > iZERO && delta.shorts > iZERO) ||
            (delta.longs < iZERO && delta.shorts < iZERO)
        ) return (false, InvalidQuoteRFQError.InvalidAssetUpdate);

        if (delta.collateral < iZERO) {
            IERC20 token = IERC20(l.getPoolToken());
            if (token.allowance(args.user, ROUTER) < l.toPoolTokenDecimals((-delta.collateral).intoUD60x18())) {
                return (false, InvalidQuoteRFQError.InsufficientCollateralAllowance);
            }

            if (token.balanceOf(args.user) < l.toPoolTokenDecimals((-delta.collateral).intoUD60x18())) {
                return (false, InvalidQuoteRFQError.InsufficientCollateralBalance);
            }
        }

        if (delta.longs < iZERO && _balanceOf(args.user, PoolStorage.LONG) < (-delta.longs).intoUD60x18().unwrap()) {
            return (false, InvalidQuoteRFQError.InsufficientLongBalance);
        }

        if (delta.shorts < iZERO && _balanceOf(args.user, PoolStorage.SHORT) < (-delta.shorts).intoUD60x18().unwrap()) {
            return (false, InvalidQuoteRFQError.InsufficientShortBalance);
        }

        return (true, InvalidQuoteRFQError.None);
    }

    /// @notice Revert if `operator` is not msg.sender
    function _revertIfOperatorNotAuthorized(address operator) internal view {
        if (operator != msg.sender) revert Pool__OperatorNotAuthorized(msg.sender);
    }

    /// @notice Revert if `operator` is not authorized by `holder` to call `action`
    function _revertIfActionNotAuthorized(address holder, IUserSettings.Action action) internal view {
        if (!IUserSettings(SETTINGS).isActionAuthorized(holder, msg.sender, action))
            revert Pool__ActionNotAuthorized(holder, msg.sender, action);
    }

    /// @notice Revert if `cost` is not authorized by `holder`
    function _revertIfCostNotAuthorized(address holder, UD60x18 cost) internal view {
        PoolStorage.Layout storage l = PoolStorage.layout();

        address poolToken = l.getPoolToken();

        UD60x18 wrappedNativeQuote = poolToken == WRAPPED_NATIVE_TOKEN
            ? ONE
            : IOracleAdapter(l.oracleAdapter).quote(WRAPPED_NATIVE_TOKEN, poolToken);

        UD60x18 costInWrappedNative = (cost * wrappedNativeQuote);
        UD60x18 authorizedCost = UD60x18.wrap(IUserSettings(SETTINGS).getAuthorizedCost(holder));

        if (costInWrappedNative > authorizedCost) revert Pool__CostNotAuthorized(costInWrappedNative, authorizedCost);
    }

    /// @notice Revert if `cost` exceeds `payout`
    function _revertIfCostExceedsPayout(UD60x18 cost, UD60x18 payout) internal pure {
        if (cost > payout) revert Pool__CostExceedsPayout(cost, payout);
    }

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);

        PoolStorage.Layout storage l = PoolStorage.layout();

        // We do not need to revert here if positions are transferred like in PoolBase, as ERC1155 transfers functions
        // are not external in this diamond facet
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];

            if (amounts[i] == 0) continue;

            if (from == address(0)) {
                l.tokenIds.add(id);
            }

            if (to == address(0) && _totalSupply(id) == 0) {
                l.tokenIds.remove(id);
            }
        }
    }
}
