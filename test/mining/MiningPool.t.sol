// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {Test} from "forge-std/Test.sol";
import {UD60x18, ud} from "@prb/math/UD60x18.sol";
import {IOwnableInternal} from "@solidstate/contracts/access/ownable/IOwnableInternal.sol";
import {IERC20} from "@solidstate/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@solidstate/contracts/token/ERC20/metadata/IERC20Metadata.sol";
import {SafeCast} from "@solidstate/contracts/utils/SafeCast.sol";

import {ONE} from "contracts/libraries/Constants.sol";
import {OptionMath} from "contracts/libraries/OptionMath.sol";
import {ProxyUpgradeableOwnable} from "contracts/proxy/ProxyUpgradeableOwnable.sol";
import {ERC20Mock} from "contracts/test/ERC20Mock.sol";

import {IMiningPool} from "contracts/mining/MiningPool.sol";
import {MiningPool} from "contracts/mining/MiningPool.sol";
import {MiningPoolFactory} from "contracts/mining/MiningPoolFactory.sol";

import {IPriceRepository} from "contracts/mining/IPriceRepository.sol";
import {PriceRepository} from "contracts/mining/PriceRepository.sol";
import {PriceRepositoryProxy} from "contracts/mining/PriceRepositoryProxy.sol";

import {PaymentSplitter} from "contracts/mining/PaymentSplitter.sol";

import {IVxPremia} from "contracts/staking/IVxPremia.sol";
import {VxPremia} from "contracts/staking/VxPremia.sol";
import {VxPremiaProxy} from "contracts/staking/VxPremiaProxy.sol";

import {Assertions} from "../Assertions.sol";

