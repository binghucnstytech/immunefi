const { expect } = require("chai");
const { ethers, config } = require("hardhat");

describe("functionality tests for BuggyNFT", () => {
  let deployer, user0, user1;
  let BuggyNFTFactory, nft;
  let WETH, USDC, ROUTER;

  const ONE_ETHER = ethers.utils.parseEther("1");

  before(async () => {
    [deployer, user0, user1, user2] = await ethers.getSigners();
    BuggyNFTFactory = await ethers.getContractFactory("BuggyNFT", deployer);
    WETH = await ethers.getContractAt("IWETH", "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
    USDC = await ethers.getContractAt("IERC20", "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
    ROUTER = await ethers.getContractAt("IUniswapV2Router02", "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D");
  });

  beforeEach(async function() {
    this.timeout(60000);
    await network.provider.request({
      method: "hardhat_reset",
      params: [
        {
          forking: {
            jsonRpcUrl: config.networks.hardhat.forking.url,
          },
        },
      ],
    });
    nft = await BuggyNFTFactory.deploy();
    await nft.connect(deployer).initialize();

    let deadline = (await ethers.provider.getBlock("latest")).timestamp + 300;
    await ROUTER.connect(user0).swapExactETHForTokens(0, [WETH.address, USDC.address], user0.address, deadline, {value: ONE_ETHER.mul(10)});
    let balance = await USDC.balanceOf(user0.address);
    await USDC.connect(user0).approve(nft.address, balance);
  });

  async function mint(user, asset, amount) {
    if (typeof asset === "undefined") {
      asset = ethers.constants.AddressZero;
    }
    if (typeof amount === "undefined") {
      amount = ONE_ETHER;
    }
    let aux = {};
    if (asset == ethers.constants.AddressZero) {
      aux = {value: amount};
    }
    let tx = await nft.connect(user).mint(asset, amount, aux);
    let receipt = await tx.wait();
    let filter = nft.filters.Mint(null, user.address);
    let events = await nft.queryFilter(filter, receipt.blockHash);
    await expect(events).to.have.lengthOf(1);
    return [events[0].args.tokenId, tx];
  }

  describe("mint", async () => {
    it("ether", async () => {
      let [tokenId] = await mint(user0);
      await expect(await nft.lastPrice(tokenId)).to.be.equal(ONE_ETHER.mul(995).div(1000));
    });
    it("USDC", async () => {
      let [tokenId, tx] = await mint(user0, USDC.address, ethers.utils.parseUnits("10000", 6));
      let receipt = await tx.wait();
      let filter = WETH.filters.Transfer(null, ROUTER.address, null);
      let events = await WETH.queryFilter(filter, receipt.blockHash);
      await expect(events).to.have.lengthOf(1);
      let amount = events[0].args[2];
      await expect(await nft.lastPrice(tokenId)).to.be.equal(amount);
    });
  });

  describe("burn", async () => {
    let tokenId;
    beforeEach(async () => {
      [tokenId] = await mint(user0);
    });
    it("ether", async () => {
      let beforeBalance = await ethers.provider.getBalance(user0.address);
      let tx = await nft.connect(user0).burn(tokenId, ethers.constants.AddressZero);
      let receipt = await tx.wait();
      let gas = tx.gasPrice.mul(receipt.gasUsed);
      await expect(tx).to.emit(nft, "Burn");
      let afterBalance = await ethers.provider.getBalance(user0.address);
      await expect(afterBalance.sub(beforeBalance)).to.be.equal(ONE_ETHER.mul(995).div(1000).sub(gas));
    });
    it("USDC", async () => {
      let beforeBalance = await USDC.balanceOf(user0.address);
      await nft.connect(user0).burn(tokenId, USDC.address);
      let afterBalance = await USDC.balanceOf(user0.address);
      await expect(afterBalance).to.be.above(beforeBalance);
    });
  });

  describe("transfer tests", () => {
    let tokenId;

    beforeEach(async () => {
      let tx = await nft.connect(user0).mint(ethers.constants.AddressZero, ONE_ETHER, {value: ONE_ETHER});
      let receipt = await tx.wait();
      let filter = nft.filters.Mint(null, user0.address);
      let events = await nft.queryFilter(filter, receipt.blockHash);
      await expect(events).to.have.lengthOf(1);
      tokenId = events[0].args.tokenId;
      await nft.connect(user0).approve(tokenId, user0.address, []);
    });

    it("transfer", async () => {
      await expect(await nft.connect(user0).transfer(tokenId, user1.address, [])).to.emit(nft, "Transfer").withArgs(user0.address, user1.address, tokenId);
      await expect(await nft.isApproved(tokenId, user0.address)).to.be.false;
    });

    it("approve", async () => {
      await expect(await nft.connect(user0).approve(tokenId, user1.address, [])).to.emit(nft, "Approve").withArgs(tokenId, user1.address);
      await nft.connect(user1).transfer(tokenId, user2.address, []);
      await expect(await nft.isOwner(tokenId, user2.address)).to.be.true;
    });

    describe("buy", () => {
      it("ether", async () => {
        let amount = ONE_ETHER.mul(2);
        await nft.connect(user1).buy(tokenId, ethers.constants.AddressZero, amount, {value: amount});
        await expect(await nft.isOwner(tokenId, user1.address)).to.be.true;
      });
      it("USDC", async () => {
        let amount = ethers.utils.parseUnits("10000", 6);
        await USDC.connect(user0).transfer(user1.address, amount);
        await USDC.connect(user1).approve(nft.address, amount);
        await nft.connect(user1).buy(tokenId, USDC.address, amount);
        await expect(await nft.isOwner(tokenId, user1.address)).to.be.true;
      });
    });

    it("permit", async () => {
      let separator = await nft.DOMAIN_SEPARATOR();
      let domain = {
        name: "BuggyNFT",
        version: "1",
        chainId: (await ethers.provider.getNetwork()).chainId,
        verifyingContract: nft.address,
      };
      let types = {
        Permit: [
          {
            name: "tokenId",
            type: "uint256",
          },
          {
            name: "spender",
            type: "address",
          },
        ]
      };
      let value = { tokenId, spender: user1.address };
      let signature = await user0._signTypedData(domain, types, value);
      signature = ethers.utils.splitSignature(signature);
      await nft.connect(user1).permit(tokenId, user1.address, signature.v, signature.r, signature.s);
      await nft.connect(user1).transfer(tokenId, user2.address, []);
      await expect(await nft.isOwner(tokenId, user2.address)).to.be.true;
    });
  });
});
