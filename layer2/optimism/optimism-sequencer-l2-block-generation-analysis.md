# Sequencer 如何产生一个新的 L2 区块

本文深入分析当前 Optimism 代码库中 Sequencer 产生 L2 区块的完整流程。当前架构采用**事件驱动（Event-Driven）**模型，排序器通过发出/接收事件与执行引擎交互，实现了清晰的关注点分离和异步处理能力。

> 本文所有代码引用均基于当前代码库源码验证，文件路径和行号可直接定位。

## 目录

1. [宏观概览](#宏观概览)
2. [Driver 事件循环与排序器调度](#driver-事件循环与排序器调度)
3. [第一步：开始构建区块 (startBuildingBlock)](#第一步开始构建区块-startbuildingblock)
4. [第二步：引擎处理 BuildStartEvent](#第二步引擎处理-buildstartevent)
5. [第三步：排序器收到 BuildStartedEvent](#第三步排序器收到-buildstartedevent)
6. [第四步：密封区块 (BuildSealEvent)](#第四步密封区块-buildsealevent)
7. [第五步：引擎密封并返回 BuildSealedEvent](#第五步引擎密封并返回-buildsealedevent)
8. [第六步：排序器处理密封结果 (onBuildSealed)](#第六步排序器处理密封结果-onbuildsealed)
9. [第七步：区块插入本地链 (PayloadProcess → PayloadSuccess)](#第七步区块插入本地链-payloadprocess--payloadsuccess)
10. [第八步：ForkchoiceUpdate 启动下一轮](#第八步forkchoiceupdate-启动下一轮)
11. [关键概念详解](#关键概念详解)
12. [完整事件流总结](#完整事件流总结)

---

## 宏观概览

在宏观层面，Sequencer 在 L2 区块生成中的角色是：**构建一个包含系统存款交易的 Payload Attributes 模板，发送给执行引擎（EL），由 EL 从交易池中提取用户交易并完成实际的区块构建。**

一个完整的出块周期可以概括为以下阶段：

```
┌─────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│  查找 L1     │     │  准备 Payload │     │  引擎开始     │     │  密封区块     │     │  广播 + 插入 │
│  Origin 区块 │ ──> │  Attributes  │ ──> │  构建区块     │ ──> │  (Seal)      │ ──> │  到本地链    │
└─────────────┘     └──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
```

整个过程通过以下事件流串联：

```
Sequencer                           Engine (EngineController)
   │                                       │
   │──── BuildStartEvent ────────────────>│  (ForkchoiceUpdate + 开始构建)
   │                                       │
   │<──── BuildStartedEvent ──────────────│  (返回 PayloadID)
   │                                       │
   │  (等待密封时机)                         │
   │                                       │
   │──── BuildSealEvent ─────────────────>│  (GetPayload 获取完成的区块)
   │                                       │
   │<──── BuildSealedEvent ───────────────│  (返回密封的区块)
   │                                       │
   │  (Conductor 共识 + P2P 广播)           │
   │                                       │
   │──── PayloadProcessEvent ────────────>│  (NewPayload 插入区块)
   │                                       │
   │<──── PayloadSuccessEvent ────────────│  (更新 unsafe head)
   │                                       │
   │<──── ForkchoiceUpdateEvent ──────────│  (通知新的链头)
   │                                       │
   │  (调度下一个出块周期)                    │
```

> **Source Code**: [op-node/rollup/sequencing/sequencer.go](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/sequencer.go)

---

## Driver 事件循环与排序器调度

当 op-node 启动后，Driver 会启动一个 `eventLoop`。在这个循环中，Driver 负责排序器动作的调度。

> **Source Code**: [op-node/rollup/driver/driver.go#L242-L269](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/driver/driver.go#L242)

```go
sequencerTimer := time.NewTimer(0)
var sequencerCh <-chan time.Time
var prevTime time.Time
planSequencerAction := func() {
    nextAction, ok := s.sequencer.NextAction()
    if !ok {
        if sequencerCh != nil {
            s.log.Info("Sequencer paused until new events")
        }
        sequencerCh = nil
        return
    }
    if nextAction == prevTime {
        return
    }
    prevTime = nextAction
    sequencerCh = sequencerTimer.C
    if len(sequencerCh) > 0 {
        <-sequencerCh
    }
    delta := time.Until(nextAction)
    s.log.Info("Scheduled sequencer action", "delta", delta)
    sequencerTimer.Reset(delta)
}
```

### 调度逻辑

排序器内部维护了 `nextAction`（绝对时间）和 `nextActionOK`（是否有动作需要执行）两个状态。Driver 通过 `NextAction()` 读取这两个值：

> **Source Code**: [op-node/rollup/sequencing/sequencer.go#L888-L892](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/sequencer.go#L888)

```go
func (d *Sequencer) NextAction() (t time.Time, ok bool) {
    d.l.Lock()
    defer d.l.Unlock()
    return d.nextAction, d.nextActionOK
}
```

当定时器到达时间后，Driver 发出 `SequencerActionEvent`：

> **Source Code**: [op-node/rollup/driver/driver.go#L326-L328](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/driver/driver.go#L326)

```go
select {
case <-sequencerCh:
    s.emitter.Emit(s.driverCtx, sequencing.SequencerActionEvent{})
```

排序器收到 `SequencerActionEvent` 后，根据当前状态决定下一步操作。

---

## 第一步：开始构建区块 (startBuildingBlock)

当排序器收到 `SequencerActionEvent` 且当前没有进行中的构建作业时，会调用 `startBuildingBlock` 开始一个新的出块流程。

> **Source Code**: [op-node/rollup/sequencing/sequencer.go#L575-L620](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/sequencer.go#L575)

`onSequencerAction` 按三个优先级决策：

```go
func (d *Sequencer) onSequencerAction(ev SequencerActionEvent) {
    // 优先级 1：检查 gossip 缓冲中是否有可重用的负载
    payload := d.asyncGossip.Get()
    if payload != nil {
        // 重用之前已广播但本地插入失败的负载，避免重复出块
        // ...
    } else {
        // 优先级 2：如果已经有构建作业在进行，发起密封请求
        if d.latest.Info != (eth.PayloadInfo{}) {
            d.emitter.Emit(d.ctx, engine.BuildSealEvent{...})
        } else if d.latest == (BuildingState{}) {
            // 优先级 3：如果没有任何构建作业，开始构建新区块
            d.startBuildingBlock()
        }
    }
}
```

### startBuildingBlock 的核心逻辑

> **Source Code**: [op-node/rollup/sequencing/sequencer.go#L757-L886](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/sequencer.go#L757)

这个函数完成以下关键步骤：

#### 1. 选择 L1 Origin

```go
l1Origin, err := d.l1OriginSelector.FindL1Origin(ctx, l2Head)
```

L1 Origin 是 L2 区块所引用的 L1 区块。选择逻辑在 `L1OriginSelector` 中实现：

> **Source Code**: [op-node/rollup/sequencing/origin_selector.go#L226-L277](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/origin_selector.go#L226)

选择算法的核心约束：

- **不能指向未来的 L1 区块**：`nextL2BlockTime >= nextL1Origin.Time`（不能产生负漂移）
- **Sequencer Drift 限制**：`nextL2BlockTime - currentL1Origin.Time <= MaxSequencerDrift`
- **缓存优化**：维护 `currentOrigin` 和 `nextOrigin` 缓存，避免频繁的 L1 RPC 调用

#### 2. 准备 Payload Attributes

```go
attrs, err := d.attrBuilder.PreparePayloadAttributes(fetchCtx, l2Head, l1Origin.ID())
```

`PreparePayloadAttributes` 是构建 L2 区块模板的核心函数：

> **Source Code**: [op-node/rollup/derive/attributes.go#L67-L213](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/derive/attributes.go#L67)

它的工作包括：

**a) 确定 epoch 和 deposit 交易：**

```go
if l2Parent.L1Origin.Number != epoch.Number {
    // 新 epoch 的第一个区块：获取 L1 收据，提取用户 deposit 交易
    info, receipts, err := ba.l1.FetchReceipts(ctx, epoch.Hash)
    deposits, err := DeriveDeposits(receipts, ba.rollupCfg.DepositContractAddress)
    seqNumber = 0
} else {
    // 同一 epoch 内的后续区块：无新 deposit
    depositTxs = nil
    seqNumber = l2Parent.SequenceNumber + 1
}
```

**b) 构建系统交易：**

```go
// L1 Info Deposit 交易（每个 L2 区块的第一笔交易）
l1InfoTx, err := L1InfoDepositBytes(ba.rollupCfg, ba.l1ChainConfig, sysConfig, seqNumber, l1Info, nextL2Time)

// 硬分叉升级交易（仅在激活区块中）
if ba.rollupCfg.IsEcotoneActivationBlock(nextL2Time) { upgradeTxs, _ = EcotoneNetworkUpgradeTransactions() }
if ba.rollupCfg.IsFjordActivationBlock(nextL2Time) { ... }
if ba.rollupCfg.IsIsthmusActivationBlock(nextL2Time) { ... }
if ba.rollupCfg.IsJovianActivationBlock(nextL2Time) { ... }
if ba.rollupCfg.IsInteropActivationBlock(nextL2Time) { ... }
```

**c) 组装最终的 PayloadAttributes：**

```go
return &eth.PayloadAttributes{
    Timestamp:             hexutil.Uint64(nextL2Time),
    PrevRandao:            eth.Bytes32(l1Info.MixDigest()),
    SuggestedFeeRecipient: predeploys.SequencerFeeVaultAddr,
    Transactions:          txs,        // [l1InfoTx, deposits..., upgradeTxs...]
    NoTxPool:              true,       // 排序器后续会根据条件修改
    GasLimit:              &sysConfig.GasLimit,
    Withdrawals:           withdrawals, // Canyon 后为空列表
    ParentBeaconBlockRoot: parentBeaconRoot, // Ecotone 后
    EIP1559Params:         ...,        // Holocene 后
    MinBaseFee:            ...,        // Jovian 后
}, nil
```

> 注意：`NoTxPool` 默认设为 `true`，排序器随后会根据条件将其改为 `false`（允许 EL 从交易池获取交易）。

#### 3. 设置 NoTxPool

回到 `startBuildingBlock`，排序器对 `NoTxPool` 进行最终判定：

> **Source Code**: [op-node/rollup/sequencing/sequencer.go#L822-L862](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/sequencer.go#L822)

```go
// Sequencer Drift：如果 L2 时间戳超出 L1 origin 时间 + MaxSequencerDrift，产生空区块
attrs.NoTxPool = uint64(attrs.Timestamp) > l1Origin.Time+d.spec.MaxSequencerDrift(l1Origin.Time)

// 硬分叉激活区块：不包含交易池交易
if d.rollupCfg.IsEcotoneActivationBlock(uint64(attrs.Timestamp)) { attrs.NoTxPool = true }
if d.rollupCfg.IsFjordActivationBlock(uint64(attrs.Timestamp))   { attrs.NoTxPool = true }
if d.rollupCfg.IsIsthmusActivationBlock(uint64(attrs.Timestamp)) { attrs.NoTxPool = true }
if d.rollupCfg.IsJovianActivationBlock(uint64(attrs.Timestamp))  { attrs.NoTxPool = true }
if d.rollupCfg.IsInteropActivationBlock(uint64(attrs.Timestamp)) { attrs.NoTxPool = true }

// Granite 激活区块是例外：允许包含交易池交易
if d.rollupCfg.IsGraniteActivationBlock(uint64(attrs.Timestamp)) {
    d.log.Info("Sequencing Granite upgrade block")
}

// 恢复模式：不包含用户交易
if recoverMode { attrs.NoTxPool = true }
```

#### 4. 发出 BuildStartEvent

```go
withParent := &derive.AttributesWithParent{
    Attributes:  attrs,
    Parent:      l2Head,
    Concluding:  false,
    DerivedFrom: eth.L1BlockRef{}, // 零值，表明这是排序器发起的（非派生管道）
}

d.nextActionOK = false  // 等待构建结果，暂停调度
d.latest = BuildingState{Onto: l2Head}  // 记录构建目标

d.emitter.Emit(d.ctx, engine.BuildStartEvent{
    Attributes: withParent,
})
```

---

## 第二步：引擎处理 BuildStartEvent

引擎控制器（`EngineController`）收到 `BuildStartEvent` 后，通过 Engine API 调用执行引擎：

> **Source Code**: [op-node/rollup/engine/build_start.go#L21-L81](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/engine/build_start.go#L21)

```go
func (e *EngineController) onBuildStart(ctx context.Context, ev BuildStartEvent) {
    // 1. 构建 ForkchoiceState
    fc := eth.ForkchoiceState{
        HeadBlockHash:      ev.Attributes.Parent.Hash,
        SafeBlockHash:      e.safeHead.Hash,
        FinalizedBlockHash: e.finalizedHead.Hash,
    }

    // 2. 调用 engine_forkchoiceUpdatedV2/V3（携带 PayloadAttributes）
    id, errTyp, err := e.startPayload(rpcCtx, fc, ev.Attributes.Attributes)

    // 3. 发出 ForkchoiceUpdateEvent（通知系统链头状态）
    e.emitter.Emit(ctx, fcEvent)

    // 4. 发出 BuildStartedEvent（携带 PayloadID）
    e.emitter.Emit(ctx, BuildStartedEvent{
        Info:         eth.PayloadInfo{ID: id, Timestamp: uint64(ev.Attributes.Attributes.Timestamp)},
        BuildStarted: buildStartTime,
        Parent:       ev.Attributes.Parent,
        DerivedFrom:  ev.Attributes.DerivedFrom,
    })
}
```

### startPayload 内部细节

> **Source Code**: [op-node/rollup/engine/engine_controller.go#L1092-L1127](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/engine/engine_controller.go#L1092)

```go
func (e *EngineController) startPayload(ctx context.Context, fc eth.ForkchoiceState, attrs *eth.PayloadAttributes) (id eth.PayloadID, ...) {
    fcRes, err := e.engine.ForkchoiceUpdate(ctx, &fc, attrs)
    // ...错误处理...
    switch fcRes.PayloadStatus.Status {
    case eth.ExecutionValid:
        return *fcRes.PayloadID, BlockInsertOK, nil
    case eth.ExecutionSyncing:
        return eth.PayloadID{}, BlockInsertTemporaryErr, ErrEngineSyncing
    }
}
```

这一步对应 Engine API 规范中的 `engine_forkchoiceUpdatedV2/V3` 调用。执行引擎（如 op-geth/op-reth）收到请求后：

1. 更新 Fork Choice 状态（head/safe/finalized）
2. 如果携带了 `PayloadAttributes`，开始一个后台的区块构建作业
3. 返回一个 `PayloadID`，后续可以通过这个 ID 获取构建结果

**在执行引擎（op-geth）中的行为：**

- 首先使用 `PayloadAttributes` 中的强制交易（`Transactions` 字段）构建一个初始区块
- 如果 `NoTxPool = false`，启动一个后台 goroutine，持续从交易池中选择高费用的交易来优化区块内容
- 这个后台优化在收到 `GetPayload` 请求时停止

---

## 第三步：排序器收到 BuildStartedEvent

排序器收到 `BuildStartedEvent` 后，验证事件有效性并调度密封时机：

> **Source Code**: [op-node/rollup/sequencing/sequencer.go#L385-L427](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/sequencer.go#L385)

```go
func (d *Sequencer) onBuildStarted(x engine.BuildStartedEvent) {
    // 排除非排序器发起的构建（派生管道发起的 DerivedFrom 非零）
    if x.DerivedFrom != (eth.L1BlockRef{}) {
        d.nextActionOK = false
        return
    }
    // 检查构建目标是否过期（链头是否已变化）
    if d.latest.Onto != x.Parent {
        d.emitter.Emit(d.ctx, engine.BuildCancelEvent{Info: x.Info})
        d.handleInvalid()
        return
    }

    // 记录构建作业信息
    d.latest.Info = x.Info
    d.latest.Started = x.BuildStarted

    // 调度密封时机
    now := d.timeNow()
    payloadTime := time.Unix(int64(x.Parent.Time+d.rollupCfg.BlockTime), 0)
    remainingTime := payloadTime.Sub(now)
    if remainingTime < d.sealingDuration {
        d.nextAction = now  // 时间不足，立即密封
    } else {
        d.nextAction = payloadTime.Add(-d.sealingDuration)  // 在目标时间前 50ms 开始密封
    }
}
```

### 密封时机的计算

```
当前时间                    密封开始时间          区块目标时间
   |                          |                    |
   |<--- 交易池收集交易 ------->|<- sealingDuration ->|
                                    (默认 50ms)
```

`sealingDuration` 默认为 50ms（`defaultSealingDuration`），这意味着排序器会尽可能给执行引擎更多时间从交易池收集交易，在区块目标时间前 50ms 才触发密封。

---

## 第四步：密封区块 (BuildSealEvent)

当密封时间到达时，Driver 再次发出 `SequencerActionEvent`，排序器此时发现 `d.latest.Info` 已有值（PayloadID 已知），进入优先级 2 的逻辑：

```go
// 优先级 2：如果已经有构建作业在进行，发起密封请求
if d.latest.Info != (eth.PayloadInfo{}) {
    d.nextActionOK = false
    d.emitter.Emit(d.ctx, engine.BuildSealEvent{
        Info:         d.latest.Info,
        BuildStarted: d.latest.Started,
        Concluding:   false,
        DerivedFrom:  eth.L1BlockRef{},
    })
}
```

---

## 第五步：引擎密封并返回 BuildSealedEvent

引擎控制器收到 `BuildSealEvent` 后，调用 `GetPayload` 获取已构建的区块：

> **Source Code**: [op-node/rollup/engine/build_seal.go#L58-L128](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/engine/build_seal.go#L58)

```go
func (e *EngineController) onBuildSeal(ctx context.Context, ev BuildSealEvent) {
    // 1. 调用 engine_getPayloadV2/V3 获取已构建的区块
    envelope, err := e.engine.GetPayload(rpcCtx, ev.Info)

    // 2. 完整性检查：至少有一笔交易，第一笔是 deposit 交易，deposit 在前面
    if err := sanityCheckPayload(envelope.ExecutionPayload); err != nil { ... }

    // 3. 将 payload 转换为 L2BlockRef
    ref, err := derive.PayloadToBlockRef(e.rollupCfg, envelope.ExecutionPayload)

    // 4. 记录指标（密封时间、构建时间、交易数量等）
    e.metrics.RecordSequencerSealingTime(sealTime)
    e.metrics.CountSequencedTxsInBlock(txnCount, depositCount)

    // 5. 发出 BuildSealedEvent
    e.emitter.Emit(ctx, BuildSealedEvent{
        Info:     ev.Info,
        Envelope: envelope,
        Ref:      ref,
    })
}
```

### Payload 完整性检查

> **Source Code**: [op-node/rollup/engine/build_seal.go#L158-L183](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/engine/build_seal.go#L158)

```go
func sanityCheckPayload(payload *eth.ExecutionPayload) error {
    if len(payload.Transactions) == 0 {
        return errors.New("no transactions in returned payload")
    }
    if payload.Transactions[0][0] != types.DepositTxType {
        return fmt.Errorf("first transaction was not deposit tx")
    }
    // 确保所有 deposit 交易在前面，非 deposit 交易在后面
    // ...
}
```

---

## 第六步：排序器处理密封结果 (onBuildSealed)

排序器收到密封后的区块后，执行三个关键步骤：

> **Source Code**: [op-node/rollup/sequencing/sequencer.go#L470-L505](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/sequencer.go#L470)

```go
func (d *Sequencer) onBuildSealed(x engine.BuildSealedEvent) {
    if d.latest.Info != x.Info { return }  // 忽略非排序器的负载

    // 步骤 1：提交到 Conductor（HA 共识）
    ctx, cancel := context.WithTimeout(d.ctx, time.Second*30)
    if err := d.conductor.CommitUnsafePayload(ctx, x.Envelope); err != nil {
        d.handleInvalid()
        return
    }

    // 步骤 2：通过 P2P gossip 立即广播区块
    d.asyncGossip.Gossip(x.Envelope)

    // 步骤 3：将区块插入到本地规范链中
    d.emitter.Emit(d.ctx, engine.PayloadProcessEvent{
        Envelope: x.Envelope,
        Ref:      x.Ref,
    })

    d.latest.Ref = x.Ref
    d.latestSealed = x.Ref
}
```

### 关键设计：先广播后插入

注意步骤 2（广播）发生在步骤 3（本地插入）之前。这是一个有意的设计决策：尽快将区块传播到网络中，减少其他节点收到区块的延迟。即使本地插入失败，广播已经完成，而 `asyncGossip` 缓冲区会保留负载，以便在恢复后重新插入。

### AsyncGossiper 的工作机制

> **Source Code**: [op-node/rollup/async/asyncgossiper.go#L24-L155](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/async/asyncgossiper.go#L24)

`SimpleAsyncGossiper` 在一个独立的 goroutine 中运行，通过 channel 与排序器通信：

```go
func (p *SimpleAsyncGossiper) gossip(ctx context.Context, payload *eth.ExecutionPayloadEnvelope) {
    if err := p.net.SignAndPublishL2Payload(ctx, payload); err == nil {
        p.currentPayload = payload  // 广播成功后保留负载，供后续恢复使用
    }
}
```

- `Gossip(payload)`: 异步广播负载到 P2P 网络
- `Get()`: 获取当前缓冲的负载（用于临时错误后的恢复）
- `Clear()`: 清除缓冲，在负载成功插入后调用

---

## 第七步：区块插入本地链 (PayloadProcess → PayloadSuccess)

引擎控制器收到 `PayloadProcessEvent` 后，调用 `engine_newPayloadV2/V3` 将区块插入执行引擎：

> **Source Code**: [op-node/rollup/engine/payload_process.go#L27-L68](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/engine/payload_process.go#L27)

```go
func (e *EngineController) onPayloadProcess(ctx context.Context, ev PayloadProcessEvent) {
    // 调用 engine_newPayloadV2/V3
    status, err := e.engine.NewPayload(rpcCtx, ev.Envelope.ExecutionPayload, ev.Envelope.ParentBeaconBlockRoot)

    switch status.Status {
    case eth.ExecutionValid:
        e.emitter.Emit(ctx, PayloadSuccessEvent{
            Envelope: ev.Envelope,
            Ref:      ev.Ref,
        })
    case eth.ExecutionInvalid:
        e.emitter.Emit(ctx, PayloadInvalidEvent{...})
    }
}
```

随后，`PayloadSuccessEvent` 触发引擎更新 unsafe head：

> **Source Code**: [op-node/rollup/engine/payload_success.go#L27-L59](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/engine/payload_success.go#L27)

```go
func (e *EngineController) onPayloadSuccess(ctx context.Context, ev PayloadSuccessEvent) {
    // 更新 unsafe head
    e.tryUpdateUnsafe(ctx, ev.Ref)
    // 同步调用 ForkchoiceUpdate 让执行引擎切换到新链头
    err := e.tryUpdateEngineInternal(ctx)
}
```

排序器收到 `PayloadSuccessEvent` 后，清理构建状态：

> **Source Code**: [op-node/rollup/sequencing/sequencer.go#L549-L561](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/sequencer.go#L549)

```go
func (d *Sequencer) onPayloadSuccess(x engine.PayloadSuccessEvent) {
    d.latest = BuildingState{}         // 清除构建状态
    d.asyncGossip.Clear()              // 清除 gossip 缓冲
}
```

---

## 第八步：ForkchoiceUpdate 启动下一轮

当引擎的 `tryUpdateEngineInternal` 完成后，会发出 `ForkchoiceUpdateEvent`，排序器收到后调度下一个出块周期：

> **Source Code**: [op-node/rollup/sequencing/sequencer.go#L703-L744](https://github.com/ethereum-optimism/optimism/blob/develop/op-node/rollup/sequencing/sequencer.go#L703)

```go
func (d *Sequencer) onForkchoiceUpdate(x engine.ForkchoiceUpdateEvent) {
    // 1. Safe Lag 检查
    if maxSafeLag := d.maxSafeLag.Load(); maxSafeLag > 0 &&
        x.SafeL2Head.Number+maxSafeLag <= x.UnsafeL2Head.Number {
        d.nextActionOK = false  // 暂停出块，等待 batcher 追上
        return
    }

    // 2. 清理过期的构建作业
    if d.latest != (BuildingState{}) && d.latest.Onto.Number < x.UnsafeL2Head.Number {
        d.latest = BuildingState{}
    }

    // 3. 调度下一次出块
    if x.UnsafeL2Head.Number > d.latestHead.Number {
        d.nextActionOK = true
        now := d.timeNow()
        blockTime := time.Duration(d.rollupCfg.BlockTime) * time.Second
        payloadTime := time.Unix(int64(x.UnsafeL2Head.Time+d.rollupCfg.BlockTime), 0)
        remainingTime := payloadTime.Sub(now)
        if remainingTime > blockTime {
            d.nextAction = payloadTime.Add(-blockTime)  // 距离较远，等到最后一个区块时间
        } else {
            d.nextAction = now  // 否则立即开始
        }
    }

    d.setLatestHead(x.UnsafeL2Head)
}
```

至此，一个完整的出块周期结束，排序器进入下一轮循环。

---

## 关键概念详解

### Sequencing Epoch 与 Sequencing Window

- **Sequencing Epoch**: 一组共享同一个 L1 Origin 的连续 L2 区块。L1 的固定区块时间为 12 秒，L2 的区块时间为 2 秒。
- **Sequencing Window**: 定义了一个 Epoch 最多可以包含多少个 L2 区块，受 `MaxSequencerDrift` 约束。

当 L2 时间戳超过 `L1Origin.Time + MaxSequencerDrift` 时，排序器必须产生空区块（`NoTxPool = true`），防止 L2 时间过度偏离 L1。

### Sequencer Drift

```go
attrs.NoTxPool = uint64(attrs.Timestamp) > l1Origin.Time + d.spec.MaxSequencerDrift(l1Origin.Time)
```

这是 OP Stack 协议的核心安全约束。如果排序器的 L2 时间戳过度领先于所引用的 L1 区块，则必须产生不包含交易池交易的区块。这确保了 L2 链不会在时间维度上与 L1 脱节。

### Safe Lag

```go
if maxSafeLag > 0 && x.SafeL2Head.Number + maxSafeLag <= x.UnsafeL2Head.Number {
    d.nextActionOK = false  // 暂停出块
}
```

当 unsafe head（排序器产生的最新区块）超过 safe head（已在 L1 上批量确认的区块）太多时，排序器会暂停出块。这迫使 Batcher 赶上进度，防止大量未确认区块积累带来的安全风险。

### 恢复模式 (Recover Mode)

排序器可以进入恢复模式，此时 `NoTxPool = true`，只产生包含系统存款交易的区块。这用于在发生故障后安全地恢复，避免在不确定状态下处理用户交易。

### BuildingState 状态机

`BuildingState` 追踪一个出块作业的多阶段状态：

```
零值 (无构建) ──> Onto 已设置 (已发出 BuildStart)
                  ──> Info 已设置 (收到 BuildStarted, 有 PayloadID)
                      ──> Ref 已设置 (收到 BuildSealed, 区块已密封)
                          ──> 零值 (PayloadSuccess 后清除)
```

### Conductor（高可用性）

在多节点部署中，Conductor 负责 Leader 选举。只有 Leader 节点才能排序出块：

```go
// Start 前检查
if isLeader, err := d.conductor.Leader(ctx); !isLeader { return }

// 密封后提交到 Conductor 共识
if err := d.conductor.CommitUnsafePayload(ctx, x.Envelope); err != nil { ... }
```

---

## 完整事件流总结

```
1. Driver: planSequencerAction() → 读取 sequencer.NextAction()
2. Driver: sequencerTimer 触发 → 发出 SequencerActionEvent
3. Sequencer: onSequencerAction() → startBuildingBlock()
   3a. L1OriginSelector.FindL1Origin() → 选择 L1 origin
   3b. attrBuilder.PreparePayloadAttributes() → 构建包含系统交易的模板
   3c. 设置 NoTxPool（Sequencer Drift / 硬分叉 / 恢复模式）
   3d. 发出 BuildStartEvent
4. EngineController: onBuildStart()
   4a. engine.ForkchoiceUpdate(fc, attrs) → Engine API 调用
   4b. EL 开始后台构建区块（如果 NoTxPool=false，从交易池收集交易）
   4c. 发出 BuildStartedEvent（携带 PayloadID）
5. Sequencer: onBuildStarted()
   5a. 验证事件有效性
   5b. 调度密封时机 = payloadTime - sealingDuration
6. Driver: sequencerTimer 再次触发 → SequencerActionEvent
7. Sequencer: onSequencerAction() → 发出 BuildSealEvent
8. EngineController: onBuildSeal()
   8a. engine.GetPayload(payloadID) → 获取已构建的区块并停止后台优化
   8b. sanityCheckPayload() → 验证区块完整性
   8c. 发出 BuildSealedEvent（携带完整的区块数据）
9. Sequencer: onBuildSealed()
   9a. conductor.CommitUnsafePayload() → HA 共识（30s 超时）
   9b. asyncGossip.Gossip() → P2P 广播
   9c. 发出 PayloadProcessEvent
10. EngineController: onPayloadProcess()
    10a. engine.NewPayload(payload) → 将区块插入 EL
    10b. 发出 PayloadSuccessEvent
11. EngineController: onPayloadSuccess()
    11a. tryUpdateUnsafe() → 更新 unsafe head
    11b. tryUpdateEngineInternal() → ForkchoiceUpdate（无 PayloadAttributes）
    11c. 发出 ForkchoiceUpdateEvent
12. Sequencer: onPayloadSuccess() → 清除 BuildingState 和 gossip 缓冲
13. Sequencer: onForkchoiceUpdate() → Safe Lag 检查 → 调度下一轮出块
14. 回到步骤 1，循环继续
```

> 上述流程中，L2 区块时间通常为 2 秒。也就是说，整个出块周期（步骤 1-14）需要在 2 秒内完成。

