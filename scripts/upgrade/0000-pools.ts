import { Premia__factory } from '../../typechain';
import { PoolUtil } from '../../utils/PoolUtil';
import { FacetCut, FacetCutAction, getSelectors } from '../utils/diamond';
import { ethers } from 'hardhat';
import { proposeOrSendTransaction } from '../utils/safe';
import { initialize } from '../../utils/deployment/deployment';

async function main() {
  const [deployer, proposer] = await ethers.getSigners();
  const { deployment, proposeToMultiSig } = await initialize(deployer);

  //////////////////////////

  let premiaDiamond: string;
  let poolFactory: string;
  let router: string;
  let referral: string;
  let vaultRegistry: string;
  let userSettings: string;
  let vxPremia: string;
  let weth: string;

  premiaDiamond = deployment.PremiaDiamond.address;
  poolFactory = deployment.PoolFactoryProxy.address;
  router = deployment.ERC20Router.address;
  referral = deployment.ReferralProxy.address;
  userSettings = deployment.UserSettingsProxy.address;
  vxPremia = deployment.VxPremiaProxy.address;
  weth = deployment.tokens.WETH;
  vaultRegistry = deployment.VaultRegistryProxy.address;

  //////////////////////////

  const deployedFacets = await PoolUtil.deployPoolImplementations(
    deployer,
    poolFactory,
    router,
    userSettings,
    vxPremia,
    weth,
    deployment.feeConverter.main.address,
    referral,
    vaultRegistry,
  );

  // Save new addresses
  // for (const el of deployedFacets) {
  //   (deployment as any)[el.name] = el.address;
  // }
  // fs.writeFileSync(addressesPath, JSON.stringify(deployment, null, 2));

  //

  const diamond = Premia__factory.connect(premiaDiamond, deployer);
  const facets = await diamond.facets();

  let selectorsToRemove: string[] = [];
  for (const el of facets.filter((el) => el.target != diamond.address)) {
    selectorsToRemove = selectorsToRemove.concat(el.selectors);
  }

  const facetCuts: FacetCut[] = [
    {
      target: ethers.constants.AddressZero,
      selectors: selectorsToRemove,
      action: FacetCutAction.REMOVE,
    },
  ];

  let registeredSelectors = [
    diamond.interface.getSighash('supportsInterface(bytes4)'),
  ];

  for (const el of deployedFacets) {
    const selectors = getSelectors(el.interface, registeredSelectors);

    facetCuts.push({
      action: FacetCutAction.ADD,
      target: el.address,
      selectors,
    });

    registeredSelectors = registeredSelectors.concat(selectors);
  }

  const transaction = await diamond.populateTransaction.diamondCut(
    facetCuts,
    ethers.constants.AddressZero,
    '0x',
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
