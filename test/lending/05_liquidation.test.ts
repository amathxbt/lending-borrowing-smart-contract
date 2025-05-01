import { expect } from "chai";
import { ethers } from "hardhat";
import type {
  UnitFlowLendingPool,
  UnitFlowLiquidationEngine,
} from "../../typechain-types";

// Re-use the same fixture helper
async function deployFixture() {
  const [owner, treasury, alice, bob, liquidator] = await ethers.getSigners();

  const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
  const usdc = await ERC20Mock.deploy("USD Coin", "USDC", 6) as any;
  const eurc = await ERC20Mock.deploy("Euro Coin", "EURC", 6) as any;

  const Oracle = await ethers.getContractFactory("UnitFlowPriceOracle");
  const oracle = await Oracle.deploy(owner.address) as any;
  await oracle.setFeed(await usdc.getAddress(), ethers.ZeroAddress, 100_000_000n);
  await oracle.setFeed(await eurc.getAddress(), ethers.ZeroAddress, 108_000_000n);

  const RAY = 10n ** 27n;
  const IRM = await ethers.getContractFactory("UnitFlowInterestRateModel");
  const irm = await IRM.deploy((80n * RAY) / 100n, RAY / 100n, (4n * RAY) / 100n, (75n * RAY) / 100n) as any;

  const FD = await ethers.getContractFactory("UnitFlowFeeDistributor");
  const fd = await FD.deploy(treasury.address, ethers.ZeroAddress, owner.address) as any;

  const Pool = await ethers.getContractFactory("UnitFlowLendingPool");
  const pool = await Pool.deploy(await oracle.getAddress(), await irm.getAddress(), await fd.getAddress(), owner.address) as UnitFlowLendingPool;
  await fd.setLendingPool(await pool.getAddress());

  const UToken = await ethers.getContractFactory("UnitFlowUToken");
  const DebtToken = await ethers.getContractFactory("UnitFlowDebtToken");

  const uUsdc = await UToken.deploy("uUSDC", "uUSDC", await usdc.getAddress(), owner.address) as any;
  const dUsdc = await DebtToken.deploy("dUSDC", "dUSDC", await usdc.getAddress(), owner.address) as any;
  const uEurc = await UToken.deploy("uEURC", "uEURC", await eurc.getAddress(), owner.address) as any;
  const dEurc = await DebtToken.deploy("dEURC", "dEURC", await eurc.getAddress(), owner.address) as any;

  await uUsdc.setPool(await pool.getAddress());
  await dUsdc.setPool(await pool.getAddress());
  await uEurc.setPool(await pool.getAddress());
  await dEurc.setPool(await pool.getAddress());

  await pool.addReserve(await usdc.getAddress(), await uUsdc.getAddress(), await dUsdc.getAddress());
  await pool.addReserve(await eurc.getAddress(), await uEurc.getAddress(), await dEurc.getAddress());

  const LE = await ethers.getContractFactory("UnitFlowLiquidationEngine");
  const le = await LE.deploy(await pool.getAddress(), owner.address) as UnitFlowLiquidationEngine;
  await pool.setLiquidationEngine(await le.getAddress());

  const MINT = ethers.parseUnits("1000000", 6);
  await usdc.mint(alice.address, MINT);
  await usdc.mint(bob.address, MINT);
  await usdc.mint(liquidator.address, MINT);
  await eurc.mint(alice.address, MINT);
  await eurc.mint(bob.address, MINT);

  return { pool, oracle, le, usdc, eurc, uUsdc, dUsdc, uEurc, dEurc, owner, treasury, alice, bob, liquidator };
}

