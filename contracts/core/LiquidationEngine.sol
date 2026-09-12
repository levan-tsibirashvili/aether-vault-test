// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAetherVault} from "../interfaces/IAetherVault.sol";
import {IAetherPool} from "../interfaces/IAetherPool.sol";

/// @title LiquidationEngine
/// @author Aether Protocol Core Team
/// @notice Handles the liquidation of undercollateralized borrower accounts in the Aether protocol,
///         managing debt repayment, collateral seizure, health factor checks, and bad debt realization.
contract LiquidationEngine {
    using SafeERC20 for IERC20;

    /// @notice The core Aether vault contract interface instance.
    IAetherVault public immutable vault;
    
    /// @notice The core Aether AMM pool contract interface instance.
    IAetherPool public immutable pool;

    // --- Constants ---

    /// @notice Maximum allowable 50% debt portion that can be closed in a single liquidation transaction.
    uint256 public constant CLOSE_FACTOR = 0.5e18;
    
    /// @notice 5% liquidation bonus incentive awarded to liquidators upon seizing collateral.
    uint256 public constant LIQ_BONUS = 1.05e18;
    
    /// @notice Minimum valuation threshold used to prevent uneconomical dust liquidations.
    uint256 public constant DUST_THRESHOLD = 1000;

    /// @notice Initializes the liquidation engine with vault and pool contract references.
    /// @param vault_ The address of the Aether vault contract.
    /// @param pool_ The address of the Aether pool contract.
    constructor(IAetherVault vault_, IAetherPool pool_) {
        vault = vault_;
        pool = pool_;
    }

    /// @notice Represents an itemized collateral token and its corresponding amount for seizure evaluation.
    struct Collateral {
        address token;
        uint256 amount;
    }

    /// @notice Liquidates an unhealthy borrower account by seizing collateral proportional to the repaid debt.
    /// @param account The address of the undercollateralized borrower being liquidated.
    /// @param collaterals The array of collateral tokens and amounts the liquidator attempts to seize.
    /// @param repayAmount The amount of base asset debt the liquidator wishes to repay on behalf of the account.
    /// @return seized The total amount of collateral tokens successfully seized during the operation.
    function liquidate(address account, Collateral[] calldata collaterals, uint256 repayAmount)
        external
        returns (uint256 seized)
    {
        require(pool.unlocked(), "flash");
        require(collaterals.length > 0 && collaterals.length <= 12, "coll");
        
        vault.accrue();
        
        int256 debtI = vault.accountDebt(account);
        require(debtI > 0, "no debt");
        uint256 debt = uint256(debtI);
        
        uint256 collValue = _collateralValue(collaterals); 
        uint256 hf = (collValue * 1e18) / debt;
        require(hf < 1e18, "healthy");

        uint256 spot = pool.markValue(account);
        uint256 twap = pool.twapMarkValue(account);
        require(twap > 0, "oracle");
        require(spot <= (twap * 120) / 100 && spot >= (twap * 80) / 100, "twap deviation");

        uint256 maxRepay = (hf > CLOSE_FACTOR) ? (debt * CLOSE_FACTOR) / 1e18 : debt;
        if (collValue <= DUST_THRESHOLD) maxRepay = debt;
        require(repayAmount > 0 && repayAmount <= maxRepay, "repay");

        // 1. Liquidator repays debt into the vault
        uint256 received = vault.takeRepayment(msg.sender, repayAmount);
        
        // 2. Reduce the borrower's debt in the vault
        vault.applyRepayment(account, received);

        // 3. Execute collateral seizure with the 5% liquidation bonus
        uint256 remaining = (received * LIQ_BONUS) / 1e18;
        (seized, ) = _executeSeizure(account, remaining);

        // 4. Handle remaining dust / bad debt cleanup if necessary
        _checkAndRealizeBadDebt(account);
    }
    
    /// @notice Executes the seizure of available collateral tokens across the vault across supported tokens.
    /// @param account The address of the borrower whose collateral is being seized.
    /// @param initialRemaining The initial target asset value to seize including liquidation bonus.
    /// @return seized The total collateral successfully seized.
    /// @return remaining Any unfulfilled seizure value remainder.
    function _executeSeizure(address account, uint256 initialRemaining) 
        private 
        returns (uint256 seized, uint256 remaining) 
    {
        remaining = initialRemaining;
        uint256 length = vault.collateralTokenCount();
        
        for (uint256 i = 0; i < length && remaining > 0; ++i) {
            address tok = vault.collateralTokenAt(i);
            uint256 bal = vault.collateralOf(account, tok);
            if (bal == 0) continue;
            
            uint256 take = remaining < bal ? remaining : bal;
            vault.seizeCollateral(tok, msg.sender, take);
            seized += take;
            remaining -= take;
        }
    }

    /// @notice Calculates the total collateral value for a specific account queried directly from the vault.
    /// @param account The address of the account.
    /// @return total The aggregate calculated collateral value.
    function _collateralValue(address account) private view returns (uint256 total) {
        uint256 length = vault.collateralTokenCount();
        for (uint256 i = 0; i < length; i++) {
            address tok = vault.collateralTokenAt(i);
            total += vault.collateralOf(account, tok);
        }
    }
    
    /// @notice Calculates the total value from a provided memory array of Collateral structs.
    /// @param collaterals The array of Collateral structs.
    /// @return total The aggregate sum of collateral amounts.
    function _collateralValue(Collateral[] calldata collaterals) private pure returns (uint256 total) {
        uint256 length = collaterals.length;
        for (uint256 i = 0; i < length; i++) {
            total += collaterals[i].amount;
        }
    }

    /// @notice Checks if residual debt remains and remaining collateral is below the dust threshold to realize bad debt.
    /// @param account The address of the borrower to inspect.
    function _checkAndRealizeBadDebt(address account) private {
        uint256 debtLeft = uint256(vault.accountDebt(account));
        if (debtLeft > 0 && _collateralValue(account) <= DUST_THRESHOLD) {
            vault.realizeBadDebt(account, debtLeft);
        }
    }

    /// @notice Helper function to retrieve the length of a calldata collaterals array.
    /// @param colls The Collateral calldata array.
    /// @return The length of the array.
    function collsLength(Collateral[] calldata colls) private pure returns (uint256) {
        return colls.length;
    }
}