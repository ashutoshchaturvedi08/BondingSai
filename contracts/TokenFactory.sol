// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./MemeToken.sol";
import "./BondingCurveFactory.sol";

contract TokenFactory is Ownable {
    BondingCurveFactory public bondingCurveFactory;
    
    event TokenCreated(address tokenAddress, address creator, string name, string symbol);
    event TokenWithBondingCurveCreated(
        address indexed tokenAddress,
        address indexed bondingCurveAddress,
        address indexed creator,
        string name,
        string symbol
    );
    
    constructor(address _bondingCurveFactory) {
        require(_bondingCurveFactory != address(0), "bondingCurveFactory 0");
        bondingCurveFactory = BondingCurveFactory(_bondingCurveFactory);
        _transferOwnership(msg.sender);
    }
    
    /**
     * @notice Update bonding curve factory address
     */
    function setBondingCurveFactory(address _bondingCurveFactory) external onlyOwner {
        require(_bondingCurveFactory != address(0), "bondingCurveFactory 0");
        bondingCurveFactory = BondingCurveFactory(_bondingCurveFactory);
    }
    
    // Create token with default settings (1 billion supply, 9 decimals)
    function createDefaultToken(
        string memory _name,
        string memory _symbol
    ) external returns (address) {
        uint8 decimals = 18;
        uint256 totalSupply = 1_000_000_000; // 1 billion
        
        MemeToken token = new MemeToken(
            _name,
            _symbol,
            decimals,
            msg.sender,
            totalSupply,
            "", // description
            "", // logoURL
            "", // website
            "", // github
            "", // twitter
            new string[](0), // projectCategories
            new uint256[](0) // buyOptions
        );
        
        address tokenAddress = address(token);
        emit TokenCreated(tokenAddress, msg.sender, _name, _symbol);
        return tokenAddress;
    }
    
    // Create token with custom settings and optional metadata
    function createCustomToken(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        uint256 _totalSupply,
        string memory _description,
        string memory _logoURL,
        string memory _website,
        string memory _github,
        string memory _twitter,
        string[] memory _projectCategories,
        uint256[] memory _buyOptions
    ) external returns (address) {
        require(bytes(_name).length > 0, "Name cannot be empty");
        require(bytes(_symbol).length > 0, "Symbol cannot be empty");
        require(_decimals > 0, "Decimals must be greater than 0");
        require(_totalSupply > 0, "Total supply must be greater than 0");
        
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
        
        address tokenAddress = address(token);
        emit TokenCreated(tokenAddress, msg.sender, _name, _symbol);
        return tokenAddress;
    }
    
    /**
     * @notice Create token with bonding curve automatically set up
     * @dev Creates token, bonding curve, and transfers 800M tokens to curve
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _decimals Token decimals (usually 18)
     * @param _description Token description
     * @param _logoURL Logo URL
     * @param _website Website URL
     * @param _github GitHub URL
     * @param _twitter Twitter handle
     * @param _projectCategories Project categories
     * @param _buyOptions Buy options
     * @return tokenAddress Address of created token
     * @return bondingCurveAddress Address of created bonding curve
     */
    function createTokenWithBondingCurve(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        string memory _description,
        string memory _logoURL,
        string memory _website,
        string memory _github,
        string memory _twitter,
        string[] memory _projectCategories,
        uint256[] memory _buyOptions
    ) external returns (address tokenAddress, address bondingCurveAddress) {
        require(bytes(_name).length > 0, "Name cannot be empty");
        require(bytes(_symbol).length > 0, "Symbol cannot be empty");
        require(_decimals > 0, "Decimals must be greater than 0");
        
        // Create token with 1 billion supply
        uint256 totalSupply = 1_000_000_000; // 1 billion
        
        MemeToken token = new MemeToken(
            _name,
            _symbol,
            _decimals,
            msg.sender,
            totalSupply,
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
        bondingCurveAddress = bondingCurveFactory.createBondingCurve(
            tokenAddress,
            _decimals,
            msg.sender
        );
        
        // Note: Token creator owns all tokens initially (1B tokens)
        // Creator needs to manually deposit 800M tokens to the bonding curve after creation
        // This can be done by calling: bondingCurve.depositCurveTokens(800_000_000 * 10^decimals)
        // The remaining 200M tokens stay with creator for liquidity provision
        
        emit TokenWithBondingCurveCreated(
            tokenAddress,
            bondingCurveAddress,
            msg.sender,
            _name,
            _symbol
        );
    }
}

