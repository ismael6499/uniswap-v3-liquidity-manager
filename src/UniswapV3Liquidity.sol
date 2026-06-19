// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

/// @title Concentrated Liquidity Position Manager for Uniswap V3 Pools
/// @author Agustin Acosta
/// @notice Demonstrates secure, non-reentrant concentrated liquidity operations on Uniswap V3.
/// @dev Bypasses high-level wrapper complexities, managing ERC-721 liquidity tokens directly.
contract UniswapV3Liquidity is ReentrancyGuard {
    // ═══════════════════════════════════════════════════════════════════════
    // STORAGE
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The Uniswap V3 Nonfungible Position Manager contract
    INonfungiblePositionManager public immutable POSITION_MANAGER;

    // ═══════════════════════════════════════════════════════════════════════
    // CUSTOM ERRORS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Thrown when a zero-value amount or liquidity is supplied.
    error ZeroAmount();

    /// @notice Thrown when a zero-address is supplied for configuration.
    error ZeroAddress();

    /// @notice Thrown when the tokens are not sorted correctly (token0 must be < token1).
    error TokenOrderInvalid();

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new liquidity position is minted.
    event PositionMinted(uint256 indexed tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Emitted when liquidity is added to an existing position.
    event LiquidityIncreased(uint256 indexed tokenId, uint128 liquidity);

    /// @notice Emitted when liquidity is decreased from an existing position.
    event LiquidityDecreased(uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    /// @notice Emitted when trading fees and principal tokens are collected.
    event FeesCollected(uint256 indexed tokenId, uint256 amount0, uint256 amount1);

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Initializes the liquidity manager with the Position Manager contract.
    /// @param _positionManager The address of the NonfungiblePositionManager.
    constructor(address _positionManager) {
        if (_positionManager == address(0)) {
            revert ZeroAddress();
        }
        POSITION_MANAGER = INonfungiblePositionManager(_positionManager);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MINT — Create a new liquidity position
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Mint a new concentrated liquidity position
    /// @dev Creates an ERC-721 token representing the position. Handles Fee-on-Transfer tokens.
    /// @param _token0 The first token address (must be lower address)
    /// @param _token1 The second token address (must be higher address)
    /// @param _fee The pool fee tier
    /// @param _tickLower Lower bound of the price range (must be multiple of tick spacing)
    /// @param _tickUpper Upper bound of the price range (must be multiple of tick spacing)
    /// @param _amount0Desired Desired amount of token0 to supply
    /// @param _amount1Desired Desired amount of token1 to supply
    /// @return tokenId The NFT token ID of the position
    /// @return liquidity The amount of liquidity minted
    /// @return amount0 Actual amount of token0 deposited
    /// @return amount1 Actual amount of token1 deposited
    function mintPosition(
        address _token0,
        address _token1,
        uint24 _fee,
        int24 _tickLower,
        int24 _tickUpper,
        uint256 _amount0Desired,
        uint256 _amount1Desired
    ) external nonReentrant returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (_token0 >= _token1) {
            revert TokenOrderInvalid();
        }
        if (_amount0Desired == 0 || _amount1Desired == 0) {
            revert ZeroAmount();
        }

        // Measure actual token amounts received to handle fee-on-transfer tokens
        uint256 balance0Before = IERC20(_token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(_token1).balanceOf(address(this));

        IERC20(_token0).transferFrom(msg.sender, address(this), _amount0Desired);
        IERC20(_token1).transferFrom(msg.sender, address(this), _amount1Desired);

        uint256 actualAmount0 = IERC20(_token0).balanceOf(address(this)) - balance0Before;
        uint256 actualAmount1 = IERC20(_token1).balanceOf(address(this)) - balance1Before;

        if (actualAmount0 == 0 || actualAmount1 == 0) {
            revert ZeroAmount();
        }

        // Approve position manager to spend the received tokens
        IERC20(_token0).approve(address(POSITION_MANAGER), actualAmount0);
        IERC20(_token1).approve(address(POSITION_MANAGER), actualAmount1);

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: _token0,
            token1: _token1,
            fee: _fee,
            tickLower: _tickLower,
            tickUpper: _tickUpper,
            amount0Desired: actualAmount0,
            amount1Desired: actualAmount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: msg.sender,
            deadline: block.timestamp
        });

        (tokenId, liquidity, amount0, amount1) = POSITION_MANAGER.mint(params);

        // Reset approvals and refund unused tokens to msg.sender
        IERC20(_token0).approve(address(POSITION_MANAGER), 0);
        IERC20(_token1).approve(address(POSITION_MANAGER), 0);

        if (amount0 < actualAmount0) {
            IERC20(_token0).transfer(msg.sender, actualAmount0 - amount0);
        }
        if (amount1 < actualAmount1) {
            IERC20(_token1).transfer(msg.sender, actualAmount1 - amount1);
        }

        emit PositionMinted(tokenId, liquidity, amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // INCREASE LIQUIDITY — Add more to an existing position
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Add more liquidity to an existing position
    /// @dev Caller must own or be approved to manage the NFT position.
    /// @param _tokenId The NFT token ID of the position
    /// @param _token0 The first token address of the pool
    /// @param _token1 The second token address of the pool
    /// @param _amount0Desired Desired amount of token0 to add
    /// @param _amount1Desired Desired amount of token1 to add
    /// @return liquidity The amount of liquidity added
    /// @return amount0 Actual amount of token0 deposited
    /// @return amount1 Actual amount of token1 deposited
    function increaseLiquidity(
        uint256 _tokenId,
        address _token0,
        address _token1,
        uint256 _amount0Desired,
        uint256 _amount1Desired
    ) external nonReentrant returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (_amount0Desired == 0 || _amount1Desired == 0) {
            revert ZeroAmount();
        }

        // Measure actual token amounts received to handle fee-on-transfer tokens
        uint256 balance0Before = IERC20(_token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(_token1).balanceOf(address(this));

        IERC20(_token0).transferFrom(msg.sender, address(this), _amount0Desired);
        IERC20(_token1).transferFrom(msg.sender, address(this), _amount1Desired);

        uint256 actualAmount0 = IERC20(_token0).balanceOf(address(this)) - balance0Before;
        uint256 actualAmount1 = IERC20(_token1).balanceOf(address(this)) - balance1Before;

        if (actualAmount0 == 0 || actualAmount1 == 0) {
            revert ZeroAmount();
        }

        // Approve position manager to spend the received tokens
        IERC20(_token0).approve(address(POSITION_MANAGER), actualAmount0);
        IERC20(_token1).approve(address(POSITION_MANAGER), actualAmount1);

        (liquidity, amount0, amount1) = POSITION_MANAGER.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: _tokenId,
                amount0Desired: actualAmount0,
                amount1Desired: actualAmount1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        // Reset approvals and refund unused tokens to msg.sender
        IERC20(_token0).approve(address(POSITION_MANAGER), 0);
        IERC20(_token1).approve(address(POSITION_MANAGER), 0);

        if (amount0 < actualAmount0) {
            IERC20(_token0).transfer(msg.sender, actualAmount0 - amount0);
        }
        if (amount1 < actualAmount1) {
            IERC20(_token1).transfer(msg.sender, actualAmount1 - amount1);
        }

        emit LiquidityIncreased(_tokenId, liquidity);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // DECREASE LIQUIDITY — Remove from an existing position
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Remove liquidity from an existing position
    /// @dev Does not transfer tokens. Caller must subsequently invoke collectFees() to retrieve assets.
    /// @param _tokenId The NFT token ID of the position
    /// @param _liquidity The amount of liquidity to remove
    /// @return amount0 The amount of token0 marked as owed
    /// @return amount1 The amount of token1 marked as owed
    function decreaseLiquidity(uint256 _tokenId, uint128 _liquidity)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (_liquidity == 0) {
            revert ZeroAmount();
        }

        (amount0, amount1) = POSITION_MANAGER.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: _tokenId,
                liquidity: _liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        emit LiquidityDecreased(_tokenId, amount0, amount1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // COLLECT — Withdraw tokens (fees + removed liquidity)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Collect all tokens owed to a position (fees and principal from decreaseLiquidity)
    /// @param _tokenId The NFT token ID of the position
    /// @return amount0 The amount of token0 collected
    /// @return amount1 The amount of token1 collected
    function collectFees(uint256 _tokenId) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        (amount0, amount1) = POSITION_MANAGER.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: _tokenId,
                recipient: msg.sender,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        emit FeesCollected(_tokenId, amount0, amount1);
    }
}
