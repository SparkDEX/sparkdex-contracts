// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.22;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract SparkDEXToken is ERC20, ERC20Permit {
    constructor(address recipient)
        ERC20("SparkDEX", "SPRK")
        ERC20Permit("SparkDEX")
    {
        _mint(recipient, 1000000000 * 10 ** decimals());
    }
}