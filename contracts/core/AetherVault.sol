// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAetherPool} from "../interfaces/IAetherPool.sol";
import {ILiquidationEngine} from "../interfaces/ILiquidationEngine.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RiskBucket} from "../libraries/RiskBucket.sol";

/// @title AetherVault
/// @author Aether Protocol Core Team
/// @notice ERC4626 Leverage Vault featuring custom EIP-712 operator grants, dynamic interest accrual, 
///         cross-margin risk validation, and strict bad debt accounting.
contract AetherVault is ERC4626, ReentrancyGuard, Ownable, EIP712 {
    using SafeERC20 for IERC20;

    /// @notice The underlying automated market maker pool contract interface.
    IAetherPool public immutable pool;
    
    /// @notice The designated liquidation engine handling undercollateralized positions.
    ILiquidationEngine public liquidationEngine;

    // --- State Variables ---

    /// @notice Global funding index scaling factor, initialized to 1e18.
    uint256 public fundingIndex = 1e18; 
    
    /// @notice Global borrow index tracking accrued interest for borrower debt over time, initialized to 1e18.
    uint256 public borrowIndex = 1e18; 
    
    /// @notice Timestamp of the last interest accrual update.
    uint256 public lastAccrual;
    
    /// @notice Cumulative unrecoverable bad debt realized within the vault.
    uint256 public badDebt;
    
    /// @notice Total active performing debt owed by all vault borrowers.
    uint256 public totalDebt;

    /// @notice Tracks cash assets held directly within the vault contract.       
    uint256 public trackedCash;      
     
    /// @notice Aggregate historical debt accrued across the system.
    uint256 public totalDebtAccrued;  
    
    /// @notice Cached LP mark value used for flash-loan manipulation protection.
    uint256 public cachedLpMark;
    
    /// @notice Lock timestamp preventing concurrent re-entrant liquidations.
    uint256 public liquidationLock;

    /// @notice EIP-712 typehash for cryptographically securing operator delegation grants.
    bytes32 public constant GRANT_OPERATOR_TYPEHASH = keccak256(
        "GrantOperator(address owner,address operator,uint256 until,uint256 nonce,uint256 deadline)"
    );

    /// @notice Mapping tracking operator validity timestamps per owner and operator address.
    /// @dev owner => operator => expiration timestamp
    mapping(address => mapping(address => uint256)) public operatorUntil;
    
    /// @notice Mapping tracking nonces for EIP-712 operator signatures to prevent replay attacks.
    /// @dev owner => operator => current nonce
    mapping(address => mapping(address => uint256)) public operatorNonce;
    
    /// @notice Mapping tracking outstanding debt amounts per account.
    /// @dev account => signed debt amount
    mapping(address => int256) public accountDebt;
    
    /// @notice Internal mapping storing the risk bucket configuration associated with each account.
    /// @dev account => RiskBucket.Bucket struct
    mapping(address => RiskBucket.Bucket) internal userRiskBucket;

    // --- Errors ---
    
    /// @notice Reverts when an operation results in zero shares minted or burned.
    error ZeroShares();
    
    /// @notice Reverts when an account fails cross-margin health checks.
    error Unhealthy();
    
    /// @notice Reverts when the caller lacks authorized owner or operator privileges.
    error NotOperator();
    
    /// @notice Reverts when a cryptographic signature or time-bound permission has expired.
    error Expired();
    
    /// @notice Reverts when an EIP-712 signature verification fails.
    error InvalidSignature();

    // --- Events ---

    /// @notice Emitted when an account successfully grants operator permissions.
    event OperatorGranted(address indexed owner, address indexed operator, uint256 until, uint256 nonce);
    
    /// @notice Emitted when an account revokes operator permissions.
    event OperatorCancelled(address indexed owner, address indexed operator);
    
    /// @notice Emitted when unrecoverable bad debt is officially realized for an account.
    event BadDebtRealized(address indexed account, uint256 amount);

    /// @notice Initializes the ERC-4626 vault with asset, pool, name, and symbol parameters.
    constructor(IERC20 asset_, IAetherPool pool_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        Ownable(msg.sender)
        EIP712(name_, "1")
    {
        pool = pool_;
        lastAccrual = block.timestamp;
    }

    /// @notice Grants operator permissions using a verified EIP-712 signature.
    /// @param owner The account owner delegating operational rights.
    /// @param operator The address receiving operator privileges.
    /// @param until The timestamp until which the operator permission remains valid.
    /// @param deadline The timestamp after which the signature becomes invalid.
    /// @param v Recovery byte of the cryptographic signature.
    /// @param r First 32 bytes of the cryptographic signature.
    /// @param s Second 32 bytes of the cryptographic signature.
    function grantOperator(
        address owner,
        address operator,
        uint256 until,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert Expired();
        if (until <= block.timestamp) revert Expired();

        uint256 currentNonce = operatorNonce[owner][operator];

        bytes32 structHash = keccak256(
            abi.encode(
                GRANT_OPERATOR_TYPEHASH,
                owner,
                operator,
                until,
                currentNonce,
                deadline
            )
        );

        bytes32 hash = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(hash, v, r, s);
        if (signer != owner) revert InvalidSignature();

        operatorNonce[owner][operator] = currentNonce + 1;
        operatorUntil[owner][operator] = until;

        emit OperatorGranted(owner, operator, until, currentNonce);
    }

    /// @notice Revokes operator permissions for the calling account.
    /// @param operator The address of the operator whose permissions are being canceled.
    function cancelOperator(address operator) external {
        operatorUntil[msg.sender][operator] = 0;
        emit OperatorCancelled(msg.sender, operator);
    }

    /// @notice Sets or updates the authorized liquidation engine address.
    /// @param eng The new liquidation engine contract interface implementation.
    function setLiquidationEngine(ILiquidationEngine eng) external onlyOwner {
        liquidationEngine = eng;
    }

    /// @notice Sets the debt amount for a specific account (Administrative override).
    /// @param account The target account address.
    /// @param amount The debt amount to set.
    function setAccountDebt(address account, int256 amount) external onlyOwner {
        accountDebt[account] = amount;
    }

    /// @notice Seizes user collateral tokens during a verified liquidation event.
    /// @param token The ERC-20 collateral token address to transfer.
    /// @param to The recipient address receiving the seized collateral.
    /// @param amount The quantity of tokens to seize.
    function seizeCollateral(address token, address to, uint256 amount) external {
        require(msg.sender == address(liquidationEngine), "only liq");
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Calculates the total assets managed by the vault including cash, LP mark value, and performing debt.
    /// @return Total assets denominated in the underlying asset decimals.
    function totalAssets() public view override returns (uint256) {
        uint256 lpMark = pool.unlocked() ? pool.twapMarkValue(address(this)) : cachedLpMark;
        
        (uint256 interest, , ) = _calculateAccrual();
        uint256 performing = totalDebt + interest; 
        
        return trackedCash + lpMark + performing;
    }
    
    /// @notice Returns the decimals offset used to mitigate share inflation vulnerabilities in ERC-4626.
    /// @return The integer offset value.
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 3; 
    }

    // --- ERC4626 Standard Functions ---

    /// @notice Deposits underlying assets into the vault in exchange for vault shares.
    /// @param assets The quantity of underlying assets to deposit.
    /// @param receiver The address receiving the minted shares.
    /// @return shares The exact quantity of shares minted to the receiver.
    function deposit(uint256 assets, address receiver)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroShares();
        _accrue();
        
        cachedLpMark = pool.unlocked() ? pool.twapMarkValue(address(this)) : cachedLpMark;
        
        uint256 assetsBefore = totalAssets();
        uint256 supplyBefore = totalSupply();
        
        uint256 balBefore = IERC20(asset()).balanceOf(address(this));
        SafeERC20.safeTransferFrom(IERC20(asset()), msg.sender, address(this), assets);
        uint256 received = IERC20(asset()).balanceOf(address(this)) - balBefore;
        
        if (received == 0) revert ZeroShares();
        
        trackedCash += received;
        
        shares = Math.mulDiv(
            received,
            supplyBefore + 10 ** _decimalsOffset(),
            assetsBefore + 1,
            Math.Rounding.Floor
        );
        
        if (shares == 0) revert ZeroShares();

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, received, shares);
    }

    /// @notice Mints an exact quantity of vault shares by depositing underlying assets.
    /// @param shares The exact quantity of shares to mint.
    /// @param receiver The address receiving the minted shares.
    /// @return assets The quantity of underlying assets pulled from the caller.
    function mint(uint256 shares, address receiver)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _accrue();
        assets = super.mint(shares, receiver);
        if (assets == 0) revert ZeroShares();
    }

    /// @notice Redeems vault shares for underlying assets, enforcing health checks and operator rights.
    /// @param shares The quantity of shares to redeem.
    /// @param receiver The address receiving the withdrawn assets.
    /// @param owner The owner of the shares being redeemed.
    /// @return assets The quantity of underlying assets transferred to the receiver.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _requireOwnerOrOperator(owner);
        _accrue();
        assets = super.redeem(shares, receiver, owner);
        _checkHealth(owner);
    }

    /// @notice Withdraws an exact amount of underlying assets, enforcing health checks and operator rights.
    /// @param assets The quantity of underlying assets to withdraw.
    /// @param receiver The address receiving the withdrawn assets.
    /// @param owner The owner of the shares being burned.
    /// @return shares The quantity of shares burned from the owner.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _requireOwnerOrOperator(owner);
        _accrue();
        shares = super.withdraw(assets, receiver, owner);
        _checkHealth(owner);
    }

    // --- Internal Accrual Logic ---

    /// @notice Updates global debt and interest indices based on elapsed timestamp intervals.
    function _accrue() internal {
        if (block.timestamp == lastAccrual) return;
        
        (uint256 interest, uint256 newBorrowIndex, uint256 newFundingIndex) = _calculateAccrual();
        
        if (interest > 0) {
            totalDebt += interest;
            borrowIndex = newBorrowIndex;
            fundingIndex = newFundingIndex;
        }
        lastAccrual = block.timestamp;
    } 
    
    /// @notice Computes interest accrual values and index deltas over time.
    /// @return interest The calculated interest amount.
    /// @return newBorrowIndex The updated global borrow index.
    /// @return newFundingIndex The updated global funding index.
    function _calculateAccrual() internal view returns (uint256 interest, uint256 newBorrowIndex, uint256 newFundingIndex) {
        uint256 timeDelta = block.timestamp - lastAccrual;
        if (timeDelta == 0 || totalDebt == 0) {
            return (0, borrowIndex, fundingIndex);
        }
        
        uint256 interestRatePerSecond = 317097929;
        interest = (totalDebt * interestRatePerSecond * timeDelta) / 1e18;
        
        uint256 borrowIndexDelta = (interest * 1e18) / totalDebt;
        newBorrowIndex = borrowIndex + borrowIndexDelta;

        uint256 supply = totalSupply();
        uint256 indexDelta = supply == 0 ? 0 : (interest * 1e18) / supply;
        newFundingIndex = fundingIndex + indexDelta;
    }

    /// @notice Realizes an unrecoverable portion of user debt as bad debt, maintaining system accounting invariants.
    /// @param account The target account address experiencing bad debt.
    /// @param amount The debt quantity to write off.
    function realizeBadDebt(address account, uint256 amount) external {
        require(msg.sender == address(liquidationEngine), "only liq");
        require(amount <= uint256(type(int256).max), "amount overflow check");
        
        badDebt += amount;
        
        int256 iAmount = int256(amount);
        if (accountDebt[account] >= iAmount) {
            accountDebt[account] -= iAmount;
        } else {
            accountDebt[account] = 0;
        }
        
        if (totalDebt >= amount) {
            totalDebt -= amount;
        } else {
            totalDebt = 0;
        }
        
        emit BadDebtRealized(account, amount);
    }

    /// @notice Verifies if an operator holds active permissions for a given account.
    /// @param account The owner account address.
    /// @param operator The operator address to check.
    /// @return Boolean flag indicating active operator authorization.
    function isOperator(address account, address operator) public view returns (bool) {
        return operatorUntil[account][operator] >= block.timestamp;
    }

    /// @notice Ensures the caller is either the owner or an authorized active operator.
    /// @param account The account owner address.
    function _requireOwnerOrOperator(address account) internal view {
        if (msg.sender != account && !isOperator(account, msg.sender)) revert NotOperator();
    }

    /// @notice Validates position health using cross-margin risk bucket requirements.
    /// @param account The account address to evaluate.
    function _checkHealth(address account) internal view {
        int256 debt = accountDebt[account];
        if (debt <= 0) return;
        
        uint256 notional = uint256(debt);
        uint256 equity = convertToAssets(balanceOf(account));

        RiskBucket.Bucket memory bucket = userRiskBucket[account]; 

        uint256 margin = RiskBucket.marginRequirement(bucket, notional);
        require(equity >= margin, "Unhealthy");
    } 
    
    /// @notice Assigns or updates the risk bucket structure configuration for a specific account.
    /// @param account The target account address.
    /// @param bucket The RiskBucket memory structure containing risk parameters.
    function setUserRiskBucket(address account, RiskBucket.Bucket memory bucket) external onlyOwner {
        userRiskBucket[account] = bucket;
    }   
}