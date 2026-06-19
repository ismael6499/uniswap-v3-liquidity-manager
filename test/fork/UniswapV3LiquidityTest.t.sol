// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {UniswapV3Liquidity} from "../../src/UniswapV3Liquidity.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title UniswapV3LiquidityTest
/// @author Agustin Acosta
/// @notice Fork tests on Ethereum mainnet validating Concentrated Liquidity interactions.
contract UniswapV3LiquidityTest is Test {
    // ─── Mainnet Addresses ───────────────────────
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    address constant POSITION_MANAGER = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // ─── Fee Tiers ───────────────────────────────
    uint24 constant FEE_MEDIUM = 3000; // 0.30%

    // ─── Contracts ───────────────────────────────
    UniswapV3Liquidity liquidityContract;

    // ─── Actors ──────────────────────────────────
    address ALICE = makeAddr("alice");

    // ─── Setup ───────────────────────────────────
    function setUp() public {
        liquidityContract = new UniswapV3Liquidity(POSITION_MANAGER);

        // Fund Alice with assets
        deal(WETH, ALICE, 1000e18);
        deal(USDC, ALICE, 1_000_000e6);
    }

    // ═════════════════════════════════════════════════════════════════════
    // SUCCESS TESTS
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify successful creation of a new concentrated liquidity position
    function test_MintPosition_Success() public {
        address pool = IUniswapV3Factory(FACTORY).getPool(USDC, WETH, FEE_MEDIUM);
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        int24 tickSpacing = 60;
        int24 tickLower = (currentTick / tickSpacing - 10) * tickSpacing;
        int24 tickUpper = (currentTick / tickSpacing + 10) * tickSpacing;

        uint256 amount0 = 10_000e6;
        uint256 amount1 = 5e18;

        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(liquidityContract), amount0);
        IERC20(WETH).approve(address(liquidityContract), amount1);

        (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1) =
            liquidityContract.mintPosition(USDC, WETH, FEE_MEDIUM, tickLower, tickUpper, amount0, amount1);
        vm.stopPrank();

        assertGt(tokenId, 0, "NFT ID should be valid");
        assertGt(liquidity, 0, "Liquidity should be greater than zero");
        assertLe(used0, amount0, "Used USDC should not exceed desired amount");
        assertLe(used1, amount1, "Used WETH should not exceed desired amount");
    }

    /// @notice Verify increasing liquidity on an existing position
    function test_IncreaseLiquidity_Success() public {
        (uint256 tokenId, ) = _mintTestPosition();

        uint256 addAmount0 = 5_000e6;
        uint256 addAmount1 = 2e18;

        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(liquidityContract), addAmount0);
        IERC20(WETH).approve(address(liquidityContract), addAmount1);

        INonfungiblePositionManager(POSITION_MANAGER).approve(address(liquidityContract), tokenId);

        (uint128 addedLiquidity,,) =
            liquidityContract.increaseLiquidity(tokenId, USDC, WETH, addAmount0, addAmount1);
        vm.stopPrank();

        assertGt(addedLiquidity, 0, "Liquidity addition should succeed");
    }

    /// @notice Verify decreasing liquidity and collecting assets
    function test_DecreaseAndCollect_Success() public {
        (uint256 tokenId, uint128 liquidity) = _mintTestPosition();
        uint128 halfLiquidity = liquidity / 2;

        vm.startPrank(ALICE);
        INonfungiblePositionManager(POSITION_MANAGER).approve(address(liquidityContract), tokenId);

        (uint256 amount0Owed, uint256 amount1Owed) =
            liquidityContract.decreaseLiquidity(tokenId, halfLiquidity);
        vm.stopPrank();

        assertGt(amount0Owed + amount1Owed, 0, "Decrease liquidity should owe assets");

        uint256 usdcBefore = IERC20(USDC).balanceOf(ALICE);

        vm.prank(ALICE);
        (uint256 collected0, uint256 collected1) = liquidityContract.collectFees(tokenId);

        assertGe(collected0, amount0Owed, "Collected USDC mismatch");
        assertGe(collected1, amount1Owed, "Collected WETH mismatch");
        assertGt(IERC20(USDC).balanceOf(ALICE), usdcBefore, "USDC balance must increase");
    }

    /// @notice Verify fee harvesting after swaps routes trade volume through position range
    function test_CollectFeesAfterSwaps_Success() public {
        (uint256 tokenId,) = _mintTestPosition();

        // Perform a swap to route trading volume and generate protocol fees
        vm.startPrank(ALICE);
        uint256 swapAmount = 5e18; // Swap 5 WETH for USDC
        IERC20(WETH).approve(SWAP_ROUTER, swapAmount);
        ISwapRouter(SWAP_ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: USDC,
                fee: FEE_MEDIUM,
                recipient: ALICE,
                deadline: block.timestamp,
                amountIn: swapAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        // Approve and harvest generated fees
        vm.startPrank(ALICE);
        INonfungiblePositionManager(POSITION_MANAGER).approve(address(liquidityContract), tokenId);
        (uint256 fee0, uint256 fee1) = liquidityContract.collectFees(tokenId);
        vm.stopPrank();

        assertTrue(fee0 > 0 || fee1 > 0, "Fees should be generated and collected");
    }

    /// @notice Full position lifecycle verification
    function test_FullLifecycle_Success() public {
        (uint256 tokenId, uint128 liquidity) = _mintTestPosition();

        // Generate trading volume
        vm.startPrank(ALICE);
        uint256 swapAmount = 10e18;
        IERC20(WETH).approve(SWAP_ROUTER, swapAmount);
        ISwapRouter(SWAP_ROUTER).exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: USDC,
                fee: FEE_MEDIUM,
                recipient: ALICE,
                deadline: block.timestamp,
                amountIn: swapAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        vm.stopPrank();

        vm.startPrank(ALICE);
        INonfungiblePositionManager(POSITION_MANAGER).approve(address(liquidityContract), tokenId);

        // Collect fees first
        (uint256 fee0, uint256 fee1) = liquidityContract.collectFees(tokenId);
        console2.log("Collected trading fees - USDC:", fee0, "WETH:", fee1);

        // Burn/remove all liquidity
        liquidityContract.decreaseLiquidity(tokenId, liquidity);

        // Withdraw principal
        (uint256 collected0, uint256 collected1) = liquidityContract.collectFees(tokenId);
        vm.stopPrank();

        assertTrue(collected0 > 0 || collected1 > 0, "Principal withdrawal should succeed");
    }

    // ═════════════════════════════════════════════════════════════════════
    // FUZZ TESTS
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Fuzz test the minting process over randomized, bounded input amounts
    function testFuzz_MintPosition_Success(uint256 _amount0, uint256 _amount1) public {
        _amount0 = bound(_amount0, 100e6, 50_000e6); // 100 to 50k USDC
        _amount1 = bound(_amount1, 0.1e18, 50e18);   // 0.1 to 50 WETH

        address pool = IUniswapV3Factory(FACTORY).getPool(USDC, WETH, FEE_MEDIUM);
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        int24 tickSpacing = 60;
        int24 tickLower = (currentTick / tickSpacing - 10) * tickSpacing;
        int24 tickUpper = (currentTick / tickSpacing + 10) * tickSpacing;

        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(liquidityContract), _amount0);
        IERC20(WETH).approve(address(liquidityContract), _amount1);

        (uint256 tokenId, uint128 liquidity, uint256 used0, uint256 used1) =
            liquidityContract.mintPosition(USDC, WETH, FEE_MEDIUM, tickLower, tickUpper, _amount0, _amount1);
        vm.stopPrank();

        assertGt(tokenId, 0);
        assertGt(liquidity, 0);
        assertLe(used0, _amount0);
        assertLe(used1, _amount1);
    }

    // ═════════════════════════════════════════════════════════════════════
    // REVERT TESTS
    // ═════════════════════════════════════════════════════════════════════

    /// @notice Verify constructor reverts if zero address is passed
    function test_RevertWhen_ConstructorZeroAddress() public {
        vm.expectRevert(UniswapV3Liquidity.ZeroAddress.selector);
        new UniswapV3Liquidity(address(0));
    }

    /// @notice Verify revert when minting with zero desired amounts
    function test_RevertWhen_ZeroAmountDesired() public {
        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(liquidityContract), 1000);
        IERC20(WETH).approve(address(liquidityContract), 1000);

        vm.expectRevert(UniswapV3Liquidity.ZeroAmount.selector);
        liquidityContract.mintPosition(USDC, WETH, FEE_MEDIUM, -60, 60, 0, 1000);

        vm.expectRevert(UniswapV3Liquidity.ZeroAmount.selector);
        liquidityContract.mintPosition(USDC, WETH, FEE_MEDIUM, -60, 60, 1000, 0);
        vm.stopPrank();
    }

    /// @notice Verify revert when tokens are not sorted correctly
    function test_RevertWhen_TokenOrderInvalid() public {
        vm.startPrank(ALICE);
        IERC20(WETH).approve(address(liquidityContract), 1000);
        IERC20(USDC).approve(address(liquidityContract), 1000);

        // WETH (higher address) passed as token0, USDC (lower address) passed as token1
        vm.expectRevert(UniswapV3Liquidity.TokenOrderInvalid.selector);
        liquidityContract.mintPosition(WETH, USDC, FEE_MEDIUM, -60, 60, 1000, 1000);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════
    // HELPERS
    // ═════════════════════════════════════════════════════════════════════

    /// @dev Mint a test liquidity position and return the tokenId and liquidity
    function _mintTestPosition() internal returns (uint256 tokenId, uint128 liquidity) {
        address pool = IUniswapV3Factory(FACTORY).getPool(USDC, WETH, FEE_MEDIUM);
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        int24 tickSpacing = 60;
        int24 tickLower = (currentTick / tickSpacing - 10) * tickSpacing;
        int24 tickUpper = (currentTick / tickSpacing + 10) * tickSpacing;

        uint256 amount0 = 50_000e6;
        uint256 amount1 = 20e18;

        vm.startPrank(ALICE);
        IERC20(USDC).approve(address(liquidityContract), amount0);
        IERC20(WETH).approve(address(liquidityContract), amount1);

        (tokenId, liquidity,,) =
            liquidityContract.mintPosition(USDC, WETH, FEE_MEDIUM, tickLower, tickUpper, amount0, amount1);
        vm.stopPrank();
    }
}
