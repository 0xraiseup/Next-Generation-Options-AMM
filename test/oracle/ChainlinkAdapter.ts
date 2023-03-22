import { expect } from 'chai';
import { ethers } from 'hardhat';
import { BigNumber } from 'ethers';

import { bnToAddress } from '@solidstate/library';
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';

import {
  ChainlinkAdapter,
  ChainlinkAdapter__factory,
  ChainlinkAdapterProxy__factory,
  ChainlinkOraclePriceStub__factory,
} from '../../typechain';

import {
  convertPriceToBigNumberWithDecimals,
  getPrice,
} from '../../utils/defillama';

import { feeds, Token, tokens } from '../../utils/addresses';
import { ONE_ETHER } from '../../utils/constants';
import { increaseTo, latest } from '../../utils/time';

const target = 1676016000; // Fri Feb 10 2023 08:00:00 GMT+0000

enum PricingPath {
  NONE,
  ETH_USD,
  TOKEN_USD,
  TOKEN_ETH,
  TOKEN_USD_TOKEN,
  TOKEN_ETH_TOKEN,
  A_USD_ETH_B,
  A_ETH_USD_B,
  TOKEN_USD_BTC_WBTC,
}

enum FailureMode {
  NONE,
  GET_ROUND_DATA_REVERT_WITH_REASON,
  GET_ROUND_DATA_REVERT,
  LAST_ROUND_DATA_REVERT_WITH_REASON,
  LAST_ROUND_DATA_REVERT,
}

let paths: { path: PricingPath; tokenIn: Token; tokenOut: Token }[][];

