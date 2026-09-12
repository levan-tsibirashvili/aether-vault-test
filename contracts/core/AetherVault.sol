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

/// @title AetherVault
/// @notice ERC4626 Leverage Vault with customized EIP712 operator grants and debt accounting.
contract AetherVault is ERC4626, ReentrancyGuard, Ownable, EIP712 {
    using SafeERC20 for IERC20;

    IAetherPool public immutable pool;
    ILiquidationEngine public liquidationEngine;

    // --- State Variables ---
    uint256 public fundingIndex = 1e18; 
    uint256 public borrowIndex = 1e18; // Added borrowIndex for accurate borrower debt tracking
    uint256 public lastAccrual;    
    uint256 public badDebt;
    uint256 public totalDebt;
    uint256 public trackedCash;       
    uint256 public totalDebtAccrued;  
    uint256 public cachedLpMark;
    uint256 public liquidationLock;

    // Added 'owner' parameter to the TYPEHASH for cryptographic replay protection
    bytes32 public constant GRANT_OPERATOR_TYPEHASH = keccak256(
        "GrantOperator(address owner,address operator,uint256 until,uint256 nonce,uint256 deadline)"
    );

    mapping(address => mapping(address => uint256)) public operatorUntil;
    mapping(address => mapping(address => uint256)) public operatorNonce;
    mapping(address => int256) public accountDebt;

    // --- Errors ---
    error ZeroShares();
    error Unhealthy();
    error NotOperator();
    error Expired();
    error InvalidSignature();

    // --- Events ---
    event OperatorGranted(address indexed owner, address indexed operator, uint256 until, uint256 nonce);
    event OperatorCancelled(address indexed owner, address indexed operator);
    event BadDebtRealized(address indexed account, uint256 amount); // New event for tracking bad debt

    constructor(IERC20 asset_, IAetherPool pool_, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        ERC4626(asset_)
        Ownable(msg.sender)
        EIP712(name_, "1")
    {
        pool = pool_;
        lastAccrual = block.timestamp;
    }

    /// @notice Grants operator permissions using an EIP-712 signature
    /// @dev The owner's address is now integrated into the struct hash
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

        uint256 currentNonce = operatorNonce[owner][operator];

        bytes32 structHash = keccak256(
            abi.encode(
                GRANT_OPERATOR_TYPEHASH,
                owner, // Owner is now securely part of the hashed data
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

    /// @notice Revokes operator permissions for the caller
    function cancelOperator(address operator) external {
        operatorUntil[msg.sender][operator] = 0;
        emit OperatorCancelled(msg.sender, operator);
    }

    function setLiquidationEngine(ILiquidationEngine eng) external onlyOwner {
        liquidationEngine = eng;
    }

    function setAccountDebt(address account, int256 amount) external onlyOwner {
        accountDebt[account] = amount;
    }

    /// @notice Seizes user collateral during a liquidation event
    function seizeCollateral(address token, address to, uint256 amount) external {
        require(msg.sender == address(liquidationEngine), "only liq");
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Calculates the total assets managed by the vault
    function totalAssets() public view override returns (uint256) {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        uint256 lpMark = pool.twapMarkValue(address(this));
        
        (uint256 interest, , ) = _calculateAccrual();
        uint256 currentTotalDebt = totalDebt + interest;
                
        uint256 grossAssets = idle + lpMark + currentTotalDebt;
        if (grossAssets < badDebt) {
            return 0;
        }
        
        return grossAssets - badDebt;
    }
    
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 3; 
    }

    // --- ERC4626 Standard Functions ---

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

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        _accrue();
        assets = super.redeem(shares, receiver, owner);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        _accrue();
        shares = super.withdraw(assets, receiver, owner);
    }

    // --- Internal Accrual Logic ---

    /// @notice Updates the debt and interest based on the elapsed time
    function _accrue() internal {
        if (block.timestamp == lastAccrual) return;
        
        (uint256 interest, uint256 newBorrowIndex, uint256 newFundingIndex) = _calculateAccrual();
        
        if (interest > 0) {
            totalDebt += interest;
            borrowIndex = newBorrowIndex; // Update global borrower index
            fundingIndex = newFundingIndex;
        }
        lastAccrual = block.timestamp;
    } 
    
    /// @notice Calculates the interest to be accrued and the new indices
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

    /// @notice Realizes a specific user's debt as unrecoverable (Bad Debt)
    /// @dev Decreases both totalDebt and accountDebt to strictly maintain system invariants
    /// @param account The address of the user whose debt is being realized
    /// @param amount The amount of debt to realize
    function realizeBadDebt(address account, uint256 amount) external {
        require(msg.sender == address(liquidationEngine), "only liq");        
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
}