# 以太坊 Base Fee（基础费用）机制详解

> **整理时间**：2025年12月20日  
> **适用网络**：以太坊主网（EIP-1559 及以后，含 PoS 时代）  
> **核心目的**：实现交易费用的可预测性 + 引入通缩经济模型

---

## 一、什么是 Base Fee？

- **Base Fee（基础费用）** 是自 **EIP-1559（2021年8月伦敦升级）** 引入的核心机制。
- 它是**每个区块中所有交易必须支付的最低 Gas 价格**（单位：Gwei）。
- **不由用户设定**，而是由协议根据网络拥堵情况**自动计算**。
- **关键特性**：
  - 每个区块更新一次；
  - 所有兼容 EIP-1559 的交易**必须支付当前 Base Fee**；
  - **支付后会被永久销毁（burned）**，不归验证者所有。

> 💡 Base Fee 旨在替代旧式“Gas 拍卖”，使费用更平滑、可预测。

---

## 二、Base Fee 的设计目标

| 目标 | 实现方式 |
|------|--------|
| **费用可预测** | 算法自动调整，避免市场竞价波动 |
| **防止验证者操纵** | Base Fee 被销毁，验证者无法从中获利 |
| **稳定区块利用率** | 以 50% 区块容量为目标，保留弹性空间 |
| **引入通缩机制** | 持续销毁 ETH，可能使总供应量下降 |

---

## 三、关键参数

| 参数 | 数值 | 说明 |
|------|------|------|
| **区块 Gas 上限（Block Gas Limit）** | 30,000,000 | 单个区块最多可消耗的 Gas |
| **目标 Gas 使用量（Target Gas）** | 15,000,000 | = 30M ÷ 2，协议期望的平均使用量 |
| **最大调整比例** | ±12.5% / 区块 | 通过分母 `8` 控制变化幅度 |
| **弹性乘数（Elasticity Multiplier）** | 2 | 决定目标 Gas = 上限 / 2 |

---

## 四、Base Fee 计算公式

设：

- `parent_base_fee`：父区块（上一区块）的 Base Fee
- `parent_gas_used`：父区块实际使用的 Gas
- `target_gas = 15,000,000`

则当前区块的 Base Fee 为：
`
base_fee = parent_base_fee +
parent_base_fee * (parent_gas_used - target_gas) /
(8 * target_gas)
`

> ✅ 所有运算在整数域进行（向下取整），避免浮点误差。

### 简化理解

- 每偏离目标 Gas **1%**，Base Fee 调整约 **0.125%**
- 最大单区块变化：**±12.5%**

---

## 五、调整逻辑示例

| 上一区块 Gas 使用量 | 相对于目标 | Base Fee 变化 |
|---------------------|------------|----------------|
| 15,000,000          | = 目标     | 不变           |
| 30,000,000          | +100%      | **+12.5%**     |
| 0                   | -100%      | **-12.5%**     |
| 22,500,000          | +50%       | +6.25%         |

> 即使网络突然空闲或拥堵，Base Fee 也会**逐步调整**，避免剧烈跳变。

---

## 六、Base Fee 与交易类型

| 交易类型 | 是否受 Base Fee 约束 | 说明 |
|--------|----------------------|------|
| **EIP-1559 交易** | ✅ 是 | 必须满足 `maxFeePerGas ≥ Base Fee + maxPriorityFeePerGas` |
| **Legacy 交易**（旧式） | ⚠️ 间接是 | 其 `gasPrice` 必须 ≥ 当前 Base Fee，否则不会被打包 |

> 📌 验证者不会包含 `gasPrice < Base Fee` 的旧式交易。

---

## 七、Base Fee 去向：销毁（Burn）

- Base Fee **不支付给验证者**，而是**从流通中永久移除**。
- 销毁机制使以太坊具备**通缩潜力**：
  - 当网络活跃 → 销毁量 > 新增区块奖励 → ETH 总量减少
  - 数据可查：[ultrasound.money](https://ultrasound.money)

---

## 八、如何查看当前 Base Fee？

### 1. 浏览器工具

- [Etherscan Gas Tracker](https://etherscan.io/gastracker)
- [Ultrasound Money](https://ultrasound.money)

### 2. JSON-RPC（命令行）

```bash
# 示例（需替换 YOUR_API_KEY）
curl -s -H "Content-Type: application/json" \
  -d '{"id":1,"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest", false]}' \
  https://mainnet.infura.io/v3/YOUR_API_KEY | jq -r '.result.baseFeePerGas'
```

> 返回值为十六进制（如 "0x3b9aca00" = 1 Gwei），可用 printf "%d\n" 0x... 转十进制。

## 九、常见误区澄清

误区  正确理解
“Base Fee 是矿工收入” ❌  它被销毁，验证者只拿 Priority Fee
“用户可以设置 Base Fee” ❌  完全由协议决定
“Base Fee 会立刻跳变” ❌  最大 ±12.5%/区块，调整平滑
“Layer 2 也用 Base Fee” ❌  L2（如 Arbitrum）有独立费用模型

## 十、总结

Base Fee 是以太坊经济模型的一次重大升级：
它将以太坊的交易定价从“混乱拍卖”转变为“算法调控”，
同时通过销毁机制赋予 ETH 通缩属性，
极大提升了用户体验与长期经济可持续性。