// prettier-ignore
{
  paths = [
    [
      // ETH_USD
      { path: PricingPath.ETH_USD, tokenIn: tokens.WETH, tokenOut: tokens.CHAINLINK_USD }, // IN is ETH, OUT is USD
      { path: PricingPath.ETH_USD, tokenIn: tokens.CHAINLINK_USD, tokenOut: tokens.WETH }, // IN is USD, OUT is ETH
      { path: PricingPath.ETH_USD, tokenIn: tokens.CHAINLINK_ETH, tokenOut: tokens.CHAINLINK_USD }, // IN is ETH, OUT is USD
    ],
    [
      // TOKEN_USD
      { path: PricingPath.TOKEN_USD, tokenIn: tokens.DAI, tokenOut: tokens.CHAINLINK_USD }, // IN (tokenA) => OUT (tokenB) is USD
      { path: PricingPath.TOKEN_USD, tokenIn: tokens.AAVE, tokenOut: tokens.CHAINLINK_USD }, // IN (tokenA) => OUT (tokenB) is USD

      // Note: Assumes WBTC/USD feed exists
      { path: PricingPath.TOKEN_USD, tokenIn: tokens.CHAINLINK_USD, tokenOut: tokens.WBTC }, // IN (tokenB) is USD => OUT (tokenA)
      { path: PricingPath.TOKEN_USD, tokenIn: tokens.WBTC, tokenOut: tokens.CHAINLINK_USD }, // IN (tokenA) => OUT (tokenB) is USD
    ],
    [
      // TOKEN_ETH
      { path: PricingPath.TOKEN_ETH, tokenIn: tokens.BNT, tokenOut: tokens.WETH }, // IN (tokenA) => OUT (tokenB) is ETH
      { path: PricingPath.TOKEN_ETH, tokenIn: tokens.AXS, tokenOut: tokens.WETH }, // IN (tokenB) => OUT (tokenA) is ETH
      { path: PricingPath.TOKEN_ETH, tokenIn: tokens.WETH, tokenOut: tokens.CRV }, // IN (tokenA) is ETH => OUT (tokenB)
    ],
    [
      // TOKEN_USD_TOKEN
      { path: PricingPath.TOKEN_USD_TOKEN, tokenIn: tokens.CRV, tokenOut: tokens.AAVE }, // IN (tokenB) => USD => OUT (tokenA)
      { path: PricingPath.TOKEN_USD_TOKEN, tokenIn: tokens.DAI, tokenOut: tokens.AAVE }, // IN (tokenA) => USD => OUT (tokenB)
      { path: PricingPath.TOKEN_USD_TOKEN, tokenIn: tokens.AAVE, tokenOut: tokens.DAI }, // IN (tokenB) => USD => OUT (tokenA)
      { path: PricingPath.TOKEN_USD_TOKEN, tokenIn: tokens.CRV, tokenOut: tokens.USDC }, // IN (tokenB) => USD => OUT (tokenA)
      { path: PricingPath.TOKEN_USD_TOKEN, tokenIn: tokens.USDC, tokenOut: tokens.COMP }, // IN (tokenA) => USD => OUT (tokenB)

      // Note: Assumes WBTC/USD feed exists
      { path: PricingPath.TOKEN_USD_TOKEN, tokenIn: tokens.DAI, tokenOut: tokens.WBTC }, // IN (tokenB) => USD => OUT (tokenA)
      { path: PricingPath.TOKEN_USD_TOKEN, tokenIn: tokens.WBTC, tokenOut: tokens.USDC }, // IN (tokenA) => USD => OUT (tokenB)
    ],
    [
      // TOKEN_ETH_TOKEN
      { path: PricingPath.TOKEN_ETH_TOKEN, tokenIn: tokens.BOND, tokenOut: tokens.AXS }, // IN (tokenA) => ETH => OUT (tokenB)
      { path: PricingPath.TOKEN_ETH_TOKEN, tokenIn: tokens.ALPHA, tokenOut: tokens.BOND }, // IN (tokenB) => ETH => OUT (tokenA)
    ],
    [
      // A_USD_ETH_B
      { path: PricingPath.A_USD_ETH_B, tokenIn: tokens.FXS, tokenOut: tokens.WETH }, // IN (tokenA) => USD, OUT (tokenB) is ETH
      { path: PricingPath.A_USD_ETH_B, tokenIn: tokens.WETH, tokenOut: tokens.MATIC }, // IN (tokenB) is ETH, USD => OUT (tokenA)

      { path: PricingPath.A_USD_ETH_B, tokenIn: tokens.USDC, tokenOut: tokens.AXS }, // IN (tokenA) is USD, ETH => OUT (tokenB)
      { path: PricingPath.A_USD_ETH_B, tokenIn: tokens.ALPHA, tokenOut: tokens.DAI }, // IN (tokenB) => ETH, OUT is USD (tokenA)
      { path: PricingPath.A_USD_ETH_B, tokenIn: tokens.DAI, tokenOut: tokens.ALPHA }, 

      { path: PricingPath.A_USD_ETH_B, tokenIn: tokens.FXS, tokenOut: tokens.AXS }, // IN (tokenA) => USD, ETH => OUT (tokenB)
      { path: PricingPath.A_USD_ETH_B, tokenIn: tokens.ALPHA, tokenOut: tokens.MATIC }, // IN (tokenB) => ETH, USD => OUT (tokenA)

      // Note: Assumes WBTC/USD feed exists
      { path: PricingPath.A_USD_ETH_B, tokenIn: tokens.WETH, tokenOut: tokens.WBTC }, // IN (tokenB) => ETH, USD => OUT (tokenA)
    ],
    [
      // A_ETH_USD_B
      // We can't test the following two cases, because we would need a token that is
      // supported by chainlink and lower than USD (address(840))
      // - IN (tokenA) => ETH, OUT (tokenB) is USD
      // - IN (tokenB) is USD, ETH => OUT (tokenA)

      { path: PricingPath.A_ETH_USD_B, tokenIn: tokens.WETH, tokenOut: tokens.IMX }, // IN (tokenA) is ETH, USD => OUT (tokenB)
      { path: PricingPath.A_ETH_USD_B, tokenIn: tokens.IMX, tokenOut: tokens.WETH }, // IN (tokenB) => USD, OUT is ETH (tokenA)

      { path: PricingPath.A_ETH_USD_B, tokenIn: tokens.AXS, tokenOut: tokens.IMX }, // IN (tokenA) => ETH, USD => OUT (tokenB)

      { path: PricingPath.A_ETH_USD_B, tokenIn: tokens.FXS, tokenOut: tokens.BOND }, // IN (tokenB) => ETH, USD => OUT (tokenA)
      { path: PricingPath.A_ETH_USD_B, tokenIn: tokens.BOND, tokenOut: tokens.FXS }, // IN (tokenA) => USD, ETH => OUT (tokenB) 
    ],
    [
      // TOKEN_USD_BTC_WBTC
      // Note: Assumes WBTC/USD feed does not exist
      { path: PricingPath.TOKEN_USD_BTC_WBTC, tokenIn: tokens.WBTC, tokenOut: tokens.CHAINLINK_USD }, // IN (tokenA) => BTC, OUT is USD
      { path: PricingPath.TOKEN_USD_BTC_WBTC, tokenIn: tokens.WBTC, tokenOut: tokens.CHAINLINK_BTC }, // IN (tokenA) => BTC, OUT is BTC
      { path: PricingPath.TOKEN_USD_BTC_WBTC, tokenIn: tokens.WBTC, tokenOut: tokens.WETH }, // IN (tokenA) => BTC, OUT is ETH (tokenB)
      { path: PricingPath.TOKEN_USD_BTC_WBTC, tokenIn: tokens.WETH, tokenOut: tokens.WBTC }, // IN (tokenB) is ETH, BTC => OUT (tokenA)
      { path: PricingPath.TOKEN_USD_BTC_WBTC, tokenIn: tokens.DAI, tokenOut: tokens.WBTC }, // IN (tokenB) => USD, BTC => OUT (tokenA)
      { path: PricingPath.TOKEN_USD_BTC_WBTC, tokenIn: tokens.WBTC, tokenOut: tokens.USDC }, // IN (tokenA) => BTC, USD => OUT (tokenB)
      { path: PricingPath.TOKEN_USD_BTC_WBTC, tokenIn: tokens.WBTC, tokenOut: tokens.BNT }, // IN (tokenA) => USD,  BTC => OUT (tokenB)
    ]
  ];
}

