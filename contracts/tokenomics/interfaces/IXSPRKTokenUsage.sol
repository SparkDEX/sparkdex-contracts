// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.7.5;

interface IXSPRKTokenUsage {
    function allocate(address userAddress, uint256 amount, bytes calldata data) external;
    function deallocate(address userAddress, uint256 amount, bytes calldata data) external;
}