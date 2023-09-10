import fs from 'fs';
import child_process from 'child_process';

import { IOwnable__factory } from '../../typechain';
import {
  BlockExplorerUrl,
  ChainID,
  ContractKey,
  ContractType,
  DeploymentMetadata,
  DeploymentPath,
} from './types';
import { Provider } from '@ethersproject/providers';
import { BaseContract } from 'ethers';
import { ethers, run } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';
import _ from 'lodash';
import { Network } from '@ethersproject/networks';
import arbitrumDeployment from './arbitrum/metadata.json';
import arbitrumGoerliDeployment from './arbitrumGoerli/metadata.json';
import { generateTables } from '../tables/model';

interface UpdateDeploymentMetadataOptions {
  logTxUrl?: boolean;
  skipWriteFile?: boolean;
  verification?: VerificationOptions;
}

interface VerificationOptions {
  enableVerification?: boolean;
  contract?: string;
  libraries?: { [key: string]: string };
}

export async function initialize(
  providerOrSigner: Provider | SignerWithAddress,
) {
  const network = await getNetwork(providerOrSigner);

  let deployment: DeploymentMetadata = getDeployment(network.chainId);
  let proposeToMultiSig: boolean;
  let proxyManager: string;

  if (network.chainId === ChainID.Arbitrum) {
    proxyManager = '0x89b36CE3491f2258793C7408Bd46aac725973BA2';
    proposeToMultiSig = false;
  } else if (network.chainId === ChainID.ArbitrumGoerli) {
    proxyManager = ethers.constants.AddressZero;
    proposeToMultiSig = false;
  } else {
    throw new Error('ChainId not implemented');
  }

  return { network, deployment, proposeToMultiSig, proxyManager };
}

export function getDeployment(chain: ChainID): DeploymentMetadata {
  if (chain === ChainID.Arbitrum) return arbitrumDeployment;
  if (chain === ChainID.ArbitrumGoerli) return arbitrumGoerliDeployment;
  throw new Error('ChainId not implemented');
}

export async function updateDeploymentMetadata(
  providerOrSigner: Provider | SignerWithAddress,
  objectPath: ContractKey | string,
  contractType: ContractType,
  deployedContract: BaseContract,
  deploymentArgs: string[],
  options: UpdateDeploymentMetadataOptions = {},
) {
  if (objectPath in ContractKey) {
    objectPath = 'core.' + objectPath;
  }

  const provider = getProvider(providerOrSigner);
  const network = await getNetwork(provider);
  const chainId = network.chainId;
  const metadataJsonPath = DeploymentPath[chainId] + 'metadata.json';

  const data = JSON.parse(
    fs.readFileSync(metadataJsonPath).toString(),
  ) as DeploymentMetadata;

  const txReceipt = await deployedContract.deployTransaction.wait();
  let owner = '';

  try {
    const owned = IOwnable__factory.connect(deployedContract.address, provider);
    owner = await owned.owner();
  } catch (e) {}

  _.set(data, objectPath, {
    address: deployedContract.address,
    block: txReceipt.blockNumber,
    commitHash: getCommitHash(),
    contractType,
    deploymentArgs,
    timestamp: await getBlockTimestamp(provider, txReceipt.blockNumber),
    txHash: txReceipt.transactionHash,
    owner: owner,
  });

  if (!options.skipWriteFile) {
    fs.writeFileSync(metadataJsonPath, JSON.stringify(data, undefined, 2));
  }

  if (options.logTxUrl) {
    const addressUrl = await getAddressUrl(
      deployedContract.address,
      providerOrSigner,
    );

    console.log(
      `${objectPath} deployed: ${deployedContract.address} (${addressUrl})`,
    );
  }

  if (options.verification?.enableVerification) {
    await verifyContractsOnEtherscan(
      deployedContract.address,
      deploymentArgs,
      options.verification?.libraries ?? {},
      options.verification?.contract,
    );
  }

  await generateTables(chainId);

  return data;
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

export async function getTransactionUrl(
  txHash: string,
  providerOrSigner: Provider | SignerWithAddress,
): Promise<string> {
  const network = await getNetwork(providerOrSigner);
  return `${BlockExplorerUrl[network.chainId]}/tx/${txHash}`;
}

export async function getAddressUrl(
  address: string,
  providerOrSigner: Provider | SignerWithAddress,
): Promise<string> {
  const network = await getNetwork(providerOrSigner);
  return `${BlockExplorerUrl[network.chainId]}/address/${address}`;
}

export async function getNetwork(
  providerOrSigner: Provider | SignerWithAddress,
): Promise<Network> {
  const provider = getProvider(providerOrSigner);
  return await provider.getNetwork();
}

export function getProvider(
  providerOrSigner: Provider | SignerWithAddress,
): Provider {
  return (
    (providerOrSigner as SignerWithAddress).provider ??
    (providerOrSigner as Provider)
  );
}

export async function verifyContractsOnEtherscan(
  address: string,
  constructorArguments: any[],
  libraries: { [key: string]: string } = {},
  contractPath: string | undefined = undefined, // Example : contracts/proxy/ProxyUpgradeableOwnable.sol:ProxyUpgradeableOwnable
) {
  await run('verify:verify', {
    address,
    contract: contractPath,
    constructorArguments,
    libraries,
  });
}
