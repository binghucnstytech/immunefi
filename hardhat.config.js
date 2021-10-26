require("@nomiclabs/hardhat-waffle");
require("@nomiclabs/hardhat-ethers");
require('hardhat-contract-sizer');
require('dotenv').config();
const { API_URL, PRIVATE_KEY } = process.env;
/**
 * @type import('hardhat/config').HardhatUserConfig
 */
module.exports = {
  defaultNetwork: "hardhat",
  mocha: {
    color: false,
  },
  networks: {
    hardhat: {
      hardfork: "london",
      allowUnlimitedContractSize: true,
      forking: {
        // This endpoint is provided to you for the purpose of his coding
        // challenge only. Misuse or abuse will be prosecuted.
        url: "https://eth-mainnet.alchemyapi.io/v2/6M3WhIXIEJewktxphZVvXXh0Sckw2U3x",
      },
    },
    rinkeby: {
      url: API_URL,
      accounts: [`0x${PRIVATE_KEY}`],
      gas: 2100000,
      gasPrice: 8000000000
    }
  },
  solidity: {
    version: "0.8.7",
    settings: {
      optimizer: {
        enabled: true,
        runs: 9999,
      },
    }
  }
};
