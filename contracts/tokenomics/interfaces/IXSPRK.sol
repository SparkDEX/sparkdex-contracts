// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.7.5;

import "./IERC20.sol";

interface IXSPRK is IERC20{
  function lastEmissionTime() external view returns (uint256);
  function claimMasterRewards(uint256 amount) external returns (uint256 effectiveAmount);
  function masterEmissionRate() external view returns (uint256);
  function burn(uint256 amount) external;
}