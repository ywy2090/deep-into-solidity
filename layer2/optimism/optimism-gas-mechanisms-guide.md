# OP Stack Gas 机制总览

> 适用范围：以 `packages/contracts-bedrock` 为主，补充说明与执行客户端相关的 `baseFee` 机制。  
> 相关文档：`docs/ai/optimism-gas-deposit-min-gas-limit.md`、`docs/ai/optimism-gas-l2-mechanisms.md`

## 概述

OP Stack 里的 gas 机制不是单一模型，而是几套机制叠加：

1. **L1 存款资源计量**  
   由 `OptimismPortal2` + `ResourceMetering` 负责，限制和定价 L1 向 L2 注入的 deposit 资源。
2. **L2 执行 gas**  
   由执行客户端按 EIP-1559 维护 `block.basefee`，对应普通 L2 交易的执行成本。
3. **L1 数据费（L1 Data Fee）**  
   由 L2 预部署 `GasPriceOracle` 按 Bedrock / Ecotone / Fjord 等分叉规则计算，反映“把交易数据发布到 L1”的成本。
4. **Operator Fee**  
   由 `GasPriceOracle` 在 Isthmus / Jovian 之后计算，作为额外的运营侧费用。
5. **费用归集与分配**  
   由 `BaseFeeVault`、`L1FeeVault`、`SequencerFeeVault`、`OperatorFeeVault` 归集，再由后续流程提取和分配。

可以把它理解成两条主线：

- **主线 A：L1 -> L2 存款消息**  
  关心 `_minGasLimit`、`baseGas()`、`minimumGasLimit()`、`ResourceMetering`。
- **主线 B：普通 L2 交易**  
  关心 `block.basefee`、`GasPriceOracle.getL1Fee()`、`getOperatorFee()`、各类 `FeeVault`。

## 总体结构

```mermaid
graph TD
    A[用户发起 L1->L2 存款] --> B[CrossDomainMessenger / StandardBridge]
    B --> C[baseGas(message, _minGasLimit)]
    C --> D[OptimismPortal2.depositTransaction]
    D --> E[ResourceMetering.metered(_gasLimit)]

    F[用户发起普通 L2 交易] --> G[执行客户端执行交易]
    G --> H[L2 Execution Fee<br/>block.basefee]
    G --> I[GasPriceOracle.getL1Fee]
    G --> J[GasPriceOracle.getOperatorFee]

    K[SystemConfig on L1] --> L[L1Block predeploy on L2]
    L --> I
    L --> J

    H --> M[BaseFeeVault]
    I --> N[L1FeeVault]
    J --> O[OperatorFeeVault]
    G --> P[SequencerFeeVault]
```

## 1. L1 存款路径里的 gas 机制

### 1.1 `_minGasLimit`：目标链执行承诺

`_minGasLimit` 出现在 `CrossDomainMessenger.sendMessage()`、桥合约的 `depositETH` / `bridgeETH` 一类接口里。

其核心语义是：目标链在执行这条消息时，给目标合约调用的 gas 不应低于这个值。

它本身不是最终传给 `OptimismPortal2.depositTransaction()` 的 `_gasLimit`，而是先进入 `CrossDomainMessenger.baseGas(_message, _minGasLimit)`，由协议把它扩展成真正的 deposit gas limit。

### 1.2 `baseGas()`：把 `_minGasLimit` 变成 deposit gas limit

`CrossDomainMessenger.baseGas()` 会把以下几部分加总：

- `relayMessage` 的固定开销
- `CALL` 的动态开销
- relay 收尾预留 gas
- `hasMinGas` 到实际 `CALL` 之间的缓冲
- `_minGasLimit * 64 / 63`  
  这里是为了补偿 EIP-150 的 `63/64` 子调用规则
- message 编码与 calldata floor 成本

因此，`_minGasLimit` 越大 -> `baseGas()` 结果越大 -> `depositTransaction` 的 `_gasLimit` 越大 -> L1 上被计量和收费的资源越多。

