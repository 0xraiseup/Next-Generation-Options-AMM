import {
  ProxyUpgradeableOwnable__factory,
  UserSettings__factory,
} from '../../typechain';
import { ContractKey, ContractType } from '../../utils/deployment/types';
import { ethers } from 'hardhat';
import {
  initialize,
  updateDeploymentInfos,
} from '../../utils/deployment/deployment';
import { proposeOrSendTransaction } from '../utils/safe';

async function main() {
  const [deployer, proposer] = await ethers.getSigners();
  const { deployment, proposeToMultiSig } = await initialize(deployer);

  //////////////////////////

  const implementation = await new UserSettings__factory(deployer).deploy();
  await updateDeploymentInfos(
    deployer,
    ContractKey.UserSettingsImplementation,
    ContractType.Implementation,
    implementation,
    [],
    true,
  );

  const proxy = ProxyUpgradeableOwnable__factory.connect(
    deployment.UserSettingsProxy.address,
    deployer,
  );

  const transaction = await proxy.populateTransaction.setImplementation(
    implementation.address,
  );

  await proposeOrSendTransaction(
    proposeToMultiSig,
    deployment.treasury,
    proposer,
    [transaction],
  );
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
