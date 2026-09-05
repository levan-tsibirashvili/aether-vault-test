// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AetherVault} from "../contracts/core/AetherVault.sol";
import {AetherPool} from "../contracts/core/AetherPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAetherPool} from "interfaces/IAetherPool.sol";
import {ILiquidationEngine} from "interfaces/ILiquidationEngine.sol";
import {IFlashLiquidityReceiver} from "interfaces/IFlashLiquidityReceiver.sol";
import {MockERC20} from "mocks/MockERC20.sol";
import {MockAetherPool} from "mocks/MockAetherPool.sol";

/// @dev Attack labs — currently placeholders that document expected names.
/// Candidates must implement real exploit + fix proofs.
contract AttackLabsPlaceholder is Test {MockERC20 public mockToken;
    MockAetherPool public mockPool;
    AetherVault public vault;

    address public attacker = address(0x1337);
    address public victim = address(0x777);

    function setUp() public {
        mockToken = new MockERC20("Mock Token", "MTK");
        mockPool = new MockAetherPool();
        vault = new AetherVault(
            mockToken,
            mockPool,
            "Aether Vault",
            "aAEV"
        );
    }

    /// Test: Verify that only the owner can set the liquidation engine
    function test_AccessControl_setLiquidationEngine() public {
        /// Deploy vault with dummy parameters just for this isolated test
        AetherVault vault = new AetherVault(
            IERC20(address(0x1)), 
            IAetherPool(address(0x2)), 
            "Aether Token", 
            "AETH"
        );

        address attacker = address(0x999);
        address mockEngine = address(0x3);

        /// Ensure non-owner cannot set the liquidation engine
        vm.prank(attacker);
        vm.expectRevert(); 
        vault.setLiquidationEngine(ILiquidationEngine(mockEngine));

        /// Ensure the owner (this test contract) CAN set it
        vault.setLiquidationEngine(ILiquidationEngine(mockEngine));
        assertEq(address(vault.liquidationEngine()), mockEngine);
    }


    function test_Attack_FirstDepositInflation() public {
        /// Setup and balance distribution
        uint256 attackerDeposit = 1;
        uint256 donationAmount = 100e18;
        uint256 victimDeposit = 100e18;

        mockToken.mint(attacker, attackerDeposit + donationAmount);
        mockToken.mint(victim, victimDeposit);

        /// Attacker execution (minimal deposit + direct donation inflation)
        vm.startPrank(attacker);
        mockToken.approve(address(vault), attackerDeposit);
        vault.deposit(attackerDeposit, attacker);

        /// Inflate the vault balance directly to skew the asset-to-share ratio
        mockToken.transfer(address(vault), donationAmount);
        vm.stopPrank();

        /// Verification: Attacker shares and vault total assets after inflation
        assertEq(vault.balanceOf(attacker), 1000, "Attacker should have initial shares");
        assertEq(mockToken.balanceOf(address(vault)), attackerDeposit + donationAmount, "Vault balance incorrect");

        /// Victim deposit under inflated state
        vm.startPrank(victim);
        mockToken.approve(address(vault), victimDeposit);
        uint256 victimShares = vault.deposit(victimDeposit, victim);
        vm.stopPrank();

        /// Strict mathematical assertions (verifying protection mechanism)
        /// Victim must receive a non-zero amount of shares (preventing complete rounding-to-zero loss)
        assertGt(victimShares, 0, "Victim shares must not be zero");

        /// Victim shares count verification against expected proportional math
        assertEq(victimShares, 1999, "Victim shares count mismatch");

        /// Attacker must fail to expropriate or steal victim funds
        uint256 attackerAssetsValue = vault.convertToAssets(vault.balanceOf(attacker));
        
        ///Attacker's withdrawable assets should be bounded and unable to drain the victim's principal
        assertTrue(attackerAssetsValue < donationAmount, "Attacker should not be able to steal victim funds");
    }
    
    function test_Attack_FlashLiquidityReentrancy() public {
        MockERC20 token0 = new MockERC20("Token 0", "TK0");
        MockERC20 token1 = new MockERC20("Token 1", "TK1");
        AetherPool realPool = new AetherPool(token0, token1);

        token0.mint(address(realPool), 1000e18);
        token1.mint(address(realPool), 1000e18);

        FlashReentrancyAttacker attackerContract = new FlashReentrancyAttacker();
        
        uint256 borrowAmount0 = 100e18;
        uint256 initialReserve0 = token0.balanceOf(address(realPool));
        
        attackerContract.setExpected(initialReserve0 - borrowAmount0);

        bytes memory data = abi.encode(address(token0), address(token1));

        realPool.flashLiquidity(borrowAmount0, 0, address(attackerContract), data);

        assertTrue(attackerContract.checkPassed(), "Reserves must be updated prior to callback");
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



contract FlashReentrancyAttacker is IFlashLiquidityReceiver {
    bool public checkPassed;
    uint256 public expectedReserveAfter;

    function setExpected(uint256 expected) external {
        expectedReserveAfter = expected;
    }

    function onFlashLiquidity(
        address, 
        uint256 amount0, 
        uint256 amount1, 
        bytes calldata data
    ) external override returns (bytes32) {
        AetherPool pool = AetherPool(msg.sender);
        
        if (pool.reserve0() == expectedReserveAfter) {
            checkPassed = true;
        }

        (address token0, address token1) = abi.decode(data, (address, address));
        if (amount0 > 0) IERC20(token0).transfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(token1).transfer(msg.sender, amount1);

        return keccak256("AetherPool.onFlashLiquidity");
    }
}