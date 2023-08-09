import { PoolFactory__factory } from '../../../typechain';
import arbitrumGoerliDeployment from '../../../utils/deployment/arbitrumGoerli.json';
import { PoolKey } from '../../../utils/sdk/types';
import { getValidMaturity } from '../../../utils/time';
import { BigNumber } from 'ethers';
import { parseEther } from 'ethers/lib/utils';
import { ethers } from 'hardhat';
import { ChainID, DeploymentInfos } from '../../../utils/deployment/types';

async function main() {
  const [deployer] = await ethers.getSigners();
  const chainId = await deployer.getChainId();

  let deployment: DeploymentInfos;

  if (chainId === ChainID.ArbitrumGoerli) {
    deployment = arbitrumGoerliDeployment;
  } else {
    throw new Error('ChainId not implemented');
  }

  const poolFactory = PoolFactory__factory.connect(
    deployment.PoolFactoryProxy.address,
    deployer,
  );
  const poolKey: PoolKey = {
    base: deployment.tokens.testWETH,
    quote: deployment.tokens.USDC,
    oracleAdapter: deployment.ChainlinkAdapterProxy.address,
    strike: parseEther('2000'),
    maturity: BigNumber.from(await getValidMaturity(1, 'months')),
    isCallPool: true,
  };

  const initFee = await poolFactory.initializationFee(poolKey);

  await poolFactory.deployPool(poolKey, {
    value: initFee.add(initFee.div(20)), // Fails for some reason if we pass the exact init fee
    gasLimit: 1200000, // Fails to properly estimate gas limit
  });
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
