// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {IPool} from "../../pool/IPool.sol";

import {IPoolCoreMock} from "./IPoolCoreMock.sol";

interface IPoolMock is IPool, IPoolCoreMock {}