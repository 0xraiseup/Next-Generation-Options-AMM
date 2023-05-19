// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.20;

import {PoolAnnihilateTest} from "./Pool.annihilate.t.sol";
import {PoolClaimTest} from "./Pool.claim.t.sol";
import {PoolDepositTest} from "./Pool.deposit.t.sol";
import {PoolExerciseTest} from "./Pool.exercise.t.sol";
import {PoolFillQuoteRFQTest} from "./Pool.fillQuoteRFQ.t.sol";
import {PoolFlashLoanTest} from "./Pool.flashLoan.t.sol";
import {PoolGetQuoteAMMTest} from "./Pool.getQuoteAMM.t.sol";
import {PoolSettleTest} from "./Pool.settle.t.sol";
import {PoolSettlePositionTest} from "./Pool.settlePosition.t.sol";
import {PoolStrandedTest} from "./Pool.stranded.t.sol";
import {PoolTakerFeeTest} from "./Pool.takerFee.t.sol";
import {PoolTokenIdTest} from "./Pool.tokenId.t.sol";
import {PoolTradeTest} from "./Pool.trade.t.sol";
import {PoolTransferTest} from "./Pool.transfer.t.sol";
import {PoolWithdrawTest} from "./Pool.withdraw.t.sol";
import {PoolWriteFromTest} from "./Pool.writeFrom.t.sol";

abstract contract PoolTest is
    PoolAnnihilateTest,
    PoolClaimTest,
    PoolDepositTest,
    PoolExerciseTest,
    PoolFillQuoteRFQTest,
    PoolFlashLoanTest,
    PoolGetQuoteAMMTest,
    PoolSettleTest,
    PoolSettlePositionTest,
    PoolStrandedTest,
    PoolTakerFeeTest,
    PoolTokenIdTest,
    PoolTradeTest,
    PoolTransferTest,
    PoolWithdrawTest,
    PoolWriteFromTest
{}