### 1.3 `minimumGasLimit(byteCount)`：Portal 的硬下限

`OptimismPortal2.minimumGasLimit(_byteCount)` 给单笔存款设置最低 gas limit：

```text
minimumGasLimit = 21000 + 40 * calldata字节数
```

它的作用不是“保证目标合约成功执行”，而是：

- 防止用户提交大 calldata 却只购买极小 gas
- 确保 deposit 交易至少覆盖基本 intrinsic cost 和 calldata 成本

在 `depositTransaction()` 里，如果传入的 `_gasLimit` 小于这个下限，会直接 `revert OptimismPortal_GasLimitTooLow()`。

### 1.4 `ResourceMetering`：L1 侧的 deposit 资源市场

`OptimismPortal2.depositTransaction()` 带有 `metered(_gasLimit)` 修饰符，因此每笔存款都会进入 `ResourceMetering`。

它做的事有三类：

1. **按块累计本块已购买的 deposit gas**  
   用 `prevBoughtGas` 记录。
2. **做单块上限检查**  
   若超过 `maxResourceLimit`，直接 `OutOfGas()`。
3. **按 EIP-1559 风格更新 deposit base fee**  
   用上一块需求与目标资源上限的偏差，调整 `prevBaseFee`。

其核心配置来自 `SystemConfig.resourceConfig()`：

- `maxResourceLimit`
- `elasticityMultiplier`
- `baseFeeMaxChangeDenominator`
- `minimumBaseFee`
- `systemTxMaxGas`
- `maximumBaseFee`

这里的 gas 不是“普通 L2 交易执行 gas 市场”的替代品，而是 L1 向 L2 注入资源时的入口保护层。

## 2. 普通 L2 交易的 gas 机制

### 2.1 L2 `baseFee`：仍然是 EIP-1559

普通 L2 交易的执行费用，核心仍是执行客户端维护的 `block.basefee`。

从 `contracts-bedrock` 角度看，`GasPriceOracle.gasPrice()` 和 `baseFee()` 都只是返回：

```solidity
return block.basefee;
```

这说明：

- **真正更新 `baseFee` 的地方在执行客户端**，不是 `contracts-bedrock`
- `contracts-bedrock` 主要负责暴露查询接口、同步参数、计算附加费用

因此，L2 执行费可以近似理解为：

```text
L2 Execution Fee = gasUsed * (baseFee + priorityFee)
```

其中：

- `baseFee` 进入 `BaseFeeVault`
- `priorityFee` / sequencer 收入进入 `SequencerFeeVault`

### 2.2 `SystemConfig.gasLimit`：L2 每块 gas 上限

`SystemConfig` 在 L1 上维护 L2 区块 gas 上限：

- `gasLimit`：当前 L2 区块 gas 上限
- `minimumGasLimit()`：安全运行所需的最小上限
- `maximumGasLimit()`：协议允许的最大上限

其中 `minimumGasLimit()` 的定义是：

```text
minimumGasLimit = maxResourceLimit + systemTxMaxGas
```

它体现了一个很重要的设计：L2 每块至少要留得下“最大存款资源 + 系统交易开销”。

## 3. L1 数据费（L1 Data Fee）

### 3.1 为什么普通 L2 交易还要付 L1 费用

OP Stack 最终需要把 L2 批次数据提交到 L1，所以普通 L2 交易除了支付 L2 执行费，还要分摊“数据发布到 L1”的成本。

这部分费用由 L2 预部署 `GasPriceOracle` 计算。

### 3.2 `GasPriceOracle` 依赖 `L1Block`

`GasPriceOracle` 本身不维护 L1 base fee 等状态，而是读取 `L1Block` 预部署中的字段，例如：

- `basefee`
- `blobBaseFee`
- `baseFeeScalar`
- `blobBaseFeeScalar`
- `l1FeeOverhead`
- `l1FeeScalar`
- `operatorFeeScalar`
- `operatorFeeConstant`

