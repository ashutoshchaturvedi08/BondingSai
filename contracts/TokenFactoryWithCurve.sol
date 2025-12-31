// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./MemeToken.sol";
import "./BondingCurve.sol";

contract TokenFactoryWithCurve is Ownable {
    address public immutable feeRecipient;
    address public bondingCurveImplementation; // Can be updated for upgrades
    
    event TokenCreated(address tokenAddress, address creator, string name, string symbol);
    event BondingCurveCreated(address tokenAddress, address curveAddress);
    
    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "feeRecipient 0");
        feeRecipient = _feeRecipient;
        _transferOwnership(msg.sender);
    }
    
    function setBondingCurveImplementation(address _implementation) external onlyOwner {
        bondingCurveImplementation = _implementation;
    }
    
    // Create token with bonding curve
    // 800M tokens go to bonding curve, 200M tokens go to creator for liquidity
    function createTokenWithBondingCurve(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        uint256 _totalSupply, // Total supply (1 billion)
        string memory _description,
        string memory _logoURL,
        string memory _website,
        string memory _github,
        string memory _twitter,
        string[] memory _projectCategories,
        uint256[] memory _buyOptions,
        uint256 _P0_wad, // Initial price in BNB wei (WAD scaled)
        uint256 _m_wad,  // Slope in BNB wei per token (WAD scaled)
        uint256 /* _bnbPriceUSD */ // Current BNB price in USD (for validation - reserved for future use)
    ) external returns (address tokenAddress, address curveAddress) {
        require(bytes(_name).length > 0, "Name cannot be empty");
        require(bytes(_symbol).length > 0, "Symbol cannot be empty");
        require(_decimals > 0, "Decimals must be greater than 0");
        require(_totalSupply > 0, "Total supply must be greater than 0");
        
        // Calculate curve allocation (80% of total supply = 800M for 1B total)
        uint256 curveAllocation = (_totalSupply * 80) / 100; // 800M tokens
        require(curveAllocation > 0, "curveAllocation must be > 0");
        
        // Create token
        MemeToken token = new MemeToken(
            _name,
            _symbol,
            _decimals,
            msg.sender,
            _totalSupply,
            _description,
            _logoURL,
            _website,
            _github,
            _twitter,
            _projectCategories,
            _buyOptions
        );
        
        tokenAddress = address(token);
        
        // Create bonding curve
        BondingCurveBNB curve = new BondingCurveBNB(
            tokenAddress,
            _P0_wad,
            _m_wad,
            curveAllocation,
            feeRecipient,
            msg.sender // Owner of curve is token creator
        );
        
        curveAddress = address(curve);
        
        // Transfer curve allocation tokens to bonding curve
        // Token creator owns all tokens, so we transfer from creator's balance
        require(token.transfer(curveAddress, curveAllocation), "transfer failed");
        
        emit TokenCreated(tokenAddress, msg.sender, _name, _symbol);
        emit BondingCurveCreated(tokenAddress, curveAddress);
        
        return (tokenAddress, curveAddress);
    }
    
    // Create default token with bonding curve (1B supply, 18 decimals)
    function createDefaultTokenWithCurve(
        string memory _name,
        string memory _symbol,
        uint256 _P0_wad,
        uint256 _m_wad,
        uint256 _bnbPriceUSD
    ) external returns (address tokenAddress, address curveAddress) {
        return this.createTokenWithBondingCurve(
            _name,
            _symbol,
            18,
            1_000_000_000, // 1 billion
            "",
            "",
            "",
            "",
            "",
            new string[](0),
            new uint256[](0),
            _P0_wad,
            _m_wad,
            _bnbPriceUSD
        );
    }
}

