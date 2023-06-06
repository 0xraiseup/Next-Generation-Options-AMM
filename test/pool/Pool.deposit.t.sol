// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {UD60x18, ud} from "@prb/math/UD60x18.sol";

import {IERC20} from "@solidstate/contracts/interfaces/IERC20.sol";

import {ZERO, ONE_HALF, ONE, TWO, THREE} from "contracts/libraries/Constants.sol";
import {Pricing} from "contracts/libraries/Pricing.sol";
import {Position} from "contracts/libraries/Position.sol";

import {IPoolFactory} from "contracts/factory/IPoolFactory.sol";

import {IPoolInternal} from "contracts/pool/IPoolInternal.sol";

import {DeployTest} from "../Deploy.t.sol";

abstract contract PoolDepositTest is DeployTest {
    function test_deposit_1000_LC_WithToken() public {
        poolKey.isCallPool = isCallTest;

        IERC20 token = IERC20(getPoolToken());
        UD60x18 depositSize = ud(1000 ether);
        uint256 initialCollateral = deposit(depositSize);

        UD60x18 avgPrice = posKey.lower.avg(posKey.upper);
        UD60x18 collateral = contractsToCollateral(depositSize);
        uint256 collateralValue = scaleDecimals(collateral * avgPrice);

        assertEq(pool.balanceOf(users.lp, tokenId()), depositSize);
        assertEq(pool.totalSupply(tokenId()), depositSize);
        assertEq(token.balanceOf(address(pool)), collateralValue);
        assertEq(token.balanceOf(users.lp), initialCollateral - collateralValue);
        assertEq(pool.marketPrice(), posKey.upper);
    }

    function test_deposit_RevertIf_SenderNotOperator() public {
        posKey.operator = users.trader;

        vm.prank(users.lp);
        vm.expectRevert(abi.encodeWithSelector(IPoolInternal.Pool__OperatorNotAuthorized.selector, users.lp));

        pool.deposit(posKey, ZERO, ZERO, THREE, ZERO, ONE);
    }

    function test_deposit_RevertIf_MarketPriceOutOfMinMax() public {
        poolKey.isCallPool = isCallTest;
        deposit(1000 ether);
        assertEq(pool.marketPrice(), posKey.upper);

        vm.startPrank(users.lp);

        UD60x18 minPrice = posKey.upper + ud(1);
        UD60x18 maxPrice = posKey.upper;
        vm.expectRevert(
            abi.encodeWithSelector(IPoolInternal.Pool__AboveMaxSlippage.selector, posKey.upper, minPrice, maxPrice)
        );
        pool.deposit(posKey, ZERO, ZERO, THREE, minPrice, maxPrice);

        minPrice = posKey.upper - ud(10);
        maxPrice = posKey.upper - ud(1);
        vm.expectRevert(
            abi.encodeWithSelector(IPoolInternal.Pool__AboveMaxSlippage.selector, posKey.upper, minPrice, maxPrice)
        );
        pool.deposit(posKey, ZERO, ZERO, THREE, minPrice, maxPrice);
    }

    function test_deposit_RevertIf_ZeroSize() public {
        vm.prank(users.lp);
        vm.expectRevert(IPoolInternal.Pool__ZeroSize.selector);

        pool.deposit(posKey, ZERO, ZERO, ZERO, ZERO, ONE);
    }

    function test_deposit_RevertIf_Expired() public {
        vm.prank(users.lp);

        vm.warp(poolKey.maturity + 1);
        vm.expectRevert(IPoolInternal.Pool__OptionExpired.selector);

        pool.deposit(posKey, ZERO, ZERO, THREE, ZERO, ONE);
    }

    function test_deposit_RevertIf_InvalidRange() public {
        vm.startPrank(users.lp);

        Position.Key memory posKeySave = posKey;

        posKey.lower = ZERO;
        vm.expectRevert(abi.encodeWithSelector(IPoolInternal.Pool__InvalidRange.selector, posKey.lower, posKey.upper));
        pool.deposit(posKey, ZERO, ZERO, THREE, ZERO, ONE);

        posKey.lower = posKeySave.lower;
        posKey.upper = ZERO;
        vm.expectRevert(abi.encodeWithSelector(IPoolInternal.Pool__InvalidRange.selector, posKey.lower, posKey.upper));
        pool.deposit(posKey, ZERO, ZERO, THREE, ZERO, ONE);

        posKey.lower = ONE_HALF;
        posKey.upper = ONE_HALF / TWO;
        vm.expectRevert(abi.encodeWithSelector(IPoolInternal.Pool__InvalidRange.selector, posKey.lower, posKey.upper));
        pool.deposit(posKey, ZERO, ZERO, THREE, ZERO, ONE);

        posKey.lower = ud(0.0001e18);
        posKey.upper = posKeySave.upper;
        vm.expectRevert(abi.encodeWithSelector(IPoolInternal.Pool__InvalidRange.selector, posKey.lower, posKey.upper));
        pool.deposit(posKey, ZERO, ZERO, THREE, ZERO, ONE);

        posKey.lower = posKeySave.lower;
        posKey.upper = ud(1.01e18);
        vm.expectRevert(abi.encodeWithSelector(IPoolInternal.Pool__InvalidRange.selector, posKey.lower, posKey.upper));
        pool.deposit(posKey, ZERO, ZERO, THREE, ZERO, ONE);
    }

    function test_deposit_RevertIf_InvalidTickWidth() public {
        vm.startPrank(users.lp);

        Position.Key memory posKeySave = posKey;

        posKey.lower = ud(0.2501e18);
        vm.expectRevert(abi.encodeWithSelector(IPoolInternal.Pool__TickWidthInvalid.selector, posKey.lower));
        pool.deposit(posKey, ZERO, ZERO, THREE, ZERO, ONE);

        posKey.lower = posKeySave.lower;
        posKey.upper = ud(0.7501e18);
        vm.expectRevert(abi.encodeWithSelector(IPoolInternal.Pool__TickWidthInvalid.selector, posKey.upper));
        pool.deposit(posKey, ZERO, ZERO, THREE, ZERO, ONE);
    }

    function test_ticks_ReturnExpectedValues() public {
        deposit(1000 ether);

        IPoolInternal.TickWithRates[] memory ticks = pool.ticks();

        assertEq(ticks[0].price, Pricing.MIN_TICK_PRICE);
        assertEq(ticks[1].price, posKey.lower);
        assertEq(ticks[2].price, posKey.upper);
        assertEq(ticks[3].price, Pricing.MAX_TICK_PRICE);

        assertEq(ticks[0].longRate, ZERO);
        assertEq(ticks[1].longRate, ud(5 ether));
        assertEq(ticks[2].longRate, ZERO);
        assertEq(ticks[3].longRate, ZERO);

        Position.Key memory customPosKey = Position.Key({
            owner: users.lp,
            operator: users.lp,
            lower: ud(0.2 ether),
            upper: ud(0.3 ether),
            orderType: Position.OrderType.LC
        });

        deposit(customPosKey, ud(1000 ether));

        ticks = pool.ticks();

        assertEq(ticks[0].price, Pricing.MIN_TICK_PRICE);
        assertEq(ticks[1].price, posKey.lower);
        assertEq(ticks[2].price, customPosKey.lower);
        assertEq(ticks[3].price, posKey.upper);
        assertEq(ticks[4].price, Pricing.MAX_TICK_PRICE);

        assertEq(ticks[0].longRate, ZERO);
        assertEq(ticks[1].longRate, ud(5 ether));
        assertEq(ticks[2].longRate, ud(15 ether));
        assertEq(ticks[3].longRate, ZERO);
        assertEq(ticks[4].longRate, ZERO);
    }

    function test_ticks_NoDeposit() public {
        IPoolInternal.TickWithRates[] memory ticks = pool.ticks();

        assertEq(ticks[0].price, Pricing.MIN_TICK_PRICE);
        assertEq(ticks[1].price, Pricing.MAX_TICK_PRICE);

        assertEq(ticks[0].longRate, ZERO);
        assertEq(ticks[0].shortRate, ZERO);
        assertEq(ticks[1].longRate, ZERO);
        assertEq(ticks[1].shortRate, ZERO);
    }

    function test_ticks_DepositMinTick() public {
        Position.Key memory customPosKey0 = Position.Key({
            owner: users.lp,
            operator: users.lp,
            lower: ud(0.001 ether),
            upper: ud(0.005 ether),
            orderType: Position.OrderType.LC
        });

        deposit(customPosKey0, ud(200 ether));

        Position.Key memory customPosKey1 = Position.Key({
            owner: users.lp,
            operator: users.lp,
            lower: ud(0.005 ether),
            upper: ud(0.009 ether),
            orderType: Position.OrderType.CS
        });

        deposit(customPosKey1, ud(10 ether));

        IPoolInternal.TickWithRates[] memory ticks = pool.ticks();

        assertEq(ticks[0].price, Pricing.MIN_TICK_PRICE);
        assertEq(ticks[1].price, customPosKey0.upper);
        assertEq(ticks[2].price, customPosKey1.upper);
        assertEq(ticks[3].price, Pricing.MAX_TICK_PRICE);

        assertEq(ticks[0].longRate, ud(50 ether));
        assertEq(ticks[1].longRate, ZERO);
        assertEq(ticks[2].longRate, ZERO);
        assertEq(ticks[0].shortRate, ZERO);
        assertEq(ticks[1].shortRate, ud(2.5 ether));
        assertEq(ticks[2].shortRate, ZERO);
        assertEq(ticks[3].shortRate, ZERO);
    }

    function test_ticks_ThreeDeposits() public {
        Position.Key memory customPosKey0 = Position.Key({
            owner: users.lp,
            operator: users.lp,
            lower: ud(0.001 ether),
            upper: ud(0.002 ether),
            orderType: Position.OrderType.LC
        });

        deposit(customPosKey0, ud(40 ether));

        Position.Key memory customPosKey1 = Position.Key({
            owner: users.lp,
            operator: users.lp,
            lower: ud(0.2 ether),
            upper: ud(0.4 ether),
            orderType: Position.OrderType.LC
        });

        deposit(customPosKey1, ud(10 ether));

        Position.Key memory customPosKey2 = Position.Key({
            owner: users.lp,
            operator: users.lp,
            lower: ud(0.2 ether),
            upper: ud(0.6 ether),
            orderType: Position.OrderType.LC
        });

        deposit(customPosKey2, ud(100 ether));

        Position.Key memory customPosKey3 = Position.Key({
            owner: users.lp,
            operator: users.lp,
            lower: ud(0.6 ether),
            upper: ud(0.8 ether),
            orderType: Position.OrderType.CS
        });

        deposit(customPosKey3, ud(10 ether));

        IPoolInternal.TickWithRates[] memory ticks = pool.ticks();

        assertEq(ticks[0].price, Pricing.MIN_TICK_PRICE);
        assertEq(ticks[1].price, customPosKey0.upper);
        assertEq(ticks[2].price, customPosKey1.lower);
        assertEq(ticks[3].price, customPosKey1.upper);
        assertEq(ticks[4].price, customPosKey2.upper);
        assertEq(ticks[5].price, customPosKey3.upper);
        assertEq(ticks[6].price, Pricing.MAX_TICK_PRICE);

        assertEq(ticks[0].longRate, ud(40 ether));
        assertEq(ticks[0].shortRate, ZERO);
        // lr (0.002 - 0.2)
        assertEq(ticks[1].longRate, ud(0 ether));
        assertEq(ticks[1].shortRate, ZERO);
        // lr (0.2 and 0.4)
        // 10 / 200 + (100 / 400) = 0.3
        // total liquidity is numTicks * liqRate = 200 * 0.3 = 60
        assertEq(ticks[2].longRate, ud(0.3 ether));
        assertEq(ticks[2].shortRate, ZERO);
        // lr (0.4 and 0.6)
        // total liquidity is numTicks * liqRate = 200 * 0.25 = 50
        assertEq(ticks[3].longRate, ud(0.25 ether));
        assertEq(ticks[3].shortRate, ZERO);
        // lr (0.6 and 0.8)
        assertEq(ticks[4].longRate, ZERO);
        assertEq(ticks[4].shortRate, ud(0.05 ether));
        // lr (0.8 and 1.0)
        assertEq(ticks[5].longRate, ZERO);
        assertEq(ticks[5].shortRate, ZERO);
    }

    function test_getNearestTicksBelow_MaxTickPrice() public {
        (UD60x18 belowLower, UD60x18 belowUpper) = pool.getNearestTicksBelow(ud(0.002 ether), ud(1 ether));
        assertEq(belowLower, ud(0.001 ether));
        assertEq(belowUpper, ud(1 ether));
    }

    function test_getNearestTicksBelow_MinTickPrice() public {
        (UD60x18 belowLower, UD60x18 belowUpper) = pool.getNearestTicksBelow(ud(0.001 ether), ud(1 ether));
        assertEq(belowLower, ud(0.001 ether));
        assertEq(belowUpper, ud(1 ether));
    }

    function test_getNearestTicksBelow_LowerIsBelowUpper() public {
        (UD60x18 belowLower, UD60x18 belowUpper) = pool.getNearestTicksBelow(ud(0.002 ether), ud(0.999 ether));
        assertEq(belowLower, ud(0.001 ether));
        assertEq(belowUpper, ud(0.002 ether));
    }

    function test_getNearestTicksBelow_OneDeposit() public {
        Position.Key memory customPosKey0 = Position.Key({
            owner: users.lp,
            operator: users.lp,
            lower: ud(0.002 ether),
            upper: ud(0.004 ether),
            orderType: Position.OrderType.LC
        });

        deposit(customPosKey0, ud(40 ether));

        (UD60x18 belowLower, UD60x18 belowUpper) = pool.getNearestTicksBelow(ud(0.003 ether), ud(1 ether));
        assertEq(belowLower, ud(0.002 ether));
        assertEq(belowUpper, ud(1 ether));
    }

    function test_getNearestTicksBelow_RevertIf_InvalidRange() public {
        vm.expectRevert(
            abi.encodeWithSelector(IPoolInternal.Pool__InvalidRange.selector, ud(0.001 ether), ud(2 ether))
        );
        (UD60x18 belowLower, UD60x18 belowUpper) = pool.getNearestTicksBelow(ud(0.001 ether), ud(2 ether));
    }
}