这些值由 L1 侧配置和协议生成的 depositor 交易周期性写入 L2。

所以数据流可以概括为：

```text
SystemConfig / 协议配置 on L1
    -> depositor transaction
    -> L2 L1Block predeploy
    -> GasPriceOracle
    -> L2 交易费计算
```

### 3.3 Bedrock：calldata gas + overhead/scalar

Bedrock 下，L1 数据费大致按如下思路计算：

```text
L1Fee = (calldataGas + l1FeeOverhead) * l1BaseFee * l1FeeScalar / 10^DECIMALS
```

其中 `calldataGas` 按交易数据逐字节计费：

- 零字节：4 gas
- 非零字节：16 gas
- 额外再加 `68 * 16` 补偿 unsigned tx 不含签名

### 3.4 Ecotone：引入 blob 价格与双标量

Ecotone 后，旧 `overhead/scalar` 逻辑被弱化，开始使用：

- `baseFeeScalar`
- `blobBaseFeeScalar`
- `l1BaseFee`
- `blobBaseFee`

`GasPriceOracle._getL1FeeEcotone()` 的核心是：

```text
scaledBaseFee     = baseFeeScalar * 16 * l1BaseFee
scaledBlobBaseFee = blobBaseFeeScalar * blobBaseFee
fee               = calldataGas * (scaledBaseFee + scaledBlobBaseFee)
```

本质上是把 calldata 成本和 blob 成本统一折到一套定价里。

### 3.5 Fjord：压缩感知计费

Fjord 后，不再简单按原始 calldata 大小收费，而是：

1. 先用 `fastlz` 压缩交易数据
2. 用线性回归估算 `brotli` 大小
3. 用估算后的压缩大小来计算 L1 成本

因此 Fjord 的关键变化是：计费对象从“原始字节数”更接近“真实可用性层压缩后体积”。

这也是为什么 Fjord 后更建议直接调用：

- `getL1Fee(bytes _data)`
- `getL1FeeUpperBound(uint256 _unsignedTxSize)`

而不是沿用 Bedrock 心智做手工估算。

## 4. Operator Fee（Isthmus / Jovian）

`GasPriceOracle.getOperatorFee(_gasUsed)` 在不同分叉阶段有不同语义：

- **Isthmus 前**：返回 `0`
- **Isthmus 到 Jovian 前**：

```text
operatorFee = gasUsed * operatorFeeScalar / 1e6 + operatorFeeConstant
```

- **Jovian 及之后**：

```text
operatorFee = gasUsed * operatorFeeScalar * 100 + operatorFeeConstant
```

这部分费用独立于：

- L2 执行费
- L1 数据费

并进入单独的 `OperatorFeeVault`。

## 5. 费用最终进入哪些 Vault

L2 上与 gas 相关的费用不会都进入同一个地址，而是分到不同预部署金库：

- `BaseFeeVault`  
  归集普通 L2 交易的 `baseFee`
- `SequencerFeeVault`  
  归集 sequencer 在交易处理和出块中的收入，一般对应 priority fee / 小费侧
- `L1FeeVault`  
  归集 L1 数据费
- `OperatorFeeVault`  
  归集 Isthmus+ 的 operator fee

这些 Vault 共享基础逻辑 `FeeVault`：

- 维护 `minWithdrawalAmount`
- 维护 `recipient`
- 指定 `withdrawalNetwork`（L1 或 L2）
- 提供统一的 `withdraw()` 提取机制

后续还可通过 `FeeSplitter` 做进一步分配。

## 6. 一笔费用如何拆开理解

如果你在分析一笔 **普通 L2 交易**，总费用更适合拆成：

```text
Total Fee
= L2 Execution Fee
+ L1 Data Fee
+ Operator Fee (Isthmus+)
```

如果你在分析一笔 **L1 -> L2 存款消息**，更适合拆成：

