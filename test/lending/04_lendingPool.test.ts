import { expect } from "chai";
import { ethers } from "hardhat";
import type {
  UnitFlowLendingPool,
  UnitFlowPriceOracle,
  UnitFlowInterestRateModel,
  UnitFlowUToken,
  UnitFlowDebtToken,
  UnitFlowFeeDistributor,
  UnitFlowLiquidationEngine,
  ERC20,
} from "../../typechain-types";

// ---------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------

async function deployFixture() {
  const [owner, treasury, alice, bob, liquidator] = await ethers.getSigners();

  // Deploy mock ERC20 tokens (6 decimals like USDC/EURC)
  const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
  const usdc = await ERC20Mock.deploy("USD Coin", "USDC", 6) as any;
  const eurc = await ERC20Mock.deploy("Euro Coin", "EURC", 6) as any;

  // Oracle
  const Oracle = await ethers.getContractFactory("UnitFlowPriceOracle");
  const oracle = await Oracle.deploy(owner.address) as UnitFlowPriceOracle;
  await oracle.setFeed(await usdc.getAddress(), ethers.ZeroAddress, 100_000_000n); // $1.00
  await oracle.setFeed(await eurc.getAddress(), ethers.ZeroAddress, 108_000_000n); // $1.08

  // Interest Rate Model: 1% base, 4% slope1, 75% slope2, 80% optimal
  const RAY = 10n ** 27n;
  const IRM = await ethers.getContractFactory("UnitFlowInterestRateModel");
  // constructor(optimalUtilization, baseRate, slope1, slope2)
  const irm = await IRM.deploy(
    (80n * RAY) / 100n,  // optimal 80%
    RAY / 100n,          // base 1%
    (4n * RAY) / 100n,   // slope1 4%
    (75n * RAY) / 100n,  // slope2 75%
  ) as UnitFlowInterestRateModel;

  // Fee Distributor (placeholder — pool address set after pool deploy)
  const FD = await ethers.getContractFactory("UnitFlowFeeDistributor");
  const fd = await FD.deploy(
    treasury.address,
    ethers.ZeroAddress, // updated below
    owner.address,
  ) as UnitFlowFeeDistributor;

  // Lending Pool
  const Pool = await ethers.getContractFactory("UnitFlowLendingPool");
  const pool = await Pool.deploy(
    await oracle.getAddress(),
    await irm.getAddress(),
    await fd.getAddress(),
    owner.address,
  ) as UnitFlowLendingPool;

  // Update fee distributor with real pool address
  await fd.setLendingPool(await pool.getAddress());

  // Deploy uTokens and debtTokens for USDC
  // constructor(name, symbol, underlyingAsset, owner)
  const UToken = await ethers.getContractFactory("UnitFlowUToken");
  const uUsdc = await UToken.deploy(
    "UnitFlow USDC", "uUSDC", await usdc.getAddress(), owner.address
  ) as UnitFlowUToken;

  const DebtToken = await ethers.getContractFactory("UnitFlowDebtToken");
  const dUsdc = await DebtToken.deploy(
    "UnitFlow Debt USDC", "dUSDC", await usdc.getAddress(), owner.address
  ) as UnitFlowDebtToken;

  // Deploy uTokens and debtTokens for EURC
  const uEurc = await UToken.deploy(
    "UnitFlow EURC", "uEURC", await eurc.getAddress(), owner.address
  ) as UnitFlowUToken;
  const dEurc = await DebtToken.deploy(
    "UnitFlow Debt EURC", "dEURC", await eurc.getAddress(), owner.address
  ) as UnitFlowDebtToken;

  // Wire tokens to pool
  await uUsdc.setPool(await pool.getAddress());
  await dUsdc.setPool(await pool.getAddress());
  await uEurc.setPool(await pool.getAddress());
  await dEurc.setPool(await pool.getAddress());

  // Add reserves
  await pool.addReserve(await usdc.getAddress(), await uUsdc.getAddress(), await dUsdc.getAddress());
  await pool.addReserve(await eurc.getAddress(), await uEurc.getAddress(), await dEurc.getAddress());

  // Liquidation Engine
  const LE = await ethers.getContractFactory("UnitFlowLiquidationEngine");
  const le = await LE.deploy(await pool.getAddress(), owner.address) as UnitFlowLiquidationEngine;
  await pool.setLiquidationEngine(await le.getAddress());

  // Mint test tokens
  const MINT = ethers.parseUnits("1000000", 6); // 1M each
  await usdc.mint(alice.address,     MINT);
  await usdc.mint(bob.address,       MINT);
  await usdc.mint(liquidator.address, MINT);
  await eurc.mint(alice.address,     MINT);
  await eurc.mint(bob.address,       MINT);

  return { pool, oracle, irm, fd, le, usdc, eurc, uUsdc, dUsdc, uEurc, dEurc, owner, treasury, alice, bob, liquidator };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("UnitFlowLendingPool", () => {
  describe("Supply", () => {
    it("mints uTokens 1:1 on first supply", async () => {
      const { pool, usdc, uUsdc, alice } = await deployFixture();
      const amount = ethers.parseUnits("1000", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), amount);
      await pool.connect(alice).supply(await usdc.getAddress(), amount, alice.address);

      const uBalance = await uUsdc.balanceOf(alice.address);
      expect(uBalance).to.equal(amount);
    });

    it("increases totalLiquidity", async () => {
      const { pool, usdc, alice } = await deployFixture();
      const amount = ethers.parseUnits("500", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), amount);
      await pool.connect(alice).supply(await usdc.getAddress(), amount, alice.address);

      const reserve = await pool.reserves(await usdc.getAddress());
      expect(reserve.totalLiquidity).to.equal(amount);
    });

    it("reverts on zero amount", async () => {
      const { pool, usdc, alice } = await deployFixture();
      await expect(
        pool.connect(alice).supply(await usdc.getAddress(), 0n, alice.address)
      ).to.be.revertedWith("Pool: zero amount");
    });

    it("reverts for unsupported asset", async () => {
      const { pool, alice } = await deployFixture();
      const random = ethers.Wallet.createRandom().address;
      await expect(
        pool.connect(alice).supply(random, 100n, alice.address)
      ).to.be.revertedWith("Pool: reserve not active");
    });
  });

  describe("Withdraw", () => {
    it("burns uTokens and returns underlying", async () => {
      const { pool, usdc, uUsdc, alice } = await deployFixture();
      const amount = ethers.parseUnits("1000", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), amount);
      await pool.connect(alice).supply(await usdc.getAddress(), amount, alice.address);

      const balBefore = await usdc.balanceOf(alice.address);
      await pool.connect(alice).withdraw(await usdc.getAddress(), amount, alice.address);

      expect(await uUsdc.balanceOf(alice.address)).to.equal(0n);
      expect(await usdc.balanceOf(alice.address)).to.equal(balBefore + amount);
    });

    it("type(uint256).max withdraws full balance", async () => {
      const { pool, usdc, uUsdc, alice } = await deployFixture();
      const amount = ethers.parseUnits("500", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), amount);
      await pool.connect(alice).supply(await usdc.getAddress(), amount, alice.address);

      await pool.connect(alice).withdraw(
        await usdc.getAddress(),
        ethers.MaxUint256,
        alice.address
      );
      expect(await uUsdc.balanceOf(alice.address)).to.equal(0n);
    });

    it("reverts when withdrawing more than balance", async () => {
      const { pool, usdc, alice } = await deployFixture();
      const amount = ethers.parseUnits("100", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), amount);
      await pool.connect(alice).supply(await usdc.getAddress(), amount, alice.address);

      await expect(
        pool.connect(alice).withdraw(
          await usdc.getAddress(),
          ethers.parseUnits("200", 6),
          alice.address
        )
      ).to.be.revertedWith("Pool: exceeds balance");
    });
  });

  describe("Borrow", () => {
    it("transfers underlying and mints debt tokens", async () => {
      const { pool, usdc, eurc, dUsdc, alice, bob } = await deployFixture();
      // Alice supplies USDC as liquidity
      const liquidity = ethers.parseUnits("10000", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), liquidity);
      await pool.connect(alice).supply(await usdc.getAddress(), liquidity, alice.address);

      // Bob supplies EURC as collateral
      const collateral = ethers.parseUnits("2000", 6); // $2160 at $1.08
      await eurc.connect(bob).approve(await pool.getAddress(), collateral);
      await pool.connect(bob).supply(await eurc.getAddress(), collateral, bob.address);

      // Bob borrows USDC — max LTV 66.67% of $2160 = ~$1440
      const borrowAmt = ethers.parseUnits("1000", 6); // $1000 < $1440 — safe
      const bobUsdcBefore = await usdc.balanceOf(bob.address);
      await pool.connect(bob).borrow(await usdc.getAddress(), borrowAmt, bob.address);

      expect(await usdc.balanceOf(bob.address)).to.equal(bobUsdcBefore + borrowAmt);
      const debt = await dUsdc.balanceOf(bob.address, 10n ** 27n); // index = RAY initially
      expect(debt).to.be.gte(borrowAmt - 1n); // allow 1 wei rounding
    });

    it("reverts when borrow exceeds LTV", async () => {
      const { pool, usdc, eurc, alice, bob } = await deployFixture();
      const liquidity = ethers.parseUnits("10000", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), liquidity);
      await pool.connect(alice).supply(await usdc.getAddress(), liquidity, alice.address);

      const collateral = ethers.parseUnits("1000", 6); // $1080
      await eurc.connect(bob).approve(await pool.getAddress(), collateral);
      await pool.connect(bob).supply(await eurc.getAddress(), collateral, bob.address);

      // Try to borrow $800 against $1080 collateral — LTV limit is $720
      await expect(
        pool.connect(bob).borrow(
          await usdc.getAddress(),
          ethers.parseUnits("800", 6),
          bob.address
        )
      ).to.be.revertedWith("Pool: borrow exceeds LTV");
    });

    it("reverts when pool has insufficient liquidity", async () => {
      const { pool, usdc, eurc, alice, bob } = await deployFixture();
      // Alice supplies only 100 USDC
      const liquidity = ethers.parseUnits("100", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), liquidity);
      await pool.connect(alice).supply(await usdc.getAddress(), liquidity, alice.address);

      // Bob supplies large EURC collateral
      const collateral = ethers.parseUnits("100000", 6);
      await eurc.connect(bob).approve(await pool.getAddress(), collateral);
      await pool.connect(bob).supply(await eurc.getAddress(), collateral, bob.address);

      // Try to borrow more than available
      await expect(
        pool.connect(bob).borrow(
          await usdc.getAddress(),
          ethers.parseUnits("200", 6),
          bob.address
        )
      ).to.be.revertedWith("Pool: insufficient liquidity");
    });
  });

  describe("Repay", () => {
    it("reduces debt and returns underlying to pool", async () => {
      const { pool, usdc, eurc, dUsdc, alice, bob } = await deployFixture();
      const liquidity = ethers.parseUnits("10000", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), liquidity);
      await pool.connect(alice).supply(await usdc.getAddress(), liquidity, alice.address);

      const collateral = ethers.parseUnits("2000", 6);
      await eurc.connect(bob).approve(await pool.getAddress(), collateral);
      await pool.connect(bob).supply(await eurc.getAddress(), collateral, bob.address);

      const borrowAmt = ethers.parseUnits("1000", 6);
      await pool.connect(bob).borrow(await usdc.getAddress(), borrowAmt, bob.address);

      // Repay half
      const repayAmt = ethers.parseUnits("500", 6);
      await usdc.connect(bob).approve(await pool.getAddress(), repayAmt);
      await pool.connect(bob).repay(await usdc.getAddress(), repayAmt, bob.address);

      const RAY = 10n ** 27n;
      const remainingDebt = await dUsdc.balanceOf(bob.address, RAY);
      expect(remainingDebt).to.be.lte(borrowAmt - repayAmt + 1n);
    });

    it("type(uint256).max repays full debt", async () => {
      const { pool, usdc, eurc, dUsdc, alice, bob } = await deployFixture();
      const liquidity = ethers.parseUnits("10000", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), liquidity);
      await pool.connect(alice).supply(await usdc.getAddress(), liquidity, alice.address);

      const collateral = ethers.parseUnits("2000", 6);
      await eurc.connect(bob).approve(await pool.getAddress(), collateral);
      await pool.connect(bob).supply(await eurc.getAddress(), collateral, bob.address);

      const borrowAmt = ethers.parseUnits("1000", 6);
      await pool.connect(bob).borrow(await usdc.getAddress(), borrowAmt, bob.address);

      // Approve more than debt to cover interest
      await usdc.connect(bob).approve(await pool.getAddress(), borrowAmt * 2n);
      await pool.connect(bob).repay(await usdc.getAddress(), ethers.MaxUint256, bob.address);

      const RAY = 10n ** 27n;
      expect(await dUsdc.balanceOf(bob.address, RAY)).to.equal(0n);
    });

    it("reverts when user has no debt", async () => {
      const { pool, usdc, alice } = await deployFixture();
      await expect(
        pool.connect(alice).repay(await usdc.getAddress(), 100n, alice.address)
      ).to.be.revertedWith("Pool: no debt");
    });
  });

  describe("getUserAccountData", () => {
    it("returns max health factor when no debt", async () => {
      const { pool, usdc, alice } = await deployFixture();
      const amount = ethers.parseUnits("1000", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), amount);
      await pool.connect(alice).supply(await usdc.getAddress(), amount, alice.address);

      const data = await pool.getUserAccountData(alice.address);
      expect(data.healthFactor).to.equal(ethers.MaxUint256);
    });

    it("health factor decreases as debt increases", async () => {
      const { pool, usdc, eurc, alice, bob } = await deployFixture();
      const liquidity = ethers.parseUnits("10000", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), liquidity);
      await pool.connect(alice).supply(await usdc.getAddress(), liquidity, alice.address);

      const collateral = ethers.parseUnits("2000", 6); // $2160
      await eurc.connect(bob).approve(await pool.getAddress(), collateral);
      await pool.connect(bob).supply(await eurc.getAddress(), collateral, bob.address);

      const borrow1 = ethers.parseUnits("500", 6);
      await pool.connect(bob).borrow(await usdc.getAddress(), borrow1, bob.address);
      const data1 = await pool.getUserAccountData(bob.address);

      const borrow2 = ethers.parseUnits("400", 6);
      await pool.connect(bob).borrow(await usdc.getAddress(), borrow2, bob.address);
      const data2 = await pool.getUserAccountData(bob.address);

      expect(data2.healthFactor).to.be.lt(data1.healthFactor);
    });
  });

  describe("Pause", () => {
    it("reverts supply when paused", async () => {
      const { pool, usdc, alice, owner } = await deployFixture();
      await pool.connect(owner).pause();
      const amount = ethers.parseUnits("100", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), amount);
      await expect(
        pool.connect(alice).supply(await usdc.getAddress(), amount, alice.address)
      ).to.be.revertedWithCustomError(pool, "EnforcedPause");
    });

    it("resumes after unpause", async () => {
      const { pool, usdc, alice, owner } = await deployFixture();
      await pool.connect(owner).pause();
      await pool.connect(owner).unpause();
      const amount = ethers.parseUnits("100", 6);
      await usdc.connect(alice).approve(await pool.getAddress(), amount);
      await expect(
        pool.connect(alice).supply(await usdc.getAddress(), amount, alice.address)
      ).to.not.be.reverted;
    });
  });
});
