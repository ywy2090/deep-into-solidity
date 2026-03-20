# DepositTx 完整生命周期

> **Optimism / Deposit Lifecycle / L1 → L2**  
> 这张图把一笔 L1 存款从 `OptimismPortal2.emit(TransactionDeposited)` 开始，一直到 `op-node` 派生、Engine API 构建、执行引擎落地为 `ExecutionPayload`，以及 L2 合约链路执行的关键节点串成一条完整路径。

---

## 核心对象

| 类型 | 名称 |
|------|------|
| 事件 | `TransactionDeposited` |
| 交易类型 | `DepositTx` (type 0x7E) |
| 构建输入 | `PayloadAttributes` |
| 执行输出 | `ExecutionPayload` |
| 系统交易 | `L1InfoDepositTx` |
| 安全调用 | `SafeCall.call` |

## 一句话摘要

| 维度 | 说明 |
|------|------|
| **保证来源** | 存款不是 sequencer 自由选择上链，而是由 L1 日志和固定规则确定性派生。 |
| **执行顺序** | 每个 L2 块先执行 `L1InfoDepositTx`，然后再执行用户存款 DepositTx。 |
| **L2 语义** | DepositTx 不验签、不走普通 nonce 路径，并支持 `mint` 语义。 |

---

## 四阶段流水线

```
┌─────────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌─────────────┐
│ 01 L1 事件  │ ──> │ 02 派生 DepositTx│ ──> │ 03 构建属性     │ ──> │ 04 L2 执行  │
└─────────────┘     └─────────────────┘     └─────────────────┘     └─────────────┘
```

1. **L1 事件** — Portal 在 L1 上发出 `TransactionDeposited`，把跨链执行所需字段编码进 log。
2. **派生 DepositTx** — `op-node` 在新 epoch 首块扫描 receipts，解析事件并构造用户 DepositTx。
3. **构建属性** — 把 `L1InfoDepositTx`、用户 DepositTx 和升级交易装入 `PayloadAttributes`。
4. **L2 执行** — 执行引擎按顺序执行交易，最终产出 `ExecutionPayload` 并完成合约调用链。

---

## 阶段一：L1 事件编码

**入口**：`OptimismPortal2.depositTransaction()`

| 字段 | 说明 |
|------|------|
| `topics[0]` | `keccak256("TransactionDeposited(address,address,uint256,bytes)")` |
| `topics[1]` | `from`。若调用方是 L1 合约，会先做地址别名，避免 L1 合约伪装成同地址 L2 账户。 |
| `topics[2]` | `to`。目标 L2 合约或 EOA 地址。 |
| `topics[3]` | `version`。当前为 `0`，供未来事件格式升级保留版本位。 |
| `data` | `abi.encodePacked(mint, value, gasLimit, isCreation, data)`，保存 mint/value/gas 和 calldata。 |

---

## 阶段二：新 epoch / 同 epoch 分支

**入口**：`PreparePayloadAttributes()`

### 新 epoch 首块（扫描 receipts）

1. 读取目标 L1 origin 区块的 receipts。
2. 筛出 `TransactionDeposited` 事件。
3. 调用 `UnmarshalDepositLogEvent` 解码出 `from/to/mint/value/gas/data`。
4. 按 `l1BlockHash + logIndex` 生成确定性 `sourceHash`。

### 同 epoch 后续块（通常无用户 deposit）

1. 不再重复扫描 receipts。
2. 只继续生成新的 `L1InfoDepositTx`。
3. sequencer 块是否有普通交易，取决于本地 tx pool 和模式配置。

---

## 阶段三：从日志到 PayloadAttributes

**相关代码**：`derive/deposits.go` + `derive/attributes.go` + `derive/l1_block_info.go`