```text
用户指定 _minGasLimit
    -> baseGas(message, _minGasLimit)
    -> Portal deposit _gasLimit
    -> ResourceMetering 对 _gasLimit 计量和收费
```

两者最容易混淆的点是：

- **`_minGasLimit`**  
  是跨链消息在目标链执行时的最小 gas 承诺
- **Portal 的 `_gasLimit`**  
  是 deposit 交易真正购买的 gas 资源量
- **ResourceMetering**  
  看到的是后者，不直接看到前者

但前者通过 `baseGas()` 决定后者，所以两者是强关联的。

## 7. 具体交易示例：这些 gas 参数如何影响交易

下面用三类带数字的例子，把前面的参数放到真实交易里看。

### 7.1 示例一：L1 -> L2 存款消息

假设 Alice 在 L1 上通过 `L1StandardBridge` 向 L2 存入 1 ETH，目标是一个在 L2 上还要执行一些逻辑的合约。

参数假设：

- `_minGasLimit = 200,000`
- 消息体 `_message.length = 200 bytes`
- 当前 `ResourceMetering.prevBaseFee = 1 gwei`

第一步，`_minGasLimit` 不会直接作为 Portal 的 `_gasLimit`，而是先进入 `CrossDomainMessenger.baseGas()`：

```solidity
uint64 executionGas = uint64(
    RELAY_CONSTANT_OVERHEAD
    + RELAY_CALL_OVERHEAD
    + RELAY_RESERVED_GAS
    + RELAY_GAS_CHECK_BUFFER
    + ((_minGasLimit * MIN_GAS_DYNAMIC_OVERHEAD_NUMERATOR) / MIN_GAS_DYNAMIC_OVERHEAD_DENOMINATOR)
);
```

如果只做粗略估算：

- 固定开销约等于 `200k + 40k + 40k + 5k = 285k`
- `_minGasLimit * 64 / 63 ≈ 203,174`
- 再加消息编码和 calldata 开销

最终这笔消息在 Portal 侧购买的 `_gasLimit` 往往接近 **50 万 gas**，而不是用户看到的 20 万。

接着 Portal 会检查存款下限：

```text
minimumGasLimit(200 bytes) = 21000 + 200 * 40 = 29,000
```

因为 `baseGas()` 结果远大于 `29,000`，所以这笔存款不会因 Portal 下限而失败。

最后它进入 `ResourceMetering`：

- 如果当前 `prevBaseFee = 1 gwei`
- 且 deposit `_gasLimit ≈ 500,000`

那么资源成本可近似理解为：

```text
resourceCost ≈ 500,000 * 1 gwei = 0.0005 ETH
```

如果当前块里存款很多，`prevBaseFee` 已涨到 `5 gwei`，同样一笔交易会变成：

```text
resourceCost ≈ 500,000 * 5 gwei = 0.0025 ETH
```

这个例子里，各参数的影响分别是：

- `_minGasLimit`：决定目标调用至少需要多少 gas，并间接放大最终 deposit `_gasLimit`
- `baseGas()`：把执行承诺转换成真正要购买的 deposit 资源
- `minimumGasLimit(byteCount)`：给这笔存款设置最小合法 gas limit
- `ResourceMetering.prevBaseFee`：决定“同样的 gasLimit 要花多少钱”
- `maxResourceLimit`：决定当前块还能否继续接收这笔存款

如果 Alice 把 `_minGasLimit` 从 `200,000` 改成 `50,000`：

- L1 上 `baseGas()` 会明显下降，存款更便宜
- 但目标合约在 L2 上执行可能 gas 不够，更容易失败并需要后续重放

### 7.2 示例二：L2 -> L1 提款消息

假设 Bob 在 L2 发起提款，最终希望在 L1 上调用一个目标合约，而这个目标合约大约需要 `300,000` gas 才能顺利执行。

对 Bob 来说，有两个典型选择：

