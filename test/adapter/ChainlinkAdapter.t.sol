// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";

import {UD60x18, ud} from "@prb/math/UD60x18.sol";
import {SD59x18, sd} from "@prb/math/SD59x18.sol";

import {IOwnableInternal} from "@solidstate/contracts/access/ownable/IOwnableInternal.sol";

import "../Addresses.sol";
import {Assertions} from "../Assertions.sol";
import {ONE} from "contracts/libraries/Constants.sol";
import {IFeedRegistry} from "contracts/adapter/IFeedRegistry.sol";
import {IOracleAdapter} from "contracts/adapter/IOracleAdapter.sol";
import {IChainlinkAdapter} from "contracts/adapter/chainlink/IChainlinkAdapter.sol";
import {ChainlinkAdapter} from "contracts/adapter/chainlink/ChainlinkAdapter.sol";
import {ProxyUpgradeableOwnable} from "contracts/proxy/ProxyUpgradeableOwnable.sol";
import {IRelayerAccessManager} from "contracts/relayer/IRelayerAccessManager.sol";

import {ERC20Mock} from "contracts/test/ERC20Mock.sol";
import {ChainlinkOraclePriceStub} from "contracts/test/adapter/ChainlinkOraclePriceStub.sol";

contract ChainlinkAdapterTest is Test, Assertions {
    struct Path {
        IChainlinkAdapter.PricingPath path;
        address tokenIn;
        address tokenOut;
    }

    uint256 mainnetFork;

    Path[] paths;
    ChainlinkAdapter adapter;
    uint256 target;

    ChainlinkOraclePriceStub stub;
    address stubCoin;

    address internal relayer;
    address internal user;

    function setUp() public {
        string memory ETH_RPC_URL = string.concat(
            "https://eth-mainnet.alchemyapi.io/v2/",
            vm.envString("API_KEY_ALCHEMY")
        );
        mainnetFork = vm.createFork(ETH_RPC_URL, 16597500);
        vm.selectFork(mainnetFork);

        target = 1676016000;

        // prettier-ignore
        {
            // ETH_USD
            paths.push(Path(IChainlinkAdapter.PricingPath.ETH_USD, WETH, CHAINLINK_USD));  // IN is ETH, OUT is USD
            paths.push(Path(IChainlinkAdapter.PricingPath.ETH_USD, CHAINLINK_USD, WETH)); // IN is USD, OUT is ETH
            paths.push(Path(IChainlinkAdapter.PricingPath.ETH_USD, CHAINLINK_ETH, CHAINLINK_USD)); // IN is ETH, OUT is USD

            // TOKEN_USD
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD, DAI, CHAINLINK_USD)); // IN (tokenA) => OUT (tokenB) is USD
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD, AAVE, CHAINLINK_USD)); // IN (tokenA) => OUT (tokenB) is USD
            // Note: Assumes WBTC/USD feed exists
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD, CHAINLINK_USD, WBTC)); // IN (tokenB) is USD => OUT (tokenA)
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD, WBTC, CHAINLINK_USD)); // IN (tokenA) => OUT (tokenB) is USD

            // TOKEN_ETH
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_ETH, BNT, WETH)); // IN (tokenA) => OUT (tokenB) is ETH
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_ETH, AXS, WETH)); // IN (tokenB) => OUT (tokenA) is ETH
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_ETH, WETH, CRV)); // IN (tokenA) is ETH => OUT (tokenB)

            // TOKEN_USD_TOKEN
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_TOKEN, CRV, AAVE)); // IN (tokenB) => USD => OUT (tokenA)
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_TOKEN, DAI, AAVE)); // IN (tokenA) => USD => OUT (tokenB)
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_TOKEN, AAVE, DAI)); // IN (tokenB) => USD => OUT (tokenA)
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_TOKEN, CRV, USDC)); // IN (tokenB) => USD => OUT (tokenA)
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_TOKEN, USDC, COMP)); // IN (tokenA) => USD => OUT (tokenB)
            // Note: Assumes WBTC/USD feed exists
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_TOKEN, DAI, WBTC)); // IN (tokenB) => USD => OUT (tokenA)
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_TOKEN, WBTC, USDC)); // IN (tokenA) => USD => OUT (tokenB)

            // TOKEN_ETH_TOKEN
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_ETH_TOKEN, BOND, AXS)); // IN (tokenA) => ETH => OUT (tokenB)
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_ETH_TOKEN, ALPHA, BOND)); // IN (tokenB) => ETH => OUT (tokenA)

            // A_USD_ETH_B
            paths.push(Path(IChainlinkAdapter.PricingPath.A_USD_ETH_B, FXS, WETH)); // IN (tokenA) => USD, OUT (tokenB) is ETH
            paths.push(Path(IChainlinkAdapter.PricingPath.A_USD_ETH_B, WETH, MATIC)); // IN (tokenB) is ETH, USD => OUT (tokenA)
            paths.push(Path(IChainlinkAdapter.PricingPath.A_USD_ETH_B, USDC, AXS)); // IN (tokenA) is USD, ETH => OUT (tokenB)
            paths.push(Path(IChainlinkAdapter.PricingPath.A_USD_ETH_B, ALPHA, DAI)); // IN (tokenB) => ETH, OUT is USD (tokenA)
            paths.push(Path(IChainlinkAdapter.PricingPath.A_USD_ETH_B, DAI, ALPHA));
            paths.push(Path(IChainlinkAdapter.PricingPath.A_USD_ETH_B, FXS, AXS)); // IN (tokenA) => USD, ETH => OUT (tokenB)
            paths.push(Path(IChainlinkAdapter.PricingPath.A_USD_ETH_B, ALPHA, MATIC)); // IN (tokenB) => ETH, USD => OUT (tokenA)
            // Note: Assumes WBTC/USD feed exists
            paths.push(Path(IChainlinkAdapter.PricingPath.A_USD_ETH_B, WETH, WBTC)); // IN (tokenB) => ETH, USD => OUT (tokenA)

            // A_ETH_USD_B
            // We can't test the following two cases, because we would need a token that is
            // supported by chainlink and lower than USD (address(840))
            // - IN (tokenA) => ETH, OUT (tokenB) is USD
            // - IN (tokenB) is USD, ETH => OUT (tokenA)
            paths.push(Path(IChainlinkAdapter.PricingPath.A_ETH_USD_B, WETH, IMX)); // IN (tokenA) is ETH, USD => OUT (tokenB)
            paths.push(Path(IChainlinkAdapter.PricingPath.A_ETH_USD_B, IMX, WETH)); // IN (tokenB) => USD, OUT is ETH (tokenA)
            paths.push(Path(IChainlinkAdapter.PricingPath.A_ETH_USD_B, AXS, IMX)); // IN (tokenA) => ETH, USD => OUT (tokenB)
            paths.push(Path(IChainlinkAdapter.PricingPath.A_ETH_USD_B, FXS, BOND)); // IN (tokenB) => ETH, USD => OUT (tokenA)
            paths.push(Path(IChainlinkAdapter.PricingPath.A_ETH_USD_B, BOND, FXS)); // IN (tokenA) => USD, ETH => OUT (tokenB)

            // TOKEN_USD_BTC_WBTC
            // Note: Assumes WBTC/USD feed does not exist
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_BTC_WBTC, WBTC, CHAINLINK_USD)); // IN (tokenA) => BTC, OUT is USD
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_BTC_WBTC, WBTC, CHAINLINK_BTC)); // IN (tokenA) => BTC, OUT is BTC
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_BTC_WBTC, WBTC, WETH)); // IN (tokenA) => BTC, OUT is ETH (tokenB)
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_BTC_WBTC, WETH, WBTC)); // IN (tokenB) is ETH, BTC => OUT (tokenA)
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_BTC_WBTC, DAI, WBTC)); // IN (tokenB) => USD, BTC => OUT (tokenA)
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_BTC_WBTC, WBTC, USDC)); // IN (tokenA) => BTC, USD => OUT (tokenB)
            paths.push(Path(IChainlinkAdapter.PricingPath.TOKEN_USD_BTC_WBTC, WBTC, BNT)); // IN (tokenA) => USD,  BTC => OUT (tokenB)
        }

        address implementation = address(new ChainlinkAdapter(WETH, WBTC));
        address proxy = address(new ProxyUpgradeableOwnable(implementation));
        adapter = ChainlinkAdapter(proxy);

        adapter.batchRegisterFeedMappings(feeds());
        _deployStub();

        relayer = vm.addr(1);
        user = vm.addr(2);

        address[] memory relayers = new address[](1);
        relayers[0] = relayer;
        adapter.addWhitelistedRelayers(relayers);
    }

    function _deployStub() internal {
        stub = new ChainlinkOraclePriceStub();
        stubCoin = address(100);

        IFeedRegistry.FeedMappingArgs[] memory data = new IFeedRegistry.FeedMappingArgs[](2);
        data[0] = IFeedRegistry.FeedMappingArgs(stubCoin, CHAINLINK_USD, address(stub));
        data[1] = IFeedRegistry.FeedMappingArgs(stubCoin, CHAINLINK_ETH, address(stub));

        adapter.batchRegisterFeedMappings(data);
        adapter.upsertPair(stubCoin, CHAINLINK_USD);
        adapter.upsertPair(stubCoin, CHAINLINK_ETH);
    }

    function _addWBTCUSD(IChainlinkAdapter.PricingPath path) internal {
        if (
            path != IChainlinkAdapter.PricingPath.TOKEN_USD &&
            path != IChainlinkAdapter.PricingPath.TOKEN_USD_TOKEN &&
            path != IChainlinkAdapter.PricingPath.A_USD_ETH_B
        ) return;

        IFeedRegistry.FeedMappingArgs[] memory data = new IFeedRegistry.FeedMappingArgs[](1);

        data[0] = IFeedRegistry.FeedMappingArgs(WBTC, CHAINLINK_USD, 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c);

        adapter.batchRegisterFeedMappings(data);
    }

    function test_isPairSupported_ReturnTrue_IfPairCachedAndPathExists() public {
        uint256 snapshot = vm.snapshot();

        for (uint256 i = 0; i < paths.length; i++) {
            Path memory p = paths[i];

            _addWBTCUSD(p.path);

            adapter.upsertPair(p.tokenIn, p.tokenOut);

            (bool isCached, bool hasPath) = adapter.isPairSupported(p.tokenIn, p.tokenOut);
            assertTrue(isCached);
            assertTrue(hasPath);

            vm.revertTo(snapshot);
            snapshot = vm.snapshot();
        }
    }

    function test_isPairSupported_ReturnFalse_IfPairNotSupported() public {
        (bool isCached, ) = adapter.isPairSupported(WETH, DAI);
        assertFalse(isCached);
    }

    function test_isPairSupported_ReturnFalse_IfPathDoesNotExist() public {
        (, bool hasPath) = adapter.isPairSupported(WETH, WBTC);
        assertTrue(hasPath);
    }

    function test_isPairSupported_RevertIf_TokensAreSame() public {
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.OracleAdapter__TokensAreSame.selector, CRV, CRV));
        adapter.isPairSupported(CRV, CRV);
    }

    function test_isPairSupported_RevertIf_ZeroAddress() public {
        vm.expectRevert(IOracleAdapter.OracleAdapter__ZeroAddress.selector);
        adapter.isPairSupported(address(0), DAI);

        vm.expectRevert(IOracleAdapter.OracleAdapter__ZeroAddress.selector);
        adapter.isPairSupported(CRV, address(0));
    }

    function test_upsertPair_ShouldNotRevert_IfCalledMultipleTime_ForSamePair() public {
        adapter.upsertPair(WETH, DAI);
        (bool isCached, ) = adapter.isPairSupported(WETH, DAI);
        assertTrue(isCached);

        adapter.upsertPair(WETH, DAI);
    }

    function test_upsertPair_RevertIf_PairCannotBeSupported() public {
        vm.expectRevert(
            abi.encodeWithSelector(IOracleAdapter.OracleAdapter__PairCannotBeSupported.selector, address(1), WETH)
        );
        adapter.upsertPair(address(1), WETH);

        vm.expectRevert(
            abi.encodeWithSelector(IOracleAdapter.OracleAdapter__PairCannotBeSupported.selector, WBTC, address(1))
        );
        adapter.upsertPair(WBTC, address(1));
    }

    function test_upsertPair_RevertIf_TokensAreSame() public {
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.OracleAdapter__TokensAreSame.selector, CRV, CRV));
        adapter.upsertPair(CRV, CRV);
    }

    function test_upsertPair_RevertIf_ZeroAddress() public {
        vm.expectRevert(IOracleAdapter.OracleAdapter__ZeroAddress.selector);
        adapter.upsertPair(address(0), DAI);

        vm.expectRevert(IOracleAdapter.OracleAdapter__ZeroAddress.selector);
        adapter.upsertPair(CRV, address(0));
    }

    function test_batchRegisterFeedMappings_RemoveFeed() public {
        adapter.upsertPair(YFI, DAI);
        adapter.upsertPair(USDC, YFI);

        assertTrue(adapter.pricingPath(YFI, DAI) == IChainlinkAdapter.PricingPath.TOKEN_USD_TOKEN);
        assertTrue(adapter.pricingPath(USDC, YFI) == IChainlinkAdapter.PricingPath.TOKEN_USD_TOKEN);

        {
            UD60x18 quote = adapter.getPrice(YFI, DAI);
            assertGt(quote.unwrap(), 0);
        }

        {
            UD60x18 quote = adapter.getPrice(USDC, YFI);
            assertGt(quote.unwrap(), 0);
        }

        {
            (bool isCached, bool hasPath) = adapter.isPairSupported(YFI, DAI);
            assertTrue(isCached);
            assertTrue(hasPath);
        }

        {
            (bool isCached, bool hasPath) = adapter.isPairSupported(USDC, YFI);
            assertTrue(isCached);
            assertTrue(hasPath);
        }

        {
            (IOracleAdapter.AdapterType adapterType, address[][] memory path, uint8[] memory decimals) = adapter
                .describePricingPath(YFI);

            assertEq(uint256(adapterType), uint256(IOracleAdapter.AdapterType.Chainlink));
            assertEq(path.length, 2);
            assertEq(path[0][0], 0x8a4D74003870064d41D4f84940550911FBfCcF04);
            assertEq(path[1][0], 0x37bC7498f4FF12C19678ee8fE19d713b87F6a9e6);
            assertEq(decimals.length, 2);
            assertEq(decimals[0], 8);
            assertEq(decimals[1], 8);
        }

        IFeedRegistry.FeedMappingArgs[] memory data = new IFeedRegistry.FeedMappingArgs[](1);
        data[0] = IFeedRegistry.FeedMappingArgs(YFI, CHAINLINK_USD, address(0));
        adapter.batchRegisterFeedMappings(data);

        vm.expectRevert();
        adapter.upsertPair(YFI, DAI);

        vm.expectRevert();
        adapter.upsertPair(USDC, YFI);

        assertTrue(adapter.pricingPath(YFI, DAI) == IChainlinkAdapter.PricingPath.NONE);
        assertTrue(adapter.pricingPath(USDC, YFI) == IChainlinkAdapter.PricingPath.NONE);

        vm.expectRevert();
        adapter.getPrice(YFI, DAI);

        vm.expectRevert();
        adapter.getPrice(USDC, YFI);

        {
            (bool isCached, bool hasPath) = adapter.isPairSupported(YFI, DAI);
            assertFalse(isCached);
            assertFalse(hasPath);
        }

        {
            (bool isCached, bool hasPath) = adapter.isPairSupported(USDC, YFI);
            assertFalse(isCached);
            assertFalse(hasPath);
        }

        {
            (IOracleAdapter.AdapterType adapterType, address[][] memory path, uint8[] memory decimals) = adapter
                .describePricingPath(YFI);

            assertEq(uint256(adapterType), uint256(IOracleAdapter.AdapterType.Chainlink));
            assertEq(path.length, 0);
            assertEq(decimals.length, 0);
        }
    }

    function test_batchRegisterFeedMappings_RevertIf_TokensAreSame() public {
        IFeedRegistry.FeedMappingArgs[] memory data = new IFeedRegistry.FeedMappingArgs[](1);
        data[0] = IFeedRegistry.FeedMappingArgs(EUL, EUL, address(1));

        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.OracleAdapter__TokensAreSame.selector, EUL, EUL));
        adapter.batchRegisterFeedMappings(data);
    }

    function test_batchRegisterFeedMappings_RevertIf_ZeroAddress() public {
        IFeedRegistry.FeedMappingArgs[] memory data = new IFeedRegistry.FeedMappingArgs[](1);

        data[0] = IFeedRegistry.FeedMappingArgs(address(0), DAI, address(1));
        vm.expectRevert(IOracleAdapter.OracleAdapter__ZeroAddress.selector);
        adapter.batchRegisterFeedMappings(data);

        data[0] = IFeedRegistry.FeedMappingArgs(EUL, address(0), address(1));
        vm.expectRevert(IOracleAdapter.OracleAdapter__ZeroAddress.selector);
        adapter.batchRegisterFeedMappings(data);
    }

    function test_batchRegisterFeedMappings_RevertIf_InvalidDenomination() public {
        IFeedRegistry.FeedMappingArgs[] memory data = new IFeedRegistry.FeedMappingArgs[](1);
        data[0] = IFeedRegistry.FeedMappingArgs(WETH, CRV, address(1));
        vm.expectRevert(abi.encodeWithSelector(IChainlinkAdapter.ChainlinkAdapter__InvalidDenomination.selector, CRV));
        adapter.batchRegisterFeedMappings(data);
    }

    function test_batchRegisterFeedMappings_RevertIf_NotOwner() public {
        IFeedRegistry.FeedMappingArgs[] memory data = new IFeedRegistry.FeedMappingArgs[](1);
        data[0] = IFeedRegistry.FeedMappingArgs(DAI, CHAINLINK_USD, address(0));
        vm.expectRevert(IOwnableInternal.Ownable__NotOwner.selector);
        vm.prank(user);
        adapter.batchRegisterFeedMappings(data);
    }

    function test_feed_ReturnFeed() public {
        IFeedRegistry.FeedMappingArgs[] memory _feeds = feeds();

        for (uint256 i = 0; i < _feeds.length; i++) {
            assertEq(adapter.feed(_feeds[i].token, _feeds[i].denomination), _feeds[i].feed);
        }
    }

    function test_feed_ReturnZeroAddress_IfFeedDoesNotExist() public {
        assertEq(adapter.feed(EUL, DAI), address(0));
    }

    function test_getPrice_ReturnPriceForPair() public {
        // Expected price values provided by DeFiLlama API (https://coins.llama.fi)
        uint80[39] memory expected = [
            1551253958184865268777, // WETH CHAINLINK_USD
            644639773341889, // CHAINLINK_USD WETH
            1552089999999999918145, // CHAINLINK_ETH CHAINLINK_USD
            999758000000000036, // DAI CHAINLINK_USD
            79200000000000002842, // AAVE CHAINLINK_USD
            45722646426775, // CHAINLINK_USD WBTC
            21871000000000000000000, // WBTC CHAINLINK_USD
            282273493583309, // BNT WETH
            6617057201666803, // AXS WETH
            1570958490531603047202, // WETH CRV
            12467891414141414, // CRV AAVE
            12623207070707071, // DAI AAVE
            79219171039391525824, // AAVE DAI
            987652555205930871, // CRV USDC
            20230716309186565, // USDC COMP
            45711581546340, // DAI WBTC
            21875331315600487869233, // WBTC USDC
            410573778449028981, // BOND AXS
            28582048972903472, // ALPHA BOND
            7725626669884812, // FXS WETH
            1202522448205321779824, // WETH MATIC
            97446588693957115, // USDC AXS
            120430653003309712, // ALPHA DAI
            8303533818524737597, // DAI ALPHA
            1168071047867190515, // FXS AXS
            93334502934327837, // ALPHA MATIC
            70927436248222092, // WETH WBTC
            1701565115821158997278, // WETH IMX
            587694229684187, // IMX WETH
            11254158609047422601, // AXS IMX
            2844972351326624072, // FXS BOND
            351497264827088818, // BOND FXS
            21871000000000000000000, // WBTC CHAINLINK_USD
            999177669148887615, // WBTC CHAINLINK_BTC
            14098916482760458280, // WBTC WETH
            70927436248222092, // WETH WBTC
            45711581546340, // DAI WBTC
            21875331315600487869233, // WBTC USDC
            49947716676413132518064 // WBTC BNT
        ];

        uint256 snapshot = vm.snapshot();

        for (uint256 i = 0; i < paths.length; i++) {
            Path memory p = paths[i];
            _addWBTCUSD(p.path);
            adapter.upsertPair(p.tokenIn, p.tokenOut);

            UD60x18 price = adapter.getPrice(p.tokenIn, p.tokenOut);

            assertApproxEqAbs(
                price.unwrap(),
                expected[i],
                (expected[i] * 3) / 100 // 3% tolerance
            );

            vm.revertTo(snapshot);
            snapshot = vm.snapshot();
        }
    }

    function test_getPrice_Return1e18ForPairWithSameFeed() public {
        // tokenIn > tokenOut, tokenIn == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
        address testWETH = address(new ERC20Mock("testWETH", 18));

        IFeedRegistry.FeedMappingArgs[] memory feedMapping = new IFeedRegistry.FeedMappingArgs[](1);

        feedMapping[0] = IFeedRegistry.FeedMappingArgs(
            testWETH,
            CHAINLINK_USD,
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 // Same feed as WETH/USD
        );

        adapter.batchRegisterFeedMappings(feedMapping);
        assertEq(adapter.getPrice(WETH, testWETH), ud(1e18));
        assertEq(adapter.getPrice(testWETH, WETH), ud(1e18));
    }

    function test_getPrice_ReturnPriceUsingCorrectDenomination() public {
        address tokenIn = WETH;
        address tokenOut = DAI;

        adapter.upsertPair(tokenIn, tokenOut);

        UD60x18 price = adapter.getPrice(tokenIn, tokenOut);
        UD60x18 invertedPrice = adapter.getPrice(tokenOut, tokenIn);

        assertEq(price, ud(1e18) / invertedPrice);

        //

        tokenIn = CRV;
        tokenOut = AAVE;

        adapter.upsertPair(tokenIn, tokenOut);

        price = adapter.getPrice(tokenIn, tokenOut);
        invertedPrice = adapter.getPrice(tokenOut, tokenIn);

        assertEq(price, ud(1e18) / invertedPrice);
    }

    function test_getPrice_ReturnCorrectPrice_IfPathExistsButNotCached() public {
        UD60x18 priceBeforeUpsert = adapter.getPrice(WETH, DAI);

        adapter.upsertPair(WETH, DAI);
        UD60x18 price = adapter.getPrice(WETH, DAI);

        assertEq(price, priceBeforeUpsert);
    }

    function test_getPrice_RevertIf_InvalidPrice() public {
        adapter.upsertPair(stubCoin, CHAINLINK_USD);

        int256[] memory prices = new int256[](1);
        uint256[] memory timestamps = new uint256[](1);

        prices[0] = 0;
        timestamps[0] = block.timestamp;

        stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);

        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.OracleAdapter__InvalidPrice.selector, prices[0]));
        adapter.getPrice(stubCoin, CHAINLINK_USD);
    }

    function test_getPrice_RevertIf_PriceLeftOfTargetStale() public {
        adapter.upsertPair(stubCoin, CHAINLINK_USD);

        int256[] memory prices = new int256[](1);
        uint256[] memory timestamps = new uint256[](1);

        prices[0] = 100000000000;
        timestamps[0] = block.timestamp - 25 hours;

        stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);

        assertEq(adapter.getPrice(stubCoin, CHAINLINK_USD), ud(uint256(prices[0]) * 1e10));
        vm.warp(block.timestamp + 1 seconds);

        vm.expectRevert(
            abi.encodeWithSelector(
                IChainlinkAdapter.ChainlinkAdapter__PriceLeftOfTargetStale.selector,
                timestamps[0],
                block.timestamp
            )
        );

        adapter.getPrice(stubCoin, CHAINLINK_USD);
    }

    function test_getPrice_RevertIf_PairNotSupported() public {
        vm.expectRevert(
            abi.encodeWithSelector(IOracleAdapter.OracleAdapter__PairNotSupported.selector, WETH, address(1))
        );
        adapter.getPrice(WETH, address(1));
    }

    function test_getPrice_RevertIf_TokensAreSame() public {
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.OracleAdapter__TokensAreSame.selector, CRV, CRV));
        adapter.getPrice(CRV, CRV);
    }

    function test_getPrice_RevertIf_ZeroAddress() public {
        vm.expectRevert(IOracleAdapter.OracleAdapter__ZeroAddress.selector);
        adapter.getPrice(address(0), DAI);

        vm.expectRevert(IOracleAdapter.OracleAdapter__ZeroAddress.selector);
        adapter.getPrice(CRV, address(0));
    }

    function test_getPrice_CatchRevert() public {
        int256[] memory prices = new int256[](1);
        uint256[] memory timestamps = new uint256[](1);

        prices[0] = 100000000000;
        timestamps[0] = target - 90000;

        stub.setup(ChainlinkOraclePriceStub.FailureMode.LastRoundDataRevertWithReason, prices, timestamps);

        vm.expectRevert("reverted with reason");
        adapter.getPrice(stubCoin, CHAINLINK_USD);

        //

        stub.setup(ChainlinkOraclePriceStub.FailureMode.LastRoundDataRevert, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(IChainlinkAdapter.ChainlinkAdapter__LatestRoundDataCallReverted.selector, "")
        );
        adapter.getPrice(stubCoin, CHAINLINK_USD);
    }

    function test_getPriceAt_ReturnPriceForPairFromTarget() public {
        // Expected price values provided by DeFiLlama API (https://coins.llama.fi)
        uint80[39] memory expected = [
            1552329999999999927240, // WETH CHAINLINK_USD
            644192922896549, // CHAINLINK_USD WETH
            1553210000000000036380, // CHAINLINK_ETH CHAINLINK_USD
            1000999999999999890, // DAI CHAINLINK_USD
            79620000000000004547, // AAVE CHAINLINK_USD
            45583006655119, // CHAINLINK_USD WBTC
            21938000000000000000000, // WBTC CHAINLINK_USD
            282841277305728, // BNT WETH
            6609419388918594, // AXS WETH
            1560637272199920062121, // WETH CRV
            12492803315749812, // CRV AAVE
            12572218035669427, // DAI AAVE
            79540459540459551135, // AAVE DAI
            992691616766467111, // CRV USDC
            20242424242424242, // USDC COMP
            45628589661774, // DAI WBTC
            21894211576846308162203, // WBTC USDC
            413255360623781709, // BOND AXS
            28558726415094340, // ALPHA BOND
            7930014880856519, // FXS WETH
            1232007936507936392445, // WETH MATIC
            97660818713450295, // USDC AXS
            120968031968031978, // ALPHA DAI
            8266646846534365878, // DAI ALPHA
            1199805068226120985, // FXS AXS
            96102380952380953, // ALPHA MATIC
            70759868720940824, // WETH WBTC
            1732435753354485541422, // WETH IMX
            577221982439301, // IMX WETH
            11450394458276926812, // AXS IMX
            2903301886792452713, // FXS BOND
            344435418359057666, // BOND FXS
            21938000000000000000000, // WBTC CHAINLINK_USD
            999225688909132326, // WBTC CHAINLINK_BTC
            14132304342504493633, // WBTC WETH
            70759868720940824, // WETH WBTC
            45628589661774, // DAI WBTC
            21894211576846308162203, // WBTC USDC
            49965494701215997338295 // WBTC BNT
        ];

        uint256 snapshot = vm.snapshot();

        for (uint256 i = 0; i < paths.length; i++) {
            Path memory p = paths[i];
            _addWBTCUSD(p.path);
            adapter.upsertPair(p.tokenIn, p.tokenOut);

            UD60x18 price = adapter.getPriceAt(p.tokenIn, p.tokenOut, target);

            assertApproxEqAbs(
                price.unwrap(),
                expected[i],
                (expected[i] * 3) / 100 // 3% tolerance
            );

            vm.revertTo(snapshot);
            snapshot = vm.snapshot();
        }
    }

    function test_getPriceAt_Return1e18ForPairWithSameFeed() public {
        // tokenIn > tokenOut, tokenIn == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
        address testWETH = address(new ERC20Mock("testWETH", 18));

        IFeedRegistry.FeedMappingArgs[] memory feedMapping = new IFeedRegistry.FeedMappingArgs[](1);

        feedMapping[0] = IFeedRegistry.FeedMappingArgs(
            testWETH,
            CHAINLINK_USD,
            0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419 // Same feed as WETH/USD
        );

        adapter.batchRegisterFeedMappings(feedMapping);
        assertEq(adapter.getPriceAt(WETH, testWETH, target), ud(1e18));
        assertEq(adapter.getPriceAt(testWETH, WETH, target), ud(1e18));
    }

    function test_getPriceAt_CatchRevert() public {
        adapter.upsertPair(stubCoin, CHAINLINK_USD);

        int256[] memory prices = new int256[](3);
        uint256[] memory timestamps = new uint256[](3);

        prices[0] = 100000000000;
        prices[1] = 100000000000;
        prices[2] = 100000000000;

        timestamps[0] = target + 3;
        timestamps[1] = target + 2;
        timestamps[2] = target + 1;

        stub.setup(ChainlinkOraclePriceStub.FailureMode.GetRoundDataRevertWithReason, prices, timestamps);

        vm.expectRevert("reverted with reason");
        adapter.getPriceAt(stubCoin, CHAINLINK_USD, target);

        //

        stub.setup(ChainlinkOraclePriceStub.FailureMode.GetRoundDataRevert, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(IChainlinkAdapter.ChainlinkAdapter__GetRoundDataCallReverted.selector, "")
        );
        adapter.getPriceAt(stubCoin, CHAINLINK_USD, target);
    }

    function test_getPriceAt_RevertIf_TargetIsZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(IOracleAdapter.OracleAdapter__InvalidTarget.selector, 0, block.timestamp)
        );
        adapter.getPriceAt(WETH, DAI, 0);
    }

    function test_getPriceAt_RevertIf_TargetGtBlockTimestamp() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IOracleAdapter.OracleAdapter__InvalidTarget.selector,
                block.timestamp + 1,
                block.timestamp
            )
        );
        adapter.getPriceAt(WETH, DAI, block.timestamp + 1);
    }

    function test_getPriceAt_ReturnsLeftOfTarget() public {
        {
            int256[] memory prices = new int256[](4);
            prices[0] = 0;
            prices[1] = 5000000000;
            prices[2] = 10000000000;
            prices[3] = 50000000000;

            // left and right of target are equidistant from target but the left side is returned
            uint256[] memory timestamps = new uint256[](4);
            timestamps[0] = 0;
            timestamps[1] = target - 10;
            timestamps[2] = target + 10;
            timestamps[3] = target + 50;

            stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);
            int256 freshPrice = stub.price(1);
            assertEq(adapter.getPriceAt(stubCoin, CHAINLINK_USD, target), ud(uint256(freshPrice) * 1e10));
        }

        {
            int256[] memory prices = new int256[](4);
            prices[0] = 0;
            prices[1] = 5000000000;
            prices[2] = 10000000000;
            prices[3] = 50000000000;

            // left of target is further from target than right, but the left side is returned
            uint256[] memory timestamps = new uint256[](4);
            timestamps[0] = 0;
            timestamps[1] = target - 20;
            timestamps[2] = target + 10;
            timestamps[3] = target + 50;

            stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);
            int256 freshPrice = stub.price(1);
            assertEq(adapter.getPriceAt(stubCoin, CHAINLINK_USD, target), ud(uint256(freshPrice) * 1e10));
        }
    }

    function test_getPriceAt_UpdatedAtEqTarget() public {
        {
            // target == updatedAt at AggregatorRoundId = 1
            int256[] memory prices = new int256[](5);
            prices[0] = 0;
            prices[1] = 100000000000;
            prices[2] = 200000000000;
            prices[3] = 300000000000;
            prices[4] = 400000000000;

            uint256[] memory timestamps = new uint256[](5);
            timestamps[0] = 0;
            timestamps[1] = target;
            timestamps[2] = target + 200;
            timestamps[3] = target + 300;
            timestamps[4] = target + 400;

            stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);
            int256 freshPrice = stub.price(1);
            assertEq(adapter.getPriceAt(stubCoin, CHAINLINK_USD, target), ud(uint256(freshPrice) * 1e10));
        }

        {
            // target == updatedAt at AggregatorRoundId = 2
            int256[] memory prices = new int256[](5);
            prices[0] = 0;
            prices[1] = 50000000000;
            prices[2] = 100000000000;
            prices[3] = 200000000000;
            prices[4] = 300000000000;

            uint256[] memory timestamps = new uint256[](5);
            timestamps[0] = 0;
            timestamps[1] = target - 100;
            timestamps[2] = target;
            timestamps[3] = target + 100;
            timestamps[4] = target + 200;

            stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);
            int256 freshPrice = stub.price(2);
            assertEq(adapter.getPriceAt(stubCoin, CHAINLINK_USD, target), ud(uint256(freshPrice) * 1e10));
        }
    }

    function test_getPriceAt_HandleAggregatorRoundIdEq1() public {
        {
            // closest round update is left of target
            int256[] memory prices = new int256[](5);
            prices[0] = 0;
            prices[1] = 50000000000;
            prices[2] = 100000000000;
            prices[3] = 200000000000;
            prices[4] = 300000000000;

            uint256[] memory timestamps = new uint256[](5);
            timestamps[0] = 0;
            timestamps[1] = target - 50;
            timestamps[2] = target + 100;
            timestamps[3] = target + 200;
            timestamps[4] = target + 300;

            stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);
            int256 freshPrice = stub.price(1);
            assertEq(adapter.getPriceAt(stubCoin, CHAINLINK_USD, target), ud(uint256(freshPrice) * 1e10));
        }

        {
            // closest round update is right of target we always return price left of target unless the left price is stale
            int256[] memory prices = new int256[](5);
            prices[0] = 0;
            prices[1] = 50000000000;
            prices[2] = 100000000000;
            prices[3] = 200000000000;
            prices[4] = 300000000000;

            uint256[] memory timestamps = new uint256[](5);
            timestamps[0] = 0;
            timestamps[1] = target - 100;
            timestamps[2] = target + 50;
            timestamps[3] = target + 300;
            timestamps[4] = target + 500;

            stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);
            int256 freshPrice = stub.price(1);
            assertEq(adapter.getPriceAt(stubCoin, CHAINLINK_USD, target), ud(uint256(freshPrice) * 1e10));
        }
    }

    function test_getPriceAt_ReturnsClosestPriceLeftOfTarget() public {
        // feed only has prices left of target, adapter returns price closest to target
        int256[] memory prices = new int256[](3);
        prices[0] = 0;
        prices[1] = 50000000000;
        prices[2] = 100000000000;

        uint256[] memory timestamps = new uint256[](3);
        timestamps[0] = 0;
        timestamps[1] = target - 100;
        timestamps[2] = target - 50;

        stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);
        int256 freshPrice = stub.price(2);
        assertEq(adapter.getPriceAt(stubCoin, CHAINLINK_USD, target), ud(uint256(freshPrice) * 1e10));
    }

    function test_getPriceAt_ChecksLeftAndRightOfTarget() public {
        int256[] memory prices = new int256[](7);
        prices[0] = 0;
        prices[1] = 50000000000;
        prices[2] = 100000000000;
        prices[3] = 200000000000;
        prices[4] = 300000000000;
        prices[5] = 400000000000;
        prices[6] = 500000000000;

        uint256[] memory timestamps = new uint256[](7);
        timestamps[0] = 0;
        timestamps[1] = target - 500;
        timestamps[2] = target - 100;
        timestamps[3] = target - 50; // second improvement
        timestamps[4] = target - 10; // first improvement (closest)
        timestamps[5] = target + 100;
        timestamps[6] = target + 500;

        stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);
        int256 freshPrice = stub.price(4);
        assertEq(adapter.getPriceAt(stubCoin, CHAINLINK_USD, target), ud(uint256(freshPrice) * 1e10));
    }

    function test_getPriceAt_ReturnPriceOverrideAtTarget() public {
        UD60x18 priceOverride = ud(9e18);

        address[] memory relayers = new address[](1);
        relayers[0] = relayer;

        adapter.addWhitelistedRelayers(relayers);

        vm.startPrank(relayer);
        adapter.setTokenPriceAt(stubCoin, CHAINLINK_USD, target, priceOverride);
        adapter.setTokenPriceAt(stubCoin, CHAINLINK_ETH, target, priceOverride);
        vm.stopPrank();

        int256[] memory prices = new int256[](7);
        prices[0] = 0;
        prices[1] = 50000000000;
        prices[2] = 100000000000;
        prices[3] = 200000000000;
        prices[4] = 300000000000;
        prices[5] = 400000000000;
        prices[6] = 500000000000;

        uint256[] memory timestamps = new uint256[](7);
        timestamps[0] = 0;
        timestamps[1] = target - 500;
        timestamps[2] = target - 100;
        timestamps[3] = target - 50;
        timestamps[4] = target;
        timestamps[5] = target + 100;
        timestamps[6] = target + 500;

        stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);

        // decimals == 8, internal logic should scale the price override (18 decimals) to feed decimals (8 decimals)
        assertEq(adapter.getPriceAt(stubCoin, CHAINLINK_USD, target), priceOverride);

        // decimals == 18, no scaling necessary
        assertEq(adapter.getPriceAt(stubCoin, CHAINLINK_ETH, target), priceOverride);
    }

    function test_getPriceAt_RevertIf_PriceAtOrLeftOfTargetNotFound() public {
        // price at or to left of target is not found
        int256[] memory prices = new int256[](4);
        prices[0] = 0;
        prices[1] = 100000000000;
        prices[2] = 200000000000;
        prices[3] = 300000000000;

        uint256[] memory timestamps = new uint256[](4);
        timestamps[0] = 0;
        timestamps[1] = target + 50;
        timestamps[2] = target + 100;
        timestamps[3] = target + 200;

        stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);

        vm.expectRevert(
            abi.encodeWithSelector(
                IChainlinkAdapter.ChainlinkAdapter__PriceAtOrLeftOfTargetNotFound.selector,
                stubCoin,
                CHAINLINK_USD,
                target
            )
        );

        adapter.getPriceAt(stubCoin, CHAINLINK_USD, target);
    }

    function test_getPriceAt_RevertIf_InvalidPrice() public {
        int256[] memory prices = new int256[](4);
        prices[0] = 0;
        prices[1] = 0;
        prices[2] = 200000000000;
        prices[3] = 300000000000;

        uint256[] memory timestamps = new uint256[](4);
        timestamps[0] = 0;
        timestamps[1] = target;
        timestamps[2] = target + 100;
        timestamps[3] = target + 200;

        stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);

        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.OracleAdapter__InvalidPrice.selector, prices[1]));
        adapter.getPriceAt(stubCoin, CHAINLINK_USD, target);
    }

    function test_getPriceAt_RevertIf_PriceLeftOfTargetStale() public {
        {
            // left is stale and right does not exist
            int256[] memory prices = new int256[](4);
            prices[0] = 0;
            prices[1] = 100000000000;
            prices[2] = 200000000000;
            prices[3] = 300000000000;

            uint256[] memory timestamps = new uint256[](4);
            timestamps[0] = 0;
            timestamps[1] = target - 110000;
            timestamps[2] = target - 100000;
            timestamps[3] = target - 90001;

            stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);

            vm.expectRevert(
                abi.encodeWithSelector(
                    IChainlinkAdapter.ChainlinkAdapter__PriceLeftOfTargetStale.selector,
                    timestamps[3],
                    target
                )
            );

            adapter.getPriceAt(stubCoin, CHAINLINK_USD, target);
        }

        {
            // left is stale but right is closer to target
            int256[] memory prices = new int256[](5);
            prices[0] = 0;
            prices[1] = 100000000000;
            prices[2] = 200000000000;
            prices[3] = 300000000000;
            prices[4] = 400000000000;

            uint256[] memory timestamps = new uint256[](5);
            timestamps[0] = 0;
            timestamps[1] = target - 110000;
            timestamps[2] = target - 100000;
            timestamps[3] = target - 90001;
            timestamps[4] = target + 10;

            stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);

            vm.expectRevert(
                abi.encodeWithSelector(
                    IChainlinkAdapter.ChainlinkAdapter__PriceLeftOfTargetStale.selector,
                    timestamps[3],
                    target
                )
            );

            adapter.getPriceAt(stubCoin, CHAINLINK_USD, target);
        }

        {
            // left and right are both stale but right is closer to target
            int256[] memory prices = new int256[](5);
            prices[0] = 0;
            prices[1] = 100000000000;
            prices[2] = 200000000000;
            prices[3] = 300000000000;
            prices[4] = 400000000000;

            uint256[] memory timestamps = new uint256[](5);
            timestamps[0] = 0;
            timestamps[1] = target - 110000;
            timestamps[2] = target - 100000;
            timestamps[3] = target - 90002;
            timestamps[4] = target + 90001;

            stub.setup(ChainlinkOraclePriceStub.FailureMode.None, prices, timestamps);

            vm.expectRevert(
                abi.encodeWithSelector(
                    IChainlinkAdapter.ChainlinkAdapter__PriceLeftOfTargetStale.selector,
                    timestamps[3],
                    target
                )
            );

            adapter.getPriceAt(stubCoin, CHAINLINK_USD, target);
        }
    }

    function test_getPriceAt_RevertIf_PairNotSupported() public {
        vm.expectRevert(
            abi.encodeWithSelector(IOracleAdapter.OracleAdapter__PairNotSupported.selector, WETH, address(1))
        );
        adapter.getPriceAt(WETH, address(1), target);
    }

    function test_getPriceAt_RevertIf_TokensAreSame() public {
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.OracleAdapter__TokensAreSame.selector, CRV, CRV));
        adapter.getPriceAt(CRV, CRV, target);
    }

    function test_getPriceAt_RevertIf_ZeroAddress() public {
        vm.expectRevert(IOracleAdapter.OracleAdapter__ZeroAddress.selector);
        adapter.getPriceAt(address(0), DAI, target);

        vm.expectRevert(IOracleAdapter.OracleAdapter__ZeroAddress.selector);
        adapter.getPriceAt(CRV, address(0), target);
    }

    function test_describePricingPath_Success() public {
        {
            (IOracleAdapter.AdapterType adapterType, address[][] memory path, uint8[] memory decimals) = adapter
                .describePricingPath(address(1));

            assertEq(uint256(adapterType), uint256(IOracleAdapter.AdapterType.Chainlink));
            assertEq(path.length, 0);
            assertEq(decimals.length, 0);
        }

        //

        {
            (IOracleAdapter.AdapterType adapterType, address[][] memory path, uint8[] memory decimals) = adapter
                .describePricingPath(WETH);

            assertEq(uint256(adapterType), uint256(IOracleAdapter.AdapterType.Chainlink));
            assertEq(path.length, 1);
            assertEq(path[0][0], 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
            assertEq(decimals.length, 1);
            assertEq(decimals[0], 18);
        }

        //

        {
            (IOracleAdapter.AdapterType adapterType, address[][] memory path, uint8[] memory decimals) = adapter
                .describePricingPath(DAI);

            assertEq(uint256(adapterType), uint256(IOracleAdapter.AdapterType.Chainlink));
            assertEq(path.length, 1);
            assertEq(path[0][0], 0x158228e08C52F3e2211Ccbc8ec275FA93f6033FC);
            assertEq(decimals.length, 1);
            assertEq(decimals[0], 18);
        }

        //

        {
            (IOracleAdapter.AdapterType adapterType, address[][] memory path, uint8[] memory decimals) = adapter
                .describePricingPath(ENS);

            assertEq(uint256(adapterType), uint256(IOracleAdapter.AdapterType.Chainlink));
            assertEq(path.length, 2);
            assertEq(path[0][0], 0x780f1bD91a5a22Ede36d4B2b2c0EcCB9b1726a28);
            assertEq(path[1][0], 0x37bC7498f4FF12C19678ee8fE19d713b87F6a9e6);
            assertEq(decimals.length, 2);
            assertEq(decimals[0], 8);
            assertEq(decimals[0], 8);
        }
    }

    function test_pricingPath_ReturnPathForPair() public {
        uint256 snapshot = vm.snapshot();

        for (uint256 i = 0; i < paths.length; i++) {
            Path memory p = paths[i];

            _addWBTCUSD(p.path);

            adapter.upsertPair(p.tokenIn, p.tokenOut);

            IChainlinkAdapter.PricingPath path1 = adapter.pricingPath(p.tokenIn, p.tokenOut);
            IChainlinkAdapter.PricingPath path2 = adapter.pricingPath(p.tokenOut, p.tokenIn);

            assertEq(uint256(path1), uint256(p.path));
            assertEq(uint256(path2), uint256(p.path));

            vm.revertTo(snapshot);
            snapshot = vm.snapshot();
        }
    }

    function test_setTokenPriceAt_Success() public {
        vm.prank(relayer);
        adapter.setTokenPriceAt(address(1), CHAINLINK_USD, block.timestamp, ONE);
    }

    function test_setTokenPriceAt_RevertIf_TokensAreSame() public {
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IOracleAdapter.OracleAdapter__TokensAreSame.selector, CRV, CRV));
        adapter.setTokenPriceAt(CRV, CRV, block.timestamp, ONE);
    }

    function test_setTokenPriceAt_RevertIf_ZeroAddress() public {
        vm.prank(relayer);
        vm.expectRevert(IOracleAdapter.OracleAdapter__ZeroAddress.selector);
        adapter.setTokenPriceAt(address(0), DAI, block.timestamp, ONE);

        vm.prank(relayer);
        vm.expectRevert(IOracleAdapter.OracleAdapter__ZeroAddress.selector);
        adapter.setTokenPriceAt(CRV, address(0), block.timestamp, ONE);
    }

    function test_setTokenPriceAt_RevertIf_InvalidDenomination() public {
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IChainlinkAdapter.ChainlinkAdapter__InvalidDenomination.selector, CRV));
        adapter.setTokenPriceAt(address(1), CRV, block.timestamp, ONE);
    }

    function test_setTokenPriceAt_RevertIf_NotWhitelistedRelayer() public {
        vm.prank(user);
        vm.expectRevert(
            abi.encodeWithSelector(IRelayerAccessManager.RelayerAccessManager__NotWhitelistedRelayer.selector, user)
        );
        adapter.setTokenPriceAt(address(1), CHAINLINK_USD, block.timestamp, ONE);
    }
}