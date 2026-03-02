# 用户交易从提交到被打包成区块的完整流程

本文解析 Optimism L2 中一笔用户交易从提交到最终被包含在区块中的完整生命周期。涵盖两条路径：**L2 直接交易**和 **L1→L2 存款交易（Deposit）**，并给出核心数据结构、模块间数据传输路径、时序图和源码解析。

> 本文所有代码引用均基于当前代码库源码验证。

## 目录

1. [交易入口的两条路径](#交易入口的两条路径)
2. [核心数据结构](#核心数据结构)
3. [路径一：L2 用户交易](#路径一l2-用户交易)
4. [路径二：L1→L2 存款交易](#路径二l1l2-存款交易)
5. [区块构建：交易如何被组装到区块中](#区块构建交易如何被组装到区块中)
6. [完整时序图](#完整时序图)
7. [区块中的交易排序规则](#区块中的交易排序规则)
8. [关键源码解析](#关键源码解析)
9. [模块间数据传输路径总览](#模块间数据传输路径总览)

---

## 交易入口的两条路径

用户交易进入 Optimism L2 有两条路径：

```
路径一：L2 直接交易（快速路径）
用户钱包 ──RPC──> op-geth 交易池 ──Engine API──> 区块

路径二：L1→L2 存款交易（安全路径）
用户钱包 ──L1 TX──> OptimismPortal2 ──L1 Event──> op-node 派生 ──Engine API──> 区块
```

| 维度 | L2 直接交易 | L1→L2 存款交易 |
|------|-----------|---------------|
| 入口 | op-geth JSON-RPC (`eth_sendRawTransaction`) | L1 上 `OptimismPortal2.depositTransaction()` |
| 交易类型 | 标准 EIP-2718 交易（Type 0/1/2） | Deposit 交易（Type 0x7E） |
| 存放位置 | op-geth 交易池（mempool） | `PayloadAttributes.Transactions` 强制交易列表 |
| 包含方式 | 执行引擎从交易池中选取（`NoTxPool=false` 时） | 排序器通过 Engine API 强制包含 |
| Gas 来源 | 用户在 L2 上的 ETH 余额 | L1 上燃烧的 Gas（不消耗 L2 Gas） |
| 审查抗性 | 依赖排序器选择 | 由 L1 合约保证，排序器必须包含 |

---

## 核心数据结构

### PayloadAttributes — 排序器给执行引擎的"出块指令"

> **Source Code**: [op-service/eth/types.go#L500-L524](https://github.com/ethereum-optimism/optimism/blob/develop/op-service/eth/types.go#L500)

```go
type PayloadAttributes struct {
    Timestamp             Uint64Quantity      `json:"timestamp"`              // 区块时间戳
    PrevRandao            Bytes32             `json:"prevRandao"`             // 随机数（来自 L1）
    SuggestedFeeRecipient common.Address      `json:"suggestedFeeRecipient"` // 手续费接收地址
    Withdrawals           *types.Withdrawals  `json:"withdrawals,omitempty"` // Canyon 后为空列表
    ParentBeaconBlockRoot *common.Hash        `json:"parentBeaconBlockRoot,omitempty"` // Ecotone 后

    // ===== Optimism 扩展字段 =====
    Transactions  []Data          `json:"transactions,omitempty"`  // 强制包含的交易列表
    NoTxPool      bool            `json:"noTxPool,omitempty"`      // true=不从交易池取交易
    GasLimit      *Uint64Quantity `json:"gasLimit,omitempty"`      // Gas 限制
    EIP1559Params *Bytes8         `json:"eip1559Params,omitempty"` // Holocene 后
    MinBaseFee    *uint64         `json:"minBaseFee,omitempty"`    // Jovian 后
}
```

**`Transactions` 字段**是理解交易打包的关键：排序器将系统交易（L1 Info Deposit）和用户存款交易预先放入这个列表，执行引擎在构建区块时会将这些交易强制放在区块最前面，然后根据 `NoTxPool` 决定是否从交易池中追加用户交易。

### ExecutionPayload — 执行引擎返回的"完成的区块"

> **Source Code**: [op-service/eth/types.go#L246-L271](https://github.com/ethereum-optimism/optimism/blob/develop/op-service/eth/types.go#L246)

```go
type ExecutionPayload struct {
    ParentHash    common.Hash     `json:"parentHash"`
    FeeRecipient  common.Address  `json:"feeRecipient"`
    StateRoot     Bytes32         `json:"stateRoot"`
    ReceiptsRoot  Bytes32         `json:"receiptsRoot"`
    LogsBloom     Bytes256        `json:"logsBloom"`
    PrevRandao    Bytes32         `json:"prevRandao"`
    BlockNumber   Uint64Quantity  `json:"blockNumber"`
    GasLimit      Uint64Quantity  `json:"gasLimit"`
    GasUsed       Uint64Quantity  `json:"gasUsed"`
    Timestamp     Uint64Quantity  `json:"timestamp"`
    ExtraData     BytesMax32      `json:"extraData"`
    BaseFeePerGas Uint256Quantity `json:"baseFeePerGas"`
    BlockHash     common.Hash     `json:"blockHash"`
    Transactions  []Data          `json:"transactions"`            // 最终的交易列表
    Withdrawals   *types.Withdrawals `json:"withdrawals,omitempty"`
    BlobGasUsed   *Uint64Quantity `json:"blobGasUsed,omitempty"`
    ExcessBlobGas *Uint64Quantity `json:"excessBlobGas,omitempty"`
}
```

### ForkchoiceState — 链头状态

> **Source Code**: [op-service/eth/types.go#L578-L585](https://github.com/ethereum-optimism/optimism/blob/develop/op-service/eth/types.go#L578)

```go
type ForkchoiceState struct {
    HeadBlockHash      common.Hash `json:"headBlockHash"`      // 规范链头部
    SafeBlockHash      common.Hash `json:"safeBlockHash"`      // 安全头部（L1 确认）
    FinalizedBlockHash common.Hash `json:"finalizedBlockHash"` // 最终确认头部
}
```

### ExecEngine 接口 — op-node 与执行引擎的边界

> **Source Code**: [op-node/rollup/engine/engine_controller.go#L59-L66](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/engine/engine_controller.go#L59)

```go
type ExecEngine interface {
    GetPayload(ctx context.Context, payloadInfo eth.PayloadInfo) (*eth.ExecutionPayloadEnvelope, error)
    ForkchoiceUpdate(ctx context.Context, state *eth.ForkchoiceState, attr *eth.PayloadAttributes) (*eth.ForkchoiceUpdatedResult, error)
    NewPayload(ctx context.Context, payload *eth.ExecutionPayload, parentBeaconBlockRoot *common.Hash) (*eth.PayloadStatusV1, error)
    L2BlockRefByLabel(ctx context.Context, label eth.BlockLabel) (eth.L2BlockRef, error)
    L2BlockRefByHash(ctx context.Context, hash common.Hash) (eth.L2BlockRef, error)
    L2BlockRefByNumber(ctx context.Context, num uint64) (eth.L2BlockRef, error)
}
```

这三个核心方法对应 Engine API 规范：
- **`ForkchoiceUpdate`**: `engine_forkchoiceUpdatedV2/V3` — 更新链头 + 可选地开始构建新区块
- **`GetPayload`**: `engine_getPayloadV2/V3` — 获取已构建的区块（停止交易池收集）
- **`NewPayload`**: `engine_newPayloadV2/V3` — 将区块插入执行引擎

---

## 路径一：L2 用户交易

### 阶段 1：交易提交到交易池

```
用户钱包 ──eth_sendRawTransaction──> op-geth JSON-RPC ──> 交易验证 ──> 交易池 (txpool)
```

用户通过标准的以太坊 JSON-RPC 接口（`eth_sendRawTransaction`）向 op-geth 提交交易。op-geth 会进行基本验证（签名、nonce、余额、gas 等），通过后将交易放入本地交易池。

**关键点**：排序器的交易池是**私有的** —— 由于 P2P 交易广播默认关闭，只有直接提交给排序器的交易才会进入其交易池。

### 阶段 2：排序器触发区块构建

排序器按固定的区块时间间隔（通常 2 秒）触发出块。在 `startBuildingBlock` 中准备 `PayloadAttributes`，关键的 `NoTxPool` 字段决定了交易池交易是否被包含：

> **Source Code**: [op-node/rollup/sequencing/sequencer.go#L822](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/sequencer.go#L822)

```go
// 正常情况：NoTxPool = false，允许执行引擎从交易池选取交易
attrs.NoTxPool = uint64(attrs.Timestamp) > l1Origin.Time+d.spec.MaxSequencerDrift(l1Origin.Time)

// 硬分叉激活区块、恢复模式等特殊情况：NoTxPool = true
```

### 阶段 3：执行引擎构建区块

排序器发出 `BuildStartEvent`，引擎控制器调用 `engine_forkchoiceUpdatedV2/V3`：

> **Source Code**: [op-node/rollup/engine/engine_controller.go#L1092-L1127](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/engine/engine_controller.go#L1092)

```go
func (e *EngineController) startPayload(ctx context.Context, fc eth.ForkchoiceState, attrs *eth.PayloadAttributes) (...) {
    fcRes, err := e.engine.ForkchoiceUpdate(ctx, &fc, attrs)
    // 返回 PayloadID，标识此次构建作业
}
```

op-geth 收到请求后的内部处理：

1. **创建初始区块**：使用 `PayloadAttributes.Transactions` 中的强制交易构建基础区块
2. **填充交易池交易**（如果 `NoTxPool=false`）：
   - 启动一个后台 goroutine
   - 按 gas price 降序从交易池中选取交易
   - 逐笔执行，更新状态
   - 持续优化直到收到 `GetPayload` 请求

### 阶段 4：密封和最终确认

排序器在区块目标时间前 50ms 发出 `BuildSealEvent`，触发 `engine_getPayloadV2/V3` 调用，获取包含用户交易的完整区块。

---

## 路径二：L1→L2 存款交易

### 阶段 1：用户在 L1 发起存款

用户调用 L1 上的 `OptimismPortal2.depositTransaction()` 函数：

> **Source Code**: [packages/contracts-bedrock/src/L1/OptimismPortal2.sol#L626-L685](https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L1/OptimismPortal2.sol#L626)

```solidity
function depositTransaction(
    address _to,        // L2 接收地址
    uint256 _value,     // L2 上转移的 ETH 数量
    uint64 _gasLimit,   // L2 执行 gas 限制
    bool _isCreation,   // 是否创建合约
    bytes memory _data  // 调用数据
) public payable metered(_gasLimit) {
    // 合约调用者使用地址别名
    address from = msg.sender;
    if (!EOA.isSenderEOA()) {
        from = AddressAliasHelper.applyL1ToL2Alias(msg.sender);
    }

    // 编码不透明数据
    bytes memory opaqueData = abi.encodePacked(msg.value, _value, _gasLimit, _isCreation, _data);

    // 发出事件，op-node 监听此事件来派生存款交易
    emit TransactionDeposited(from, _to, DEPOSIT_VERSION, opaqueData);
}
```

### 阶段 2：op-node 从 L1 区块中派生存款交易

当排序器构建新区块时，如果新区块的 L1 Origin 发生了变化（进入新的 Sequencing Epoch），需要从对应的 L1 区块收据中提取存款交易：

> **Source Code**: [op-node/rollup/derive/deposits.go#L14-L51](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/derive/deposits.go#L14)

```go
// UserDeposits 从 L1 收据中提取用户存款交易
func UserDeposits(receipts []*types.Receipt, depositContractAddr common.Address) ([]*types.DepositTx, error) {
    var out []*types.DepositTx
    for i, rec := range receipts {
        if rec.Status != types.ReceiptStatusSuccessful { continue }
        for j, log := range rec.Logs {
            if log.Address == depositContractAddr &&
               len(log.Topics) > 0 &&
               log.Topics[0] == DepositEventABIHash {
                dep, err := UnmarshalDepositLogEvent(log)
                if err == nil { out = append(out, dep) }
            }
        }
    }
    return out, nil
}

// DeriveDeposits 将 DepositTx 编码为字节
func DeriveDeposits(receipts []*types.Receipt, depositContractAddr common.Address) ([]hexutil.Bytes, error) {
    userDeposits, _ := UserDeposits(receipts, depositContractAddr)
    encodedTxs := make([]hexutil.Bytes, 0, len(userDeposits))
    for _, tx := range userDeposits {
        opaqueTx, _ := types.NewTx(tx).MarshalBinary()
        encodedTxs = append(encodedTxs, opaqueTx)
    }
    return encodedTxs, nil
}
```

### 阶段 3：事件日志解码为 DepositTx

> **Source Code**: [op-node/rollup/derive/deposit_log.go#L36-L98](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/derive/deposit_log.go#L36)

```go
func UnmarshalDepositLogEvent(ev *types.Log) (*types.DepositTx, error) {
    // 从 indexed topics 中提取 from, to, version
    from := common.BytesToAddress(ev.Topics[1][12:])
    to := common.BytesToAddress(ev.Topics[2][12:])
    version := ev.Topics[3]

    // 从 data 中提取 opaqueData（包含 mint, value, gasLimit, isCreation, data）
    opaqueData := ev.Data[64 : 64+opaqueContentLength.Uint64()]

    // 构建 DepositTx
    var dep types.DepositTx
    source := UserDepositSource{
        L1BlockHash: ev.BlockHash,
        LogIndex:    uint64(ev.Index),
    }
    dep.SourceHash = source.SourceHash()  // 唯一标识，防止重放
    dep.From = from
    dep.IsSystemTransaction = false

    // 解码 v0 版本数据：mint(32) + value(32) + gas(8) + isCreation(1) + data(...)
    unmarshalDepositVersion0(&dep, to, opaqueData)

    return &dep, nil
}
```

### SourceHash：存款交易的唯一标识

每个存款交易都有唯一的 `SourceHash`，用于防止重放攻击：

> **Source Code**: [op-node/rollup/derive/deposit_source.go#L10-L34](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/derive/deposit_source.go#L10)

```go
type UserDepositSource struct {
    L1BlockHash common.Hash   // 产生此存款的 L1 区块哈希
    LogIndex    uint64        // 日志在区块中的索引
}

func (dep *UserDepositSource) SourceHash() common.Hash {
    // depositID = keccak256(L1BlockHash ++ LogIndex)
    // sourceHash = keccak256(UserDepositSourceDomain ++ depositID)
    // Domain 0 = 用户存款, 1 = L1 Info, 2 = 升级
}
```

### 阶段 4：存款交易被包含到 PayloadAttributes

在 `PreparePayloadAttributes` 中，存款交易被放入 `Transactions` 字段：

> **Source Code**: [op-node/rollup/derive/attributes.go#L67-L213](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/derive/attributes.go#L67)

```go
func (ba *FetchingAttributesBuilder) PreparePayloadAttributes(...) (*eth.PayloadAttributes, error) {
    if l2Parent.L1Origin.Number != epoch.Number {
        // 新 Epoch：获取 L1 区块的所有收据，派生存款交易
        info, receipts, _ := ba.l1.FetchReceipts(ctx, epoch.Hash)
        deposits, _ := DeriveDeposits(receipts, ba.rollupCfg.DepositContractAddress)
        depositTxs = deposits
        seqNumber = 0
    } else {
        // 同一 Epoch 的后续区块：没有新的存款
        depositTxs = nil
        seqNumber = l2Parent.SequenceNumber + 1
    }

    // 创建 L1 Info Deposit 交易
    l1InfoTx, _ := L1InfoDepositBytes(ba.rollupCfg, ba.l1ChainConfig, sysConfig, seqNumber, l1Info, nextL2Time)

    // 组装交易列表
    txs := make([]hexutil.Bytes, 0, 1+len(depositTxs)+len(upgradeTxs))
    txs = append(txs, l1InfoTx)       // 位置 0：L1 Info Deposit（系统交易）
    txs = append(txs, depositTxs...)  // 位置 1~N：用户存款交易
    txs = append(txs, upgradeTxs...)  // 位置 N+1~：硬分叉升级交易

    return &eth.PayloadAttributes{
        Transactions: txs,
        NoTxPool:     true,  // 默认不从交易池取（排序器后续会修改）
        // ...
    }, nil
}
```

---

## 区块构建：交易如何被组装到区块中

### L1 Info Deposit 交易：每个区块的"系统心跳"

每个 L2 区块的第一笔交易固定是 L1 Info Deposit 交易，它将 L1 区块信息写入 L2 的 `L1Block` 预部署合约：

> **Source Code**: [op-node/rollup/derive/l1_block_info.go#L484-L600](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/derive/l1_block_info.go#L484)

```go
func L1InfoDeposit(rollupCfg *rollup.Config, ...) (*types.DepositTx, error) {
    l1BlockInfo := L1BlockInfo{
        Number:         block.NumberU64(),      // L1 区块号
        Time:           block.Time(),           // L1 区块时间
        BaseFee:        block.BaseFee(),        // L1 基础费用
        BlockHash:      block.Hash(),           // L1 区块哈希
        SequenceNumber: seqNumber,              // 在 epoch 内的序号
        BatcherAddr:    sysCfg.BatcherAddr,     // Batcher 地址
        BlobBaseFee:    block.BlobBaseFee(...),  // Ecotone 后
        BaseFeeScalar:     scalars.BaseFeeScalar,     // L1 费用缩放因子
        BlobBaseFeeScalar: scalars.BlobBaseFeeScalar,  // Blob 费用缩放因子
    }

    out := &types.DepositTx{
        SourceHash:          source.SourceHash(),
        From:                L1InfoDepositerAddress,  // 0xdeaddeaddeaddeaddeaddeaddeaddeaddead0001
        To:                  &L1BlockAddress,         // L1Block 预部署合约地址
        Mint:                nil,
        Value:               big.NewInt(0),
        Gas:                 RegolithSystemTxGas,      // 1_000_000
        IsSystemTransaction: false,
        Data:                data,                     // 编码后的 L1BlockInfo
    }
    return out, nil
}
```

### 排序器设置 NoTxPool

回到排序器，`PreparePayloadAttributes` 返回的 `NoTxPool=true` 会被排序器根据条件覆盖：

> **Source Code**: [op-node/rollup/sequencing/sequencer.go#L818-L862](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/sequencer.go#L818)

```go
// 核心判断：Sequencer Drift
attrs.NoTxPool = uint64(attrs.Timestamp) > l1Origin.Time+d.spec.MaxSequencerDrift(l1Origin.Time)

// 硬分叉激活区块强制不包含交易池交易
if d.rollupCfg.IsEcotoneActivationBlock(...)  { attrs.NoTxPool = true }
if d.rollupCfg.IsFjordActivationBlock(...)    { attrs.NoTxPool = true }
if d.rollupCfg.IsIsthmusActivationBlock(...)  { attrs.NoTxPool = true }
if d.rollupCfg.IsJovianActivationBlock(...)   { attrs.NoTxPool = true }
if d.rollupCfg.IsInteropActivationBlock(...)  { attrs.NoTxPool = true }

// Granite 激活区块例外：允许交易池交易

// 恢复模式
if recoverMode { attrs.NoTxPool = true }
```

**正常情况下 `NoTxPool = false`**，这意味着执行引擎会在强制交易之后，从交易池中选取用户交易填充区块。

### 执行引擎内部的区块构建

op-geth 收到带有 `PayloadAttributes` 的 `ForkchoiceUpdate` 请求后：

```
1. 创建初始区块框架
   - 设置区块头（时间戳、Gas Limit、BaseFee 等）

2. 执行强制交易（PayloadAttributes.Transactions）
   - 顺序执行 L1 Info Deposit 交易
   - 顺序执行用户存款交易
   - 顺序执行升级交易

3. 如果 NoTxPool = false：
   - 从交易池中按 effective gas price 降序选取交易
   - 逐笔验证和执行（nonce 检查、余额检查、gas 限制等）
   - 跳过执行失败的交易
   - 持续填充直到达到 gas 限制或没有更多交易

4. 后台持续优化（直到 GetPayload 被调用）
   - 定期重新构建区块以包含新到达的交易
   - 追求更高的交易费收入
```

---

## 完整时序图

### L2 用户交易的完整生命周期

```
用户              op-geth (EL)              Sequencer (op-node)            P2P 网络
 │                    │                          │                          │
 │─eth_sendRawTx─────>│                          │                          │
 │                    │  验证 + 入交易池           │                          │
 │                    │                          │                          │
 │                    │                    [定时器触发]                       │
 │                    │                          │                          │
 │                    │    ForkchoiceUpdate       │                          │
 │                    │   (fc + PayloadAttributes)│                          │
 │                    │<─────────────────────────│  startBuildingBlock()    │
 │                    │                          │                          │
 │                    │  开始构建区块              │                          │
 │                    │  1. 执行强制交易           │                          │
 │                    │  2. 从交易池选取用户交易    │                          │
 │                    │  [用户的交易在此被选中]     │                          │
 │                    │                          │                          │
 │                    │    返回 PayloadID         │                          │
 │                    │─────────────────────────>│  BuildStartedEvent       │
 │                    │                          │                          │
 │                    │                   [等待密封时机]                      │
 │                    │                          │                          │
 │                    │       GetPayload          │                          │
 │                    │<─────────────────────────│  BuildSealEvent          │
 │                    │                          │                          │
 │                    │  停止交易池收集            │                          │
 │                    │  返回完整 ExecutionPayload │                          │
 │                    │─────────────────────────>│  BuildSealedEvent        │
 │                    │                          │                          │
 │                    │                          │──Gossip────────────────>│
 │                    │                          │  P2P 广播区块             │
 │                    │                          │                          │
 │                    │       NewPayload          │                          │
 │                    │<─────────────────────────│  PayloadProcessEvent     │
 │                    │  将区块插入本地链          │                          │
 │                    │─────────────────────────>│  PayloadSuccessEvent     │
 │                    │                          │                          │
 │                    │    ForkchoiceUpdate       │                          │
 │                    │   (更新 head，无 attrs)    │                          │
 │                    │<─────────────────────────│  tryUpdateEngine         │
 │                    │─────────────────────────>│  ForkchoiceUpdateEvent   │
 │                    │                          │                          │
 │                    │                    [调度下一轮出块]                    │
```

### L1→L2 存款交易的完整生命周期

```
用户              L1 (以太坊)        OptimismPortal2        op-node           op-geth (EL)
 │                    │                   │                   │                   │
 │──L1 交易──────────>│                   │                   │                   │
 │                    │──调用──────────────>│                   │                   │
 │                    │                   │  depositTransaction()                  │
 │                    │                   │  emit TransactionDeposited              │
 │                    │<──receipt──────────│                   │                   │
 │                    │                   │                   │                   │
 │             [L1 区块被确认]             │                   │                   │
 │                    │                   │                   │                   │
 │                    │                   │   FetchReceipts()  │                   │
 │                    │────────────────────────────────────────>│                   │
 │                    │                   │                   │                   │
 │                    │                   │   扫描 TransactionDeposited 事件         │
 │                    │                   │   DeriveDeposits() │                   │
 │                    │                   │   构建 PayloadAttributes                │
 │                    │                   │   Transactions: [L1Info, Deposit...]    │
 │                    │                   │                   │                   │
 │                    │                   │                   │ ForkchoiceUpdate   │
 │                    │                   │                   │──────────────────>│
 │                    │                   │                   │  [存款交易作为     │
 │                    │                   │                   │   强制交易被执行]  │
 │                    │                   │                   │                   │
 │                    │                   │                   │   GetPayload      │
 │                    │                   │                   │──────────────────>│
 │                    │                   │                   │<──区块(含存款)────│
 │                    │                   │                   │                   │
 │                    │                   │                   │   区块广播+插入    │
```

---

## 区块中的交易排序规则

每个 L2 区块中的交易严格遵循以下顺序：

```
┌─────────────────────────────────────────────────────────────────┐
│                        L2 区块                                   │
├─────────────────────────────────────────────────────────────────┤
│  [0] L1 Info Deposit 交易 (系统)                                  │
│      - 写入 L1 区块信息到 L1Block 预部署合约                        │
│      - 每个 L2 区块有且仅有一笔                                    │
├─────────────────────────────────────────────────────────────────┤
│  [1..N] 用户存款交易 (仅新 Epoch 首块)                             │
│      - 来自 L1 OptimismPortal 的 TransactionDeposited 事件        │
│      - 按 L1 日志索引顺序排列                                      │
│      - 同一 Epoch 后续区块为空                                     │
├─────────────────────────────────────────────────────────────────┤
│  [N+1..M] 硬分叉升级交易 (仅激活区块)                              │
│      - Ecotone/Fjord/Isthmus/Jovian/Interop 升级系统调用          │
│      - 绝大多数区块没有此部分                                      │
├─────────────────────────────────────────────────────────────────┤
│  [M+1..] 用户 L2 交易 (来自交易池)                                 │
│      - 由执行引擎从交易池中按 gas price 选取                        │
│      - NoTxPool=true 时此部分为空                                  │
│      - 按 effective gas price 降序排列                             │
└─────────────────────────────────────────────────────────────────┘
```

### 完整性检查

引擎密封区块时会进行完整性检查：

> **Source Code**: [op-node/rollup/engine/build_seal.go#L158-L183](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/engine/build_seal.go#L158)

```go
func sanityCheckPayload(payload *eth.ExecutionPayload) error {
    // 区块必须至少有一笔交易
    if len(payload.Transactions) == 0 {
        return errors.New("no transactions in returned payload")
    }
    // 第一笔必须是 deposit 交易（L1 Info）
    if payload.Transactions[0][0] != types.DepositTxType {
        return fmt.Errorf("first transaction was not deposit tx")
    }
    // 所有 deposit 交易必须在前面，非 deposit 交易在后面
    lastDeposit, _ := lastDeposit(payload.Transactions)
    for i := lastDeposit + 1; i < len(payload.Transactions); i++ {
        deposit, _ := isDepositTx(payload.Transactions[i])
        if deposit {
            return fmt.Errorf("deposit tx after non-deposit tx")
        }
    }
    return nil
}
```

---

## 关键源码解析

### Engine API 交互的三步流程

**步骤 1：ForkchoiceUpdate（开始构建）**

> **Source Code**: [op-node/rollup/engine/build_start.go#L21-L81](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/engine/build_start.go#L21)

```go
func (e *EngineController) onBuildStart(ctx context.Context, ev BuildStartEvent) {
    fc := eth.ForkchoiceState{
        HeadBlockHash:      ev.Attributes.Parent.Hash,
        SafeBlockHash:      e.safeHead.Hash,
        FinalizedBlockHash: e.finalizedHead.Hash,
    }
    // 携带 PayloadAttributes 调用 ForkchoiceUpdate
    // 执行引擎开始后台构建区块
    id, errTyp, err := e.startPayload(rpcCtx, fc, ev.Attributes.Attributes)

    e.emitter.Emit(ctx, BuildStartedEvent{
        Info: eth.PayloadInfo{ID: id, Timestamp: ...},
    })
}
```

**步骤 2：GetPayload（密封区块）**

> **Source Code**: [op-node/rollup/engine/build_seal.go#L58-L128](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/engine/build_seal.go#L58)

```go
func (e *EngineController) onBuildSeal(ctx context.Context, ev BuildSealEvent) {
    // 获取已构建的区块，停止后台交易收集
    envelope, err := e.engine.GetPayload(rpcCtx, ev.Info)

    // 完整性检查
    sanityCheckPayload(envelope.ExecutionPayload)

    // 转换为区块引用
    ref, _ := derive.PayloadToBlockRef(e.rollupCfg, envelope.ExecutionPayload)

    e.emitter.Emit(ctx, BuildSealedEvent{
        Envelope: envelope,
        Ref:      ref,
    })
}
```

**步骤 3：NewPayload（插入区块）**

> **Source Code**: [op-node/rollup/engine/payload_process.go#L27-L68](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/engine/payload_process.go#L27)

```go
func (e *EngineController) onPayloadProcess(ctx context.Context, ev PayloadProcessEvent) {
    // 将区块插入执行引擎
    status, err := e.engine.NewPayload(rpcCtx, ev.Envelope.ExecutionPayload, ev.Envelope.ParentBeaconBlockRoot)

    switch status.Status {
    case eth.ExecutionValid:
        e.emitter.Emit(ctx, PayloadSuccessEvent{...})
    case eth.ExecutionInvalid:
        e.emitter.Emit(ctx, PayloadInvalidEvent{...})
    }
}
```

### 排序器的三优先级调度

> **Source Code**: [op-node/rollup/sequencing/sequencer.go#L575-L620](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/sequencer.go#L575)

```go
func (d *Sequencer) onSequencerAction(ev SequencerActionEvent) {
    // 优先级 1：重用已广播但本地插入失败的负载
    payload := d.asyncGossip.Get()
    if payload != nil {
        d.emitter.Emit(d.ctx, engine.PayloadProcessEvent{Envelope: payload, Ref: ref})
        return
    }

    // 优先级 2：密封正在构建的区块
    if d.latest.Info != (eth.PayloadInfo{}) {
        d.emitter.Emit(d.ctx, engine.BuildSealEvent{Info: d.latest.Info, ...})
        return
    }

    // 优先级 3：开始构建新区块
    if d.latest == (BuildingState{}) {
        d.startBuildingBlock()
    }
}
```

---

## 模块间数据传输路径总览

```
┌──────────────────────────────────────────────────────────────────────────┐
│                              用户                                        │
│                         ┌────┴────┐                                      │
│                    L2 RPC交易  L1 存款交易                                 │
│                         │         │                                      │
│                         ▼         ▼                                      │
│                    ┌─────────┐  ┌──────────────┐                         │
│                    │ op-geth │  │ L1 Ethereum  │                         │
│                    │ txpool  │  │ OptimismPortal│                        │
│                    └────┬────┘  └──────┬───────┘                         │
│                         │              │                                 │
│                         │    FetchReceipts + DeriveDeposits              │
│                         │              │                                 │
│                         │              ▼                                 │
│                         │    ┌──────────────────┐                        │
│                         │    │    op-node        │                        │
│                         │    │   Sequencer       │                        │
│                         │    │                  │                        │
│                         │    │ PreparePayload-  │                        │
│                         │    │ Attributes()     │                        │
│                         │    │                  │                        │
│                         │    │ Transactions:    │                        │
│                         │    │ [L1Info,Deposits]│                        │
│                         │    │ NoTxPool: false  │                        │
│                         │    └────────┬─────────┘                        │
│                         │             │                                  │
│                         │   ForkchoiceUpdate(fc, attrs)                  │
│                         │             │                                  │
│                         ▼             ▼                                  │
│                    ┌───────────────────────┐                              │
│                    │     op-geth Engine    │                              │
│                    │                       │                              │
│                    │  1. 执行强制交易       │                              │
│                    │     (L1Info+Deposits) │                              │
│                    │                       │                              │
│                    │  2. 从 txpool 选取    │ ◄── 用户的 L2 交易在此被选中  │
│                    │     用户交易           │                              │
│                    │                       │                              │
│                    │  3. 构建 Execution-   │                              │
│                    │     Payload           │                              │
│                    └───────────┬───────────┘                              │
│                               │                                          │
│                      GetPayload / NewPayload                             │
│                               │                                          │
│                               ▼                                          │
│                    ┌───────────────────────┐                              │
│                    │    最终的 L2 区块       │                              │
│                    │  [L1Info][Deposits]    │                              │
│                    │  [User L2 Txs...]     │                              │
│                    └───────────────────────┘                              │
│                               │                                          │
│                    P2P Gossip 广播到网络                                   │
└──────────────────────────────────────────────────────────────────────────┘
```

### 数据转换链

```
L1 存款交易路径:
  TransactionDeposited Event (L1 Log)
    → UnmarshalDepositLogEvent() → types.DepositTx
      → MarshalBinary() → hexutil.Bytes
        → PayloadAttributes.Transactions[1..N]
          → ExecutionPayload.Transactions[1..N]

L2 用户交易路径:
  eth_sendRawTransaction (RPC)
    → op-geth txpool (内存)
      → fillTransactions() (gas price 排序)
        → ExecutionPayload.Transactions[N+1..]

L1 Info 系统交易路径:
  L1BlockInfo struct
    → marshalBinaryEcotone/Isthmus/Jovian() → []byte
      → types.DepositTx{Data: data}
        → MarshalBinary() → hexutil.Bytes
          → PayloadAttributes.Transactions[0]
            → ExecutionPayload.Transactions[0]
```