- 方案 A：`_minGasLimit = 80,000`
- 方案 B：`_minGasLimit = 300,000`

这时 `_minGasLimit` 的影响主要有两层。

第一层：**影响 Bob 在 L2 发起提款时的消息成本**

因为提款消息同样要经过 `sendMessage()` 和 `baseGas()`：

- `_minGasLimit = 80,000` 时，`baseGas()` 更小，L2 发起提款更便宜
- `_minGasLimit = 300,000` 时，`baseGas()` 更大，L2 发起提款更贵

第二层：**影响未来在 L1 上 relayMessage 时的成功率**

如果未来在 L1 relay 这条消息时，能够提供给目标调用的 gas 不足 `_minGasLimit`，那么目标调用更容易失败，需要重放。

因此：

- 方案 A
  - L2 发起时更便宜
  - 但未来在 L1 上执行目标合约时更容易 gas 不足
- 方案 B
  - L2 发起时更贵
  - 但更接近目标合约真实所需 gas，一次成功的概率更高

这个场景里要特别区分两类 gas 成本：

- **提款消息的 gas 预算**：由 `_minGasLimit` 和 `baseGas()` 影响
- **提款 proving / finalization 的 L1 执行成本**：本质上还是普通 Ethereum L1 gas，不走 `ResourceMetering`

也就是说，`ResourceMetering` 主要保护的是 **L1 -> L2 deposit 入口**，并不直接给 L2 -> L1 提款最终确认定价。

### 7.3 示例三：L2 原生交易

假设 Carol 在 L2 上发起一笔普通 ETH 转账，参数如下：

- `gasUsed = 21,000`
- `block.basefee = 0.02 gwei`
- `priorityFee = 0.005 gwei`

那么它的 **L2 执行费** 可以近似理解为：

```text
executionFee = 21,000 * (0.02 + 0.005) gwei = 525 gwei
```

但在 OP Stack 里，这还不是总费用。普通 L2 交易往往还会有 **L1 Data Fee**。

再看一个更复杂的例子：Dave 在 L2 上发起一笔 DEX swap：

- `gasUsed = 180,000`
- calldata 明显比 ETH 转账大很多
- 当前链已进入 `Ecotone` 或 `Fjord`

这时总费用大致拆成：

```text
Total Fee
= L2 Execution Fee
+ L1 Data Fee
+ Operator Fee（Isthmus+）
```

这些参数分别如何影响它：

1. `block.basefee` 上升  
   会直接抬高 `180,000` gas 对应的执行费。

2. `l1BaseFee` 上升  
   会抬高 `GasPriceOracle.getL1Fee()` 算出的 L1 数据费。

3. `baseFeeScalar` / `blobBaseFeeScalar` 上调  
   会进一步放大 L1 数据费，即使交易本身 `gasUsed` 没变，总费也会上涨。

4. 交易字节数或压缩后体积更大  
   在 Bedrock 下会让 calldata gas 更大，在 Fjord 下会让压缩感知的体积估算更大，因此 L1 数据费也更高。

5. `operatorFeeScalar` / `operatorFeeConstant` 非零  
   在 Isthmus / Jovian 之后，还会额外产生 operator fee。

因此，两笔 L2 原生交易即使 `gasUsed` 接近，总费也可能差很多：

- 一笔是简单 ETH 转账，calldata 很短，`L1 Data Fee` 很小
- 一笔是复杂 swap，calldata 很长，`L1 Data Fee` 和 `Operator Fee` 都可能显著更高

可以把它总结为：

- **简单交易** 更容易主要受 `block.basefee` 影响
- **复杂交易** 往往同时受 `block.basefee`、`l1BaseFee`、`baseFeeScalar/blobBaseFeeScalar`、operator 参数共同影响

## 8. 对照表：交易类型 -> 关键 gas 参数 -> 主要成本来源 -> 常见误解

