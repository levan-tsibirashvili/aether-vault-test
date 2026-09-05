// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {MockERC20} from "./MockERC20.sol";

contract MockFeeOnTransferToken is MockERC20 {
    constructor(string memory name, string memory symbol) MockERC20(name, symbol) {}

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        ///  for example 10% fee
        uint256 fee = amount / 10; 
        uint256 netAmount = amount - fee;
        
        super.transferFrom(sender, recipient, netAmount);
        return true;
    }
}