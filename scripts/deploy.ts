import { ethers, run, network } from "hardhat";

// ---------------------------------------------------------------------------
// Deployment order:
//   1. UnitFlowPriceOracle
//   2. UnitFlowInterestRateModel
//   3. UnitFlowFeeDistributor  (pool address = ZeroAddress initially)
//   4. UnitFlowLendingPool
//   5. UnitFlowUToken  x2  (USDC, EURC)
//   6. UnitFlowDebtToken x2 (USDC, EURC)
//   7. Wire tokens → pool (setPool)
//   8. pool.addReserve x2
//   9. UnitFlowLiquidationEngine
//  10. pool.setLiquidationEngine
//  11. fd.setLendingPool
//  12. UnitFlowLendingConfigurator
//  13. oracle.setFeed x2 (USDC, EURC fallback prices)
// ---------------------------------------------------------------------------

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`Deploying from: ${deployer.address}`);
  console.log(`Network: ${network.name}`);

  const USDC     = process.env.USDC_ADDRESS!;
  const EURC     = process.env.EURC_ADDRESS!;
  const OWNER    = process.env.OWNER_ADDRESS    ?? deployer.address;
  const TREASURY = process.env.TREASURY_ADDRESS ?? deployer.address;

  if (!USDC || !EURC) throw new Error("USDC_ADDRESS and EURC_ADDRESS must be set in .env");

  const RAY = 10n ** 27n;

  // ── 1. Oracle ──────────────────────────────────────────────────────────────
  console.log("\n[1/13] Deploying UnitFlowPriceOracle...");
  const Oracle = await ethers.getContractFactory("UnitFlowPriceOracle");
  const oracle = await Oracle.deploy(OWNER);
  await oracle.waitForDeployment();
  console.log(`  UnitFlowPriceOracle: ${await oracle.getAddress()}`);

  // ── 2. Interest Rate Model ─────────────────────────────────────────────────
  // Params: optimal=80%, base=1%, slope1=4%, slope2=75%
  console.log("\n[2/13] Deploying UnitFlowInterestRateModel...");
  const IRM = await ethers.getContractFactory("UnitFlowInterestRateModel");
  const irm = await IRM.deploy(
    (80n * RAY) / 100n,  // optimalUtilizationRate
    RAY / 100n,          // baseVariableBorrowRate (1%)
    (4n * RAY) / 100n,   // variableRateSlope1 (4%)
    (75n * RAY) / 100n,  // variableRateSlope2 (75%)
  );
  await irm.waitForDeployment();
  console.log(`  UnitFlowInterestRateModel: ${await irm.getAddress()}`);

  // ── 3. Fee Distributor (pool address set later) ────────────────────────────
  console.log("\n[3/13] Deploying UnitFlowFeeDistributor...");
  const FD = await ethers.getContractFactory("UnitFlowFeeDistributor");
  const fd = await FD.deploy(TREASURY, ethers.ZeroAddress, OWNER);
  await fd.waitForDeployment();
  console.log(`  UnitFlowFeeDistributor: ${await fd.getAddress()}`);

  // ── 4. Lending Pool ────────────────────────────────────────────────────────
  console.log("\n[4/13] Deploying UnitFlowLendingPool...");
  const Pool = await ethers.getContractFactory("UnitFlowLendingPool");
  const pool = await Pool.deploy(
    await oracle.getAddress(),
    await irm.getAddress(),
    await fd.getAddress(),
    OWNER,
  );
  await pool.waitForDeployment();
  console.log(`  UnitFlowLendingPool: ${await pool.getAddress()}`);

  // ── 5. uTokens ────────────────────────────────────────────────────────────
  console.log("\n[5/13] Deploying UnitFlowUToken x2...");
  const UToken = await ethers.getContractFactory("UnitFlowUToken");

  const uUsdc = await UToken.deploy("UnitFlow USDC", "uUSDC", USDC, OWNER);
  await uUsdc.waitForDeployment();
  console.log(`  uUSDC: ${await uUsdc.getAddress()}`);

  const uEurc = await UToken.deploy("UnitFlow EURC", "uEURC", EURC, OWNER);
  await uEurc.waitForDeployment();
  console.log(`  uEURC: ${await uEurc.getAddress()}`);

  // ── 6. Debt Tokens ────────────────────────────────────────────────────────
  console.log("\n[6/13] Deploying UnitFlowDebtToken x2...");
  const DebtToken = await ethers.getContractFactory("UnitFlowDebtToken");

  const dUsdc = await DebtToken.deploy("UnitFlow Debt USDC", "dUSDC", USDC, OWNER);
  await dUsdc.waitForDeployment();
  console.log(`  dUSDC: ${await dUsdc.getAddress()}`);

  const dEurc = await DebtToken.deploy("UnitFlow Debt EURC", "dEURC", EURC, OWNER);
  await dEurc.waitForDeployment();
  console.log(`  dEURC: ${await dEurc.getAddress()}`);

  // ── 7. Wire tokens → pool ─────────────────────────────────────────────────
  console.log("\n[7/13] Wiring tokens to pool...");
  await (await uUsdc.setPool(await pool.getAddress())).wait();
  await (await uEurc.setPool(await pool.getAddress())).wait();
  await (await dUsdc.setPool(await pool.getAddress())).wait();
  await (await dEurc.setPool(await pool.getAddress())).wait();
  console.log("  Done.");

  // ── 8. Add reserves ───────────────────────────────────────────────────────
  console.log("\n[8/13] Adding reserves...");
  await (await pool.addReserve(USDC, await uUsdc.getAddress(), await dUsdc.getAddress())).wait();
  console.log("  USDC reserve added.");
  await (await pool.addReserve(EURC, await uEurc.getAddress(), await dEurc.getAddress())).wait();
  console.log("  EURC reserve added.");

  // ── 9. Liquidation Engine ─────────────────────────────────────────────────
  console.log("\n[9/13] Deploying UnitFlowLiquidationEngine...");
  const LE = await ethers.getContractFactory("UnitFlowLiquidationEngine");
  const le = await LE.deploy(await pool.getAddress(), OWNER);
  await le.waitForDeployment();
  console.log(`  UnitFlowLiquidationEngine: ${await le.getAddress()}`);

  // ── 10. Wire liquidation engine → pool ────────────────────────────────────
  console.log("\n[10/13] Wiring liquidation engine to pool...");
  await (await pool.setLiquidationEngine(await le.getAddress())).wait();
  console.log("  Done.");

  // ── 11. Wire pool → fee distributor ───────────────────────────────────────
  console.log("\n[11/13] Wiring pool to fee distributor...");
  await (await fd.setLendingPool(await pool.getAddress())).wait();
  console.log("  Done.");

  // ── 12. Lending Configurator ──────────────────────────────────────────────
  console.log("\n[12/13] Deploying UnitFlowLendingConfigurator...");
  const Cfg = await ethers.getContractFactory("UnitFlowLendingConfigurator");
  const cfg = await Cfg.deploy(await pool.getAddress(), OWNER);
  await cfg.waitForDeployment();
  console.log(`  UnitFlowLendingConfigurator: ${await cfg.getAddress()}`);

  // ── 13. Register oracle feeds (fallback prices, no Chainlink on testnet) ──
  console.log("\n[13/13] Registering oracle feeds...");
  // USDC: $1.00 = 100_000_000 (8 decimals)
  await (await oracle.setFeed(USDC, ethers.ZeroAddress, 100_000_000n)).wait();
  console.log("  USDC feed set ($1.00).");
  // EURC: $1.08 = 108_000_000 (8 decimals)
  await (await oracle.setFeed(EURC, ethers.ZeroAddress, 108_000_000n)).wait();
  console.log("  EURC feed set ($1.08).");

  // ── Summary ───────────────────────────────────────────────────────────────
  const addresses = {
    UnitFlowPriceOracle:          await oracle.getAddress(),
    UnitFlowInterestRateModel:    await irm.getAddress(),
    UnitFlowFeeDistributor:       await fd.getAddress(),
    UnitFlowLendingPool:          await pool.getAddress(),
    uUSDC:                        await uUsdc.getAddress(),
    uEURC:                        await uEurc.getAddress(),
    dUSDC:                        await dUsdc.getAddress(),
    dEURC:                        await dEurc.getAddress(),
    UnitFlowLiquidationEngine:    await le.getAddress(),
    UnitFlowLendingConfigurator:  await cfg.getAddress(),
  };

  console.log("\n=== Deployment complete ===");
  console.log(JSON.stringify(addresses, null, 2));

  // Write addresses to file for verification script
  const fs = await import("fs");
  fs.writeFileSync(
    "deployments/arc-testnet.json",
    JSON.stringify({ network: network.name, timestamp: new Date().toISOString(), addresses }, null, 2)
  );
  console.log("\nAddresses saved to deployments/arc-testnet.json");

  // ── Verify (if not local) ─────────────────────────────────────────────────
  if (network.name !== "hardhat" && network.name !== "localhost") {
    console.log("\nWaiting 10s before verification...");
    await new Promise(r => setTimeout(r, 10_000));
    await verifyAll(addresses, { USDC, EURC, OWNER, TREASURY, RAY });
  }
}