describe("UnitFlowLiquidationEngine", () => {
  it("isLiquidatable returns false for healthy position", async () => {
    const { pool, le, usdc, eurc, alice, bob } = await deployFixture();
    const liquidity = ethers.parseUnits("10000", 6);
    await usdc.connect(alice).approve(await pool.getAddress(), liquidity);
    await pool.connect(alice).supply(await usdc.getAddress(), liquidity, alice.address);

    const collateral = ethers.parseUnits("2000", 6);
    await eurc.connect(bob).approve(await pool.getAddress(), collateral);
    await pool.connect(bob).supply(await eurc.getAddress(), collateral, bob.address);

    await pool.connect(bob).borrow(await usdc.getAddress(), ethers.parseUnits("500", 6), bob.address);

    expect(await le.isLiquidatable(bob.address)).to.be.false;
  });

  it("liquidation reverts when position is healthy", async () => {
    const { pool, le, usdc, eurc, alice, bob, liquidator } = await deployFixture();
    const liquidity = ethers.parseUnits("10000", 6);
    await usdc.connect(alice).approve(await pool.getAddress(), liquidity);
    await pool.connect(alice).supply(await usdc.getAddress(), liquidity, alice.address);

    const collateral = ethers.parseUnits("2000", 6);
    await eurc.connect(bob).approve(await pool.getAddress(), collateral);
    await pool.connect(bob).supply(await eurc.getAddress(), collateral, bob.address);

    await pool.connect(bob).borrow(await usdc.getAddress(), ethers.parseUnits("500", 6), bob.address);

    const debtToCover = ethers.parseUnits("100", 6);
    await usdc.connect(liquidator).approve(await le.getAddress(), debtToCover);
    await expect(
      le.connect(liquidator).liquidate(
        bob.address,
        await eurc.getAddress(),
        await usdc.getAddress(),
        debtToCover
      )
    ).to.be.revertedWith("LE: position healthy");
  });

  it("liquidates undercollateralised position after oracle price drop", async () => {
    const { pool, oracle, le, usdc, eurc, alice, bob, liquidator } = await deployFixture();

    // Alice provides USDC liquidity
    const liquidity = ethers.parseUnits("10000", 6);
    await usdc.connect(alice).approve(await pool.getAddress(), liquidity);
    await pool.connect(alice).supply(await usdc.getAddress(), liquidity, alice.address);

    // Bob supplies EURC collateral and borrows near max LTV
    const collateral = ethers.parseUnits("1000", 6); // $1080 at $1.08
    await eurc.connect(bob).approve(await pool.getAddress(), collateral);
    await pool.connect(bob).supply(await eurc.getAddress(), collateral, bob.address);

    // Borrow $700 (LTV limit ~$720 — just under)
    const borrowAmt = ethers.parseUnits("700", 6);
    await pool.connect(bob).borrow(await usdc.getAddress(), borrowAmt, bob.address);

    // Verify position is healthy before price drop
    expect(await le.isLiquidatable(bob.address)).to.be.false;

    // Drop EURC price to $0.90 — collateral now worth $900, debt $700
    // healthFactor = ($900 * 66.67%) / $700 = $600 / $700 = 0.857 < 1 → liquidatable
    await oracle.setFallbackPrice(await eurc.getAddress(), 90_000_000n); // $0.90

    expect(await le.isLiquidatable(bob.address)).to.be.true;

    // Liquidator covers 50% of debt (close factor)
    const debtToCover = ethers.parseUnits("350", 6);
    const liquidatorUsdcBefore = await usdc.balanceOf(liquidator.address);
    const liquidatorEurcBefore = await eurc.balanceOf(liquidator.address);

    await usdc.connect(liquidator).approve(await le.getAddress(), debtToCover);
    await le.connect(liquidator).liquidate(
      bob.address,
      await eurc.getAddress(),
      await usdc.getAddress(),
      debtToCover
    );

    const liquidatorUsdcAfter = await usdc.balanceOf(liquidator.address);
    const liquidatorEurcAfter = await eurc.balanceOf(liquidator.address);

    // Liquidator spent USDC
    expect(liquidatorUsdcAfter).to.be.lt(liquidatorUsdcBefore);
    // Liquidator received EURC collateral + 5% bonus
    expect(liquidatorEurcAfter).to.be.gt(liquidatorEurcBefore);

    // Verify bonus: received collateral value > debt covered value
    const eurcReceived = liquidatorEurcAfter - liquidatorEurcBefore;
    const eurcValueUSD = (eurcReceived * 90_000_000n) / 10n ** 8n; // in 6-decimal USD
    const debtValueUSD = debtToCover; // USDC is $1
    // eurcValueUSD should be ~5% more than debtValueUSD
    expect(eurcValueUSD).to.be.gt(debtValueUSD);
  });

  it("getHealthFactor matches pool getUserAccountData", async () => {
    const { pool, le, usdc, eurc, alice, bob } = await deployFixture();
    const liquidity = ethers.parseUnits("10000", 6);
    await usdc.connect(alice).approve(await pool.getAddress(), liquidity);
    await pool.connect(alice).supply(await usdc.getAddress(), liquidity, alice.address);

    const collateral = ethers.parseUnits("2000", 6);
    await eurc.connect(bob).approve(await pool.getAddress(), collateral);
    await pool.connect(bob).supply(await eurc.getAddress(), collateral, bob.address);

    await pool.connect(bob).borrow(await usdc.getAddress(), ethers.parseUnits("600", 6), bob.address);

    const hfFromLE   = await le.getHealthFactor(bob.address);
    const hfFromPool = (await pool.getUserAccountData(bob.address)).healthFactor;
    expect(hfFromLE).to.equal(hfFromPool);
  });
});
