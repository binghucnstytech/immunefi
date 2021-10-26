// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.7;

import {AccessControlEnumerable} from "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IBuggyNFTReceiver} from "./interfaces/IBuggyNFTReceiver.sol";
import {ROUTER} from "./interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";

contract BuggyNFT is AccessControlEnumerable, Pausable {
  using Address for address;

  uint256 public nextNonce;
  mapping(IERC20 => uint256) public feesCollected;
  mapping(uint256 => uint256) public lastPrice;

  uint256 public constant PROTOCOL_FEE = 5;
  uint256 public constant PROTOCOL_FEE_BASIS = 1000;
  uint256 public constant PRICE_INCREMENT = 1;
  uint256 public constant PRICE_INCREMENT_BASIS = 10;
  uint256 public constant SELLER_FEE = 1;
  uint256 public constant SELLER_FEE_BASIS = 5;

  bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

  IERC20 public constant ETHER = IERC20(address(0));

  bytes32 public immutable DOMAIN_SEPARATOR;

  event Mint(uint256 indexed tokenId, address indexed owner);
  event Burn(uint256 indexed tokenId, address indexed owner);
  event Transfer(address indexed owner, address indexed receiver, uint256 indexed tokenId);
  event Approve(uint256 indexed tokenId, address indexed spender);
  event Collect(IERC20 indexed asset, address indexed receiver, uint256 amount);

  constructor() {
    // EIP712-compatible domain separator. Used for `permit`
    bytes32 typeHash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 nameHash = keccak256("BuggyNFT");
    bytes32 versionHash = keccak256("1");
    DOMAIN_SEPARATOR = keccak256(abi.encode(typeHash, nameHash, versionHash, block.chainid, address(this)));
  }

  function initialize() external {
    // we have to call AccessControl.revokeRole by this.revokeRole to get the msg.sender correct
    _setupRole(DEFAULT_ADMIN_ROLE, address(this));
    _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _setupRole(PAUSER_ROLE, msg.sender);
  }

  function _ownerRole(uint256 tokenId) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked("OWNER_ROLE", tokenId));
  }

  function _approvedRole(uint256 tokenId) internal pure returns (bytes32) {
    return keccak256(abi.encodePacked("APPROVED_ROLE", tokenId));
  }

  // Just in case I wrote a bug, we can pause the contract to make sure nobody
  // loses money. But I know I didn't write any bugs.
  function pause() external whenNotPaused onlyRole(PAUSER_ROLE) {
    _pause();
  }

  function unpause() external whenNotPaused onlyRole(PAUSER_ROLE) { // **bug**: whenNotPaused should be replaced with whenPaused.
    _unpause();
  }

  function isOwner(uint256 tokenId, address account) public view returns (bool) {
    return hasRole(_ownerRole(tokenId), account);
  }

  function isApproved(uint256 tokenId, address account) public view returns (bool) {
    return hasRole(_approvedRole(tokenId), account);
  }

  function _check(
    uint256 tokenId,
    address receiver,
    bytes4 selector,
    bytes calldata data
  ) internal returns (bool) {
    if (!receiver.isContract()) {
      return true;
    }
    if (data.length == 0) {
      (bool success, bytes memory returnData) = receiver.call(abi.encodeWithSelector(selector, tokenId));
      return success && returnData.length == 4 && abi.decode(returnData, (bytes4)) == selector;
    } else {
      (bool success, ) = receiver.call(data);
      return success;
    }
  }

  function _nextPrice(uint256 tokenId) internal view returns (uint256) {
    return (lastPrice[tokenId] * (PRICE_INCREMENT + PRICE_INCREMENT_BASIS)) / PRICE_INCREMENT_BASIS;
  }

  function _ethValue(IERC20 asset, uint256 amount) internal view returns (uint256) {
    IUniswapV2Factory factory = IUniswapV2Factory(ROUTER.factory());
    IUniswapV2Pair pair = IUniswapV2Pair(factory.getPair(ROUTER.WETH(), address(asset)));
    (uint112 reserve0, uint112 reserve1, ) = pair.getReserves();
    if (address(asset) == pair.token1()) {
      (reserve0, reserve1) = (reserve1, reserve0);
    }
    return ROUTER.getAmountOut(amount, reserve0, reserve1);
  }

  // A token with higher `level` is rarer, and therefore more valuable
  function level(uint256 tokenId) external pure returns (uint256 i) {
    for (; tokenId & 1 == 0 && i < 256; i++) {
      tokenId >>= 1;
    }
  }

  // A token can be purchased by paying at least 10% more than the price the
  // current owner paid. Don't be too sad, though. The original owner gets a
  // cut.
  function buy(
    uint256 tokenId,
    IERC20 asset,
    uint256 amount
  ) external payable whenNotPaused {
    address oldOwner = getRoleMember(_ownerRole(tokenId), 0);
    uint256 oldPrice = lastPrice[tokenId];
    address msgSender = _msgSender();
    if (asset == ETHER) {
      require(msg.value == amount, "BuggyNFT: amount/value mismatch");
      uint256 fee = ((amount - oldPrice) * PROTOCOL_FEE) / PROTOCOL_FEE_BASIS;
      feesCollected[asset] += fee;
      amount -= fee;
    } else {
      require(!msgSender.isContract(), "BuggyNFT: no flash loan");
      asset.transferFrom(msgSender, address(this), amount);   // **bug**:  sender should approve first - allowance,  **bug** it should be require(asset.transferFrom(msgSender, address(this), amount), "approve failed");
      uint256 ethAmount = _ethValue(asset, amount);
      uint256 ethFee = ((ethAmount - oldPrice) * PROTOCOL_FEE) / PROTOCOL_FEE_BASIS;
      uint256 assetFee = (amount * ethFee) / ethAmount;
      feesCollected[asset] += assetFee;
      amount -= assetFee;
      asset.approve(address(ROUTER), amount); // **bug**:  it should be require(asset.approve(address(ROUTER), amount), "approve failed");
      address[] memory path = new address[](2);
      path[0] = address(asset);
      path[1] = ROUTER.WETH();
      amount = ROUTER.swapExactTokensForETH(amount, 0, path, address(this), block.timestamp)[1];
    }
    uint256 sellerFee = ((amount - oldPrice) * SELLER_FEE) / SELLER_FEE_BASIS;
    amount -= sellerFee;
    require(amount >= _nextPrice(oldPrice), "BuggyNFT: not enough"); 
    payable(oldOwner).transfer(oldPrice + sellerFee);
    bytes32 ownerRole = _ownerRole(tokenId);
    this.revokeRole(ownerRole, oldOwner);
    this.grantRole(ownerRole, msgSender);
    lastPrice[tokenId] += amount;
  }

  // The tokenId is chosen randomly, but the amount of money to be paid has to
  // be chosen beforehand. Make sure you spend a lot otherwise somebody else
  // might buy your rare token out from under you!
  function mint(IERC20 asset, uint256 amount) external payable whenNotPaused {
    require(balanceOf[msg.sender] >= _value && balanceOf[_to] + _value >= balanceOf[_to]);  // *******  _value ?
    address msgSender = _msgSender();
    uint256 tokenId = uint256(
      keccak256(abi.encodePacked(address(this), blockhash(block.number - 1), msgSender, nextNonce))
    );
    this.grantRole(_ownerRole(tokenId), msgSender);
    uint256 fee = (amount * PROTOCOL_FEE) / PROTOCOL_FEE_BASIS;
    feesCollected[asset] += fee;
    if (asset == ETHER) {
      require(msg.value == amount, "BuggyNFT: amount/value mismatch");
      amount -= fee;
    } else {
      require(!msgSender.isContract(), "BuggyNFT: no flash loan");
      asset.transferFrom(msgSender, address(this), amount);
      amount -= fee;
      asset.approve(address(ROUTER), amount);
      address[] memory path = new address[](2);
      path[0] = address(asset);
      path[1] = ROUTER.WETH();
      amount = ROUTER.swapExactTokensForETH(amount, 0, path, address(this), block.timestamp)[1];
    }
    lastPrice[tokenId] = amount;
    nextNonce++;
    emit Mint(tokenId, msgSender);
  }

  // If you're unhappy with your token, you can burn it to get back the money
  // you spent... minus a small fee, of course.
  function burn(uint256 tokenId, IERC20 asset) external onlyRole(_ownerRole(tokenId)) whenNotPaused {
    address msgSender = _msgSender();
    this.revokeRole(_ownerRole(tokenId), msgSender);
    if (asset == ETHER) {
      (bool success, ) = payable(msgSender).call{value: lastPrice[tokenId]}("");
      require(success, "BuggyNFT: transfer failed");
    } else {
      require(!msgSender.isContract(), "BuggyNFT: no flash loan");
      address[] memory path = new address[](2);
      path[0] = ROUTER.WETH();
      path[1] = address(asset);
      ROUTER.swapExactETHForTokens{value: lastPrice[tokenId]}(0, path, msgSender, block.timestamp);
    }
    emit Burn(tokenId, msgSender);
  }

  function approve(
    uint256 tokenId,
    address spender,
    bytes calldata approveData
  ) external onlyRole(_ownerRole(tokenId)) whenNotPaused {
    require(_check(tokenId, spender, IBuggyNFTReceiver.receiveApproval.selector, approveData), "BuggyNFT: rejected");
    this.grantRole(_approvedRole(tokenId), spender);
    emit Approve(tokenId, spender);
  }

  bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(uint256 tokenId,address spender)");

  // Allows other addresses to set approval without the owner spending gas. This
  // is EIP712 compatible.
  function permit(
    uint256 tokenId,
    address spender,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) external whenNotPaused {
    bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, tokenId, spender));
    bytes32 signingHash = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    address signer = ecrecover(signingHash, v, r, s);
    require(isOwner(tokenId, signer), "BuggyNFT: not owner");
    this.grantRole(_approvedRole(tokenId), spender);
  }

  function transfer(
    uint256 tokenId,
    address receiver,
    bytes calldata transferData
  ) external whenNotPaused {
    address msgSender = _msgSender();
    this.grantRole(_ownerRole(tokenId), receiver);
    require(_check(tokenId, receiver, IBuggyNFTReceiver.receiveNFT.selector, transferData), "BuggyNFT: rejected");
    require(isApproved(tokenId, msgSender), "BuggyNFT: not approved");
    this.revokeRole(_approvedRole(tokenId), msgSender);
    emit Transfer(msgSender, receiver, tokenId);
  }

  // The guy who wrote this contract has to eat too. The fee is taken in
  // whatever token is paid, not just ETH.
  function collect(address payable receiver, IERC20 asset) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
    if (asset == ETHER) {
      (bool success, ) = receiver.call{value: feesCollected[asset]}("");
      require(success, "BuggyNFT: transfer failed"
    } else {
      asset.transfer(receiver, feesCollected[asset]);
    }
    emit Collect(asset, receiver, feesCollected[asset]);
    delete feesCollected[asset];
  }

  receive() external payable {}
}
