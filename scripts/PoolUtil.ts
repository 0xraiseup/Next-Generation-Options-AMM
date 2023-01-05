import {
  PoolBase__factory,
  PoolCore__factory,
  PoolFactory,
  PoolFactory__factory,
  PoolFactoryProxy__factory,
  Premia,
  Premia__factory,
} from '../typechain';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/dist/src/signer-with-address';
import { diamondCut } from './utils/diamond';

interface PoolUtilArgs {
  premiaDiamond: Premia;
  poolFactory: PoolFactory;
}

export class PoolUtil {
  premiaDiamond: Premia;
  poolFactory: PoolFactory;

  constructor(args: PoolUtilArgs) {
    this.premiaDiamond = args.premiaDiamond;
    this.poolFactory = args.poolFactory;
  }

  static async deploy(deployer: SignerWithAddress, log = true) {
    // Diamond and facets deployment
    const premiaDiamond = await new Premia__factory(deployer).deploy();
    await premiaDiamond.deployed();

    if (log) console.log(`Premia Diamond : ${premiaDiamond.address}`);

    const poolBaseFactory = new PoolBase__factory(deployer);
    const poolBaseImpl = await poolBaseFactory.deploy();
    await poolBaseImpl.deployed();

    if (log) console.log(`PoolBase : ${poolBaseImpl.address}`);

    const poolCoreFactory = new PoolCore__factory(deployer);
    const poolCoreImpl = await poolCoreFactory.deploy();
    await poolCoreImpl.deployed();

    if (log) console.log(`PoolCore : ${poolCoreImpl.address}`);

    let registeredSelectors = [
      premiaDiamond.interface.getSighash('supportsInterface(bytes4)'),
    ];

    registeredSelectors = registeredSelectors.concat(
      await diamondCut(
        premiaDiamond,
        poolBaseImpl.address,
        poolBaseFactory,
        registeredSelectors,
      ),
    );

    registeredSelectors = registeredSelectors.concat(
      await diamondCut(
        premiaDiamond,
        poolCoreImpl.address,
        poolCoreFactory,
        registeredSelectors,
      ),
    );

    //////////////////////////////////////////////

    /////////////////
    // PoolFactory //
    /////////////////

    const poolFactoryImpl = await new PoolFactory__factory(deployer).deploy();
    await poolFactoryImpl.deployed();

    if (log) console.log(`PoolFactory : ${poolFactoryImpl.address}`);

    const poolFactoryProxy = await new PoolFactoryProxy__factory(
      deployer,
    ).deploy(poolFactoryImpl.address);
    await poolFactoryProxy.deployed();

    if (log) console.log(`PoolFactoryProxy : ${poolFactoryProxy.address}`);

    const poolFactory = PoolFactory__factory.connect(
      poolFactoryProxy.address,
      deployer,
    );

    return new PoolUtil({ premiaDiamond, poolFactory });
  }
}
