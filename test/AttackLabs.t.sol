// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

/// @dev Attack labs — currently placeholders that document expected names.
/// Candidates must implement real exploit + fix proofs.
contract AttackLabsPlaceholder is Test {
    function test_Attack_FirstDepositInflation() public {
        // TODO: demonstrate inflation then show fix
        assertTrue(true, "replace with real attack test");
    }

    function test_Attack_FlashLiquidityReentrancy() public {
        assertTrue(true, "replace with real attack test");
    }

    function test_Attack_LiquidationDustGrief() public {
        assertTrue(true, "replace with real attack test");
    }

    function test_Attack_TwapManipulationSandwich() public {
        assertTrue(true, "replace with real attack test");
    }

    function test_Attack_BadDebtBricksRedeems() public {
        assertTrue(true, "replace with real attack test");
    }
}
