// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import {PoolStorage} from "./PoolStorage.sol";
import {PoolInternal} from "./PoolInternal.sol";
import {Position} from "../libraries/Position.sol";
import {IPoolCore} from "./IPoolCore.sol";

contract PoolCore is IPoolCore, PoolInternal {
    using PoolStorage for PoolStorage.Layout;
    using Position for Position.Key;

    constructor(
        address factory,
        address exchangeHelper,
        address wrappedNativeToken
    ) PoolInternal(factory, exchangeHelper, wrappedNativeToken) {}

    /// @inheritdoc IPoolCore
    function takerFee(
        uint256 size,
        uint256 premium,
        bool isPremiumNormalized
    ) external view returns (uint256) {
        return
            _takerFee(PoolStorage.layout(), size, premium, isPremiumNormalized);
    }

    /// @inheritdoc IPoolCore
    function getPoolSettings()
        external
        view
        returns (
            address base,
            address quote,
            address oracleAdapter,
            uint256 strike,
            uint64 maturity,
            bool isCallPool
        )
    {
        PoolStorage.Layout storage l = PoolStorage.layout();
        return (
            l.base,
            l.quote,
            l.oracleAdapter,
            l.strike,
            l.maturity,
            l.isCallPool
        );
    }

    /// @inheritdoc IPoolCore
    function claim(Position.Key memory p) external {
        _claim(p);
    }

    /// @inheritdoc IPoolCore
    function getClaimableFees(
        Position.Key memory p
    ) external view returns (uint256) {
        PoolStorage.Layout storage l = PoolStorage.layout();
        Position.Data storage pData = l.positions[p.keyHash()];

        (uint256 pendingClaimableFees, ) = _pendingClaimableFees(l, p, pData);

        return pData.claimableFees + pendingClaimableFees;
    }

    /// @inheritdoc IPoolCore
    function deposit(
        Position.Key memory p,
        uint256 belowLower,
        uint256 belowUpper,
        uint256 size,
        uint256 maxSlippage
    ) external {
        _ensureOperator(p.operator);
        _deposit(p, belowLower, belowUpper, size, maxSlippage, 0, address(0));
    }

    /// @inheritdoc IPoolCore
    function deposit(
        Position.Key memory p,
        uint256 belowLower,
        uint256 belowUpper,
        uint256 size,
        uint256 maxSlippage,
        bool isBidIfStrandedMarketPrice
    ) external {
        _ensureOperator(p.operator);
        _deposit(
            p,
            DepositArgsInternal(
                belowLower,
                belowUpper,
                size,
                maxSlippage,
                0,
                address(0),
                isBidIfStrandedMarketPrice
            )
        );
    }

    /// @inheritdoc IPoolCore
    function swapAndDeposit(
        SwapArgs memory s,
        Position.Key memory p,
        uint256 belowLower,
        uint256 belowUpper,
        uint256 size,
        uint256 maxSlippage
    ) external payable {
        _ensureOperator(p.operator);
        PoolStorage.Layout storage l = PoolStorage.layout();

        if (l.getPoolToken() != s.tokenOut) revert Pool__InvalidSwapTokenOut();
        (uint256 creditAmount, ) = _swap(s);

        _deposit(
            p,
            belowLower,
            belowUpper,
            size,
            maxSlippage,
            creditAmount,
            s.refundAddress
        );
    }

    /// @inheritdoc IPoolCore
    function withdraw(
        Position.Key memory p,
        uint256 size,
        uint256 maxSlippage
    ) external {
        _ensureOperator(p.operator);
        _withdraw(p, size, maxSlippage);
    }

    /// @inheritdoc IPoolCore
    function writeFrom(
        address underwriter,
        address longReceiver,
        uint256 size
    ) external {
        return _writeFrom(underwriter, longReceiver, size);
    }

    /// @inheritdoc IPoolCore
    function annihilate(uint256 size) external {
        _annihilate(msg.sender, size);
    }

    /// @inheritdoc IPoolCore
    function exercise(address holder) external returns (uint256) {
        return _exercise(holder);
    }

    /// @inheritdoc IPoolCore
    function settle(address holder) external returns (uint256) {
        return _settle(holder);
    }

    /// @inheritdoc IPoolCore
    function settlePosition(Position.Key memory p) external returns (uint256) {
        return _settlePosition(p);
    }

    /// @inheritdoc IPoolCore
    function getNearestTicksBelow(
        uint256 lower,
        uint256 upper
    )
        external
        view
        returns (uint256 nearestBelowLower, uint256 nearestBelowUpper)
    {
        return _getNearestTicksBelow(lower, upper);
    }
}
