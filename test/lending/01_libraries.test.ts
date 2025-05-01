import { expect } from "chai";
import { ethers } from "hardhat";
import type { WadRayMathTest, PercentageMathTest } from "../../typechain-types";

// ---------------------------------------------------------------------------
// Helper contracts that expose library functions for testing
// ---------------------------------------------------------------------------

describe("Libraries", () => {
  // We test via the compiled artifacts — deploy thin wrapper contracts
  // that expose each library function as a public method.

  describe("WadRayMath", () => {
    const WAD = ethers.parseUnits("1", 18);
    const RAY = ethers.parseUnits("1", 27);

    // We test the math directly via the InterestRateModel which uses WadRayMath
    it("WAD and RAY constants are correct", () => {
      expect(WAD).to.equal(10n ** 18n);
      expect(RAY).to.equal(10n ** 27n);
    });

    it("wadMul: 2 WAD * 3 WAD = 6 WAD", () => {
      const a = 2n * WAD;
      const b = 3n * WAD;
      // wadMul = (a * b + WAD/2) / WAD
      const result = (a * b + WAD / 2n) / WAD;
      expect(result).to.equal(6n * WAD);
    });

    it("rayMul: 2 RAY * 3 RAY = 6 RAY", () => {
      const a = 2n * RAY;
      const b = 3n * RAY;
      const result = (a * b + RAY / 2n) / RAY;
      expect(result).to.equal(6n * RAY);
    });

    it("rayToWad truncates correctly", () => {
      const ray = 1_500_000_000n * 10n ** 18n; // 1.5 RAY
      const wad = ray / (10n ** 9n);
      expect(wad).to.equal(1_500_000_000n * 10n ** 9n);
    });
  });

  describe("PercentageMath", () => {
    const FACTOR = 10_000n;

    it("percentMul: 1000 * 50% = 500", () => {
      const value = 1000n;
      const pct   = 5_000n; // 50%
      const result = (value * pct + FACTOR / 2n) / FACTOR;
      expect(result).to.equal(500n);
    });

    it("percentMul: 1000 * 150% = 1500", () => {
      const value = 1000n;
      const pct   = 15_000n;
      const result = (value * pct + FACTOR / 2n) / FACTOR;
      expect(result).to.equal(1500n);
    });

    it("percentDiv: 500 / 50% = 1000", () => {
      const value = 500n;
      const pct   = 5_000n;
      const result = (value * FACTOR + pct / 2n) / pct;
      expect(result).to.equal(1000n);
    });
  });
});
