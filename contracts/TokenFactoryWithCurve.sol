// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./MemeToken.sol";
import "./BondingCurve.sol";

contract TokenFactoryWithCurve is Ownable {
    using SafeERC20 for IERC20;

    address public immutable feeRecipient;

    // LOT-12 (Audit): Bounds for P0 and m to prevent free/flat curves and overflow
    // AUDIT FIX (BUG-19): Increased MIN_P0 and MIN_M from 1 to 1e6. With MIN=1 (1 wei in WAD),
    // P0 = 0.000000000000000001 BNB/token — effectively free. 1e6 ensures a minimum meaningful price
    // of ~0.000000000001 BNB/token, preventing sub-dust economics that offer no economic protection.
    uint256 public constant MIN_P0 = 1e6;
    uint256 public constant MAX_P0 = 1e18;
    uint256 public constant MIN_M = 1e6;
    uint256 public constant MAX_M = 100e18;

    event TokenCreated(address tokenAddress, address creator, string name, string symbol);
    event BondingCurveCreated(address tokenAddress, address curveAddress);

    constructor(address _feeRecipient) {
        require(_feeRecipient != address(0), "feeRecipient 0");
        feeRecipient = _feeRecipient;
        _transferOwnership(msg.sender);
    }

    /// @dev LOT-07 (Audit): Internal implementation so msg.sender is preserved when called from createDefaultTokenWithCurve
    function _createTokenWithBondingCurve(
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
        uint256[] memory _buyOptions,
        uint256 _P0_wad,
        uint256 _m_wad
    ) internal returns (address tokenAddress, address curveAddress) {
        require(bytes(_name).length > 0, "Name cannot be empty");
        require(bytes(_symbol).length > 0, "Symbol cannot be empty");
        require(_decimals > 0, "Decimals must be greater than 0");
        require(_totalSupply > 0, "Total supply must be greater than 0");
        // LOT-19 (Audit): Bonding curve math assumes 18-decimal tokens; enforce in all factory paths
        require(_decimals == 18, "bonding curves require 18 decimals");
        require(_P0_wad >= MIN_P0 && _P0_wad <= MAX_P0, "P0 out of range");
        require(_m_wad >= MIN_M && _m_wad <= MAX_M, "m out of range");

        // LOT-03 (Audit): Scale curveAllocation by token decimals (was 1e18 too small)
        uint256 rawTotalSupply = _totalSupply * (10 ** _decimals);
        uint256 curveAllocation = (rawTotalSupply * 80) / 100;
        uint256 creatorAllocation = rawTotalSupply - curveAllocation;
        require(curveAllocation > 0, "curveAllocation must be > 0");

        // LOT-02 (Audit): Mint to factory so we can transfer; then distribute atomically
        MemeToken token = new MemeToken(
            _name,
            _symbol,
            _decimals,
            address(this),
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

        BondingCurveBNB curve = new BondingCurveBNB(
            tokenAddress,
            _P0_wad,
            _m_wad,
            curveAllocation,
            feeRecipient,
            msg.sender
        );
        curveAddress = address(curve);

        IERC20(tokenAddress).safeTransfer(curveAddress, curveAllocation);
        IERC20(tokenAddress).safeTransfer(msg.sender, creatorAllocation);

        // LOT-28 (Audit Round 2): Call setExcludedFromLimits BEFORE transferOwnership — factory must perform
        // owner-only operations while it still owns the token; otherwise setExcludedFromLimits reverts (onlyOwner).
        token.setExcludedFromLimits(curveAddress, true);
        // LOT-29 (Audit Round 2): Defense-in-depth — verify exclusion was applied before handing off ownership
        require(token.isExcludedFromLimits(curveAddress), "curve exclusion failed");
        token.transferOwnership(msg.sender);

        emit TokenCreated(tokenAddress, msg.sender, _name, _symbol);
        emit BondingCurveCreated(tokenAddress, curveAddress);
        return (tokenAddress, curveAddress);
    }

    function createTokenWithBondingCurve(
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
        uint256[] memory _buyOptions,
        uint256 _P0_wad,
        uint256 _m_wad,
        uint256 /* _bnbPriceUSD */
    ) external returns (address tokenAddress, address curveAddress) {
        return _createTokenWithBondingCurve(
            _name, _symbol, _decimals, _totalSupply,
            _description, _logoURL, _website, _github, _twitter,
            _projectCategories, _buyOptions, _P0_wad, _m_wad
        );
    }

    /// @dev LOT-07 (Audit): Call internal to preserve msg.sender (no external self-call)
    function createDefaultTokenWithCurve(
        string memory _name,
        string memory _symbol,
        uint256 _P0_wad,
        uint256 _m_wad,
        uint256 _bnbPriceUSD
    ) external returns (address tokenAddress, address curveAddress) {
        return _createTokenWithBondingCurve(
            _name, _symbol, 18, 1_000_000_000,
            "", "", "", "", "",
            new string[](0), new uint256[](0),
            _P0_wad, _m_wad
        );
    }
}

