// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
 
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {
    Currency,
    CurrencyLibrary
} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {
    LiquidityAmounts
} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {LiquidityHelpers} from "./LiquidityHelpers.sol";
import {IPositionManager} from "./interfaces/IPositionManager.sol";
interface IBondingCurveBNB {
    function migrateLiquidity() external;
    function isMigrated() external view returns (bool);
}

interface IPermit2 {
    function approve(
        address token,
        address spender,
        uint160 amount,
        uint48 expiration
    ) external;
}

/// @title TokenMigrator
/// @notice Migrates liquidity from bonding curves to Uniswap V4 pools
/// @dev Handles the migration of tokens and native assets (BNB) from bonding curve contracts
/// to Uniswap V4 concentrated liquidity positions, with proper authorization and safety checks.
contract TokenMigrator is AccessControl, LiquidityHelpers, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    /// @notice Emitted when liquidity is successfully migrated to a Uniswap V4 pool
    /// @param token The ERC20 token being migrated
    /// @param bondingCurve The address of the bonding curve contract
    /// @param liquidity The amount of liquidity added to the Uniswap V4 pool
    event Migrated(address token, address bondingCurve, uint256 liquidity);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    address public positionManager;
    address immutable PERMIT2;
    address immutable public hook;


    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "Not admin");
        _;
    }

    /// @notice Initializes the TokenMigrator contract with essential Uniswap V4 configuration
    /// @param _positionManager Address of the Uniswap V4 PositionManager contract
    /// @param _hook Address of the Uniswap V4 hook contract to use for the pool
    /// @param _permit2 Address of the Permit2 contract for token approvals
    /// @dev Grants DEFAULT_ADMIN_ROLE and ADMIN_ROLE to the deployer
    constructor(
        address _positionManager,
        address _hook,
        address _permit2
    ) {
        require(_positionManager != address(0), "invalid positionManager");
        require(_hook != address(0), "invalid hook");
        require(_permit2 != address(0), "invalid permit2");
        positionManager = _positionManager;
        hook = _hook;
        PERMIT2 = _permit2;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /// @notice Migrates liquidity from a bonding curve to a Uniswap V4 concentrated liquidity position
    /// @param token The ERC20 token address to migrate
    /// @param bondingCurve The bonding curve contract address holding the liquidity
    /// @dev Only callable by admin. Performs these steps:
    ///   1. Validates the bonding curve hasn't already been migrated
    ///   2. Pulls BNB and tokens from the bonding curve
    ///   3. Calculates initial price and tick range for Uniswap V4
    ///   4. Approves tokens via Permit2 for the PositionManager
    ///   5. Creates a new pool and mints concentrated liquidity position
    function migrateBondingCurve(
        address token,
        address bondingCurve
    ) external onlyAdmin nonReentrant {
        // check is already migrated in bonding curve
        bool isMigrated = IBondingCurveBNB(bondingCurve).isMigrated();
        require(!isMigrated, "Bonding curve already migrated");
     
        // 1. Pull funds from bonding curve
        IBondingCurveBNB(bondingCurve).migrateLiquidity();

        uint256 bnbBalance = address(this).balance;
        require(bnbBalance > 0, "No BNB");

        address native = address(0); // using address(0) to represent native token in Uniswap V4

        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        require(tokenBalance > 0, "No tokens");

        // 3. Sort tokens (important for v4)
        (address token0, address token1) = native < token
            ? (native, token)
            : (token, native);

        uint256 amount0 = token0 == token ? tokenBalance : bnbBalance;
        uint256 amount1 = token1 == token ? tokenBalance : bnbBalance;
        require(amount0 > 0 && amount1 > 0, "Invalid amounts");
        // sqrtPrice
        uint160 sqrtPriceX96 = encodeSqrtPriceX96(amount1, amount0);

        // tick
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        // range
        int24 tickSpacing = 60;
        int24 range = 6000;

        int24 tickLower = ((tick - range) / tickSpacing) * tickSpacing;
        int24 tickUpper = ((tick + range) / tickSpacing) * tickSpacing;

        Currency currency0 = Currency.wrap(token0);
        Currency currency1 = Currency.wrap(token1);

        // 4. Pool key
        PoolKey memory poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });


        // 5. Approvals
        // Step 1: approve permit2
        IERC20(token).approve(PERMIT2, 0);
        IERC20(token).approve(PERMIT2, type(uint256).max);

        // Step 2: permit2 approve positionManager
        IPermit2(PERMIT2).approve(
            token,
            positionManager,
            uint160(tokenBalance),
            uint48(block.timestamp + 1 hours)
        );

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );

        uint256 amount0Max = amount0 + 1;
        uint256 amount1Max = amount1 + 1;

        bytes memory hookData = "";
        (
            bytes memory actions,
            bytes[] memory mintParams
        ) = _mintLiquidityParams(
                poolKey,
                tickLower,
                tickUpper,
                liquidity,
                amount0Max,
                amount1Max,
                msg.sender,
                hookData
            );

        // multicall parameters
        bytes[] memory params = new bytes[](2);

        // Initialize Pool
        params[0] = abi.encodeWithSelector(
            IPositionManager(positionManager).initializePool.selector,
            poolKey,
            sqrtPriceX96,
            hookData
        );

        // Mint Liquidity
        params[1] = abi.encodeWithSelector(
            IPositionManager(positionManager).modifyLiquidities.selector,
            abi.encode(actions, mintParams),
            block.timestamp + 3600
        );

        // If the pool is an ETH pair, native tokens are to be transferred
        uint256 valueToPass = bnbBalance;

        // Multicall to atomically create pool & add liquidity
        IPositionManager(positionManager).multicall{value: valueToPass}(params);
        emit Migrated(token, bondingCurve, liquidity);
    }

    /// @notice Rescues ERC20 tokens accidentally sent to or stuck in the contract
    /// @param token The ERC20 token address to rescue
    /// @param amount The amount of tokens to withdraw
    /// @dev ⚠️ ONLY USE IF A TINY AMOUNT IS STUCK DURING LP ADD ⚠️
    ///   This is for emergency recovery of dust amounts that may remain after migration.
    ///   Should NOT be used under normal circumstances. Only admin can call this.
    ///   Typical use case: Small rounding errors or precision loss during liquidity provisioning.
    function rescueTokens(
        address token,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    /// @notice Rescues native BNB accidentally sent to or stuck in the contract
    /// @param amount The amount of BNB (in wei) to withdraw
    /// @dev ⚠️ ONLY USE IF A TINY AMOUNT IS STUCK DURING LP ADD ⚠️
    ///   This is for emergency recovery of dust amounts that may remain after migration.
    ///   Should NOT be used under normal circumstances. Only admin can call this.
    ///   Typical use case: Small rounding errors or precision loss during liquidity provisioning.
    function rescueBNB(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(this).balance >= amount, "insufficient balance");

        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }

    /// @notice Encodes the initial price ratio as a sqrtPriceX96 value for Uniswap V4
    /// @param amount1 The amount of token1 (numerator value)
    /// @param amount0 The amount of token0 (denominator value)
    /// @return The encoded sqrtPriceX96 value
    /// @dev Calculates sqrt(amount1/amount0) in Q64.96 fixed-point format
    ///   This is used as the initial price when creating a new Uniswap V4 pool
    function encodeSqrtPriceX96(
        uint256 amount1,
        uint256 amount0
    ) internal pure returns (uint160) {
        uint256 ratioX192 = (amount1 << 192) / amount0;
        return uint160(sqrt(ratioX192));
    }

    /// @notice Calculates the integer square root using the Babylonian method
    /// @param x The value to calculate the square root of
    /// @return y The integer square root of x
    /// @dev Uses an iterative approach for gas-efficient computation
    ///   Returns the largest integer y such that y² ≤ x
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /// @notice Allows the contract to receive native BNB directly
    /// @dev Required for accepting BNB from the bonding curve and for refunds from Uniswap V4
    receive() external payable {}
}