describe('ChainlinkAdapter', () => {
  async function deploy() {
    const [deployer] = await ethers.getSigners();

    const implementation = await new ChainlinkAdapter__factory(deployer).deploy(
      tokens.WETH.address,
      tokens.WBTC.address,
    );

    await implementation.deployed();

    const proxy = await new ChainlinkAdapterProxy__factory(deployer).deploy(
      implementation.address,
    );

    await proxy.deployed();

    const instance = ChainlinkAdapter__factory.connect(proxy.address, deployer);

    await instance.batchRegisterFeedMappings(feeds);

    return { deployer, instance };
  }

  async function deployStub() {
    const { deployer, instance } = await deploy();

    const stub = await new ChainlinkOraclePriceStub__factory(deployer).deploy();

    const stubCoin = bnToAddress(BigNumber.from(100));

    await instance.batchRegisterFeedMappings([
      {
        token: stubCoin,
        denomination: tokens.CHAINLINK_USD.address,
        feed: stub.address,
      },
    ]);

    await instance.upsertPair(stubCoin, tokens.CHAINLINK_USD.address);

    return { deployer, instance, stub, stubCoin };
  }

  describe('#isPairSupported', () => {
    it('returns false if pair is not supported by adapter', async () => {
      const { instance } = await loadFixture(deploy);

      const [isCached, _] = await instance.isPairSupported(
        tokens.WETH.address,
        tokens.DAI.address,
      );

      expect(isCached).to.be.false;
    });

    it('returns false if path for pair does not exist', async () => {
      const { instance } = await loadFixture(deploy);

      const [_, hasPath] = await instance.isPairSupported(
        tokens.WETH.address,
        bnToAddress(BigNumber.from(0)),
      );

      expect(hasPath).to.be.false;
    });
  });

  describe('#upsertPair', () => {
    it('should revert if pair cannot be supported', async () => {
      const { instance } = await loadFixture(deploy);

      await expect(
        instance.upsertPair(
          bnToAddress(BigNumber.from(0)),
          tokens.WETH.address,
        ),
      ).to.be.revertedWithCustomError(
        instance,
        'OracleAdapter__PairCannotBeSupported',
      );

      await expect(
        instance.upsertPair(
          tokens.WBTC.address,
          bnToAddress(BigNumber.from(0)),
        ),
      ).to.be.revertedWithCustomError(
        instance,
        'OracleAdapter__PairCannotBeSupported',
      );
    });

    it('should not fail if called multiple times for same pair', async () => {
      const { instance } = await loadFixture(deploy);

      await instance.upsertPair(tokens.WETH.address, tokens.DAI.address);

      const [isCached, _] = await instance.isPairSupported(
        tokens.WETH.address,
        tokens.DAI.address,
      );

      expect(isCached).to.be.true;

      await instance.upsertPair(tokens.WETH.address, tokens.DAI.address);
    });

    it('should only emit UpdatedPathForPair when path is updated', async () => {
      const { instance } = await loadFixture(deploy);

      await expect(
        instance.upsertPair(tokens.WETH.address, tokens.DAI.address),
      ).to.emit(instance, 'UpdatedPathForPair');

      let [isCached, _] = await instance.isPairSupported(
        tokens.WETH.address,
        tokens.DAI.address,
      );

      expect(isCached).to.be.true;

      await expect(
        instance.upsertPair(tokens.WETH.address, tokens.DAI.address),
      ).to.not.emit(instance, 'UpdatedPathForPair');

      [isCached, _] = await instance.isPairSupported(
        tokens.WETH.address,
        tokens.DAI.address,
      );

      expect(isCached).to.be.true;

      await instance.batchRegisterFeedMappings([
        {
          token: tokens.DAI.address,
          denomination: tokens.CHAINLINK_ETH.address,
          feed: bnToAddress(BigNumber.from(0)),
        },
      ]);

      await expect(
        instance.upsertPair(tokens.WETH.address, tokens.DAI.address),
      ).to.emit(instance, 'UpdatedPathForPair');

      [isCached, _] = await instance.isPairSupported(
        tokens.WETH.address,
        tokens.DAI.address,
      );
    });
  });

  describe('#bathRegisterFeedMappings', async () => {
    it('should revert if token == denomination', async () => {
      const { instance } = await loadFixture(deploy);

      await expect(
        instance.batchRegisterFeedMappings([
          {
            token: tokens.EUL.address,
            denomination: tokens.EUL.address,
            feed: bnToAddress(BigNumber.from(1)),
          },
        ]),
      ).to.be.revertedWithCustomError(instance, 'OracleAdapter__TokensAreSame');
    });

    it('should revert if token or denomination address is 0', async () => {
      const { instance } = await loadFixture(deploy);

      await expect(
        instance.batchRegisterFeedMappings([
          {
            token: bnToAddress(BigNumber.from(0)),
            denomination: tokens.DAI.address,
            feed: bnToAddress(BigNumber.from(1)),
          },
        ]),
      ).to.be.revertedWithCustomError(instance, 'OracleAdapter__ZeroAddress');

      await expect(
        instance.batchRegisterFeedMappings([
          {
            token: tokens.EUL.address,
            denomination: bnToAddress(BigNumber.from(0)),
            feed: bnToAddress(BigNumber.from(1)),
          },
        ]),
      ).to.be.revertedWithCustomError(instance, 'OracleAdapter__ZeroAddress');
    });

    it('shoud return feed of mapped token and denomination', async () => {
      const { instance } = await loadFixture(deploy);

      await instance.batchRegisterFeedMappings(feeds);

      for (let i = 0; i < feeds.length; i++) {
        expect(
          await instance.feed(feeds[i].token, feeds[i].denomination),
        ).to.equal(feeds[i].feed);
      }
    });
  });

  describe('#feed', async () => {
    it('should return zero address if feed has not been added', async () => {
      const { instance } = await loadFixture(deploy);

      expect(
        await instance.feed(tokens.EUL.address, tokens.DAI.address),
      ).to.equal(bnToAddress(BigNumber.from(0)));
    });
  });

  describe('#quote', async () => {
    it('should catch revert', async () => {
      const { instance, stub, stubCoin } = await loadFixture(deployStub);

      await stub.setup(
        FailureMode.LAST_ROUND_DATA_REVERT_WITH_REASON,
        [100000000000],
        [target - 90000],
      );

      await expect(
        instance.quote(stubCoin, tokens.CHAINLINK_USD.address),
      ).to.be.revertedWith('reverted with reason');

      await stub.setup(
        FailureMode.LAST_ROUND_DATA_REVERT,
        [100000000000],
        [target - 90000],
      );

      await expect(
        instance.quote(stubCoin, tokens.CHAINLINK_USD.address),
      ).to.be.revertedWithCustomError(
        instance,
        'ChainlinkAdapter__LatestRoundDataCallReverted',
      );
    });

    it('should revert if pair is not supported', async () => {
      const { instance } = await loadFixture(deploy);

      await expect(
        instance.quote(tokens.WETH.address, bnToAddress(BigNumber.from(0))),
      ).to.be.revertedWithCustomError(
        instance,
        'OracleAdapter__PairNotSupported',
      );
    });

    it('should find path if pair has not been added', async () => {
      const { instance } = await loadFixture(deploy);
      expect(await instance.quote(tokens.WETH.address, tokens.DAI.address));
    });

    it('should return quote using correct denomination', async () => {
      const { instance } = await loadFixture(deploy);

      let tokenIn = tokens.WETH;
      let tokenOut = tokens.DAI;

      await instance.upsertPair(tokenIn.address, tokenOut.address);

      let quote = await instance.quote(tokenIn.address, tokenOut.address);
      let invertedQuote = await instance.quote(
        tokenOut.address,
        tokenIn.address,
      );

      expect(quote.div(ONE_ETHER)).to.be.eq(ONE_ETHER.div(invertedQuote));

      tokenIn = tokens.CRV;
      tokenOut = tokens.AAVE;

      await instance.upsertPair(tokenIn.address, tokenOut.address);

      quote = await instance.quote(tokenIn.address, tokenOut.address);
      invertedQuote = await instance.quote(tokenOut.address, tokenIn.address);

      expect(quote.div(ONE_ETHER)).to.be.eq(ONE_ETHER.div(invertedQuote));
    });
  });

  describe('#quoteFrom', async () => {
    it('should catch revert', async () => {
      const { instance, stub, stubCoin } = await loadFixture(deployStub);

      await instance.upsertPair(stubCoin, tokens.CHAINLINK_USD.address);

      await stub.setup(
        FailureMode.GET_ROUND_DATA_REVERT_WITH_REASON,
        [100000000000, 100000000000, 100000000000],
        [target + 3, target + 2, target + 1],
      );

      await expect(
        instance.quoteFrom(stubCoin, tokens.CHAINLINK_USD.address, target),
      ).to.be.revertedWith('reverted with reason');

      await stub.setup(
        FailureMode.GET_ROUND_DATA_REVERT,
        [100000000000, 100000000000, 100000000000],
        [target + 3, target + 2, target + 1],
      );

      await expect(
        instance.quoteFrom(stubCoin, tokens.CHAINLINK_USD.address, target),
      ).to.be.revertedWithCustomError(
        instance,
        'ChainlinkAdapter__GetRoundDataCallReverted',
      );
    });

    it('should revert if target is 0', async () => {
      const { instance } = await loadFixture(deploy);

      await expect(
        instance.quoteFrom(tokens.WETH.address, tokens.DAI.address, 0),
      ).to.be.revertedWithCustomError(instance, 'OracleAdapter__InvalidTarget');
    });

    it('should revert if target > block.timestamp', async () => {
      const { instance } = await loadFixture(deploy);

      const blockTimestamp = await latest();

      await expect(
        instance.quoteFrom(
          tokens.WETH.address,
          tokens.DAI.address,
          blockTimestamp + 1,
        ),
      ).to.be.revertedWithCustomError(instance, 'OracleAdapter__InvalidTarget');
    });

    const stubCoin = bnToAddress(BigNumber.from(100));

    describe('#when price is stale', async () => {
      it('should revert when called within 12 hours of target time', async () => {
        const { instance, stub, stubCoin } = await loadFixture(deployStub);

        await stub.setup(FailureMode.NONE, [100000000000], [target - 90000]);

        await expect(
          instance.quoteFrom(stubCoin, tokens.CHAINLINK_USD.address, target),
        ).to.be.revertedWithCustomError(
          instance,
          'ChainlinkAdapter__PriceAfterTargetIsStale',
        );
      });

      it('should return stale price when called 12 hours after target time', async () => {
        const { instance, stub, stubCoin } = await loadFixture(deployStub);

        await increaseTo(target + 43200);
        await stub.setup(FailureMode.NONE, [100000000000], [target - 90000]);

        const stalePrice = await stub.price(0);

        expect(
          await instance.quoteFrom(
            stubCoin,
            tokens.CHAINLINK_USD.address,
            target,
          ),
        ).to.be.eq(stalePrice.mul(1e10)); // convert to 1E18
      });
    });

    describe('#when price is fresh', async () => {
      it('should return price closest to target when called within 12 hours of target time', async () => {
        const { instance, stub, stubCoin } = await loadFixture(deployStub);

        await stub.setup(FailureMode.NONE, [1000000000000], [target + 100]);
        let freshPrice = await stub.price(0);

        expect(
          await instance.quoteFrom(
            stubCoin,
            tokens.CHAINLINK_USD.address,
            target,
          ),
        ).to.be.eq(freshPrice.mul(1e10)); // convert to 1E18

        await stub.setup(
          FailureMode.NONE,
          [100000000000, 200000000000, 300000000000],
          [target + 100, target + 300, target + 500],
        );

        freshPrice = await stub.price(0);

        expect(
          await instance.quoteFrom(
            stubCoin,
            tokens.CHAINLINK_USD.address,
            target,
          ),
        ).to.be.eq(freshPrice.mul(1e10)); // convert to 1E18

        await stub.setup(
          FailureMode.NONE,
          [50000000000, 100000000000, 200000000000, 300000000000],
          [target - 50, target + 100, target + 300, target + 500],
        );

        freshPrice = await stub.price(0);

        expect(
          await instance.quoteFrom(
            stubCoin,
            tokens.CHAINLINK_USD.address,
            target,
          ),
        ).to.be.eq(freshPrice.mul(1e10)); // convert to 1E18

        await stub.setup(
          FailureMode.NONE,
          [50000000000, 100000000000, 200000000000, 300000000000],
          [target - 100, target + 50, target + 300, target + 500],
        );

        freshPrice = await stub.price(1);

        expect(
          await instance.quoteFrom(
            stubCoin,
            tokens.CHAINLINK_USD.address,
            target,
          ),
        ).to.be.eq(freshPrice.mul(1e10)); // convert to 1E18

        await stub.setup(
          FailureMode.NONE,
          [50000000000, 100000000000],
          [target - 100, target - 50],
        );

        freshPrice = await stub.price(1);

        expect(
          await instance.quoteFrom(
            stubCoin,
            tokens.CHAINLINK_USD.address,
            target,
          ),
        ).to.be.eq(freshPrice.mul(1e10)); // convert to 1E18
      });

      it('should return price closest to target when called 12 hours after target time', async () => {
        const { instance, stub, stubCoin } = await loadFixture(deployStub);

        await increaseTo(target + 43200);
        await stub.setup(FailureMode.NONE, [1000000000000], [target + 100]);
        let freshPrice = await stub.price(0);

        expect(
          await instance.quoteFrom(
            stubCoin,
            tokens.CHAINLINK_USD.address,
            target,
          ),
        ).to.be.eq(freshPrice.mul(1e10)); // convert to 1E18

        await stub.setup(
          FailureMode.NONE,
          [100000000000, 200000000000, 300000000000],
          [target + 100, target + 300, target + 500],
        );

        freshPrice = await stub.price(0);

        expect(
          await instance.quoteFrom(
            stubCoin,
            tokens.CHAINLINK_USD.address,
            target,
          ),
        ).to.be.eq(freshPrice.mul(1e10)); // convert to 1E18

        await stub.setup(
          FailureMode.NONE,
          [50000000000, 100000000000, 200000000000, 300000000000],
          [target - 50, target + 100, target + 300, target + 500],
        );

        freshPrice = await stub.price(0);

        expect(
          await instance.quoteFrom(
            stubCoin,
            tokens.CHAINLINK_USD.address,
            target,
          ),
        ).to.be.eq(freshPrice.mul(1e10)); // convert to 1E18

        await stub.setup(
          FailureMode.NONE,
          [50000000000, 100000000000, 200000000000, 300000000000],
          [target - 100, target + 50, target + 300, target + 500],
        );

        freshPrice = await stub.price(1);

        expect(
          await instance.quoteFrom(
            stubCoin,
            tokens.CHAINLINK_USD.address,
            target,
          ),
        ).to.be.eq(freshPrice.mul(1e10)); // convert to 1E18

        await stub.setup(
          FailureMode.NONE,
          [50000000000, 100000000000],
          [target - 100, target - 50],
        );

        freshPrice = await stub.price(1);

        expect(
          await instance.quoteFrom(
            stubCoin,
            tokens.CHAINLINK_USD.address,
            target,
          ),
        ).to.be.eq(freshPrice.mul(1e10)); // convert to 1E18
      });
    });
  });

  for (let i = 0; i < paths.length; i++) {
    describe(`${PricingPath[paths[i][0].path]}`, () => {
      for (const { path, tokenIn, tokenOut } of paths[i]) {
        let instance: ChainlinkAdapter;

        describe(`${tokenIn.symbol}-${tokenOut.symbol}`, () => {
          beforeEach(async () => {
            const f = await loadFixture(deploy);
            instance = f.instance;

            if (
              path == PricingPath.TOKEN_USD ||
              path == PricingPath.TOKEN_USD_TOKEN ||
              path == PricingPath.A_USD_ETH_B
            ) {
              await instance.batchRegisterFeedMappings([
                {
                  token: tokens.WBTC.address,
                  denomination: tokens.CHAINLINK_USD.address,
                  feed: '0xf4030086522a5beea4988f8ca5b36dbc97bee88c', // maps WBTC/USD to BTC/USD feed on Ethereum mainnet
                },
              ]);
            }

            await instance.upsertPair(tokenIn.address, tokenOut.address);
          });

          describe('#isPairSupported', () => {
            it('should return true if pair is cached and path exists', async () => {
              const [isCached, hasPath] = await instance.isPairSupported(
                tokenIn.address,
                tokenOut.address,
              );

              expect(isCached).to.be.true;
              expect(hasPath).to.be.true;
            });
          });

          describe('#pathForPair', () => {
            it('should return pricing path for pair', async () => {
              const path1 = await instance.pathForPair(
                tokenIn.address,
                tokenOut.address,
              );

              const path2 = await instance.pathForPair(
                tokenOut.address,
                tokenIn.address,
              );

              expect(path1).to.equal(path);
              expect(path2).to.equal(path);
            });
          });

          describe('#quote', async () => {
            it('should return quote for pair', async () => {
              let _tokenIn = Object.assign({}, tokenIn);
              let _tokenOut = Object.assign({}, tokenOut);

              let networks = { tokenIn: 'ethereum', tokenOut: 'ethereum' };

              const quote = await instance.quote(
                _tokenIn.address,
                _tokenOut.address,
              );

              if (tokenIn.symbol === tokens.CHAINLINK_ETH.symbol) {
                networks.tokenIn = 'coingecko';
                _tokenIn.address = 'ethereum';
              }

              if (tokenOut.symbol === tokens.CHAINLINK_ETH.symbol) {
                networks.tokenOut = 'coingecko';
                _tokenOut.address = 'ethereum';
              }

              if (tokenIn.symbol === tokens.CHAINLINK_BTC.symbol) {
                networks.tokenIn = 'coingecko';
                _tokenIn.address = 'bitcoin';
              }

              if (tokenOut.symbol === tokens.CHAINLINK_BTC.symbol) {
                networks.tokenOut = 'coingecko';
                _tokenOut.address = 'bitcoin';
              }

              const coingeckoPrice = await getPriceBetweenTokens(
                networks,
                _tokenIn,
                _tokenOut,
              );

              const expected = convertPriceToBigNumberWithDecimals(
                coingeckoPrice,
                18,
              );

              validateQuote(quote, expected);
            });
          });

          describe('#quoteFrom', async () => {
            it('should return quote for pair from target', async () => {
              // although the adapter will attepmt to return the price closest to the target
              // the time of the update will likely be before or after the target.
              TRESHOLD_PERCENTAGE = 4;

              let _tokenIn = Object.assign({}, tokenIn);
              let _tokenOut = Object.assign({}, tokenOut);

              let networks = { tokenIn: 'ethereum', tokenOut: 'ethereum' };

              const quoteFrom = await instance.quoteFrom(
                _tokenIn.address,
                _tokenOut.address,
                target,
              );

              if (tokenIn.symbol === tokens.CHAINLINK_ETH.symbol) {
                networks.tokenIn = 'coingecko';
                _tokenIn.address = 'ethereum';
              }

              if (tokenOut.symbol === tokens.CHAINLINK_ETH.symbol) {
                networks.tokenOut = 'coingecko';
                _tokenOut.address = 'ethereum';
              }

              if (tokenIn.symbol === tokens.CHAINLINK_BTC.symbol) {
                networks.tokenIn = 'coingecko';
                _tokenIn.address = 'bitcoin';
              }

              if (tokenOut.symbol === tokens.CHAINLINK_BTC.symbol) {
                networks.tokenOut = 'coingecko';
                _tokenOut.address = 'bitcoin';
              }

              const coingeckoPrice = await getPriceBetweenTokens(
                networks,
                _tokenIn,
                _tokenOut,
                target,
              );

              const expected = convertPriceToBigNumberWithDecimals(
                coingeckoPrice,
                18,
              );

              validateQuote(quoteFrom, expected);
            });
          });
        });
      }
    });
  }
});