contract MiningPoolTest is Assertions, Test {
    using SafeCast for int256;
    using SafeCast for uint256;

    PaymentSplitter paymentSplitter;
    PriceRepository priceRepository;

    MiningPool miningPool;
    MiningPool wbtcUSDCMiningPool;
    MiningPool premiaWETHMiningPool;

    UD60x18 fee;
    uint256 size;

    Users users;

    address vxPremia;
    address base;
    address quote;

    DataInternal data;

    struct DataInternal {
        UD60x18 discount;
        UD60x18 spot;
        UD60x18 settlementITM;
        UD60x18 penalty;
        uint256 expiryDuration;
        uint256 exerciseDuration;
        uint256 lockupDuration;
    }

    struct Users {
        address underwriter;
        address longReceiver;
        address keeper;
        address treasury;
    }

    function setUp() public {
        string memory ETH_RPC_URL = string.concat(
            "https://eth-mainnet.alchemyapi.io/v2/",
            vm.envString("API_KEY_ALCHEMY")
        );

        uint256 fork = vm.createFork(ETH_RPC_URL, 17101000); // Apr-22-2023 09:30:23 AM +UTC
        vm.selectFork(fork);

        fee = ud(0.01e18);

        base = 0x6399C842dD2bE3dE30BF99Bc7D1bBF6Fa3650E70; // PREMIA (18 decimals)
        quote = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC (6 decimals)

        users = Users({underwriter: vm.addr(1), longReceiver: vm.addr(2), keeper: vm.addr(3), treasury: vm.addr(4)});

        VxPremia vxPremiaImpl = new VxPremia(address(0), address(0), address(base), address(quote), address(0));
        VxPremiaProxy vxPremiaProxy = new VxPremiaProxy(address(vxPremiaImpl));
        vxPremia = address(vxPremiaProxy);

        paymentSplitter = new PaymentSplitter(quote, vxPremia);

        PriceRepository implementation = new PriceRepository();
        PriceRepositoryProxy proxy = new PriceRepositoryProxy(address(implementation), users.keeper);
        priceRepository = PriceRepository(address(proxy));

        MiningPool miningPoolImplementation = new MiningPool(users.treasury, fee);
        ProxyUpgradeableOwnable miningPoolProxy = new ProxyUpgradeableOwnable(address(miningPoolImplementation));
        MiningPoolFactory miningPoolFactory = new MiningPoolFactory(address(miningPoolProxy));

        data = DataInternal(ud(0.55e18), ud(1e18), ud(2e18), ud(0.80e18), 30 days, 30 days, 365 days);
        size = 1000000e18;

        miningPool = MiningPool(
            miningPoolFactory.deployMiningPool(
                base,
                quote,
                users.underwriter,
                address(priceRepository),
                address(paymentSplitter),
                data.discount,
                data.penalty,
                data.expiryDuration,
                data.exerciseDuration,
                data.lockupDuration
            )
        );
    }

    function getMaturity(uint256 timestamp, uint256 expiryDuration) internal pure returns (uint256 maturity) {
        maturity = timestamp - (timestamp % 24 hours) + 8 hours + expiryDuration;
    }

    function setPriceAt(uint256 timestamp, UD60x18 price) internal {
        vm.prank(users.keeper);
        priceRepository.setPriceAt(base, quote, timestamp, price);
    }

    function scaleDecimalsFrom(address token, uint256 amount) internal view returns (UD60x18) {
        uint8 decimals = IERC20Metadata(token).decimals();
        return ud(OptionMath.scaleDecimals(amount, decimals, 18));
    }

    function scaleDecimalsTo(address token, UD60x18 amount) internal view returns (uint256) {
        uint8 decimals = IERC20Metadata(token).decimals();
        return OptionMath.scaleDecimals(amount.unwrap(), 18, decimals);
    }

    function _test_writeFrom_Success()
        internal
        returns (uint64 maturity, uint256 collateral, uint256 longTokenId, uint256 shortTokenId)
    {
        maturity = uint64(getMaturity(block.timestamp, data.expiryDuration));
        setPriceAt(block.timestamp, data.spot);

        UD60x18 _size = ud(size);
        collateral = scaleDecimalsTo(base, _size);
        deal(base, users.underwriter, collateral);

        vm.startPrank(users.underwriter);
        IERC20(base).approve(address(miningPool), collateral);
        miningPool.writeFrom(users.longReceiver, _size);
        vm.stopPrank();

        UD60x18 strike = data.discount * data.spot;
        longTokenId = miningPool.formatTokenId(IMiningPool.TokenType.LONG, maturity, strike);
        shortTokenId = miningPool.formatTokenId(IMiningPool.TokenType.SHORT, maturity, strike);

        assertEq(miningPool.balanceOf(users.longReceiver, longTokenId), size);
        assertEq(miningPool.balanceOf(users.longReceiver, shortTokenId), 0);
        assertEq(miningPool.balanceOf(users.underwriter, shortTokenId), size);
        assertEq(miningPool.balanceOf(users.underwriter, longTokenId), 0);

        assertEq(IERC20(base).balanceOf(users.underwriter), 0);
        assertEq(IERC20(base).balanceOf(address(miningPool)), collateral);
    }

    function test_writeFrom_Success() public {
        _test_writeFrom_Success();
    }

    event WriteFrom(
        address indexed underwriter,
        address indexed longReceiver,
        UD60x18 contractSize,
        UD60x18 strike,
        uint64 maturity
    );

    function test_writeFrom_CorrectMaturity() public {
        setPriceAt(block.timestamp, ONE);

        uint256 collateral = scaleDecimalsTo(base, ud(100e18));
        deal(base, users.underwriter, collateral);

        vm.prank(users.underwriter);
        IERC20(base).approve(address(miningPool), collateral);

        UD60x18 _size = ONE;

        // block.timestamp = Apr-22-2023 09:30:23 AM +UTC
        uint64 timeToMaturity = uint64(30 days);
        uint64 timestamp8AMUTC = 1682150400; // Apr-22-2023 08:00:00 AM +UTC
        uint64 expectedMaturity = timestamp8AMUTC + timeToMaturity; // May-22-2023 08:00:00 AM +UTC

        vm.expectEmit();
        emit WriteFrom(users.underwriter, users.longReceiver, _size, ud(0.55e18), expectedMaturity);

        vm.prank(users.underwriter);
        miningPool.writeFrom(users.longReceiver, _size);

        vm.warp(1682207999); // Apr-22-2023 23:59:59 PM +UTC

        expectedMaturity = timestamp8AMUTC + timeToMaturity; // May-22-2023 08:00:00 AM +UTC
        vm.expectEmit();
        emit WriteFrom(users.underwriter, users.longReceiver, _size, ud(0.55e18), expectedMaturity);

        vm.prank(users.underwriter);
        miningPool.writeFrom(users.longReceiver, _size);

        vm.warp(1682208000); // Apr-23-2023 00:00:00 PM +UTC

        timestamp8AMUTC = 1682236800; // Apr-23-2023 08:00:00 AM +UTC
        expectedMaturity = timestamp8AMUTC + timeToMaturity; // May-23-2023 08:00:00 AM +UTC
        vm.expectEmit();
        emit WriteFrom(users.underwriter, users.longReceiver, _size, ud(0.55e18), expectedMaturity);

        vm.prank(users.underwriter);
        miningPool.writeFrom(users.longReceiver, _size);
    }

    function test_writeFrom_RevertIf_UnderwriterNotAuthorized() public {
        vm.expectRevert(
            abi.encodeWithSelector(IMiningPool.MiningPool__UnderwriterNotAuthorized.selector, users.longReceiver)
        );

        vm.prank(users.longReceiver);
        miningPool.writeFrom(users.longReceiver, ud(1000000e18));
    }

    function _test_exercise_PhysicallySettled_Success() internal {
        (uint64 maturity, uint256 collateral, uint256 longTokenId, uint256 shortTokenId) = _test_writeFrom_Success();

        vm.warp(maturity);
        setPriceAt(maturity, data.settlementITM);

        UD60x18 _strike = data.discount * data.spot;
        UD60x18 _size = ud(size);

        vm.startPrank(users.longReceiver);
        UD60x18 _exerciseCost = _size * _strike;
        uint256 exerciseCost = scaleDecimalsTo(quote, _exerciseCost);
        deal(quote, users.longReceiver, exerciseCost);

        assertEq(IERC20(quote).balanceOf(users.longReceiver), exerciseCost);

        IERC20(quote).approve(address(miningPool), exerciseCost);
        miningPool.exercise(longTokenId, _size);
        vm.stopPrank();

        assertEq(miningPool.balanceOf(users.longReceiver, longTokenId), 0);
        assertEq(miningPool.balanceOf(users.longReceiver, shortTokenId), 0);
        assertEq(miningPool.balanceOf(users.underwriter, shortTokenId), size);
        assertEq(miningPool.balanceOf(users.underwriter, longTokenId), 0);

        assertEq(IERC20(quote).balanceOf(users.longReceiver), 0);
        assertEq(IERC20(quote).balanceOf(users.underwriter), 0);

        {
            uint256 feeAmount = scaleDecimalsTo(quote, fee * _exerciseCost);
            assertEq(IERC20(quote).balanceOf(users.treasury), feeAmount);
            assertEq(IERC20(quote).balanceOf(vxPremia), exerciseCost - feeAmount);
            assertEq(IERC20(quote).balanceOf(address(paymentSplitter)), 0);
        }

        assertEq(IERC20(base).balanceOf(users.longReceiver), collateral);
        assertEq(IERC20(base).balanceOf(users.underwriter), 0);
        assertEq(IERC20(base).balanceOf(address(miningPool)), 0);
    }

    function test_exercise_PhysicallySettled_Success() public {
        _test_exercise_PhysicallySettled_Success();
    }

    function _test_exercise_CashSettled_Success() internal {
        (uint64 maturity, uint256 collateral, uint256 longTokenId, uint256 shortTokenId) = _test_writeFrom_Success();

        vm.warp(maturity);
        setPriceAt(maturity, data.settlementITM);

        {
            uint256 lockupStart = maturity + data.exerciseDuration;
            uint256 lockupEnd = lockupStart + data.lockupDuration;
            vm.warp(lockupEnd);
        }

        uint256 exerciseValue;
        {
            UD60x18 intrinsicValue = data.settlementITM - data.discount * data.spot;
            UD60x18 _exerciseValue = (ud(size) * intrinsicValue) / data.settlementITM;
            _exerciseValue = _exerciseValue * (ONE - data.penalty);
            exerciseValue = scaleDecimalsTo(base, _exerciseValue);
        }

        vm.prank(users.longReceiver);
        miningPool.exercise(longTokenId, ud(size));

        assertEq(miningPool.balanceOf(users.longReceiver, longTokenId), 0);
        assertEq(miningPool.balanceOf(users.longReceiver, shortTokenId), 0);
        assertEq(miningPool.balanceOf(users.underwriter, shortTokenId), size);
        assertEq(miningPool.balanceOf(users.underwriter, longTokenId), 0);

        assertEq(IERC20(quote).balanceOf(users.longReceiver), 0);
        assertEq(IERC20(quote).balanceOf(users.underwriter), 0);

        assertEq(IERC20(quote).balanceOf(vxPremia), 0);
        assertEq(IERC20(quote).balanceOf(users.treasury), 0);
        assertEq(IERC20(quote).balanceOf(address(paymentSplitter)), 0);

        assertEq(IERC20(base).balanceOf(users.longReceiver), exerciseValue);
        assertApproxEqAbs(IERC20(base).balanceOf(users.underwriter), collateral - exerciseValue, 1); // handles rounding error of 1 wei
        assertApproxEqAbs(IERC20(base).balanceOf(address(miningPool)), 0, 1); // handles rounding error of 1 wei
    }

    function test_exercise_CashSettled_Success() public {
        _test_exercise_CashSettled_Success();
    }

    function _test_exercise_RevertIf_TokenTypeNotLong() internal {
        uint64 maturity = uint64(getMaturity(block.timestamp, data.expiryDuration));

        UD60x18 strike = data.discount * data.spot;
        uint256 shortTokenId = miningPool.formatTokenId(IMiningPool.TokenType.SHORT, maturity, strike);

        vm.expectRevert(IMiningPool.MiningPool__TokenTypeNotLong.selector);
        vm.prank(users.longReceiver);
        miningPool.exercise(shortTokenId, ud(1000000e18));
    }

    function test_exercise_RevertIf_TokenTypeNotLong() public {
        _test_exercise_RevertIf_TokenTypeNotLong();
    }

    function _test_exercise_RevertIf_OptionNotExpired() internal {
        uint64 maturity = uint64(getMaturity(block.timestamp, data.expiryDuration));

        UD60x18 strike = data.discount * data.spot;
        uint256 longTokenId = miningPool.formatTokenId(IMiningPool.TokenType.LONG, maturity, strike);

        vm.expectRevert(abi.encodeWithSelector(IMiningPool.MiningPool__OptionNotExpired.selector, maturity));
        vm.warp(maturity - 1);
        vm.prank(users.longReceiver);
        miningPool.exercise(longTokenId, ud(1000000e18));
    }

    function test_exercise_RevertIf_OptionNotExpired() public {
        _test_exercise_RevertIf_OptionNotExpired();
    }

    function _test_exercise_RevertIf_OptionOutTheMoney() internal {
        (uint64 maturity, , uint256 longTokenId, ) = _test_writeFrom_Success();

        UD60x18 _strike = data.discount * data.spot;
        UD60x18 settlementOTM = _strike.sub(ud(1));

        vm.warp(maturity);
        setPriceAt(maturity, settlementOTM);

        vm.expectRevert(
            abi.encodeWithSelector(IMiningPool.MiningPool__OptionOutTheMoney.selector, settlementOTM, _strike)
        );

        vm.prank(users.longReceiver);
        miningPool.exercise(longTokenId, ud(size));
    }

    function test_exercise_RevertIf_OptionOutTheMoney() public {
        _test_exercise_RevertIf_OptionOutTheMoney();
    }

    function _test_exercise_RevertIf_LockupNotExpired() internal {
        (uint64 maturity, , uint256 longTokenId, ) = _test_writeFrom_Success();
        vm.warp(maturity);
        setPriceAt(maturity, data.settlementITM);

        uint256 lockupStart = maturity + data.exerciseDuration;
        uint256 lockupEnd = lockupStart + data.lockupDuration;

        vm.warp(lockupStart);

        vm.expectRevert(
            abi.encodeWithSelector(IMiningPool.MiningPool__LockupNotExpired.selector, lockupStart, lockupEnd)
        );

        vm.prank(users.longReceiver);
        miningPool.exercise(longTokenId, ud(size));
    }

    function test_exercise_RevertIf_LockupNotExpired() public {
        _test_exercise_RevertIf_LockupNotExpired();
    }

    function _test_settle_Success() internal {
        (uint64 maturity, uint256 collateral, uint256 longTokenId, uint256 shortTokenId) = _test_writeFrom_Success();

        UD60x18 _strike = data.discount * data.spot;
        UD60x18 settlementOTM = _strike.sub(ud(1));

        vm.warp(maturity);
        setPriceAt(maturity, settlementOTM);

        vm.prank(users.underwriter);
        miningPool.settle(shortTokenId, ud(size));

        assertEq(miningPool.balanceOf(users.longReceiver, longTokenId), size);
        assertEq(miningPool.balanceOf(users.longReceiver, shortTokenId), 0);
        assertEq(miningPool.balanceOf(users.underwriter, shortTokenId), 0);
        assertEq(miningPool.balanceOf(users.underwriter, longTokenId), 0);

        assertEq(IERC20(quote).balanceOf(users.longReceiver), 0);
        assertEq(IERC20(quote).balanceOf(users.underwriter), 0);

        assertEq(IERC20(quote).balanceOf(vxPremia), 0);
        assertEq(IERC20(quote).balanceOf(users.treasury), 0);

        assertEq(IERC20(base).balanceOf(users.longReceiver), 0);
        assertEq(IERC20(base).balanceOf(users.underwriter), collateral);
        assertEq(IERC20(base).balanceOf(address(miningPool)), 0);
    }

    function test_settle_Success() public {
        _test_settle_Success();
    }

    function _test_settle_RevertIf_TokenTypeNotShort() internal {
        uint64 maturity = uint64(getMaturity(block.timestamp, data.expiryDuration));

        UD60x18 strike = data.discount * data.spot;
        uint256 longTokenId = miningPool.formatTokenId(IMiningPool.TokenType.LONG, maturity, strike);

        vm.expectRevert(IMiningPool.MiningPool__TokenTypeNotShort.selector);

        vm.prank(users.underwriter);
        miningPool.settle(longTokenId, ud(1000000e18));
    }

    function test_settle_RevertIf_TokenTypeNotShort() public {
        _test_settle_RevertIf_TokenTypeNotShort();
    }

    function _test_settle_RevertIf_OptionNotExpired() internal {
        (uint64 maturity, , , uint256 shortTokenId) = _test_writeFrom_Success();
        vm.expectRevert(abi.encodeWithSelector(IMiningPool.MiningPool__OptionNotExpired.selector, maturity));
        vm.prank(users.underwriter);
        miningPool.settle(shortTokenId, ud(size));
    }

    function test_settle_RevertIf_OptionNotExpired() public {
        _test_settle_RevertIf_OptionNotExpired();
    }

    function _test_settle_RevertIf_OptionInTheMoney() internal {
        (uint64 maturity, , , uint256 shortTokenId) = _test_writeFrom_Success();
        vm.warp(maturity);
        setPriceAt(maturity, data.settlementITM);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMiningPool.MiningPool__OptionInTheMoney.selector,
                data.settlementITM,
                data.discount * data.spot
            )
        );

        vm.prank(users.underwriter);
        miningPool.settle(shortTokenId, ud(size));
    }

    function test_settle_RevertIf_OptionInTheMoney() public {
        _test_settle_RevertIf_OptionInTheMoney();
    }
}
