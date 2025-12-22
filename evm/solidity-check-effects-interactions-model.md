# 检查-效果-交互（Check-Effects-Interactions）模式

检查-效果-交互（Check-Effects-Interactions）是一种常见的智能合约安全设计模式，旨在通过**调整操作顺序**来**降低重入攻击（Reentrancy Attack）的风险**。

---

## 原理解释

该模式要求函数逻辑按照以下三个阶段顺序执行：

1. **检查（Check）**  
   - 验证所有前置条件（如权限、余额、状态等）是否满足。
   - 通常使用 `require()`、`assert()` 等语句。

2. **效果（Effects）**  
   - **立即更新合约内部状态变量**（如余额、标志位等）。
   - 这是关键步骤：确保状态在与外部交互前已更改。

3. **交互（Interactions）**  
   - 最后才与外部地址或合约进行交互（如调用 `call`、`send`、`transfer` 等）。
   - 此时即使发生重入，攻击者也无法利用旧状态获利。

> ✅ **核心思想**：**先改状态，再对外调用**，防止重入时利用未更新的状态重复执行逻辑。

---

## 安全示例：采用 CEI 模式的提款合约

```solidity
pragma solidity ^0.8.0;

contract SimpleWithdrawal {
    mapping(address => uint256) public balances;

    // 存款函数
    function deposit() public payable {
        balances[msg.sender] += msg.value;
    }

    // 提款函数（安全）
    function withdraw(uint256 amount) public {
        // 1. 检查
        require(balances[msg.sender] >= amount, "Insufficient balance");

        // 2. 效果：先更新状态
        balances[msg.sender] -= amount;

        // 3. 交互：最后发送资金
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "Transfer failed");
    }
}
```

### 分析

- **检查**：确保用户有足够余额。
- **效果**：**在发送 ETH 前**就减少用户余额，使状态立即生效。
- **交互**：调用 `call` 发送 ETH，此时即使恶意合约重入 `withdraw`，也会因余额不足而失败。

---

## 不安全示例：违反 CEI 模式

```solidity
function withdrawUnsafe(uint256 amount) public {
    require(balances[msg.sender] >= amount, "Insufficient balance");

    // ❌ 先交互：发送资金（危险！）
    (bool success, ) = msg.sender.call{value: amount}("");
    require(success, "Transfer failed");

    // ❌ 后效果：才更新余额
    balances[msg.sender] -= amount;
}
```

### 风险说明

- 恶意合约在 `call` 被触发时，可在其 `fallback` 函数中**再次调用 `withdrawUnsafe`**。
- 由于此时 `balances[msg.sender]` 尚未减少，攻击者可**多次成功提取资金**，直到耗尽合约余额。
- 这正是 **The DAO 攻击** 所利用的经典重入漏洞。

---

## 总结

| 步骤 | 安全做法 | 不安全做法 |
|------|--------|----------|
| 顺序 | 检查 → 效果 → 交互 | 检查 → 交互 → 效果 |
| 状态更新时机 | **在外部调用前** | 在外部调用后 |
| 抗重入能力 | ✅ 强 | ❌ 弱 |

> 💡 **最佳实践**：**始终遵循 CEI 模式**，尤其是在涉及状态修改和外部调用的函数中。  
> 🔒 对于高风险场景，可进一步结合 **ReentrancyGuard**（如 OpenZeppelin 提供）进行双重防护。