let TRESHOLD_PERCENTAGE = 3; // In mainnet, max threshold is usually 2%, but since we are combining pairs, it can sometimes be a little higher

function validateQuote(quote: BigNumber, expected: BigNumber) {
  const threshold = expected.mul(TRESHOLD_PERCENTAGE * 10).div(100 * 10);
  const [upperThreshold, lowerThreshold] = [
    expected.add(threshold),
    expected.sub(threshold),
  ];
  const diff = quote.sub(expected);
  const sign = diff.isNegative() ? '-' : '+';
  const diffPercentage = diff.abs().mul(10000).div(expected).toNumber() / 100;

  expect(
    quote.lte(upperThreshold) && quote.gte(lowerThreshold),
    `Expected ${quote.toString()} to be within [${lowerThreshold.toString()},${upperThreshold.toString()}]. Diff was ${sign}${diffPercentage}%`,
  ).to.be.true;
}

async function getPriceBetweenTokens(
  networks: { tokenIn: string; tokenOut: string },
  tokenIn: Token,
  tokenOut: Token,
  target: number = 0,
) {
  if (tokenIn.address === tokens.CHAINLINK_USD.address) {
    return 1 / (await fetchPrice(networks.tokenOut, tokenOut.address, target));
  }
  if (tokenOut.address === tokens.CHAINLINK_USD.address) {
    return await fetchPrice(networks.tokenIn, tokenIn.address, target);
  }

  let tokenInPrice = await fetchPrice(
    networks.tokenIn,
    tokenIn.address,
    target,
  );
  let tokenOutPrice = await fetchPrice(
    networks.tokenOut,
    tokenOut.address,
    target,
  );

  return tokenInPrice / tokenOutPrice;
}

let cache: { [address: string]: { [target: number]: number } } = {};

async function fetchPrice(
  network: string,
  address: string,
  target: number = 0,
): Promise<number> {
  if (!cache[address]) cache[address] = {};
  if (!cache[address][target]) {
    if (target == 0) target = await latest();
    const price = await getPrice(network, address, target);
    cache[address][target] = price;
  }
  return cache[address][target];
}