| 交易类型 | 关键 gas 参数 | 主要成本来源 | 常见误解 |
| --- | --- | --- | --- |
| `L1 -> L2` 普通存款 / 跨链消息 | `_minGasLimit`、`baseGas()`、`OptimismPortal2.minimumGasLimit(byteCount)`、`ResourceMetering.prevBaseFee`、`maxResourceLimit` | L1 侧购买 deposit 资源的成本；本质上是 `baseGas()` 推导出的 Portal `_gasLimit` 再进入 `ResourceMetering` 定价 | 误以为用户填写的 `_minGasLimit` 就是 Portal 实际购买的 gas；误以为这和普通 L2 `block.basefee` 是同一市场 |
| `L2 -> L1` 提款消息 | `_minGasLimit`、`baseGas()`、L1 relay 时可用 gas | 发起提款时的 L2 消息成本，加上未来在 L1 prove / finalize / relay 的普通 L1 执行成本 | 误以为提款最终确认也走 `ResourceMetering`；误以为 `_minGasLimit` 只影响 L2 发起阶段，不影响后续 L1 relay 成功率 |
| L2 简单原生交易（如 ETH 转账） | `block.basefee`、priority fee、`l1BaseFee` | 以 L2 执行费为主，外加较小的 L1 数据费 | 误以为 `GasPriceOracle.gasPrice()` 就是总费用；忽略了 L1 数据费 |
| L2 复杂原生交易（如 DEX swap） | `block.basefee`、`l1BaseFee`、`baseFeeScalar`、`blobBaseFeeScalar`、`operatorFeeScalar`、`operatorFeeConstant`、交易字节数 / 压缩后体积 | `L2 Execution Fee + L1 Data Fee + Operator Fee（Isthmus+）` | 误以为 `gasUsed` 接近则总费也接近；实际上 calldata 大小、压缩效果和 operator 参数都可能显著改变总费 |
| 单笔 deposit 合法性检查 | `minimumGasLimit(byteCount)` | 不是独立收费项，而是 Portal 对单笔 deposit 设置的最低 gas 门槛 | 误以为它决定整条链每块 gas 上限；实际上它只约束单笔 deposit |
| L2 区块级容量约束 | `SystemConfig.gasLimit`、`SystemConfig.minimumGasLimit()`、`maxResourceLimit` | 不是用户直接支付的单笔费用，而是决定每块最多能容纳多少执行 gas 与 deposit 资源 | 误以为 `SystemConfig.minimumGasLimit()` 和 `OptimismPortal2.minimumGasLimit()` 是同一个概念 |

读这张表时，可以抓一个最实用的判断方法：

- 只要是 **L1 -> L2 入口消息**，先看 `_minGasLimit -> baseGas() -> Portal _gasLimit -> ResourceMetering`
- 只要是 **普通 L2 交易**，先看 `block.basefee + L1 Data Fee + Operator Fee`
- 只要看到两个 `minimumGasLimit`，先分清是在讲 **单笔 deposit** 还是 **整条链的区块 gas 下限**

## 9. 源码索引表：参数 -> 在哪定义 -> 在哪生效 -> 影响哪类交易

这张表更偏“顺着代码读”的视角。一个参数经常会出现两处：

- **定义 / 存储处**：这个值最初放在哪里，谁负责更新
- **生效处**：真正在哪个函数里被读取并影响交易成本或执行结果

