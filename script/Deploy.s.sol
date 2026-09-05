// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";

/// @dev Placeholder deploy script — candidates may extend.
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        // deploy AetherPool, AetherVault, LiquidationEngine
        vm.stopBroadcast();
    }
}
