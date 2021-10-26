// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

interface IBuggyNFTReceiver {
  function receiveNFT(uint256 tokenId) external returns (bytes4);

  function receiveApproval(uint256 tokenId) external returns (bytes4);
}
