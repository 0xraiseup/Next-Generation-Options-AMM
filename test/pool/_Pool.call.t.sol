// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.19;

import {IPoolMock} from "contracts/test/pool/IPoolMock.sol";

import {PoolTest} from "./_Pool.t.sol";

contract PoolCallTest is PoolTest {
    function setUp() public override {
        super.setUp();

        isCallTest = true;
        poolKey.isCallPool = true;
        pool = IPoolMock(factory.deployPool{value: 1 ether}(poolKey));
    }
}