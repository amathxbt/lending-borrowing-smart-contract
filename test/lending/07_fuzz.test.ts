import { expect } from "chai";
import { ethers } from "hardhat";

// ---------------------------------------------------------------------------
// Fuzz / property-based tests
// These run the same scenario with randomised amounts to catch edge cases.
// ---------------------------------------------------------------------------

async function deployFixture() {
  const [owner, treasury, alice, bob] = await ethers.getSigners();

  const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
  const usdc = await ERC20Mock.deploy("USD Coin", "USDC", 6) as any;
  const eurc = await ERC20Mock.deploy("Euro Coin", "EURC", 6) as any;

  const Oracle = await ethers.getContractFactory("UnitFlowPriceOracle");
  const oracle = await Oracle.deploy(owner.address) as any;
  await oracle.setFeed(await usdc.getAddress(), ethers.ZeroAddress, 100_000_000n);
  await oracle.setFeed(await eurc.getAddress(), ethers.ZeroAddress, 100_000_000n); // $1 each for simplicity

  const RAY = 10n ** 27n;
  const IRM = await ethers.getContractFactory("UnitFlowInterestRateModel");
  const irm = await IRM.deploy((80n * RAY) / 100n, RAY / 100n, (4n * RAY) / 100n, (75n * RAY) / 100n) as any;

  const FD = await ethers.getContractFactory("UnitFlowFeeDistributor");
  const fd = await FD.deploy(treasury.address, ethers.ZeroAddress, owner.address) as any;

  const Pool = await ethers.getContractFactory("UnitFlowLendingPool");
  const pool = await Pool.deploy(await oracle.getAddress(), await irm.getAddress(), await fd.getAddress(), owner.address) as any;
  await fd.setLendingPool(await pool.getAddress());

  const UToken = await ethers.getContractFactory("UnitFlowUToken");
  const DebtToken = await ethers.getContractFactory("UnitFlowDebtToken");

  const uUsdc = await UToken.deploy("uUSDC", "uUSDC", await usdc.getAddress(), owner.address) as any;
  const dUsdc = await DebtToken.deploy("dUSDC", "dUSDC", await usdc.getAddress(), owner.address) as any;
  const uEurc = await UToken.deploy("uEURC", "uEURC", await eurc.getAddress(), owner.address) as any;
  const dEurc = await DebtToken.deploy("dEURC", "dEURC", await eurc.getAddress(), owner.address) as any;

  await uUsdc.setPool(await pool.getAddress()); await dUsdc.setPool(await pool.getAddress());
  await uEurc.setPool(await pool.getAddress()); await dEurc.setPool(await pool.getAddress());

  await pool.addReserve(await usdc.getAddress(), await uUsdc.getAddress(), await dUsdc.getAddress());
  await pool.addReserve(await eurc.getAddress(), await uEurc.getAddress(), await dEurc.getAddress());

  const LE = await ethers.getContractFactory("UnitFlowLiquidationEngine");
  const le = await LE.deploy(await pool.getAddress(), owner.address) as any;
  await pool.setLiquidationEngine(await le.getAddress());

  const MINT = ethers.parseUnits("10000000", 6);
  await usdc.mint(alice.address, MINT);
  await usdc.mint(bob.address, MINT);
  await eurc.mint(alice.address, MINT);
  await eurc.mint(bob.address, MINT);

  return { pool, oracle, le, usdc, eurc, uUsdc, dUsdc, alice, bob };
}

// Pseudo-random bigint in [min, max]
function randBig(min: bigint, max: bigint, seed: number): bigint {
  const range = max - min + 1n;
  return min + (BigInt(Math.abs(Math.sin(seed) * 1e15 | 0)) % range);
}

describe("Fuzz: supply/withdraw invariants", () => {
  // Property: after supply then full withdraw, uToken balance = 0
  for (let i = 0; i < 5; i++) {
    const amount = randBig(1_000_000n, 500_000_000n, i * 7 + 1); // 1 to 500 USDC (6 dec)

    it(`supply then withdraw full balance — seed ${i} (amount=${amount})`, async () => {
      const { pool, usdc, uUsdc, alice } = await deployFixture();
      await usdc.connect(alice).approve(await pool.getAddress(), amount);
      await pool.connect(alice).supply(await usdc.getAddress(), amount, alice.address);

      await pool.connect(alice).withdraw(await usdc.getAddress(), ethers.MaxUint256, alice.address);
      expect(await uUsdc.balanceOf(alice.address)).to.equal(0n);
    });
  }
});

describe("Fuzz: borrow/repay invariants", () => {
  // Property: after full repay, debt = 0
  for (let i = 0; i < 5; i++) {
    const collateral = randBig(10_000_000n, 500_000_000n, i * 13 + 3); // 10–500 EURC
    // Borrow at most 60% of collateral (safely under 66.67% LTV)
    const borrow = (collateral * 60n) / 100n;

    it(`borrow then full repay — seed ${i} (collateral=${collateral}, borrow=${borrow})`, async () => {
      const { pool, usdc, eurc, dUsdc, alice, bob } = await deployFixture();

      // Alice provides liquidity
      const liquidity = collateral * 2n;
      await usdc.connect(alice).approve(await pool.getAddress(), liquidity);
      await pool.connect(alice).supply(await usdc.getAddress(), liquidity, alice.address);

      // Bob supplies collateral and borrows
      await eurc.connect(bob).approve(await pool.getAddress(), collateral);
      await pool.connect(bob).supply(await eurc.getAddress(), collateral, bob.address);
      await pool.connect(bob).borrow(await usdc.getAddress(), borrow, bob.address);

      // Full repay
      await usdc.connect(bob).approve(await pool.getAddress(), borrow * 2n);
      await pool.connect(bob).repay(await usdc.getAddress(), ethers.MaxUint256, bob.address);

      const RAY = 10n ** 27n;
      expect(await dUsdc.balanceOf(bob.address, RAY)).to.equal(0n);
    });
  }
});

describe("Fuzz: health factor monotonicity", () => {
  // Property: health factor decreases monotonically as more debt is added
  it("health factor strictly decreases with each additional borrow", async () => {
    const { pool, usdc, eurc, alice, bob } = await deployFixture();

    const liquidity = ethers.parseUnits("100000", 6);
    await usdc.connect(alice).approve(await pool.getAddress(), liquidity);
    await pool.connect(alice).supply(await usdc.getAddress(), liquidity, alice.address);

    const collateral = ethers.parseUnits("10000", 6); // $10000
    await eurc.connect(bob).approve(await pool.getAddress(), collateral);
    await pool.connect(bob).supply(await eurc.getAddress(), collateral, bob.address);

    let prevHF = ethers.MaxUint256;
    // Borrow in 5 increments of $1000 (total $5000 < $6667 LTV limit)
    for (let i = 0; i < 5; i++) {
      const chunk = ethers.parseUnits("1000", 6);
      await pool.connect(bob).borrow(await usdc.getAddress(), chunk, bob.address);
      const data = await pool.getUserAccountData(bob.address);
      expect(data.healthFactor).to.be.lt(prevHF);
      prevHF = data.healthFactor;
    }
  });
});
