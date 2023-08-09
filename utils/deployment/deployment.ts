import child_process from 'child_process';
import { ChainID, ContractKey, ContractType, DeploymentInfos } from './types';
import fs from 'fs';
import { Provider } from '@ethersproject/providers';
import { BaseContract } from 'ethers';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';

export async function updateDeploymentInfos(
  providerOrSigner: Provider | SignerWithAddress,
  contractKey: ContractKey,
  contractType: ContractType,
  deployedContract: BaseContract,
  deploymentArgs: string[],
  logAddress = false,
) {
  if (logAddress) console.log(`${contractKey}: ${deployedContract.address}`);

  const provider: Provider =
    (providerOrSigner as SignerWithAddress).provider ??
    (providerOrSigner as Provider);

  const chainId = (await provider.getNetwork()).chainId;

  const jsonPath = getDeploymentJsonPath(chainId);

  const data = JSON.parse(
    fs.readFileSync(jsonPath).toString(),
  ) as DeploymentInfos;

  const txReceipt = await deployedContract.deployTransaction.wait();

  data[contractKey] = {
    address: deployedContract.address,
    block: txReceipt.blockNumber,
    commitHash: getCommitHash(),
    contractType: ContractType.Standalone,
    deploymentArgs,
    timestamp: await getBlockTimestamp(provider, txReceipt.blockNumber),
    txHash: txReceipt.transactionHash,
  };

  fs.writeFileSync(jsonPath, JSON.stringify(data, undefined, 2));

  return data;
}

export function getDeploymentJsonPath(chainId: ChainID) {
  switch (chainId) {
    case ChainID.Arbitrum:
      return 'utils/deployment/arbitrum.json';
    case ChainID.ArbitrumGoerli:
      return 'utils/deployment/arbitrumGoerli.json';
    default:
      throw new Error('ChainId not implemented');
  }
}

export async function getBlockTimestamp(
  provider: Provider,
  blockNumber: number,
) {
  return (await provider.getBlock(blockNumber)).timestamp;
}

export function getCommitHash() {
  return child_process.execSync('git rev-parse HEAD').toString().trim();
}
