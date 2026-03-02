# L2 区块构建完整流程深度解析

本文从**区块构建**的视角，系统解析 Optimism L2 区块从创建到最终确认的完整生命周期。涵盖排序器出块模式与派生重建模式、核心数据结构、Engine API 交互协议、区块安全级别演进机制，以及错误处理与恢复策略。

> 本文所有代码引用均基于当前代码库源码验证。

## 目录

1. [架构总览：区块构建的两种模式](#架构总览区块构建的两种模式)
2. [核心组件与职责](#核心组件与职责)
3. [核心数据结构](#核心数据结构)
4. [排序器模式：完整出块流程](#排序器模式完整出块流程)
5. [Engine API 交互协议](#engine-api-交互协议)
6. [区块安全级别演进](#区块安全级别演进)
7. [派生模式：从 L1 数据重建区块](#派生模式从-l1-数据重建区块)
8. [区块内交易组装与排序](#区块内交易组装与排序)
9. [完整时序图](#完整时序图)
10. [错误处理与恢复机制](#错误处理与恢复机制)
11. [关键源码解析](#关键源码解析)
12. [模块交互全景图](#模块交互全景图)

---

## 架构总览：区块构建的两种模式

Optimism L2 区块的产生有两种模式，二者使用**完全相同的 Engine API** 与执行引擎交互，但触发来源不同：

```
模式一：排序器模式（Sequencer Mode）—— 主动出块
  Driver eventLoop → Sequencer → EngineController → op-geth (EL)
  特点：排序器主动按区块时间间隔构建新区块，包含交易池中的用户交易

模式二：派生模式（Derivation Mode）—— 从 L1 数据重建
  Driver eventLoop → DerivationPipeline → AttributesHandler → EngineController → op-geth (EL)
  特点：验证者从 L1 链上的 batch 数据重新推导出 L2 区块，用于同步和验证
```

两种模式的核心区别在于 **PayloadAttributes 的来源**：

| 维度 | 排序器模式 | 派生模式 |
|------|-----------|---------|
| 触发源 | 定时器 + ForkchoiceUpdate | L1 区块数据到达 |
| Attributes 构建 | `Sequencer.startBuildingBlock()` | `DerivationPipeline` 输出 |
| `DerivedFrom` 字段 | 零值（`eth.L1BlockRef{}`） | 非零（指向 L1 源区块） |
| `NoTxPool` | 通常 `false`（从交易池取交易） | `true`（仅包含 batch 中的交易） |
| 区块安全级别 | 产出 unsafe 区块 | 产出 pending-safe / local-safe 区块 |
| P2P 广播 | 密封后立即广播 | 不广播 |

---

## 核心组件与职责

```
┌────────────────────────────────────────────────────────────────┐
│                        Driver (事件循环)                        │
│  - 管理排序器调度（sequencerTimer）                              │
│  - 管理派生步骤调度（derivation step）                           │
│  - 协调排序器与派生管道的优先级                                   │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  ┌──────────────┐  事件  ┌──────────────────┐  事件            │
│  │  Sequencer   │ ────── │ EngineController │                  │
│  │  (排序器)     │ ←───── │  (引擎控制器)     │                  │
│  └──────────────┘        └────────┬─────────┘                  │
│                                   │                            │
│  ┌──────────────┐  事件           │ Engine API                 │
│  │  Pipeline    │ ────── ─────────┤ (RPC)                      │
│  │  (派生管道)   │                 │                            │
│  └──────────────┘                 ▼                            │
│                          ┌──────────────────┐                  │
│                          │    op-geth (EL)   │                  │
│                          │  执行层 / 交易池   │                  │
│                          └──────────────────┘                  │
└────────────────────────────────────────────────────────────────┘
```

### 各组件职责

**Driver（`op-node/rollup/driver/driver.go`）**
- 运行主事件循环 `eventLoop()`
- 通过 `planSequencerAction()` 动态调度排序器动作
- 在排序器和派生管道之间调解资源

**Sequencer（`op-node/rollup/sequencing/sequencer.go`）**
- 决定何时构建新区块（调度策略）
- 选择 L1 Origin（锚定 L1 链）
- 构建 PayloadAttributes（系统交易模板）
- 管理区块构建状态机

**EngineController（`op-node/rollup/engine/engine_controller.go`）**
- 封装与执行引擎的所有 Engine API 交互
- 管理区块头状态（unsafe/safe/finalized）
- 处理 ForkchoiceUpdate 调用
- 执行区块 sanity check

**op-geth（执行层）**
- 执行交易，维护状态树
- 管理交易池（mempool）
- 响应 Engine API 调用
- 实际构建区块内容（选择交易、计算状态根）

---

## 核心数据结构

### L2BlockRef —— L2 区块引用

```go
// op-service/eth/id.go
type L2BlockRef struct {
    Hash           common.Hash // 区块哈希
    Number         uint64      // 区块号
    ParentHash     common.Hash // 父区块哈希
    Time           uint64      // 时间戳
    L1Origin       BlockID     // 对应的 L1 origin 区块（hash + number）
    SequenceNumber uint64      // 距离 epoch 首区块的距离
}
```

`SequenceNumber` 表示当前区块在同一个 L1 epoch 内的序号。每当 L1 Origin 推进时，序号归零。

### PayloadAttributes —— 区块构建指令

```go
// op-service/eth/types.go
type PayloadAttributes struct {
    Timestamp             Uint64Quantity    // 区块时间戳
    PrevRandao            Bytes32           // 随机数（来自 L1）
    SuggestedFeeRecipient common.Address    // 手续费接收者（SequencerFeeVault）
    Withdrawals           *types.Withdrawals // Canyon 后为空列表
    ParentBeaconBlockRoot *common.Hash      // Ecotone 后的 beacon block root

    // Optimism 扩展字段
    Transactions []Data           // 强制包含的交易（L1 Info + Deposits + Upgrades）
    NoTxPool     bool             // 是否禁止从交易池获取交易
    GasLimit     *Uint64Quantity  // Gas 上限覆盖
    EIP1559Params *Bytes8         // Holocene 后的 EIP-1559 参数
    MinBaseFee   *uint64          // Jovian 后的最低 base fee
}
```

`Transactions` 字段中包含的是**强制交易**（forced transactions），始终排列在区块的最前面。如果 `NoTxPool = false`，op-geth 会在这些强制交易之后追加交易池中的用户交易。

### ExecutionPayload —— 已构建的区块

```go
// op-service/eth/types.go
type ExecutionPayload struct {
    ParentHash    common.Hash      // 父区块哈希
    FeeRecipient  common.Address   // 手续费接收者
    StateRoot     Bytes32          // 状态根（EL 执行交易后计算）
    ReceiptsRoot  Bytes32          // 收据根
    LogsBloom     Bytes256         // 日志 bloom 过滤器
    PrevRandao    Bytes32          // 随机数
    BlockNumber   Uint64Quantity   // 区块号
    GasLimit      Uint64Quantity   // Gas 上限
    GasUsed       Uint64Quantity   // 已使用 Gas
    Timestamp     Uint64Quantity   // 时间戳
    ExtraData     BytesMax32       // 额外数据
    BaseFeePerGas Uint256Quantity  // 基础费
    BlockHash     common.Hash      // 区块哈希
    Transactions  []Data           // 所有交易（Deposits + 用户交易）
    Withdrawals   *types.Withdrawals
}
```

这是 op-geth 完成区块构建后返回的**完整区块数据**。相比输入的 `PayloadAttributes`，它多了 `StateRoot`、`ReceiptsRoot`、`GasUsed`、`BlockHash` 等执行结果字段。

### ForkchoiceState —— 链头三元组

```go
// op-service/eth/types.go
type ForkchoiceState struct {
    HeadBlockHash      common.Hash // 链头（unsafe head）
    SafeBlockHash      common.Hash // 安全头（safe head）
    FinalizedBlockHash common.Hash // 最终确认头（finalized head）
}
```

这三个值代表了 L2 链的当前状态视图，通过 `engine_forkchoiceUpdatedV3` 发送给执行引擎。

### BuildingState —— 区块构建作业状态

```go
// op-node/rollup/sequencing/sequencer.go
type BuildingState struct {
    Onto    eth.L2BlockRef   // 父区块（在其上构建）
    Info    eth.PayloadInfo  // PayloadID + 时间戳（EL 返回）
    Started time.Time        // 构建开始时间
    Ref     eth.L2BlockRef   // 密封后的区块引用
}
```

零值 `BuildingState{}` 表示没有正在进行的构建作业。整个区块构建的生命周期通过逐步填充这个结构的各字段来追踪。

---

## 排序器模式：完整出块流程

### 流程概览

```
  时间线：  T=0          T=N-50ms       T=N（区块目标时间）
           │              │              │
  阶段：   ├─ 开始构建 ───┼─ 密封区块 ───┼─ 广播+插入
           │              │              │
  事件：   BuildStart    BuildSeal     PayloadProcess
           ↓              ↓              ↓
           BuildStarted  BuildSealed   PayloadSuccess
                                         ↓
                                       ForkchoiceUpdate
                                         ↓
                                       下一轮...
```

### 第一阶段：调度触发

Driver 事件循环通过 `planSequencerAction()` 检查排序器的下一个动作时间：

```go
// op-node/rollup/driver/driver.go
planSequencerAction := func() {
    nextAction, ok := s.sequencer.NextAction()
    if !ok {
        sequencerCh = nil  // 无动作，暂停定时器
        return
    }
    delta := time.Until(nextAction)
    sequencerTimer.Reset(delta)
}
```

当定时器到期，Driver 发出 `SequencerActionEvent`：

```go
select {
case <-sequencerCh:
    s.emitter.Emit(s.driverCtx, sequencing.SequencerActionEvent{})
```

### 第二阶段：开始构建区块

排序器收到 `SequencerActionEvent` 后，调用 `startBuildingBlock()`：

**步骤 2.1：选择 L1 Origin**

```go
// op-node/rollup/sequencing/sequencer.go
l1Origin, err := d.l1OriginSelector.FindL1Origin(ctx, l2Head)
```

L1 Origin 选择遵循以下规则（`origin_selector.go`）：

```
                  currentL1Origin          nextL1Origin
                       │                       │
  L1:  ───────────── [block N] ──────────── [block N+1] ──────
                       │                       │
  L2:  ─── l2Head ─── │ ─── nextL2Block ───── │
             ↑         │         ↑             │
          origin=N     │    选择 N 还是 N+1？    │
                       │                       │
  规则：
  - nextL2Time >= nextL1Origin.Time → 可以推进到 N+1
  - nextL2Time < nextL1Origin.Time → 保持在 N（不能指向未来的 L1 区块）
  - drift > MaxSequencerDrift → 必须推进到 N+1（防止 L2 过度领先 L1）
```

**步骤 2.2：构建 PayloadAttributes**

```go
// op-node/rollup/sequencing/sequencer.go
attrs, err := d.attrBuilder.PreparePayloadAttributes(fetchCtx, l2Head, l1Origin.ID())
```

`PreparePayloadAttributes`（`op-node/rollup/derive/attributes.go`）组装强制交易列表：

```
Transactions 列表的组装顺序：
┌─────────────────────────────┐
│ 1. L1 Info Deposit Tx       │  ← 始终第一个，包含 L1 区块上下文
├─────────────────────────────┤
│ 2. User Deposit Txs         │  ← 仅在 epoch 首区块（L1 Origin 变化时）
├─────────────────────────────┤
│ 3. Hardfork Upgrade Txs     │  ← 仅在硬分叉激活区块
└─────────────────────────────┘
```

**步骤 2.3：设置 NoTxPool 标志**

```go
// Sequencer Drift 检查
attrs.NoTxPool = uint64(attrs.Timestamp) > l1Origin.Time+d.spec.MaxSequencerDrift(l1Origin.Time)

// 硬分叉激活区块（Ecotone/Fjord/Isthmus/Jovian/Interop，Granite 除外）
if d.rollupCfg.IsEcotoneActivationBlock(uint64(attrs.Timestamp)) {
    attrs.NoTxPool = true
}

// 恢复模式
if recoverMode {
    attrs.NoTxPool = true
}
```

**步骤 2.4：发出构建开始事件**

```go
d.latest = BuildingState{Onto: l2Head}
d.emitter.Emit(d.ctx, engine.BuildStartEvent{
    Attributes: withParent,
})
```

### 第三阶段：引擎启动区块构建

`EngineController` 收到 `BuildStartEvent`，调用 Engine API：

```go
// op-node/rollup/engine/build_start.go
func (e *EngineController) onBuildStart(ctx context.Context, ev BuildStartEvent) {
    // 1. 构建 ForkchoiceState
    fc := eth.ForkchoiceState{
        HeadBlockHash:      ev.Attributes.Parent.Hash,  // 父区块
        SafeBlockHash:      e.safeHead.Hash,
        FinalizedBlockHash: e.finalizedHead.Hash,
    }
    // 2. 调用 engine_forkchoiceUpdatedV3（携带 PayloadAttributes）
    id, errTyp, err := e.startPayload(rpcCtx, fc, ev.Attributes.Attributes)
    // 3. 发出 BuildStartedEvent（包含 PayloadID）
    e.emitter.Emit(ctx, BuildStartedEvent{
        Info: eth.PayloadInfo{ID: id, Timestamp: ...},
        ...
    })
}
```

`startPayload` 的底层实现：

```go
// op-node/rollup/engine/engine_controller.go
func (e *EngineController) startPayload(ctx context.Context, fc eth.ForkchoiceState,
    attrs *eth.PayloadAttributes) (id eth.PayloadID, errType BlockInsertionErrType, err error) {

    fcRes, err := e.engine.ForkchoiceUpdate(ctx, &fc, attrs)
    // ...
    return *fcRes.PayloadID, BlockInsertOK, nil
}
```

这个 `ForkchoiceUpdate` 调用同时完成了两件事：
1. **更新链头状态**（ForkchoiceState）
2. **启动区块构建作业**（携带 PayloadAttributes）

op-geth 收到后开始异步构建区块，返回一个 `PayloadID` 供后续获取。

### 第四阶段：等待并调度密封

排序器收到 `BuildStartedEvent`，计算密封时机：

```go
// op-node/rollup/sequencing/sequencer.go
func (d *Sequencer) onBuildStarted(x engine.BuildStartedEvent) {
    payloadTime := time.Unix(int64(x.Parent.Time+d.rollupCfg.BlockTime), 0)
    remainingTime := payloadTime.Sub(now)
    if remainingTime < d.sealingDuration {
        d.nextAction = now  // 时间不够，立即密封
    } else {
        d.nextAction = payloadTime.Add(-d.sealingDuration)  // 预留 50ms 密封时间
    }
}
```

时间线示意：

```
  BuildStarted         nextAction（密封开始）  区块目标时间
      │                      │                  │
      │<── EL 构建区块 ──────>│<── 50ms seal ──>│
      │   (选择交易/执行/      │                  │
      │    计算状态根)         │                  │
```

### 第五阶段：密封区块

定时器到期后，排序器发出 `BuildSealEvent`，EngineController 调用 `engine_getPayloadV3`：

```go
// op-node/rollup/engine/build_seal.go
func (e *EngineController) onBuildSeal(ctx context.Context, ev BuildSealEvent) {
    // 1. 获取已构建的区块
    envelope, err := e.engine.GetPayload(rpcCtx, ev.Info)

    // 2. Sanity Check —— 验证交易排序规则
    if err := sanityCheckPayload(envelope.ExecutionPayload); err != nil { ... }

    // 3. 转换为 L2BlockRef
    ref, err := derive.PayloadToBlockRef(e.rollupCfg, envelope.ExecutionPayload)

    // 4. 发出 BuildSealedEvent
    e.emitter.Emit(ctx, BuildSealedEvent{
        Envelope: envelope,
        Ref:      ref,
        ...
    })
}
```

**Sanity Check 规则**：

```go
// op-node/rollup/engine/build_seal.go
func sanityCheckPayload(payload *eth.ExecutionPayload) error {
    // 规则 1：区块不能为空
    if len(payload.Transactions) == 0 { return error }
    // 规则 2：第一笔交易必须是 Deposit 类型
    if payload.Transactions[0][0] != types.DepositTxType { return error }
    // 规则 3：所有 Deposit 交易必须排在非 Deposit 交易之前
    for i := lastDeposit + 1; i < len(txs); i++ {
        if isDeposit(txs[i]) { return error }  // 不允许 deposit 出现在普通交易之后
    }
}
```

### 第六阶段：广播与插入

排序器收到 `BuildSealedEvent`，执行三个关键步骤：

```go
// op-node/rollup/sequencing/sequencer.go
func (d *Sequencer) onBuildSealed(x engine.BuildSealedEvent) {
    // 步骤 1：提交到 Conductor（HA 共识）
    d.conductor.CommitUnsafePayload(ctx, x.Envelope)

    // 步骤 2：P2P 广播（异步，不阻塞）
    d.asyncGossip.Gossip(x.Envelope)

    // 步骤 3：插入本地链
    d.emitter.Emit(d.ctx, engine.PayloadProcessEvent{
        Envelope: x.Envelope,
        Ref:      x.Ref,
    })
}
```

**广播先于本地插入**是有意为之的设计：

```
排序器节点：  密封 → 广播 → 本地插入
其他节点：              → 接收广播 → 插入
```

这样可以最小化区块到达网络其他节点的延迟。即使本地插入暂时失败，区块已经在网络中传播。

### 第七阶段：本地链插入

`EngineController` 处理 `PayloadProcessEvent`，调用 `engine_newPayloadV3`：

```go
// op-node/rollup/engine/payload_process.go
func (e *EngineController) onPayloadProcess(ctx context.Context, ev PayloadProcessEvent) {
    status, err := e.engine.NewPayload(rpcCtx, ev.Envelope.ExecutionPayload,
        ev.Envelope.ParentBeaconBlockRoot)

    switch status.Status {
    case eth.ExecutionValid:
        e.emitter.Emit(ctx, PayloadSuccessEvent{...})
    case eth.ExecutionInvalid:
        e.emitter.Emit(ctx, PayloadInvalidEvent{...})
    }
}
```

`PayloadSuccessEvent` 触发头部状态更新：

```go
// op-node/rollup/engine/payload_success.go
func (e *EngineController) onPayloadSuccess(ctx context.Context, ev PayloadSuccessEvent) {
    // 1. 更新 unsafe head
    e.tryUpdateUnsafe(ctx, ev.Ref)
    // 2. 如果来自派生（DerivedFrom 非零），还更新 pending-safe 和 local-safe
    if ev.DerivedFrom != (eth.L1BlockRef{}) {
        e.tryUpdatePendingSafe(ctx, ev.Ref, ev.Concluding, ev.DerivedFrom)
        e.tryUpdateLocalSafe(ctx, ev.Ref, ev.Concluding, ev.DerivedFrom)
    }
    // 3. 同步调用 ForkchoiceUpdate 通知 EL
    e.tryUpdateEngineInternal(ctx)
}
```

### 第八阶段：ForkchoiceUpdate 触发下一轮

`tryUpdateEngine` 内部发送 ForkchoiceUpdate（不带 PayloadAttributes），纯粹用于同步链头状态：

```go
// op-node/rollup/engine/engine_controller.go
func (e *EngineController) tryUpdateEngineInternal(ctx context.Context) error {
    fc := eth.ForkchoiceState{
        HeadBlockHash:      e.unsafeHead.Hash,
        SafeBlockHash:      e.safeHead.Hash,
        FinalizedBlockHash: e.finalizedHead.Hash,
    }
    fcRes, err := e.engine.ForkchoiceUpdate(ctx, &fc, nil)  // nil = 不启动新构建
    // ...
    e.requestForkchoiceUpdate(ctx)  // 发出 ForkchoiceUpdateEvent
}
```

排序器收到 `ForkchoiceUpdateEvent`，根据新的头部计算下一次出块时间：

```go
// op-node/rollup/sequencing/sequencer.go
func (d *Sequencer) onForkchoiceUpdate(x engine.ForkchoiceUpdateEvent) {
    // 1. Safe lag 检查
    if maxSafeLag > 0 && x.SafeL2Head.Number+maxSafeLag <= x.UnsafeL2Head.Number {
        d.nextActionOK = false  // 暂停出块
    }
    // 2. 清理过期构建作业
    if d.latest.Onto.Number < x.UnsafeL2Head.Number {
        d.latest = BuildingState{}
    }
    // 3. 计算下一次出块时间
    payloadTime := time.Unix(int64(x.UnsafeL2Head.Time+d.rollupCfg.BlockTime), 0)
    remainingTime := payloadTime.Sub(now)
    if remainingTime > blockTime {
        d.nextAction = payloadTime.Add(-blockTime)
    } else {
        d.nextAction = now  // 立即开始
    }
}
```

至此一个完整的出块周期结束，排序器等待下一次定时器触发。

---

## Engine API 交互协议

op-node 与 op-geth 之间的交互通过三个核心 Engine API 完成：

### 交互总览

```
op-node (CL)                           op-geth (EL)
    │                                      │
    │── ForkchoiceUpdate(fc, attrs) ──────>│  启动区块构建
    │<──── {PayloadID} ───────────────────│
    │                                      │
    │   ... EL 异步构建区块 ...              │
    │                                      │
    │── GetPayload(payloadID) ───────────>│  获取构建结果
    │<──── {ExecutionPayloadEnvelope} ────│
    │                                      │
    │── NewPayload(payload) ─────────────>│  插入区块
    │<──── {PayloadStatusV1} ─────────────│
    │                                      │
    │── ForkchoiceUpdate(fc, nil) ────────>│  更新链头状态
    │<──── {PayloadStatusV1} ─────────────│
```

### 1. ForkchoiceUpdate（带 Attributes）

**用途**：同时更新链头状态并启动新区块构建

**调用时机**：`BuildStartEvent` 处理中

**关键语义**：
- `HeadBlockHash` 设为要构建的**父区块**的哈希（非当前 unsafe head）
- `PayloadAttributes.Transactions` 包含强制交易
- 返回的 `PayloadID` 是后续 GetPayload 的凭证

### 2. GetPayload

**用途**：获取正在构建/已完成的区块

**调用时机**：`BuildSealEvent` 处理中

**关键语义**：
- op-geth 返回当前最佳的区块（包含尽可能多的交易）
- 如果构建作业已超时或被取消，返回 `UnknownPayload` 错误
- 返回的 `ExecutionPayloadEnvelope` 包含完整区块数据

### 3. NewPayload

**用途**：将已构建的区块插入执行引擎

**调用时机**：`PayloadProcessEvent` 处理中

**返回状态**：
| 状态 | 含义 | op-node 行为 |
|------|------|-------------|
| `VALID` | 区块有效 | 发出 PayloadSuccessEvent |
| `INVALID` | 区块无效 | 发出 PayloadInvalidEvent |
| `SYNCING` | EL 正在同步 | 视为临时错误，重试 |
| `ACCEPTED` | 已接收但未完全验证 | 视为临时错误，重试 |

### 4. ForkchoiceUpdate（不带 Attributes）

**用途**：纯粹的链头状态同步

**调用时机**：区块成功插入后的 `tryUpdateEngine`

**关键语义**：
- `attrs = nil`，不启动新构建
- 将 unsafe/safe/finalized 三元组通知给 EL
- EL 据此进行链头切换和状态修剪

---

## 区块安全级别演进

L2 区块从产生到最终确认，经历多个安全级别的递进：

```
                         排序器出块
                            │
                            ▼
┌──────────┐  NewPayload  ┌──────────────┐  L1 batch    ┌──────────────┐
│ 构建+密封 │ ──────────> │  Unsafe      │ ──提交────> │ Pending Safe │
└──────────┘              │  (不安全)     │              │ (待安全)      │
                          └──────────────┘              └──────────────┘
                                                              │
                                                    span batch 完成
                                                              ▼
                          ┌──────────────┐  跨链验证   ┌──────────────┐
                          │  Safe        │ <────────── │ Local Safe   │
                          │  (安全)      │              │ (本地安全)    │
                          └──────────────┘              └──────────────┘
                                │
                         L1 finalized
                                ▼
                          ┌──────────────┐
                          │  Finalized   │
                          │  (最终确认)   │
                          └──────────────┘
```

### 各级别定义

| 安全级别 | 含义 | 对应字段 |
|---------|------|---------|
| **Unsafe** | 已执行但未提交到 L1 | `unsafeHead` |
| **Cross-Unsafe** | 跨链验证的 unsafe（interop） | `crossUnsafeHead` |
| **Pending Safe** | 已从 L1 batch 派生，span batch 进行中 | `pendingSafeHead` |
| **Local Safe** | span batch 完成，本地验证通过 | `localSafeHead` |
| **Safe（Cross Safe）** | 跨链依赖验证通过 | `safeHead` |
| **Finalized** | 所基于的 L1 数据已 finalized | `finalizedHead` |

### EngineController 中的头部状态管理

```go
// op-node/rollup/engine/engine_controller.go
type EngineController struct {
    // 各级别头部
    unsafeHead       eth.L2BlockRef  // 最新已执行的区块
    crossUnsafeHead  eth.L2BlockRef  // 跨链验证的 unsafe
    pendingSafeHead  eth.L2BlockRef  // span batch 中间状态
    localSafeHead    eth.L2BlockRef  // 本地派生完成
    safeHead         eth.L2BlockRef  // 跨链验证安全
    finalizedHead    eth.L2BlockRef  // L1 finalized
    backupUnsafeHead eth.L2BlockRef  // unsafe 回退备份

    needFCUCall bool  // 是否需要调用 ForkchoiceUpdate
    // ...
}
```

### 头部更新流程

**Unsafe 更新**（每个新区块）：

```go
func (e *EngineController) tryUpdateUnsafe(ctx context.Context, ref eth.L2BlockRef) {
    if e.unsafeHead.Number >= ref.Number {
        e.SetBackupUnsafeL2Head(e.unsafeHead, false)  // 备份旧 head
    }
    e.SetUnsafeHead(ref)
    e.emitter.Emit(ctx, UnsafeUpdateEvent{Ref: ref})
}
```

**Local Safe 更新**（派生完成时）：

```go
func (e *EngineController) tryUpdateLocalSafe(ctx context.Context, ref eth.L2BlockRef,
    concluding bool, source eth.L1BlockRef) {
    if concluding && ref.Number > e.localSafeHead.Number {
        e.SetLocalSafeHead(ref)
        e.emitter.Emit(ctx, LocalSafeUpdateEvent{Ref: ref, Source: source})
    }
}
```

**Safe 更新**（跨链验证通过）：

```go
func (e *EngineController) PromoteSafe(ctx context.Context, ref eth.L2BlockRef, source eth.L1BlockRef) {
    e.SetSafeHead(ref)
    e.emitter.Emit(ctx, SafeDerivedEvent{Safe: ref, Source: source})
    e.tryUpdateEngine(ctx)  // 发送 ForkchoiceUpdate 通知 EL
}
```

**Finalized 更新**（L1 finalized 后）：

```go
func (e *EngineController) promoteFinalized(ctx context.Context, ref eth.L2BlockRef) {
    if ref.Number < e.finalizedHead.Number { return }  // 不能倒退
    if ref.Number > e.safeHead.Number { return }       // 必须先 safe
    e.SetFinalizedHead(ref)
    e.emitter.Emit(ctx, FinalizedUpdateEvent{Ref: ref})
    e.tryUpdateEngine(ctx)
}
```

---

## 派生模式：从 L1 数据重建区块

验证者节点不运行排序器，而是通过**派生管道（Derivation Pipeline）**从 L1 数据重建 L2 区块。

### 派生管道概览

```
L1 链
  │
  ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ L1 Traversal │ -> │ L1 Retrieval │ -> │ Frame Queue  │
│ (遍历 L1)     │    │ (获取数据)    │    │ (帧队列)     │
└──────────────┘    └──────────────┘    └──────────────┘
                                              │
                                              ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ Attributes   │ <- │ Batch Stage  │ <- │ Channel Bank │
│ (构建属性)    │    │ (批次处理)    │    │ (通道组装)    │
└──────────────┘    └──────────────┘    └──────────────┘
        │
        ▼
  PayloadAttributes
  (DerivedFrom != 零值)
        │
        ▼
  EngineController
  (与排序器共用相同路径)
```

### 排序器模式 vs 派生模式的关键差异

**构建过程相同**，差异在于 PayloadAttributes 的来源和后续处理：

```go
// 排序器模式 —— startBuildingBlock()
withParent := &derive.AttributesWithParent{
    DerivedFrom: eth.L1BlockRef{},  // 零值 → 不提升 safe
    Concluding:  false,
}

// 派生模式 —— DerivationPipeline 输出
withParent := &derive.AttributesWithParent{
    DerivedFrom: l1Source,           // 非零 → 可提升 safe
    Concluding:  isLastInBatch,      // span batch 最后一个 → 提升 local-safe
}
```

在 `onPayloadSuccess` 中的区分处理：

```go
func (e *EngineController) onPayloadSuccess(ctx context.Context, ev PayloadSuccessEvent) {
    e.tryUpdateUnsafe(ctx, ev.Ref)     // 两种模式都更新 unsafe

    if ev.DerivedFrom != (eth.L1BlockRef{}) {
        // 仅派生模式执行以下操作
        e.tryUpdatePendingSafe(...)     // 更新 pending-safe
        e.tryUpdateLocalSafe(...)       // 如果 concluding=true，更新 local-safe
    }
    e.tryUpdateEngineInternal(ctx)      // 两种模式都同步 FCU
}
```

---

## 区块内交易组装与排序

### 交易排序规则

一个 L2 区块内的交易严格按以下顺序排列：

```
┌─────────────────────────────────────────────────────┐
│ 位置 0: L1 Info Deposit Transaction                 │  ← 必须，每个区块恰好一个
│   - 包含 L1 区块上下文（basefee, blobBaseFee 等）     │
│   - 写入 L2 的 L1Block 预部署合约                     │
├─────────────────────────────────────────────────────┤
│ 位置 1..N: User Deposit Transactions                │  ← 可选，仅在 epoch 首区块
│   - 来自 L1 OptimismPortal2 的 TransactionDeposited  │
│   - 按 L1 日志顺序排列                               │
├─────────────────────────────────────────────────────┤
│ 位置 N+1..M: Hardfork Upgrade Transactions          │  ← 可选，仅在硬分叉激活区块
│   - 系统合约升级交易                                   │
├─────────────────────────────────────────────────────┤
│ 位置 M+1..: User L2 Transactions                   │  ← 可选，来自 op-geth 交易池
│   - 仅当 NoTxPool = false 时才包含                    │
│   - 由 op-geth 按 gas price 排序选择                  │
└─────────────────────────────────────────────────────┘
```

### PayloadAttributes 中的 Transactions 构建

```go
// op-node/rollup/derive/attributes.go
func (ba *FetchingAttributesBuilder) PreparePayloadAttributes(...) {
    // 1. L1 Info Deposit Tx
    l1InfoTx, _ := L1InfoDepositBytes(ba.rollupCfg, ba.l1ChainConfig, sysConfig,
        seqNumber, l1Info, nextL2Time)

    // 2. User Deposit Txs（仅 epoch 首区块）
    if l2Parent.L1Origin.Number != epoch.Number {
        deposits, _ := DeriveDeposits(receipts, ba.rollupCfg.DepositContractAddress)
        depositTxs = deposits
    }

    // 3. Hardfork Upgrade Txs
    if ba.rollupCfg.IsEcotoneActivationBlock(nextL2Time) {
        upgradeTxs, _ = EcotoneNetworkUpgradeTransactions()
    }
    // ... Fjord, Isthmus, Jovian, Interop 类似

    // 组装
    txs := make([]hexutil.Bytes, 0, 1+len(depositTxs)+len(upgradeTxs))
    txs = append(txs, l1InfoTx)
    txs = append(txs, depositTxs...)
    txs = append(txs, upgradeTxs...)

    return &eth.PayloadAttributes{
        Transactions: txs,
        NoTxPool:     true,  // 默认不从交易池取交易，排序器会覆盖此值
        // ...
    }
}
```

### op-geth 内部的区块构建

op-geth 收到带 Attributes 的 ForkchoiceUpdate 后：
1. 创建新的区块构建作业
2. 执行 `Transactions` 中的所有强制交易
3. 如果 `NoTxPool = false`，从交易池中按 gas price 选择交易追加
4. 计算 StateRoot、ReceiptsRoot 等
5. 将构建结果缓存，等待 GetPayload 请求

---

## 完整时序图

### 排序器出块时序

```
  Driver         Sequencer          EngineController         op-geth (EL)
    │                │                     │                      │
    │ sequencerTimer │                     │                      │
    │    expires     │                     │                      │
    ├───────────────>│                     │                      │
    │ SequencerAction│                     │                      │
    │   Event        │                     │                      │
    │                │                     │                      │
    │                │ startBuildingBlock() │                      │
    │                │  ┌─────────────────┐│                      │
    │                │  │FindL1Origin     ││                      │
    │                │  │PreparePayload   ││                      │
    │                │  │Attributes       ││                      │
    │                │  └─────────────────┘│                      │
    │                │                     │                      │
    │                │── BuildStartEvent ->│                      │
    │                │                     │── FCU(fc, attrs) ──>│
    │                │                     │<── {PayloadID} ─────│
    │                │                     │                      │
    │                │<─ BuildStartedEvent─│                      │
    │                │                     │            ┌─────────┤
    │                │  (schedule seal     │            │ EL 异步  │
    │                │   @ T - 50ms)       │            │ 构建区块 │
    │                │                     │            │(选择交易 │
    │                │                     │            │ 执行状态)│
    │ sequencerTimer │                     │            └─────────┤
    │    expires     │                     │                      │
    ├───────────────>│                     │                      │
    │ SequencerAction│                     │                      │
    │                │── BuildSealEvent -->│                      │
    │                │                     │── GetPayload ──────>│
    │                │                     │<── {Envelope} ──────│
    │                │                     │                      │
    │                │                     │ sanityCheck()        │
    │                │                     │                      │
    │                │<─ BuildSealedEvent──│                      │
    │                │                     │                      │
    │                │ onBuildSealed():     │                      │
    │                │  1. Conductor commit │                      │
    │                │  2. P2P gossip       │                      │
    │                │  3. PayloadProcess   │                      │
    │                │                     │                      │
    │                │── PayloadProcess -->│                      │
    │                │     Event           │── NewPayload ──────>│
    │                │                     │<── {VALID} ─────────│
    │                │                     │                      │
    │                │                     │ updateUnsafeHead     │
    │                │                     │                      │
    │                │                     │── FCU(fc, nil) ────>│
    │                │                     │<── {VALID} ─────────│
    │                │                     │                      │
    │                │<─ ForkchoiceUpdate──│                      │
    │                │     Event           │                      │
    │                │                     │                      │
    │                │ 计算下一次出块时间    │                      │
    │                │                     │                      │
    └── 下一轮 ──────┘                     │                      │
```

### 区块安全级别演进时序

```
  Sequencer    EngineController    Batcher      L1 Chain     Finalizer
     │               │               │             │             │
     │  出块+插入     │               │             │             │
     ├──────────────>│               │             │             │
     │               │ unsafe ← new  │             │             │
     │               │               │             │             │
     │               │               │ 提交 batch  │             │
     │               │               ├────────────>│             │
     │               │               │             │             │
     │  (派生管道从 L1 重新推导)       │             │             │
     │               │               │             │             │
     │               │ pending-safe   │             │             │
     │               │ (span batch中) │             │             │
     │               │               │             │             │
     │               │ local-safe     │             │             │
     │               │ (batch 完成)   │             │             │
     │               │               │             │             │
     │               │               │ (跨链验证)   │             │
     │               │ safe           │             │             │
     │               │ (cross-safe)   │             │             │
     │               │               │             │             │
     │               │               │             │ L1 finalized│
     │               │               │             ├────────────>│
     │               │               │             │             │
     │               │ finalized     │             │             │
     │               │<──────────────┼─────────────┼─────────────┤
     │               │               │             │             │
```

---

## 错误处理与恢复机制

### 错误分类

区块构建过程中的错误按严重程度分为三类：

| 类型 | 含义 | 处理方式 |
|------|------|---------|
| **Temporary** | 临时性错误（网络/RPC 超时） | 退避重试（1s 或 30s） |
| **Reset** | 状态不一致（L1 重组） | 触发系统重置 |
| **Critical** | 不可恢复错误 | 节点退出 |

### 排序器错误处理

```go
func (d *Sequencer) handleInvalid() {
    d.metrics.RecordSequencingError()
    d.latest = BuildingState{}       // 清除构建状态
    d.asyncGossip.Clear()            // 清除广播缓冲
    blockTime := time.Duration(d.rollupCfg.BlockTime) * time.Second
    d.nextAction = d.timeNow().Add(blockTime)  // 一个区块时间后重试
    d.nextActionOK = d.active.Load()
}
```

### 临时错误退避策略

```go
func (d *Sequencer) onEngineTemporaryError(x rollup.EngineTemporaryErrorEvent) {
    if errors.Is(x.Err, engine.ErrEngineSyncing) {
        d.nextAction = d.timeNow().Add(30 * time.Second)  // 同步中，长退避
    } else {
        d.nextAction = d.timeNow().Add(time.Second)        // 一般错误，短退避
    }
    // 不取消进行中的构建 —— 它可能仍然能完成
    if d.latest.Info == (eth.PayloadInfo{}) {
        d.latest = BuildingState{}  // 没有 PayloadID 的话，清除重新开始
    }
}
```

### 重置流程

```go
func (d *Sequencer) onReset(x rollup.ResetEvent) {
    // 1. 取消正在进行的构建
    if d.latest.Info != (eth.PayloadInfo{}) {
        d.emitter.Emit(d.ctx, engine.BuildCancelEvent{Info: d.latest.Info})
    }
    d.latest = BuildingState{}
    d.nextActionOK = false  // 等待重置确认
}

func (d *Sequencer) onEngineResetConfirmedEvent(engine.EngineResetConfirmedEvent) {
    d.nextActionOK = d.active.Load()
    d.nextAction = d.timeNow().Add(time.Second * time.Duration(d.rollupCfg.BlockTime))
}
```

### Gossip 缓冲恢复

如果区块密封成功并广播，但本地插入失败（临时错误），排序器在下一次 action 时会尝试从 gossip 缓冲恢复：

```go
func (d *Sequencer) onSequencerAction(ev SequencerActionEvent) {
    payload := d.asyncGossip.Get()
    if payload != nil {
        // 已有广播过的负载，重新尝试插入
        d.emitter.Emit(d.ctx, engine.PayloadProcessEvent{
            Envelope: payload,
            Ref:      ref,
        })
        return
    }
    // 否则：密封现有构建 或 开始新构建
}
```

### Safe Lag 保护

```go
func (d *Sequencer) onForkchoiceUpdate(x engine.ForkchoiceUpdateEvent) {
    if maxSafeLag := d.maxSafeLag.Load(); maxSafeLag > 0 &&
        x.SafeL2Head.Number+maxSafeLag <= x.UnsafeL2Head.Number {
        d.nextActionOK = false  // 暂停出块，等待 batcher 追上
    }
}
```

---

## 关键源码解析

### 1. ExecEngine 接口 —— op-node 与 op-geth 的桥梁

```go
// op-node/rollup/engine/engine_controller.go
type ExecEngine interface {
    GetPayload(ctx context.Context, payloadInfo eth.PayloadInfo) (*eth.ExecutionPayloadEnvelope, error)
    ForkchoiceUpdate(ctx context.Context, state *eth.ForkchoiceState, attr *eth.PayloadAttributes) (*eth.ForkchoiceUpdatedResult, error)
    NewPayload(ctx context.Context, payload *eth.ExecutionPayload, parentBeaconBlockRoot *common.Hash) (*eth.PayloadStatusV1, error)
    L2BlockRefByLabel(ctx context.Context, label eth.BlockLabel) (eth.L2BlockRef, error)
    L2BlockRefByHash(ctx context.Context, hash common.Hash) (eth.L2BlockRef, error)
    L2BlockRefByNumber(ctx context.Context, num uint64) (eth.L2BlockRef, error)
}
```

### 2. Sequencer 核心事件处理

排序器的 `OnEvent` 函数是一个中央事件分发器，处理区块构建生命周期中的所有事件：

```go
// op-node/rollup/sequencing/sequencer.go
func (d *Sequencer) OnEvent(ctx context.Context, ev event.Event) bool {
    switch x := ev.(type) {
    case engine.BuildStartedEvent:           d.onBuildStarted(x)
    case engine.InvalidPayloadAttributesEvent: d.onInvalidPayloadAttributes(x)
    case engine.BuildSealedEvent:            d.onBuildSealed(x)
    case engine.PayloadSealInvalidEvent:     d.onPayloadSealInvalid(x)
    case engine.PayloadSealExpiredErrorEvent: d.onPayloadSealExpiredError(x)
    case engine.PayloadInvalidEvent:         d.onPayloadInvalid(x)
    case engine.PayloadSuccessEvent:         d.onPayloadSuccess(x)
    case SequencerActionEvent:               d.onSequencerAction(x)
    case rollup.EngineTemporaryErrorEvent:   d.onEngineTemporaryError(x)
    case rollup.ResetEvent:                  d.onReset(x)
    case engine.EngineResetConfirmedEvent:   d.onEngineResetConfirmedEvent(x)
    case engine.ForkchoiceUpdateEvent:       d.onForkchoiceUpdate(x)
    case engine.ForkchoiceUpdateInitEvent:   d.onForkchoiceUpdate(...)
    }
}
```

### 3. 异步 P2P 广播

```go
// op-node/rollup/async/asyncgossiper.go
type SimpleAsyncGossiper struct {
    set            chan *eth.ExecutionPayloadEnvelope  // 新负载通道
    get            chan chan *eth.ExecutionPayloadEnvelope  // 获取负载通道
    clear          chan struct{}                       // 清除通道
    currentPayload *eth.ExecutionPayloadEnvelope       // 当前负载
    net            Network                            // P2P 网络接口
}

func (p *SimpleAsyncGossiper) gossip(ctx context.Context, payload *eth.ExecutionPayloadEnvelope) {
    if err := p.net.SignAndPublishL2Payload(ctx, payload); err == nil {
        p.currentPayload = payload  // 广播成功才保存
    }
}
```

`SimpleAsyncGossiper` 在独立的 goroutine 中运行，通过 channel 与排序器通信。只有广播成功的负载才会被缓存，供后续恢复使用。

### 4. tryUpdateEngine —— ForkchoiceUpdate 同步

```go
// op-node/rollup/engine/engine_controller.go
func (e *EngineController) tryUpdateEngineInternal(ctx context.Context) error {
    if !e.needFCUCall { return ErrNoFCUNeeded }

    fc := eth.ForkchoiceState{
        HeadBlockHash:      e.unsafeHead.Hash,
        SafeBlockHash:      e.safeHead.Hash,
        FinalizedBlockHash: e.finalizedHead.Hash,
    }
    fcRes, err := e.engine.ForkchoiceUpdate(ctx, &fc, nil)
    if fcRes.PayloadStatus.Status == eth.ExecutionValid {
        e.requestForkchoiceUpdate(ctx)  // 通知其他组件
    }
    e.needFCUCall = false
    return nil
}
```

`needFCUCall` 是一个去抖标志，避免在短时间内多次头部更新时重复调用 Engine API。

---

## 模块交互全景图

```
                     ┌──────────────────────────────────────────────────────────┐
                     │                      op-node (CL)                       │
                     │                                                          │
   L1 Chain ────────>│  ┌─────────────────┐      ┌──────────────────────┐      │
   (区块+收据)        │  │ Derivation      │      │   Sequencer          │      │
                     │  │ Pipeline        │      │                      │      │
                     │  │                 │      │  L1OriginSelector    │      │
                     │  │ L1Traversal     │      │  AttributesBuilder   │      │
                     │  │ → FrameQueue    │      │  BuildingState       │      │
                     │  │ → ChannelBank   │      │  AsyncGossiper ──────┼──────┼──> P2P Network
                     │  │ → BatchStage    │      │                      │      │   (gossip 区块)
                     │  │ → Attributes    │      └──────────┬───────────┘      │
                     │  └────────┬────────┘                 │                  │
                     │           │                          │                  │
                     │           │ PayloadAttributes        │ PayloadAttributes│
                     │           │ (DerivedFrom≠零)         │ (DerivedFrom=零) │
                     │           │                          │                  │
                     │           ▼                          ▼                  │
                     │  ┌──────────────────────────────────────────────┐       │
                     │  │            EngineController                  │       │
                     │  │                                              │       │
                     │  │  unsafeHead / safeHead / finalizedHead      │       │
                     │  │                                              │       │
                     │  │  onBuildStart() ──── ForkchoiceUpdate+attrs │       │
                     │  │  onBuildSeal()  ──── GetPayload             │       │
                     │  │  onPayloadProcess() ─ NewPayload            │       │
                     │  │  tryUpdateEngine() ── ForkchoiceUpdate      │       │
                     │  └────────────────────────┬─────────────────────┘       │
                     │                           │ Engine API (JSON-RPC)       │
                     └───────────────────────────┼────────────────────────────┘
                                                 │
                                                 ▼
                     ┌───────────────────────────────────────────────────────────┐
                     │                      op-geth (EL)                         │
                     │                                                           │
                     │  ┌─────────────────┐    ┌──────────────────────────────┐ │
                     │  │  Transaction    │    │    Block Builder              │ │
                     │  │  Pool (mempool) │───>│                              │ │
                     │  │                 │    │  1. 执行 forced txs          │ │
  用户 ──RPC──>      │  │  用户提交的      │    │  2. 选择 pool txs            │ │
  L2 交易            │  │  L2 交易        │    │  3. 执行 + 计算 stateRoot    │ │
                     │  └─────────────────┘    │  4. 缓存 ExecutionPayload   │ │
                     │                         └──────────────────────────────┘ │
                     │                                                           │
                     │  ┌───────────────────────────────────────────────────────┐│
                     │  │              State Database                           ││
                     │  │  账户状态 / 合约存储 / 状态树                            ││
                     │  └───────────────────────────────────────────────────────┘│
                     └───────────────────────────────────────────────────────────┘
```

---

## 附录：关键文件索引

| 文件 | 功能 |
|------|------|
| `op-node/rollup/driver/driver.go` | Driver 主循环、排序器调度 |
| `op-node/rollup/sequencing/sequencer.go` | 排序器核心状态机 |
| `op-node/rollup/sequencing/origin_selector.go` | L1 Origin 选择算法 |
| `op-node/rollup/engine/engine_controller.go` | 引擎控制器（头部管理、Engine API 封装） |
| `op-node/rollup/engine/build_start.go` | BuildStartEvent 处理（ForkchoiceUpdate+attrs） |
| `op-node/rollup/engine/build_seal.go` | BuildSealEvent 处理（GetPayload + sanity check） |
| `op-node/rollup/engine/payload_process.go` | PayloadProcessEvent 处理（NewPayload） |
| `op-node/rollup/engine/payload_success.go` | PayloadSuccessEvent 处理（更新头部状态） |
| `op-node/rollup/engine/events.go` | 引擎事件类型定义 |
| `op-node/rollup/derive/attributes.go` | PreparePayloadAttributes 实现 |
| `op-node/rollup/derive/deposits.go` | L1 存款交易派生 |
| `op-node/rollup/derive/l1_block_info.go` | L1 Info Deposit 交易构建 |
| `op-node/rollup/async/asyncgossiper.go` | 异步 P2P 广播 |
| `op-service/eth/types.go` | 核心数据结构（Payload, ForkchoiceState 等） |
| `op-service/eth/id.go` | L1BlockRef, L2BlockRef 定义 |
