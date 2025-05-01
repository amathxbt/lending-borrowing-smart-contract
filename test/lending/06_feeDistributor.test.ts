import { expect } from "chai";
import { ethers } from "hardhat";

describe("UnitFlowFeeDistributor", () => {
  async function deployFixture() {
    const [owner, treasury, pool, staking, alice] = await ethers.getSigners();

    const ERC20Mock = await ethers.getContractFactory("ERC20Mock");
    const usdc = await ERC20Mock.deploy("USD Coin", "USDC", 6) as any;

    const FD = await ethers.getContractFactory("UnitFlowFeeDistributor");
    const fd = await FD.deploy(treasury.address, pool.address, owner.address) as any;

    return { fd, usdc, owner, treasury, pool, staking, alice };
  }

  it("splits fees 60/20/20 when staking contract is set", async () => {
    const { fd, usdc, owner, treasury, pool, staking } = await deployFixture();
    await fd.setStakingContract(staking.address);

    const amount = ethers.parseUnits("1000", 6);
    await usdc.mint(await fd.getAddress(), amount);

    const treasuryBefore = await usdc.balanceOf(treasury.address);
    const stakingBefore  = await usdc.balanceOf(staking.address);
    const poolBefore     = await usdc.balanceOf(pool.address);

    await fd.connect(pool).distribute(await usdc.getAddress(), amount);

    const treasuryAfter = await usdc.balanceOf(treasury.address);
    const stakingAfter  = await usdc.balanceOf(staking.address);
    const poolAfter     = await usdc.balanceOf(pool.address);

    expect(treasuryAfter - treasuryBefore).to.equal(ethers.parseUnits("200", 6)); // 20%
    expect(stakingAfter  - stakingBefore).to.equal(ethers.parseUnits("200", 6));  // 20%
    expect(poolAfter     - poolBefore).to.equal(ethers.parseUnits("600", 6));     // 60%
  });

  it("accumulates staker reserve when no staking contract", async () => {
    const { fd, usdc, pool } = await deployFixture();
    const amount = ethers.parseUnits("1000", 6);
    await usdc.mint(await fd.getAddress(), amount);

    await fd.connect(pool).distribute(await usdc.getAddress(), amount);

    const pending = await fd.pendingStakerReserve(await usdc.getAddress());
    expect(pending).to.equal(ethers.parseUnits("200", 6)); // 20%
  });

  it("flushStakerReserve forwards pending to staking contract", async () => {
    const { fd, usdc, pool, staking } = await deployFixture();
    const amount = ethers.parseUnits("1000", 6);
    await usdc.mint(await fd.getAddress(), amount);
    await fd.connect(pool).distribute(await usdc.getAddress(), amount);

    // Now set staking contract and flush
    await fd.setStakingContract(staking.address);
    const stakingBefore = await usdc.balanceOf(staking.address);
    await fd.flushStakerReserve(await usdc.getAddress());

    expect(await usdc.balanceOf(staking.address) - stakingBefore)
      .to.equal(ethers.parseUnits("200", 6));
    expect(await fd.pendingStakerReserve(await usdc.getAddress())).to.equal(0n);
  });

  it("flushStakerReserve reverts when no staking contract", async () => {
    const { fd, usdc } = await deployFixture();
    await expect(fd.flushStakerReserve(await usdc.getAddress()))
      .to.be.revertedWith("FD: no staking contract");
  });

  it("only pool or owner can call distribute", async () => {
    const { fd, usdc, alice } = await deployFixture();
    await expect(
      fd.connect(alice).distribute(await usdc.getAddress(), 100n)
    ).to.be.revertedWith("FD: not pool");
  });
});
