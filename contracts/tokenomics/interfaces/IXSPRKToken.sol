// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.7.5;

import "./IERC20.sol";

interface IXSPRKToken is IERC20 {
  function usageAllocations(address userAddress, address usageAddress) external view returns (uint256 allocation);
  function allocateFromUsage(address userAddress, uint256 amount) external;
  function convertTo(uint256 amount, address to) external;
  function deallocateFromUsage(address userAddress, uint256 amount) external;
  function isTransferWhitelisted(address account) external view returns (bool);
}