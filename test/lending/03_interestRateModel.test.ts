import { expect } from "chai";
import { ethers } from "hardhat";
import type { UnitFlowInterestRateModel } from "../../typechain-types";

describe("UnitFlowInterestRateModel", () => {
  let irm: UnitFlowInterestRateModel;

  const RAY = 10n ** 27n;
  // Constructor order: (optimalUtilization, baseRate, slope1, slope2)
  const OPTIMAL    = (80n * RAY) / 100n;  // 80%
  const BASE_RATE  = RAY / 100n;          // 1%
  const SLOPE1     = (4n * RAY) / 100n;   // 4%
  const SLOPE2     = (75n * RAY) / 100n;  // 75%

  beforeEach(async () => {
    const IRM = await ethers.getContractFactory("UnitFlowInterestRateModel");
    // constructor(optimalUtilizationRate, baseVariableBorrowRate, variableRateSlope1, variableRateSlope2)
    irm = await IRM.deploy(OPTIMAL, BASE_RATE, SLOPE1, SLOPE2) as UnitFlowInterestRateModel;
  });

  it("borrow rate at 0% utilization = base rate", async () => {
    const rate = await irm.calculateBorrowRate(0n);
    expect(rate).to.equal(BASE_RATE);
  });

  it("borrow rate at optimal utilization = base + slope1", async () => {
    const rate = await irm.calculateBorrowRate(OPTIMAL);
    // At exactly optimal: base + slope1 * (optimal/optimal) = base + slope1
    // Allow 1 RAY rounding from rayDiv
    const expected = BASE_RATE + SLOPE1;
    expect(rate).to.be.closeTo(expected, 1n);
  });

  it("borrow rate above optimal increases steeply", async () => {
    const rateAtOptimal = await irm.calculateBorrowRate(OPTIMAL);
    const rateAt90 = await irm.calculateBorrowRate((90n * RAY) / 100n);
    expect(rateAt90).to.be.gt(rateAtOptimal);
  });

  it("borrow rate at 100% utilization = base + slope1 + slope2", async () => {
    const rate = await irm.calculateBorrowRate(RAY);
    // At 100%: base + slope1 + slope2 * (excess/excess) = base + slope1 + slope2
    const expected = BASE_RATE + SLOPE1 + SLOPE2;
    expect(rate).to.be.closeTo(expected, 1n);
  });

  it("supply rate is always <= borrow rate", async () => {
    for (const util of [0n, OPTIMAL / 2n, OPTIMAL, (90n * RAY) / 100n, RAY]) {
      const borrow = await irm.calculateBorrowRate(util);
      const supply = await irm.calculateSupplyRate(util, 1_000n); // 10% reserve factor
      expect(supply).to.be.lte(borrow);
    }
  });

  it("supply rate at 0% utilization = 0", async () => {
    const rate = await irm.calculateSupplyRate(0n, 1_000n);
    expect(rate).to.equal(0n);
  });

  it("higher reserve factor reduces supply rate", async () => {
    const util = OPTIMAL;
    const rate10pct = await irm.calculateSupplyRate(util, 1_000n);
    const rate20pct = await irm.calculateSupplyRate(util, 2_000n);
    expect(rate20pct).to.be.lt(rate10pct);
  });
});
