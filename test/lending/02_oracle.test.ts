import { expect } from "chai";
import { ethers } from "hardhat";
import type { UnitFlowPriceOracle } from "../../typechain-types";

describe("UnitFlowPriceOracle", () => {
  let oracle: UnitFlowPriceOracle;
  let owner: any, other: any;
  let usdc: string, eurc: string;

  const USDC_PRICE = 100_000_000n; // $1.00 in 8 decimals
  const EURC_PRICE = 108_000_000n; // $1.08 in 8 decimals

  beforeEach(async () => {
    [owner, other] = await ethers.getSigners();
    usdc = ethers.Wallet.createRandom().address;
    eurc = ethers.Wallet.createRandom().address;

    const Oracle = await ethers.getContractFactory("UnitFlowPriceOracle");
    oracle = await Oracle.deploy(owner.address) as UnitFlowPriceOracle;

    // Register both assets with fallback-only feeds (no Chainlink on testnet)
    await oracle.setFeed(usdc, ethers.ZeroAddress, USDC_PRICE);
    await oracle.setFeed(eurc, ethers.ZeroAddress, EURC_PRICE);
  });

  it("returns fallback price when no aggregator is set", async () => {
    expect(await oracle.getAssetPrice(usdc)).to.equal(USDC_PRICE);
    expect(await oracle.getAssetPrice(eurc)).to.equal(EURC_PRICE);
  });

  it("reverts for unsupported asset", async () => {
    const random = ethers.Wallet.createRandom().address;
    await expect(oracle.getAssetPrice(random))
      .to.be.revertedWith("Oracle: asset not supported");
  });

  it("isSupported returns true after setFeed", async () => {
    expect(await oracle.isSupported(usdc)).to.be.true;
    expect(await oracle.isSupported(ethers.Wallet.createRandom().address)).to.be.false;
  });

  it("setFallbackPrice updates the price", async () => {
    const newPrice = 99_900_000n; // $0.999
    await oracle.setFallbackPrice(usdc, newPrice);
    expect(await oracle.getAssetPrice(usdc)).to.equal(newPrice);
  });

  it("setFallbackPrice reverts for zero price", async () => {
    await expect(oracle.setFallbackPrice(usdc, 0n))
      .to.be.revertedWith("Oracle: zero price");
  });

  it("only owner can set feeds", async () => {
    await expect(
      oracle.connect(other).setFeed(usdc, ethers.ZeroAddress, USDC_PRICE)
    ).to.be.reverted;
  });

  it("setFeed reverts for zero fallback price", async () => {
    const newAsset = ethers.Wallet.createRandom().address;
    await expect(oracle.setFeed(newAsset, ethers.ZeroAddress, 0n))
      .to.be.revertedWith("Oracle: zero fallback");
  });
});