async function verifyAll(
  addresses: Record<string, string>,
  params: { USDC: string; EURC: string; OWNER: string; TREASURY: string; RAY: bigint }
) {
  const { USDC, EURC, OWNER, TREASURY, RAY } = params;

  const verifications: Array<{ name: string; address: string; args: unknown[] }> = [
    { name: "UnitFlowPriceOracle",         address: addresses.UnitFlowPriceOracle,        args: [OWNER] },
    { name: "UnitFlowInterestRateModel",   address: addresses.UnitFlowInterestRateModel,  args: [(80n * RAY) / 100n, RAY / 100n, (4n * RAY) / 100n, (75n * RAY) / 100n] },
    { name: "UnitFlowFeeDistributor",      address: addresses.UnitFlowFeeDistributor,     args: [TREASURY, ethers.ZeroAddress, OWNER] },
    { name: "UnitFlowLendingPool",         address: addresses.UnitFlowLendingPool,        args: [addresses.UnitFlowPriceOracle, addresses.UnitFlowInterestRateModel, addresses.UnitFlowFeeDistributor, OWNER] },
    { name: "UnitFlowUToken",              address: addresses.uUSDC,                      args: ["UnitFlow USDC", "uUSDC", USDC, OWNER] },
    { name: "UnitFlowUToken",              address: addresses.uEURC,                      args: ["UnitFlow EURC", "uEURC", EURC, OWNER] },
    { name: "UnitFlowDebtToken",           address: addresses.dUSDC,                      args: ["UnitFlow Debt USDC", "dUSDC", USDC, OWNER] },
    { name: "UnitFlowDebtToken",           address: addresses.dEURC,                      args: ["UnitFlow Debt EURC", "dEURC", EURC, OWNER] },
    { name: "UnitFlowLiquidationEngine",   address: addresses.UnitFlowLiquidationEngine,  args: [addresses.UnitFlowLendingPool, OWNER] },
    { name: "UnitFlowLendingConfigurator", address: addresses.UnitFlowLendingConfigurator, args: [addresses.UnitFlowLendingPool, OWNER] },
  ];

  for (const v of verifications) {
    try {
      console.log(`\nVerifying ${v.name} at ${v.address}...`);
      await run("verify:verify", { address: v.address, constructorArguments: v.args });
      console.log(`  ✓ Verified`);
    } catch (e: any) {
      if (e.message?.includes("Already Verified")) {
        console.log(`  Already verified.`);
      } else {
        console.warn(`  Verification failed: ${e.message}`);
      }
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