| 参数 | 在哪定义 / 存储 | 在哪生效 | 影响哪类交易 |
| --- | --- | --- | --- |
| `_minGasLimit` | 用户调用 `CrossDomainMessenger.sendMessage()` 时传入 | `CrossDomainMessenger.baseGas()` 用它推导消息总 gas；目标链 `relayMessage` 也会据此保证最小执行 gas | `L1 -> L2` 存款消息、`L2 -> L1` 提款消息 |
| `baseGas(message, _minGasLimit)` | 定义在 `CrossDomainMessenger` | 被 `L1CrossDomainMessenger` / `L2CrossDomainMessenger` 发送跨链消息时调用，用来推导最终提交给对端的 gas 预算 | 所有跨域消息 |
| `minimumGasLimit(byteCount)` | 定义在 `OptimismPortal2` | `OptimismPortal2.depositTransaction()` 检查单笔 deposit 的 `_gasLimit` 是否过低 | `L1 -> L2` deposit / 跨链消息 |
| `maxResourceLimit` | `SystemConfig._resourceConfig.maxResourceLimit` | `ResourceMetering._metered()` 检查本块累计 deposit gas 是否超上限；`SystemConfig.minimumGasLimit()` 也会引用它 | `L1 -> L2` deposit；同时影响整条链的最小区块 gas 下限 |
| `elasticityMultiplier` | `SystemConfig._resourceConfig.elasticityMultiplier` | `ResourceMetering._metered()` 用它把 `maxResourceLimit` 转成 target resource limit，决定 EIP-1559 调价灵敏度 | `L1 -> L2` deposit |
| `prevBaseFee` | `ResourceMetering.params.prevBaseFee` | `ResourceMetering._metered()` 按 `resourceCost = amount * prevBaseFee` 定价，并在新块开始时更新 | `L1 -> L2` deposit |
| `minimumBaseFee` / `maximumBaseFee` | `SystemConfig._resourceConfig` | `ResourceMetering._metered()` 在更新 deposit base fee 时对结果做上下界钳制 | `L1 -> L2` deposit |
| `systemTxMaxGas` | `SystemConfig._resourceConfig.systemTxMaxGas` | `SystemConfig.minimumGasLimit()` 把它与 `maxResourceLimit` 相加，约束整条链的最小 `gasLimit` | L2 区块级容量约束，间接影响所有交易 |
| `gasLimit` | `SystemConfig.gasLimit`，通过 `setGasLimit()` 更新并发 `ConfigUpdate` | 被 op-node / 执行层应用为 L2 区块 gas 上限；`_setGasLimit()` 还会校验不得低于 `minimumGasLimit()` | 所有 L2 交易、deposit、系统交易 |
| `eip1559Denominator` / `eip1559Elasticity` | `SystemConfig`，通过 `setEIP1559Params()` 更新 | 被 L2 执行层的 EIP-1559 逻辑使用，决定 `block.basefee` 如何随区块拥堵变化 | 所有普通 L2 交易 |
| `block.basefee` | 由 L2 执行客户端维护在区块头里，不是 `contracts-bedrock` 里的状态变量 | 普通 L2 交易执行费直接按它计价；`GasPriceOracle.gasPrice()` / `baseFee()` 只是返回它 | 所有普通 L2 交易 |
| `basefeeScalar` / `blobbasefeeScalar` | `SystemConfig` 存储，随后由协议写入 `L1Block.baseFeeScalar` / `blobBaseFeeScalar` | `GasPriceOracle._getL1FeeEcotone()` / `_getL1FeeFjord()` 读取后计算 L1 Data Fee | `Ecotone+`、`Fjord+` 的普通 L2 交易 |
| `l1FeeOverhead` / `l1FeeScalar` | 由协议写入 `L1Block`（Bedrock 时代的 L1 数据费参数） | `GasPriceOracle._getL1FeeBedrock()` 使用 | Bedrock 时代普通 L2 交易 |
| `l1BaseFee` / `blobBaseFee` | 存在 `L1Block.basefee` / `blobBaseFee`，由 depositor 账户每个 epoch 更新 | `GasPriceOracle` 的 Bedrock / Ecotone / Fjord 公式都会读取它们 | 普通 L2 交易的 L1 Data Fee |
| `operatorFeeScalar` / `operatorFeeConstant` | `SystemConfig` 存储，随后由协议写入 `L1Block` | `GasPriceOracle.getOperatorFee()` 在 `Isthmus` / `Jovian` 后读取并计费 | `Isthmus+` 的普通 L2 交易 |
| `daFootprintGasScalar` | `SystemConfig` 存储，`Jovian` 后写入 `L1Block` | 主要作为 Jovian 时代的数据可用性成本参数保存在 L2 系统状态中，供协议后续 DA 成本模型使用 | `Jovian+` 的 DA 成本相关路径 |

