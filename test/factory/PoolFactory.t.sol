// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import {UD60x18, ud} from "@prb/math/UD60x18.sol";

import {IPoolFactory} from "contracts/factory/IPoolFactory.sol";
import {IPool} from "contracts/pool/IPool.sol";

import {DeployTest} from "../Deploy.t.sol";

contract PoolFactoryTest is DeployTest {
    function setUp() public override {
        super.setUp();
        vm.warp(1679758940);
    }

    function test_getPoolAddress_ReturnIsDeployedFalse() public {
        (address pool, bool isDeployed) = factory.getPoolAddress(poolKey);

        assert(pool != address(0));
        assertFalse(isDeployed);
    }

    function test_getPoolAddress_ReturnIsDeployedTrue() public {
        address poolAddress = factory.deployPool{value: 1 ether}(poolKey);

        (address pool, bool isDeployed) = factory.getPoolAddress(poolKey);
        assertEq(pool, poolAddress);
        assertTrue(isDeployed);
    }

    function test_deployPool_DeployPool() public {
        address pool = factory.deployPool{value: 1 ether}(poolKey);

        (address base, address quote, address oracleAdapter, UD60x18 strike, uint256 maturity, bool isCallPool) = IPool(
            pool
        ).getPoolSettings();

        assertEq(base, poolKey.base);
        assertEq(quote, poolKey.quote);
        assertEq(oracleAdapter, poolKey.oracleAdapter);
        assertEq(strike, poolKey.strike);
        assertEq(maturity, poolKey.maturity);
        assertEq(isCallPool, poolKey.isCallPool);
    }

    function test_deployPool_NoRefund() public {
        uint256 maturity = (block.timestamp - (block.timestamp % 24 hours)) + 32 hours; // 8AM UTC of the following day
        vm.warp(maturity - 1 hours);

        IPoolFactory.PoolKey memory poolKey = IPoolFactory.PoolKey({
            base: base,
            quote: quote,
            oracleAdapter: address(oracleAdapter),
            strike: ud(2000 ether), // OTM
            maturity: maturity + 24 hours,
            isCallPool: true
        });

        uint256 fee = factory.initializationFee(poolKey).unwrap();

        assertEq(fee, 109188259456203059);
        assertEq(address(factory).balance, 0);

        vm.deal(users.lp, 1 ether);
        uint256 lpBalanceBefore = users.lp.balance;

        vm.prank(users.lp);
        factory.deployPool{value: fee}(poolKey);

        assertEq(users.lp.balance, lpBalanceBefore - fee);
        assertEq(FEE_RECEIVER.balance, fee);
        assertEq(address(factory).balance, 0);
    }

    function test_deployPool_PartialRefund() public {
        uint256 maturity = (block.timestamp - (block.timestamp % 24 hours)) + 32 hours; // 8AM UTC of the following day
        vm.warp(maturity - 1 hours);

        IPoolFactory.PoolKey memory poolKey = IPoolFactory.PoolKey({
            base: base,
            quote: quote,
            oracleAdapter: address(oracleAdapter),
            strike: ud(2000 ether), // OTM
            maturity: maturity + 24 hours,
            isCallPool: true
        });

        uint256 fee = factory.initializationFee(poolKey).unwrap();

        assertEq(fee, 109188259456203059);
        assertEq(address(factory).balance, 0);

        vm.deal(users.lp, 1 ether);
        uint256 lpBalanceBefore = users.lp.balance;

        vm.prank(users.lp);
        factory.deployPool{value: 1 ether}(poolKey);

        assertEq(users.lp.balance, lpBalanceBefore - fee);
        assertEq(FEE_RECEIVER.balance, fee);
        assertEq(address(factory).balance, 0);
    }

    function test_deployPool_RevertIf_InitializationFeeRequired() public {
        uint256 maturity = (block.timestamp - (block.timestamp % 24 hours)) + 32 hours; // 8AM UTC of the following day
        vm.warp(maturity - 1 hours);

        IPoolFactory.PoolKey memory poolKey = IPoolFactory.PoolKey({
            base: base,
            quote: quote,
            oracleAdapter: address(oracleAdapter),
            strike: ud(2000 ether), // OTM
            maturity: maturity + 24 hours,
            isCallPool: true
        });

        uint256 fee = factory.initializationFee(poolKey).unwrap();

        vm.deal(users.lp, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IPoolFactory.PoolFactory__InitializationFeeRequired.selector, 0, fee));
        vm.prank(users.lp);
        factory.deployPool{value: 0}(poolKey);
    }

    function test_deployPool_RevertIf_BaseAndQuoteEqual() public {
        vm.expectRevert(IPoolFactory.PoolFactory__IdenticalAddresses.selector);

        poolKey.base = poolKey.quote;
        factory.deployPool{value: 1 ether}(poolKey);
    }

    function test_deployPool_RevertIf_QuoteZeroAddress() public {
        poolKey.quote = address(0);

        vm.expectRevert(IPoolFactory.PoolFactory__ZeroAddress.selector);
        factory.deployPool{value: 1 ether}(poolKey);
    }

    function test_deployPool_RevertIf_BaseZeroAddress() public {
        poolKey.base = address(0);

        vm.expectRevert(IPoolFactory.PoolFactory__ZeroAddress.selector);
        factory.deployPool{value: 1 ether}(poolKey);
    }

    // Note, this test is temporary and should be removed when the factory is updated to support multiple adapters
    function test_deployPool_RevertIf_InvalidOracleAdapter() public {
        poolKey.oracleAdapter = address(0);

        vm.expectRevert(IPoolFactory.PoolFactory__InvalidOracleAdapter.selector);
        factory.deployPool{value: 1 ether}(poolKey);
    }

    //    function test_deployPool_RevertIf_OracleAddress() public {
    //        poolKey.oracleAdapter = address(0);
    //
    //        vm.expectRevert(IPoolFactory.PoolFactory__ZeroAddress.selector);
    //        factory.deployPool{value: 1 ether}(poolKey);
    //    }

    function test_deployPool_RevertIf_StrikeIsZero() public {
        poolKey.strike = ud(0);

        vm.expectRevert(IPoolFactory.PoolFactory__OptionStrikeEqualsZero.selector);
        factory.deployPool{value: 1 ether}(poolKey);
    }

    function test_deployPool_RevertIf_AlreadyDeployed() public {
        address poolAddress = factory.deployPool{value: 1 ether}(poolKey);

        vm.expectRevert(abi.encodeWithSelector(IPoolFactory.PoolFactory__PoolAlreadyDeployed.selector, poolAddress));
        factory.deployPool{value: 1 ether}(poolKey);
    }

    function test_deployPool_RevertIf_PriceNotWithinStrikeInterval() public {
        uint256[4] memory strike = [uint256(99999 ether), uint256(1050 ether), uint256(960 ether), uint256(11.1 ether)];
        uint256[4] memory interval = [uint256(5000 ether), uint256(100 ether), uint256(50 ether), uint256(1 ether)];

        for (uint256 i; i < strike.length; i++) {
            poolKey.strike = ud(strike[i]);

            vm.expectRevert(
                abi.encodeWithSelector(IPoolFactory.PoolFactory__OptionStrikeInvalid.selector, strike[i], interval[i])
            );

            factory.deployPool{value: 1 ether}(poolKey);
        }
    }

    function test_deployPool_RevertIf_MaturityExpired() public {
        poolKey.maturity = 1679758930;

        vm.expectRevert(abi.encodeWithSelector(IPoolFactory.PoolFactory__OptionExpired.selector, poolKey.maturity));
        factory.deployPool{value: 1 ether}(poolKey);
    }

    function test_deployPool_RevertIf_MaturityNot8UTC() public {
        poolKey.maturity = 1679768950;

        vm.expectRevert(
            abi.encodeWithSelector(IPoolFactory.PoolFactory__OptionMaturityNot8UTC.selector, poolKey.maturity)
        );
        factory.deployPool{value: 1 ether}(poolKey);

        poolKey.maturity = 1688572800;

        vm.expectRevert(
            abi.encodeWithSelector(IPoolFactory.PoolFactory__OptionMaturityNot8UTC.selector, poolKey.maturity)
        );
        factory.deployPool{value: 1 ether}(poolKey);

        poolKey.maturity = 1688601600;

        vm.expectRevert(
            abi.encodeWithSelector(IPoolFactory.PoolFactory__OptionMaturityNot8UTC.selector, poolKey.maturity)
        );
        factory.deployPool{value: 1 ether}(poolKey);
    }

    function test_deployPool_RevertIf_MaturityWeeklyNotFriday() public {
        poolKey.maturity = 1680163200;

        vm.expectRevert(
            abi.encodeWithSelector(IPoolFactory.PoolFactory__OptionMaturityNotFriday.selector, poolKey.maturity)
        );
        factory.deployPool{value: 1 ether}(poolKey);
    }

    function test_deployPool_RevertIf_MaturityMonthlyNotLastFriday() public {
        poolKey.maturity = 1683878400;

        vm.expectRevert(
            abi.encodeWithSelector(IPoolFactory.PoolFactory__OptionMaturityNotLastFriday.selector, poolKey.maturity)
        );
        factory.deployPool{value: 1 ether}(poolKey);
    }

    function test_deployPool_RevertIf_MaturityExceedsOneYear() public {
        poolKey.maturity = 1714118400;

        vm.expectRevert(
            abi.encodeWithSelector(IPoolFactory.PoolFactory__OptionMaturityExceedsMax.selector, poolKey.maturity)
        );
        factory.deployPool{value: 1 ether}(poolKey);
    }
}