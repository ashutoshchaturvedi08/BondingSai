// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./MemeToken.sol";
import "./BondingCurveFactory.sol";

contract TokenFactory is Ownable {
    using SafeERC20 for IERC20;
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
    /// @dev LOT-11 (Audit): Mint to factory and fund curve atomically; LOT-19: bonding curves require 18 decimals
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
        require(_decimals == 18, "bonding curves require 18 decimals");

        uint256 totalSupply = 1_000_000_000;
        uint256 rawTotalSupply = totalSupply * (10 ** _decimals);
        uint256 curveAllocation = (rawTotalSupply * 80) / 100;
        uint256 creatorAllocation = rawTotalSupply - curveAllocation;

        MemeToken token = new MemeToken(
            _name, _symbol, _decimals,
            address(this),
            totalSupply,
            _description, _logoURL, _website, _github, _twitter,
            _projectCategories, _buyOptions
        );
        tokenAddress = address(token);

        bondingCurveAddress = bondingCurveFactory.createBondingCurve(
            tokenAddress,
            _decimals,
            msg.sender
        );

        IERC20(tokenAddress).safeTransfer(bondingCurveAddress, curveAllocation);
        IERC20(tokenAddress).safeTransfer(msg.sender, creatorAllocation);

        // LOT-28 (Audit Round 2): Call setExcludedFromLimits BEFORE transferOwnership — factory must perform
        // owner-only operations while it still owns the token; otherwise setExcludedFromLimits reverts (onlyOwner).
        token.setExcludedFromLimits(bondingCurveAddress, true);
        // LOT-29 (Audit Round 2): Defense-in-depth — verify exclusion was applied before handing off ownership
        require(token.isExcludedFromLimits(bondingCurveAddress), "curve exclusion failed");
        token.transferOwnership(msg.sender);

        emit TokenWithBondingCurveCreated(
            tokenAddress,
            bondingCurveAddress,
            msg.sender,
            _name,
            _symbol
        );
    }
}

