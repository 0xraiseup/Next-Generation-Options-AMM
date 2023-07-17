// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {UD60x18, ud} from "@prb/math/UD60x18.sol";
import {IERC20} from "@solidstate/contracts/interfaces/IERC20.sol";

import {ZERO, ONE, TWO} from "contracts/libraries/Constants.sol";
import {Position} from "contracts/libraries/Position.sol";

import {PoolStorage} from "contracts/pool/PoolStorage.sol";
import {IPoolInternal} from "contracts/pool/IPoolInternal.sol";

import {IUserSettings} from "contracts/settings/IUserSettings.sol";

import {DeployTest} from "../Deploy.t.sol";

abstract contract PoolSmokeSpamTest is DeployTest {
    Traders traders;

    struct Traders {
        address trader0;
        address trader1;
        address trader2;
        address trader3;
        address trader4;
        address trader5;
        address trader6;
        address trader7;
        address trader8;
        address trader9;
    }

    function _setup_SmokeBig() public {
        traders = Traders({
            trader0: vm.addr(10),
            trader1: vm.addr(1),
            trader2: vm.addr(2),
            trader3: vm.addr(3),
            trader4: vm.addr(4),
            trader5: vm.addr(5),
            trader6: vm.addr(6),
            trader7: vm.addr(7),
            trader8: vm.addr(8),
            trader9: vm.addr(9)
        });
    }

    function depositS(uint256 size, bool isBidIfStrandedMarketPrice) internal returns (uint256 initialCollateral) {
        UD60x18 depositSize = ud(size);
        IERC20 token = IERC20(getPoolToken());
        initialCollateral = toTokenDecimals(isCallTest ? depositSize : depositSize * poolKey.strike);

        token.approve(address(router), initialCollateral);

        (UD60x18 nearestBelowLower, UD60x18 nearestBelowUpper) = pool.getNearestTicksBelow(posKey.lower, posKey.upper);

        pool.deposit(posKey, nearestBelowLower, nearestBelowUpper, depositSize, ZERO, ONE, isBidIfStrandedMarketPrice);
    }

    function withdrawS(Position.Key memory customPosKey, uint256 size) internal {
        vm.warp(block.timestamp + 120);
        pool.withdraw(customPosKey, ud(size), ZERO, ONE);
    }

    function tradeS(uint256 tradeSize, bool isBuy) internal returns (uint256 totalPremium) {
        UD60x18 _tradeSize = ud(tradeSize);
        (totalPremium, ) = pool.getQuoteAMM(users.trader, _tradeSize, isBuy);
        IERC20(getPoolToken()).approve(address(router), tradeSize);
        pool.trade(
            _tradeSize,
            isBuy,
            isBuy ? totalPremium + totalPremium / 10 : totalPremium - totalPremium / 10,
            address(0)
        );
    }

    function test_SmokeBig() public {
        _setup_SmokeBig();
        uint256 fund = 10000000000000000000000 ether;
        deal(getPoolToken(), traders.trader0, fund);
        deal(getPoolToken(), traders.trader1, fund);
        deal(getPoolToken(), traders.trader2, fund);
        deal(getPoolToken(), traders.trader3, fund);
        deal(getPoolToken(), traders.trader4, fund);
        deal(getPoolToken(), traders.trader5, fund);
        deal(getPoolToken(), traders.trader6, fund);
        deal(getPoolToken(), traders.trader7, fund);
        deal(getPoolToken(), traders.trader8, fund);
        deal(getPoolToken(), traders.trader9, fund);
        _test_SmokeBig();
    }

    function _test_SmokeBig() internal {
        uint256 size;
        bool isBidIfStrandedMarketPrice;
        size = 10000000 ether;
        posKey.owner = traders.trader5;
        posKey.operator = traders.trader5;
        posKey.lower = ud(0.193000000000000000 ether);
        posKey.upper = ud(0.318000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        isBidIfStrandedMarketPrice = false;
        vm.startPrank(traders.trader5);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 9500000 ether;
        vm.startPrank(traders.trader3);
        tradeS(size, true);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader5;
        posKey.operator = traders.trader5;
        posKey.lower = ud(0.193000000000000000 ether);
        posKey.upper = ud(0.318000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        vm.startPrank(traders.trader5);
        withdrawS(posKey, size);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader6;
        posKey.operator = traders.trader6;
        posKey.lower = ud(0.601000000000000000 ether);
        posKey.upper = ud(0.641000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        isBidIfStrandedMarketPrice = false;
        vm.startPrank(traders.trader6);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader1;
        posKey.operator = traders.trader1;
        posKey.lower = ud(0.414000000000000000 ether);
        posKey.upper = ud(0.514000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        isBidIfStrandedMarketPrice = true;
        vm.startPrank(traders.trader1);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 9500000 ether;
        vm.startPrank(traders.trader1);
        tradeS(size, false);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader9;
        posKey.operator = traders.trader9;
        posKey.lower = ud(0.176000000000000000 ether);
        posKey.upper = ud(0.186000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        isBidIfStrandedMarketPrice = true;
        vm.startPrank(traders.trader9);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader0;
        posKey.operator = traders.trader0;
        posKey.lower = ud(0.202000000000000000 ether);
        posKey.upper = ud(0.242000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        isBidIfStrandedMarketPrice = true;
        vm.startPrank(traders.trader0);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 18525000 ether;
        vm.startPrank(traders.trader3);
        tradeS(size, true);
        vm.stopPrank();
        size = 37073750 ether;
        vm.startPrank(traders.trader1);
        tradeS(size, false);
        vm.stopPrank();
        size = 1853687 ether;
        vm.startPrank(traders.trader4);
        tradeS(size, false);
        vm.stopPrank();
        size = 37907315 ether;
        vm.startPrank(traders.trader2);
        tradeS(size, true);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader0;
        posKey.operator = traders.trader0;
        posKey.lower = ud(0.083000000000000000 ether);
        posKey.upper = ud(0.483000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        isBidIfStrandedMarketPrice = true;
        vm.startPrank(traders.trader0);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 1895365 ether;
        vm.startPrank(traders.trader4);
        tradeS(size, true);
        vm.stopPrank();
        size = 47405231 ether;
        vm.startPrank(traders.trader8);
        tradeS(size, false);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader9;
        posKey.operator = traders.trader9;
        posKey.lower = ud(0.176000000000000000 ether);
        posKey.upper = ud(0.186000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        vm.startPrank(traders.trader9);
        withdrawS(posKey, size);
        vm.stopPrank();
        size = 35787310 ether;
        vm.startPrank(traders.trader2);
        tradeS(size, true);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader5;
        posKey.operator = traders.trader5;
        posKey.lower = ud(0.549000000000000000 ether);
        posKey.upper = ud(0.629000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        isBidIfStrandedMarketPrice = true;
        vm.startPrank(traders.trader5);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader4;
        posKey.operator = traders.trader4;
        posKey.lower = ud(0.649000000000000000 ether);
        posKey.upper = ud(0.681000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        isBidIfStrandedMarketPrice = false;
        vm.startPrank(traders.trader4);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader4;
        posKey.operator = traders.trader4;
        posKey.lower = ud(0.814000000000000000 ether);
        posKey.upper = ud(0.846000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        isBidIfStrandedMarketPrice = false;
        vm.startPrank(traders.trader4);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader4;
        posKey.operator = traders.trader4;
        posKey.lower = ud(0.814000000000000000 ether);
        posKey.upper = ud(0.846000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        vm.startPrank(traders.trader4);
        withdrawS(posKey, size);
        vm.stopPrank();
        size = 11289365 ether;
        vm.startPrank(traders.trader5);
        tradeS(size, true);
        vm.stopPrank();
        size = 564468 ether;
        vm.startPrank(traders.trader9);
        tradeS(size, true);
        vm.stopPrank();
        size = 28223 ether;
        vm.startPrank(traders.trader0);
        tradeS(size, true);
        vm.stopPrank();
        size = 56998588 ether;
        vm.startPrank(traders.trader0);
        tradeS(size, false);
        vm.stopPrank();
        size = 2849929 ether;
        vm.startPrank(traders.trader0);
        tradeS(size, false);
        vm.stopPrank();
        size = 56857503 ether;
        vm.startPrank(traders.trader2);
        tradeS(size, true);
        vm.stopPrank();
        size = 2842875 ether;
        vm.startPrank(traders.trader2);
        tradeS(size, true);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader3;
        posKey.operator = traders.trader3;
        posKey.lower = ud(0.858000000000000000 ether);
        posKey.upper = ud(0.908000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        isBidIfStrandedMarketPrice = false;
        vm.startPrank(traders.trader3);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader1;
        posKey.operator = traders.trader1;
        posKey.lower = ud(0.414000000000000000 ether);
        posKey.upper = ud(0.514000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        vm.startPrank(traders.trader1);
        withdrawS(posKey, size);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader9;
        posKey.operator = traders.trader9;
        posKey.lower = ud(0.594000000000000000 ether);
        posKey.upper = ud(0.674000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        isBidIfStrandedMarketPrice = false;
        vm.startPrank(traders.trader9);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 9642143 ether;
        vm.startPrank(traders.trader2);
        tradeS(size, true);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader0;
        posKey.operator = traders.trader0;
        posKey.lower = ud(0.083000000000000000 ether);
        posKey.upper = ud(0.483000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        vm.startPrank(traders.trader0);
        withdrawS(posKey, size);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader3;
        posKey.operator = traders.trader3;
        posKey.lower = ud(0.983000000000000000 ether);
        posKey.upper = ud(0.985000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        isBidIfStrandedMarketPrice = false;
        vm.startPrank(traders.trader3);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader3;
        posKey.operator = traders.trader3;
        posKey.lower = ud(0.858000000000000000 ether);
        posKey.upper = ud(0.908000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        vm.startPrank(traders.trader3);
        withdrawS(posKey, size);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader0;
        posKey.operator = traders.trader0;
        posKey.lower = ud(0.925000000000000000 ether);
        posKey.upper = ud(0.929000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        isBidIfStrandedMarketPrice = false;
        vm.startPrank(traders.trader0);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader3;
        posKey.operator = traders.trader3;
        posKey.lower = ud(0.061000000000000000 ether);
        posKey.upper = ud(0.861000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        isBidIfStrandedMarketPrice = false;
        vm.startPrank(traders.trader3);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 57000000 ether;
        vm.startPrank(traders.trader3);
        tradeS(size, false);
        vm.stopPrank();
        size = 2849999 ether;
        vm.startPrank(traders.trader9);
        tradeS(size, false);
        vm.stopPrank();
        size = 142499 ether;
        vm.startPrank(traders.trader8);
        tradeS(size, false);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader0;
        posKey.operator = traders.trader0;
        posKey.lower = ud(0.007000000000000000 ether);
        posKey.upper = ud(0.057000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        isBidIfStrandedMarketPrice = true;
        vm.startPrank(traders.trader0);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 75992875 ether;
        vm.startPrank(traders.trader3);
        tradeS(size, true);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader9;
        posKey.operator = traders.trader9;
        posKey.lower = ud(0.594000000000000000 ether);
        posKey.upper = ud(0.674000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        vm.startPrank(traders.trader9);
        withdrawS(posKey, size);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader7;
        posKey.operator = traders.trader7;
        posKey.lower = ud(0.995000000000000000 ether);
        posKey.upper = ud(1.000000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        isBidIfStrandedMarketPrice = false;
        vm.startPrank(traders.trader7);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader2;
        posKey.operator = traders.trader2;
        posKey.lower = ud(0.990000000000000000 ether);
        posKey.upper = ud(1.000000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        isBidIfStrandedMarketPrice = false;
        vm.startPrank(traders.trader2);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 72200356 ether;
        vm.startPrank(traders.trader6);
        tradeS(size, false);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader6;
        posKey.operator = traders.trader6;
        posKey.lower = ud(0.002000000000000000 ether);
        posKey.upper = ud(0.012000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        isBidIfStrandedMarketPrice = false;
        vm.startPrank(traders.trader6);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader2;
        posKey.operator = traders.trader2;
        posKey.lower = ud(0.990000000000000000 ether);
        posKey.upper = ud(1.000000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        vm.startPrank(traders.trader2);
        withdrawS(posKey, size);
        vm.stopPrank();
        size = 5000000 ether;
        posKey.owner = traders.trader3;
        posKey.operator = traders.trader3;
        posKey.lower = ud(0.983000000000000000 ether);
        posKey.upper = ud(0.985000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        vm.startPrank(traders.trader3);
        withdrawS(posKey, size);
        vm.stopPrank();
        size = 10000000 ether;
        posKey.owner = traders.trader7;
        posKey.operator = traders.trader7;
        posKey.lower = ud(0.018000000000000000 ether);
        posKey.upper = ud(0.026000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        isBidIfStrandedMarketPrice = true;
        vm.startPrank(traders.trader7);
        depositS(size, isBidIfStrandedMarketPrice);
        vm.stopPrank();
        vm.warp(poolKey.maturity);
        vm.startPrank(traders.trader0);
        pool.settle();
        vm.stopPrank();
        posKey.owner = traders.trader0;
        posKey.operator = traders.trader0;
        posKey.lower = ud(0.202000000000000000 ether);
        posKey.upper = ud(0.242000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        vm.startPrank(traders.trader0);
        pool.settlePosition(posKey);
        vm.stopPrank();
        posKey.owner = traders.trader0;
        posKey.operator = traders.trader0;
        posKey.lower = ud(0.925000000000000000 ether);
        posKey.upper = ud(0.929000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        vm.startPrank(traders.trader0);
        pool.settlePosition(posKey);
        vm.stopPrank();
        posKey.owner = traders.trader0;
        posKey.operator = traders.trader0;
        posKey.lower = ud(0.007000000000000000 ether);
        posKey.upper = ud(0.057000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        vm.startPrank(traders.trader0);
        pool.settlePosition(posKey);
        vm.stopPrank();
        vm.startPrank(traders.trader1);
        pool.settle();
        vm.stopPrank();
        vm.startPrank(traders.trader2);
        pool.exercise();
        vm.stopPrank();
        vm.startPrank(traders.trader3);
        pool.exercise();
        vm.stopPrank();
        posKey.owner = traders.trader3;
        posKey.operator = traders.trader3;
        posKey.lower = ud(0.983000000000000000 ether);
        posKey.upper = ud(0.985000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        vm.startPrank(traders.trader3);
        pool.settlePosition(posKey);
        vm.stopPrank();
        posKey.owner = traders.trader3;
        posKey.operator = traders.trader3;
        posKey.lower = ud(0.061000000000000000 ether);
        posKey.upper = ud(0.861000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        vm.startPrank(traders.trader3);
        pool.settlePosition(posKey);
        vm.stopPrank();
        vm.startPrank(traders.trader4);
        pool.exercise();
        vm.stopPrank();
        posKey.owner = traders.trader4;
        posKey.operator = traders.trader4;
        posKey.lower = ud(0.649000000000000000 ether);
        posKey.upper = ud(0.681000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        vm.startPrank(traders.trader4);
        pool.settlePosition(posKey);
        vm.stopPrank();
        vm.startPrank(traders.trader5);
        pool.exercise();
        vm.stopPrank();
        posKey.owner = traders.trader5;
        posKey.operator = traders.trader5;
        posKey.lower = ud(0.549000000000000000 ether);
        posKey.upper = ud(0.629000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        vm.startPrank(traders.trader5);
        pool.settlePosition(posKey);
        vm.stopPrank();
        vm.startPrank(traders.trader6);
        pool.settle();
        vm.stopPrank();
        posKey.owner = traders.trader6;
        posKey.operator = traders.trader6;
        posKey.lower = ud(0.601000000000000000 ether);
        posKey.upper = ud(0.641000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        vm.startPrank(traders.trader6);
        pool.settlePosition(posKey);
        vm.stopPrank();
        posKey.owner = traders.trader6;
        posKey.operator = traders.trader6;
        posKey.lower = ud(0.002000000000000000 ether);
        posKey.upper = ud(0.012000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        vm.startPrank(traders.trader6);
        pool.settlePosition(posKey);
        vm.stopPrank();
        posKey.owner = traders.trader7;
        posKey.operator = traders.trader7;
        posKey.lower = ud(0.995000000000000000 ether);
        posKey.upper = ud(1.000000000000000000 ether);
        posKey.orderType = Position.OrderType.CSUP;
        vm.startPrank(traders.trader7);
        pool.settlePosition(posKey);
        vm.stopPrank();
        posKey.owner = traders.trader7;
        posKey.operator = traders.trader7;
        posKey.lower = ud(0.018000000000000000 ether);
        posKey.upper = ud(0.026000000000000000 ether);
        posKey.orderType = Position.OrderType.LC;
        vm.startPrank(traders.trader7);
        pool.settlePosition(posKey);
        vm.stopPrank();
        vm.startPrank(traders.trader8);
        pool.settle();
        vm.stopPrank();
        vm.startPrank(traders.trader9);
        pool.settle();
        vm.stopPrank();
    }
}
