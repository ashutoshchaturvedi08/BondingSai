// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract MemeToken is Ownable, ReentrancyGuard {
    // Basic token properties
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    
    // Anti-sniper protection
    bool public antiSniperEnabled;
    uint256 public maxWallet;
    uint256 public maxTransaction;
    uint256 public cooldownPeriod;
    /// LOT-34 (Audit Round 2): Once locked, owner can only relax limits (not tighten) to prevent weaponizing anti-sniper
    bool public antiSniperLocked;
    
    // Rich metadata
    string public description;
    string public logoURL;
    string public website;
    string public github;
    string public twitter;
    string[] public projectCategories;
    string public customAddressSuffix;
    
    // Buy options and pricing tiers
    uint256[] public buyOptions;
    
    // Transfer tracking and exclusions
    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public lastTransferTime;
    mapping(address => bool) public excludedFromLimits;
    
    // ERC20 allowance for approve/transferFrom
    mapping(address => mapping(address => uint256)) public allowance;
    
    // Events
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event AntiSniperSettingsUpdated(bool enabled, uint256 maxWallet, uint256 maxTransaction, uint256 cooldown);
    event MetadataUpdated(string description, string logoURL, string website, string github, string twitter);
    event BuyOptionsUpdated(uint256[] buyOptions);
    event ExcludedAddressUpdated(address indexed account, bool excluded);
    
    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        address _creator,
        uint256 _totalSupply,
        string memory _description,
        string memory _logoURL,
        string memory _website,
        string memory _github,
        string memory _twitter,
        string[] memory _projectCategories,
        uint256[] memory _buyOptions
    ) ReentrancyGuard() {
        require(_totalSupply > 0, "Total supply must be greater than 0");
        
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        totalSupply = _totalSupply * (10 ** _decimals);
        
        // Set default anti-sniper values
        antiSniperEnabled = true;
        maxWallet = _totalSupply * (10 ** _decimals);
        maxTransaction = _totalSupply * (10 ** _decimals);
        cooldownPeriod = 30;
        
        // Set initial balance for creator
        balanceOf[_creator] = totalSupply;
        
        // Exclude creator from limits
        excludedFromLimits[_creator] = true;
        
        // Transfer ownership to creator
        _transferOwnership(_creator);
        
        // Set metadata
        _setMetadata(_description, _logoURL, _website, _github, _twitter, _projectCategories, _buyOptions);
        
        emit Transfer(address(0), _creator, totalSupply);
    }
    
    // LOT-10 (Audit): Standard EIP-20 approve; known race if spender front-runs. Consider EIP-2612 permit() for gasless approvals.
    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    // LOT-16 (Audit): Removed nonReentrant — no external calls in transfer; saves gas and allows use inside other nonReentrant flows
    // AUDIT FIX (BUG-18): Check sender and recipient limits independently.
    // AUDIT FIX (BROKEN-3): Set lastTransferTime[to] for non-excluded recipients so buyers from the
    // bonding curve cannot immediately dump — their cooldown starts when they receive tokens.
    // AUDIT FIX (BROKEN-5): Skip maxTransaction on sender when `to` is excluded (e.g., bonding curve).
    // Without this, selling to the curve is throttled by maxTransaction, forcing users into slow drip-sells
    // during a dump while their tokens lose value.
    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(balanceOf[from] >= value, "Insufficient balance");
        require(to != address(0), "Transfer to zero address");
        
        if (from != msg.sender) {
            require(allowance[from][msg.sender] >= value, "Insufficient allowance");
            allowance[from][msg.sender] -= value;
        }
        
        if (antiSniperEnabled) {
            if (!excludedFromLimits[from]) {
                if (!excludedFromLimits[to]) {
                    require(value <= maxTransaction, "Transfer > maxTransaction");
                }
                require(block.timestamp - lastTransferTime[from] >= cooldownPeriod, "Cooldown active");
                lastTransferTime[from] = block.timestamp;
            }
            if (!excludedFromLimits[to]) {
                require(balanceOf[to] + value <= maxWallet, "Recipient > maxWallet");
                // AUDIT FIX (NEW-BUG-1): Only set recipient cooldown when sender is excluded (e.g.,
                // bonding curve). Previously ANY transfer set lastTransferTime[to], enabling griefing
                // where an attacker sends dust tokens to lock the victim's ability to transfer/sell.
                // Now only curve-originating transfers (from=excluded) set the recipient's cooldown.
                if (excludedFromLimits[from]) {
                    lastTransferTime[to] = block.timestamp;
                }
            }
        }

        balanceOf[from] -= value;
        balanceOf[to] += value;
        
        emit Transfer(from, to, value);
        return true;
    }
    
    // AUDIT FIX (BUG-18, BROKEN-3, BROKEN-5, NEW-BUG-1): Same independent checks as transferFrom.
    function transfer(address to, uint256 value) external returns (bool) {
        require(balanceOf[msg.sender] >= value, "Insufficient balance");
        require(to != address(0), "Transfer to zero address");

        if (antiSniperEnabled) {
            if (!excludedFromLimits[msg.sender]) {
                if (!excludedFromLimits[to]) {
                    require(value <= maxTransaction, "Transfer > maxTransaction");
                }
                require(block.timestamp - lastTransferTime[msg.sender] >= cooldownPeriod, "Cooldown active");
                lastTransferTime[msg.sender] = block.timestamp;
            }
            if (!excludedFromLimits[to]) {
                require(balanceOf[to] + value <= maxWallet, "Recipient > maxWallet");
                if (excludedFromLimits[msg.sender]) {
                    lastTransferTime[to] = block.timestamp;
                }
            }
        }

        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        
        emit Transfer(msg.sender, to, value);
        return true;
    }
    
    /// LOT-34 (Audit Round 2): Lock anti-sniper so only relaxing is allowed.
    /// AUDIT FIX (MEDIUM-7): Require anti-sniper to be enabled when locking. Locking while disabled
    /// creates false user confidence (antiSniperLocked=true but protection is OFF).
    function lockAntiSniperSettings() external onlyOwner {
        require(antiSniperEnabled, "must be enabled to lock");
        antiSniperLocked = true;
    }

    // LOT-34 (Audit Round 2): When antiSniperLocked, owner can only relax limits (increase maxWallet/maxTransaction, decrease cooldown).
    function updateAntiSniperSettings(
        bool _antiSniperEnabled,
        uint256 _maxWallet,
        uint256 _maxTransaction,
        uint256 _cooldownPeriod
    ) external onlyOwner {
        require(_maxWallet > 0, "Max wallet must be greater than 0");
        require(_maxTransaction > 0, "Max transaction must be greater than 0");
        require(_maxTransaction <= _maxWallet, "Max transaction must be <= max wallet");
        require(_cooldownPeriod > 0, "Cooldown period must be greater than 0");

        if (antiSniperLocked) {
            // AUDIT FIX (BROKEN-4 + MEDIUM-7): When locked, the enabled flag cannot change at all.
            // Disabling is prevented (BROKEN-4) and re-enabling after disabling is also prevented
            // (MEDIUM-7). The state at lock time is frozen for the enabled flag.
            require(_antiSniperEnabled == antiSniperEnabled, "cannot change enabled flag when locked");
            uint256 maxWalletUnscaled = maxWallet / (10 ** decimals);
            uint256 maxTxUnscaled = maxTransaction / (10 ** decimals);
            require(_maxWallet >= maxWalletUnscaled, "cannot reduce maxWallet when locked");
            require(_maxTransaction >= maxTxUnscaled, "cannot reduce maxTransaction when locked");
            require(_cooldownPeriod <= cooldownPeriod, "cannot increase cooldown when locked");
        }

        antiSniperEnabled = _antiSniperEnabled;
        maxWallet = _maxWallet * (10 ** decimals);
        maxTransaction = _maxTransaction * (10 ** decimals);
        cooldownPeriod = _cooldownPeriod;
        // LOT-23 (Audit): Emit scaled (stored) values so off-chain consumers see enforced limits
        emit AntiSniperSettingsUpdated(_antiSniperEnabled, maxWallet, maxTransaction, _cooldownPeriod);
    }
    
    function updateMetadata(
        string memory _description,
        string memory _logoURL,
        string memory _website,
        string memory _github,
        string memory _twitter
    ) external onlyOwner {
        description = _description;
        logoURL = _logoURL;
        website = _website;
        github = _github;
        twitter = _twitter;
        
        emit MetadataUpdated(_description, _logoURL, _website, _github, _twitter);
    }
    
    function updateProjectCategories(string[] memory _projectCategories) external onlyOwner {
        projectCategories = _projectCategories;
    }
    
    function updateBuyOptions(uint256[] memory _buyOptions) external onlyOwner {
        buyOptions = _buyOptions;
        emit BuyOptionsUpdated(_buyOptions);
    }
    
    function setExcludedFromLimits(address account, bool excluded) external onlyOwner {
        excludedFromLimits[account] = excluded;
        emit ExcludedAddressUpdated(account, excluded);
    }
    
    // Simple view functions to avoid stack too deep
    function getProjectCategories() external view returns (string[] memory) {
        return projectCategories;
    }
    
    function getBuyOptions() external view returns (uint256[] memory) {
        return buyOptions;
    }
    
    function isExcludedFromLimits(address account) external view returns (bool) {
        return excludedFromLimits[account];
    }
    
    // Internal function to set metadata during creation (called by factory)
    function _setMetadata(
        string memory _description,
        string memory _logoURL,
        string memory _website,
        string memory _github,
        string memory _twitter,
        string[] memory _projectCategories,
        uint256[] memory _buyOptions
    ) internal {
        if (bytes(_description).length > 0 || bytes(_logoURL).length > 0 || 
            bytes(_website).length > 0 || bytes(_github).length > 0 || bytes(_twitter).length > 0) {
            description = _description;
            logoURL = _logoURL;
            website = _website;
            github = _github;
            twitter = _twitter;
            emit MetadataUpdated(_description, _logoURL, _website, _github, _twitter);
        }
        
        if (_projectCategories.length > 0) {
            projectCategories = _projectCategories;
        }
        
        if (_buyOptions.length > 0) {
            buyOptions = _buyOptions;
            emit BuyOptionsUpdated(_buyOptions);
        }
    }
}