如果你是按源码追踪，一般可以这样走：

- 想看 **跨链 gas 从用户参数一路变成费用**：
  `_minGasLimit -> CrossDomainMessenger.baseGas() -> OptimismPortal2.depositTransaction() -> ResourceMetering._metered()`
- 想看 **L1 配置如何变成 L2 上可读参数**：
  `SystemConfig -> ConfigUpdate / depositor transaction -> L1Block -> GasPriceOracle`
- 想看 **普通 L2 交易总费用怎么拆**：
  `block.basefee + GasPriceOracle.getL1Fee() + GasPriceOracle.getOperatorFee()`

## 10. 常见易混点

### 10.1 `ResourceMetering` 不是普通 L2 gas 市场

`ResourceMetering` 只作用于 L1 入口侧的 deposit 资源，不负责普通 L2 交易的 `baseFee`。

### 10.2 `GasPriceOracle.gasPrice()` 不是完整总费用

它只是返回 `block.basefee`，不能代表：

- L1 数据费
- Operator Fee
- priority fee

### 10.3 `minimumGasLimit()` 有两种语义

- `OptimismPortal2.minimumGasLimit(byteCount)`  
  是 **单笔 deposit 的最低 gas limit**
- `SystemConfig.minimumGasLimit()`  
  是 **整条链的最小 L2 区块 gas 上限**

两者名字相近，但层级完全不同。

### 10.4 `_minGasLimit` 不等于最终转发 gas

`relayMessage` 最终转发的是 `gasleft() - RELAY_RESERVED_GAS` 一类的剩余 gas；`_minGasLimit` 的作用是保证“至少不低于这个值”，而不是精确等于这个值。

## 11. 关键文件索引

如果你要继续顺着代码读，建议按下面顺序：

### 存款与跨链 gas

- `packages/contracts-bedrock/src/universal/CrossDomainMessenger.sol`
- `packages/contracts-bedrock/src/L1/OptimismPortal2.sol`
- `packages/contracts-bedrock/src/L1/ResourceMetering.sol`
- `packages/contracts-bedrock/src/libraries/SafeCall.sol`

### L2 费用计算

- `packages/contracts-bedrock/src/L2/GasPriceOracle.sol`
- `packages/contracts-bedrock/src/L2/L1Block.sol`
- `packages/contracts-bedrock/src/L1/SystemConfig.sol`

### 费用归集

- `packages/contracts-bedrock/src/L2/FeeVault.sol`
- `packages/contracts-bedrock/src/L2/BaseFeeVault.sol`
- `packages/contracts-bedrock/src/L2/L1FeeVault.sol`
- `packages/contracts-bedrock/src/L2/SequencerFeeVault.sol`
- `packages/contracts-bedrock/src/L2/OperatorFeeVault.sol`
- `packages/contracts-bedrock/src/L2/FeeSplitter.sol`

## 12. 总结

OP Stack 的 gas 机制可以浓缩成一句话：

**普通 L2 交易遵循“EIP-1559 执行费 + L1 数据费 + 可选 Operator Fee”，而 L1 -> L2 存款则额外经过 `baseGas + minimumGasLimit + ResourceMetering` 这一套入口资源市场。**

如果继续往下拆：

- 想看 **跨链 gas 为什么这么算**：读 `CrossDomainMessenger`、`OptimismPortal2`、`ResourceMetering`
- 想看 **L2 为什么除了 execution fee 还这么贵**：读 `GasPriceOracle`、`L1Block`
- 想看 **钱最后去了哪**：读各类 `FeeVault` 和 `FeeSplitter`
