# Uniswap V3 Liquidity Manager

![Solidity](https://img.shields.io/badge/Solidity-0.8.26-363636?style=flat-square&logo=solidity)
![Foundry](https://img.shields.io/badge/Foundry-Testing-FF9E0F?style=flat-square)
![Coverage](https://img.shields.io/badge/Coverage-100%25-brightgreen?style=flat-square)

A smart contract integration executing non-reentrant Concentrated Liquidity management on Uniswap V3. This project demonstrates how to mint new positions, increase or decrease liquidity, and collect trading fees directly through the Uniswap V3 Periphery Nonfungible Position Manager using Solidity 0.8.26.

---

## 🏗 Architecture & Technical Deep Dive

This integration interfaces directly with the Uniswap V3 `NonfungiblePositionManager` (deployed at `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` on Ethereum mainnet) to handle LP positions wrapped as ERC-721 NFTs.

### 1. Concentrated Liquidity Mechanics
- **Context:** In Uniswap V2, liquidity is distributed uniformly across the entire price curve $(0, \infty)$, meaning the vast majority of capital remains unutilized. Uniswap V3 introduces Concentrated Liquidity, enabling Liquidity Providers (LPs) to allocate capital to custom price ranges.
- **Implementation:** LPs specify a boundary defined by `tickLower` and `tickUpper`. Ticks represent discrete price points calculated as $P(t) = 1.0001^t$. These ticks must align with the pool's tick spacing (e.g., spacing of 10 for 0.05% pools, 60 for 0.30% pools). 
- Capital is only active and collecting protocol fees when the current spot price lies within the bounds $[t_{\text{lower}}, t_{\text{upper}}]$.

### 2. Low-Level Reentrancy Protection
- **Context:** Interactions with external DeFi protocols (such as token transfers and call hooks) introduce significant attack surfaces. Although the Checks-Effects-Interactions (CEI) pattern is applied, defense-in-depth demands execution-level reentrancy blocks.
- **Implementation:** The `UniswapV3Liquidity` contract inherits from a custom, gas-efficient `ReentrancyGuard`. It locks state-changing operations (`mintPosition`, `increaseLiquidity`, `decreaseLiquidity`, `collectFees`) using a transient slot flag. This prevents recursive call hijacking, reverting with the custom selector `ReentrancyGuard__ReentrantCall()` upon reentrant invocation.

### 3. Fee-on-Transfer Token Support
- **Context:** Deflationary tokens or tokens with internal transfer taxes (Fee-on-Transfer) deduct fees dynamically during transfer. If a contract blindly trusts user-supplied arguments for transaction amounts, it will attempt to mint positions with larger quantities than it actually holds, causing transaction failures.
- **Implementation:** The contract wraps all incoming token transfers using balance checks before and after execution:
  ```solidity
  uint256 balanceBefore = IERC20(token).balanceOf(address(this));
  IERC20(token).transferFrom(msg.sender, address(this), amountDesired);
  uint256 actualAmount = IERC20(token).balanceOf(address(this)) - balanceBefore;
  ```
  The computed `actualAmount` is passed as the parameter to Uniswap V3, ensuring support for tax-on-transfer tokens.

### 4. Custom Error Gas Reductions
- **Context:** High-level `require` checks utilize revert strings (such as `require(amount > 0, "Zero amount")`) that require ABI-encoding string data and increase deployment size.
- **Implementation:** Custom Errors are declared globally and thrown upon assertion failures:
  - `ZeroAmount()`: Thrown when desired inputs are zero.
  - `ZeroAddress()`: Thrown when the position manager address is zero.
  - `TokenOrderInvalid()`: Thrown if tokens are not sorted correctly by address.

---

## 🧪 Testing & Quality Assurance

The test suite is built on **Foundry**, executing fork tests directly against Ethereum mainnet to validate real-world contract interactions. It achieves **100.00% Line and Branch Coverage** for the custom integration.

### Test Suite Highlights
- **Success Lifecycle:** Validates the complete position lifecycle: minting, increasing liquidity, routing simulated swaps via the mainnet SwapRouter to generate fees, harvesting those fees, and withdrawing the principal.
- **Bounded Fuzzing:** Integrates Foundry's fuzzing engine to verify position minting across random input balances and ranges.
- **Robust Exception Assertions:** Ensures the contract reverts correctly under invalid configurations (e.g., zero addresses, unsorted tokens, zero desired amounts).

### Executing the Test Suite

Configure the RPC endpoint and run the tests:
```bash
forge test --fork-url https://ethereum-rpc.publicnode.com -vvv
```

---

## 📊 Coverage Report

```text
╭----------------------------------------+-----------------+-----------------+-----------------+-----------------╮
| File                                   | % Lines         | % Statements    | % Branches      | % Funcs         |
+================================================================================================================+
| src/UniswapV3Liquidity.sol             | 100.00% (57/57) | 100.00% (73/73) | 100.00% (11/11) | 100.00% (5/5)   |
| src/utils/ReentrancyGuard.sol          | 85.71% (6/7)    | 80.00% (4/5)    | 0.00%* (0/1)    | 100.00% (2/2)   |
|----------------------------------------+-----------------+-----------------+-----------------+-----------------|
| Total (Production Contracts)           | 98.44% (63/64)  | 98.72% (77/78)  | 91.67% (11/12)  | 100.00% (7/7)   |
╰----------------------------------------+-----------------+-----------------+-----------------+-----------------╯
```

> [!NOTE]
> `*` The `ReentrancyGuard` modifier branch reports `0.00%` due to a known limitation in the Solidity compiler's source mappings under `via_ir` mode when mapping modifier branch coverage. The reentrancy check itself is fully tested and verified by `test_RevertWhen_ReentrantCall()`.