| 步骤 | 组件 | 说明 |
|------|------|------|
| 1 | **L1 Log / Receipt** | `UserDeposits()` 逐个 receipt 检查执行成功状态、log 地址以及 event topic，只提取来自 Portal 的有效 deposit 事件。 |
| 2 | **Deposit Decoder** | `UnmarshalDepositLogEvent`：从 topics 解析 `from / to / version`，从 opaque data 解析 `mint / value / gas / isCreation / data`，得到 `types.DepositTx` 的核心字段。 |
| 3 | **sourceHash** | 用户 deposit 走 domain=0 规则，使用 `keccak256(domain \|\| keccak256(l1BlockHash \|\| logIndex))` 作为唯一来源标识。 |
| 4 | **L1Info Builder** | `L1InfoDeposit()` 构造一笔系统 deposit tx，把 L1 block number、timestamp、basefee、batcherHash、fee scalar 等写入 L2 的 `L1Block` 预部署合约；**L1InfoDepositTx 永远在最前**。 |
| 5 | **PayloadAttributes** | 交易顺序固定为：`txs = [L1InfoDepositTx] + [UserDepositTx...] + [UpgradeTx...]`（+ 普通交易，sequencer 模式下）。验证者模式通常开启 `NoTxPool=true`，只允许确定性派生交易进入区块。 |

---

## 阶段四：Engine API 与区块产出

**入口**：`engine_forkchoiceUpdatedV3` / `engine_getPayloadV3`

1. `BuildStartEvent` 驱动 `engine_forkchoiceUpdatedV3`，EL 返回 `PayloadID`。
2. EL 内部依据 `PayloadAttributes.Transactions` 按序执行交易。
3. `engine_getPayloadV3` 取回 `ExecutionPayload`。
4. `sanityCheckPayload()` 校验 deposit 必须连续排在最前，避免引擎返回非规范顺序区块。

### DepositTx vs 普通交易

| 维度 | 普通 L2 交易 | DepositTx |
|------|--------------|-----------|
| 签名 | 必须验签 | 不验签，`from` 由 L1 日志直接给出 |
| Nonce | 走普通 nonce 规则 | 跳过普通 nonce 递增约束 |
| Gas 费用 | 从 L2 余额扣 gas | 不走普通 L2 gas 扣款路径，L1 入口已做 metering |
| Mint | 无 | `mint > 0` 时可先为发送方增加余额 |
| 失败语义 | 状态随交易回滚 | 调用失败时，已发生的 mint 不会因为子调用失败而撤销 |

---

## 阶段五：L2 合约调用链

**相关合约**：CrossDomainMessenger / StandardBridge / SafeCall

### ETH 存款路径

- DepositTx 的 `to` 一般是 L2 上的 `L2CrossDomainMessenger`。
- 先执行 `relayMessage()`，验证 `msg.sender` 逆别名后确实来自 L1 messenger。
- 随后通过 `SafeCall.call()` 调到 `L2StandardBridge.finalizeBridgeETH()`。
- 最终再由 bridge 通过 `SafeCall.call(to, value, "")` 把 ETH 转给接收者。

### ERC20 存款路径

- DepositTx 本身通常 `value=0`、`mint=0`，只负责把跨域消息带到 L2。
- `L2StandardBridge.finalizeBridgeERC20()` 检查本地 token 是否为 `OptimismMintableERC20`。
- 通过本地 token 的 `mint(to, amount)` 在 L2 铸造对应份额。
- 因此 ERC20 的“资产落地”发生在 token 合约 mint，而不是 DepositTx 自身的 ETH mint 语义。

### 为什么 SafeCall 关键

`SafeCall.call()` 在底层使用 EVM `CALL`，但默认不复制返回数据，可以避免 returndata bomb，并通过 `hasMinGas` 检查 EIP-150 下子调用是否还能拿到足够 gas。

---

## 嵌入说明

本文件为纯 Markdown，可直接在其他文档中通过相对路径引用或复制章节内容，例如：

```markdown
详见 [DepositTx 完整生命周期](./optimism-bridge-deposit-tx-lifecycle.md)。
```

或引用某一节：

```markdown
Deposit 在 L2 的执行顺序见 [阶段三：从日志到 PayloadAttributes](./optimism-bridge-deposit-tx-lifecycle.md#阶段三从日志到-payloadattributes)。
```
