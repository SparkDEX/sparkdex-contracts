// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.7.5;

interface IDividends {
  function distributedTokensLength() external view returns (uint256);

  function distributedToken(uint256 index) external view returns (address);

  function isDistributedToken(address token) external view returns (bool);

  function addDividendsToPending(address token, uint256 amount) external;
}