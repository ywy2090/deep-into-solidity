# 以太坊 Gas Price 机制详解（Markdown 笔记）

> **当前时间**：2025年12月20日（星期六）  
> **适用网络**：以太坊主网（Post-Merge + EIP-1559）

---

## 一、Gas 基础概念

| 术语 | 说明 |
|------|------|
| **Gas** | 衡量以太坊上计算/存储操作所需工作量的单位 |
| **Gas Limit** | 用户愿意为一笔交易支付的最大 Gas 数量 |
| **Gas Used** | 交易实际消耗的 Gas 量 |
| **Gas Price** | 每单位 Gas 愿意支付的价格，单位通常为 **Gwei**（1 Gwei = 10⁻⁹ ETH） |
| **交易总费用** | `Gas Used × 实际支付的每单位 Gas 价格` |

---

## 二、Gas Price 演进：两个阶段

### 1. 旧机制（EIP-1559 之前）

- **Gas Price = 用户设定的单一价格**
- 矿工按 `Gas Price` 从高到低排序交易，优先打包高报价交易
- **总费用** = `Gas Used × Gas Price`
- **缺点**：
  - 费用波动剧烈
  - 用户常高估价格，造成 ETH 浪费
  - 无费用退还机制

---

### 2. 新机制（EIP-1559 之后，2021年8月起）

> EIP-1559 改革目标：**提高费用可预测性 + 引入通缩机制（Base Fee 销毁）**

#### 费用组成

| 成分 | 说明 |
|------|------|
| **Base Fee（基础费用）** | 协议自动计算，每区块动态调整；**必须支付，但会被销毁（burned）** |
| **Priority Fee（小费）** | 用户额外支付给验证者的激励；**归验证者所有**，可设为 0 |

#### 用户可设置参数

- `maxFeePerGas`：用户愿意为每单位 Gas 支付的**最高价格**
- `maxPriorityFeePerGas`：愿意支付给验证者的**小费上限**

#### 实际支付价格

实际 Gas Price = `min(maxFeePerGas, Base Fee + maxPriorityFeePerGas)`

> 若 `maxFeePerGas` < `Base Fee + maxPriorityFeePerGas`，交易**不会被打包**

#### 总费用计算

总费用 = `Gas Used × (Base Fee + Priority Fee)`

- **Base Fee 部分 → 销毁**
- **Priority Fee 部分 → 验证者（取代矿工）**

#### 多余费用退还 ✅

- 若 `maxFeePerGas` > 实际支付价格，差额**自动退还**给用户

---

## 三、Base Fee 动态调整机制

- **目标区块 Gas 使用量（Target）**：15,000,000（30M 为上限）
- **调整规则**：
  - 若上一区块 Gas > 15M → Base Fee **上涨**（最多 +12.5%）
  - 若 < 15M → Base Fee **下降**（最多 -12.5%）

#### 调整公式（简化）

```
new_base_fee = base_fee × [1 + (gas_used - target_gas) / (8 × target_gas)]
```

> 调整幅度平滑，避免剧烈波动

---

## 四、实际示例（EIP-1559）

**场景**：

- Base Fee = 50 Gwei  
- 用户设置：
  - `maxFeePerGas` = 100 Gwei  
  - `maxPriorityFeePerGas` = 2 Gwei  
- Gas Used = 21,000（普通 ETH 转账）

**计算**：

- 实际 Gas Price = `min(100, 50 + 2)` = **52 Gwei**
- 总费用 = 21,000 × 52 = **1,092,000 Gwei = 0.001092 ETH**
  - 销毁部分：50 × 21,000 = 1,050,000 Gwei
  - 验证者所得：2 × 21,000 = 42,000 Gwei
- 用户支付上限为 100 Gwei，但只用了 52 Gwei，**多余 48 Gwei/单位自动退还**

---

## 五、工具与最佳实践

### 推荐工具

- [Etherscan Gas Tracker](https://etherscan.io/gastracker)
- [GasNow](https://www.gasnow.org)
- [Ultrasound Money](https://ultrasound.money)（含 Base Fee 趋势与 ETH 销毁数据）

### 钱包行为

- MetaMask、Rainbow 等自动推荐 `maxFeePerGas` 和 `maxPriorityFeePerGas`
- 用户可手动调整以平衡**速度 vs 成本**

---

## 六、PoS 合并后的变化

- 2022 年“合并”（The Merge）后，以太坊从 PoW 转为 PoS
- **EIP-1559 机制保持不变**
- “矿工” → “验证者”，**Priority Fee 归验证者**

---

## 七、机制对比总结

| 特性 | 旧机制（Pre-EIP-1559） | 新机制（EIP-1559+） |
|------|------------------------|---------------------|
| **Gas Price 构成** | 单一用户设定价格 | `Base Fee + Priority Fee` |
| **费用去向** | 全部归矿工 | Base Fee 销毁，Priority Fee 归验证者 |
| **可预测性** | 低（市场竞价） | 高（Base Fee 平滑调整） |
| **用户控制** | 直接设 Gas Price | 设 `maxFeePerGas` 和 `maxPriorityFeePerGas` |
| **费用退还** | 无 | ✅ 多余部分自动退还 |
| **网络效应** | 无通缩 | ✅ Base Fee 销毁 → ETH 通缩 |

---

> 💡 **提示**：在 Layer 2（如 Arbitrum、Optimism、Base）上，Gas 费用显著降低，但底层仍依赖以太坊主网的 EIP-1559 机制进行最终结算。

---
