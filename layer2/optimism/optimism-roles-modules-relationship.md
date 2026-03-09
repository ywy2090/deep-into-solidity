# OP Stack 角色、职能与模块关联

本文档梳理 OP Stack 中的**角色**、**职能**以及**模块之间的数据流与依赖关系**，便于理解整体架构。

---

## 1. 角色与职能总览

| 角色 | 实现模块 | 核心职能 | 运行位置 |
|------|----------|----------|----------|
| **Sequencer（排序器）** | op-node | 出块、交易排序、L1 origin 选择、P2P 广播 | L2 共识层 |
| **Verifier（验证器）** | op-node | 从 L1 派生 L2 链、验证规范链、不出块 | L2 共识层 |
| **Batcher（批次提交者）** | op-batcher | 将 L2 交易数据写入 L1（DA） | 独立服务 |
| **Proposer（提议者）** | op-proposer | 周期性提交 L2 状态根（OutputRoot）到 L1 | 独立服务 |
| **Challenger（挑战者）** | op-challenger | 监控提议、发现错误时发起争议游戏 | 独立服务 |
| **Conductor** | op-conductor | 多排序器场景下的 Leader 选举与故障转移 | 独立服务（HA） |
| **Execution Engine（执行引擎）** | op-geth / op-reth | 执行 EVM、维护 L2 状态、密封区块 | L2 执行层 |

**说明：** Sequencer 与 Verifier 是 **同一二进制（op-node）的两种运行模式**，由配置（如 `--sequencer.enabled`）决定。

---

## 2. 各角色职能详解

### 2.1 Sequencer（排序器）

- **出块**：按固定区块时间（如 2 秒）构建 L2 区块。
- **交易排序**：从交易池取交易，填入 Payload Attributes，交给执行引擎执行并密封。
- **L1 锚定**：为每个 L2 区块选择 L1 origin（参考的 L1 区块），满足 Sequencer Drift、SeqWindowSize 等约束。
- **P2P 传播**：密封后通过 gossip 广播区块，再插入本地规范链。
- **安全机制**：SafeLag 检查（unsafe 领先 safe 过多时暂停出块）、RecoverMode（只出空块以追上 L1 数据）。

**数据出口：** 区块通过 op-batcher 写入 L1，供 Verifier 与 Challenger 从 L1 派生。

### 2.2 Verifier（验证器）

- **从 L1 派生 L2**：读取 L1 上的 batch 数据（calldata / blob）、receipts、deposits，经 **derivation pipeline** 得到 L2 区块输入。
- **验证规范链**：只接受能从 L1 数据重现的 L2 区块；无法重现则拒绝并可能触发重置。
- **不出块**：不运行排序逻辑，不向 P2P 广播自产区块，仅跟随 L1 数据推进 safe/finalized。

**数据入口：** L1（batcher 提交的数据）+ 可选 P2P（加速同步 unsafe 头）。

### 2.3 Batcher（批次提交者）

- **数据可用性（DA）**：从 op-node（Sequencer）的 RPC 拉取 **unsafe** L2 区块，压缩成 channel/frame，提交到 L1（或 Alt DA）。
- **与 derivation 的配合**：使用与 op-node 相同的 `ChannelOut` 等编码逻辑，保证 Verifier 能从 L1 解码出相同 L2 输入。
- **节流**：在 DA 积压时可通过 RPC 通知 Sequencer 限流，避免 safe 落后过多。

**关系：** 依赖 Sequencer 提供区块；其输出被 derivation pipeline 消费。

### 2.4 Proposer（提议者）

- **提交 OutputRoot**：按配置周期（如约 1 小时）读取 L2 状态，计算 OutputRoot，在 L1 上向 `DisputeGameFactory`（或旧版 `OptimismPortal`）提交 claim。
- **提款前置条件**：L2→L1 提款依赖「已解析且无争议」的 proposal；Proposer 不直接执行提款，但提案被接受后，提款才能最终确认。

**关系：** 依赖 rollup RPC（op-node）获取 L2 状态；与 Challenger 通过链上争议游戏交互。

### 2.5 Challenger（挑战者）

- **监控**：监听 L1 上 Proposer 提交的每个 OutputRoot/claim。
- **验证**：本地用与 L1 一致的 rollup 配置重新派生 L2 状态，对比 Proposer 的 claim。
- **挑战**：若发现不一致，质押保证金发起 fault dispute game，与 Proposer 在链上做二分搜索；最终由链上 MIPS 单步执行裁决胜负。

**关系：** 依赖 rollup RPC 与 L1 RPC；依赖 op-program + Cannon 生成 trace 与证明；与 L1 上的 `DisputeGameFactory`、`FaultDisputeGame`、`MIPS64` 等合约交互。

### 2.6 Conductor（HA 排序器）

- **Leader 选举**：在多排序器部署中，只有 Leader 可运行 Sequencer 逻辑。
- **故障转移**：Leader 不可用时，切换至其他节点，避免双花或重复出块。
- **Payload 共识**：密封后的 payload 在提交到 L1 前可在集群内达成一致（视部署而定）。

**关系：** 与多个 op-node（Sequencer 模式）通信，决定谁有权出块。

### 2.7 Execution Engine（执行引擎）

- **执行 EVM**：根据 op-node 下发的 Payload Attributes 执行交易，返回 ExecutionPayload。
- **维护状态**：维护 L2 的 state、block chain、receipts 等。
- **密封区块**：响应 `engine_forkchoiceUpdatedV3` + `engine_getPayload`，完成区块密封。

**关系：** 被 op-node（Sequencer 与 Verifier 共用）通过 Engine API 调用；不直接与 Batcher/Proposer/Challenger 通信。

---

## 3. 模块间数据流与依赖

### 3.1 高层数据流（简化）

```
                    L1 (Ethereum 或兼容链)
                         │
         ┌───────────────┼───────────────┐
         │               │               │
     Batcher 写入     Proposer 写入    Challenger 读取/写入
    (batches/blobs)  (OutputRoot)    (dispute games)
         │               │               │
         └───────────────┼───────────────┘
                        │
    ┌───────────────────┴───────────────────┐
    │              op-node                   │
    │  ┌─────────────┐    ┌─────────────┐   │
    │  │ Sequencer   │    │  Verifier   │   │
    │  │ (出块+广播)  │    │ (从L1派生)  │   │
    │  └──────┬──────┘    └──────┬──────┘   │
    │         │                  │          │
    │         └────────┬─────────┘          │
    │                  │ derivation        │
    │                  ▼                    │
    │         Engine API (Payload Attrs /   │
    │         Forkchoice / Payload)         │
    └──────────────────┬───────────────────┘
                       │
                       ▼
              Execution Engine (op-geth / op-reth)
```

### 3.2 关键依赖关系

| 模块 | 依赖的其他模块/数据 | 被谁依赖 |
|------|--------------------|----------|
| **op-node** | L1 RPC、L1 Beacon（blob）、Execution Engine、可选 P2P、可选 Conductor | Batcher（读 unsafe 块）、Proposer（读 L2 状态）、Challenger（读 rollup 配置/状态） |
| **op-batcher** | op-node RPC（Sequencer）、L1（或 Alt DA）、与 op-node 共用的 derive 编码 | op-node 的 derivation pipeline（读 L1 数据） |
| **op-proposer** | op-node rollup RPC、L1、DisputeGameFactory 等合约 | Challenger（针对其提交的 claim）、提款流程（依赖已解析的 proposal） |
| **op-challenger** | op-node rollup RPC、L1、op-program、Cannon、DisputeGameFactory / FaultDisputeGame | Proposer（争议对手）、L1 合约（裁决结果） |
| **op-conductor** | 多个 op-node（Sequencer） | op-node（谁可以出块） |
| **Execution Engine** | 无 OP 特定上游 | op-node（唯一直接调用方） |

### 3.3 Derivation Pipeline（op-node 内部）

- **输入**：L1 的 batches（blob/calldata）、receipts（TransactionDeposited 等）、L1 区块头与时间戳。
- **步骤**：L1 数据 → 解析为 channel/frame → 解码为 L2 交易与 deposit → 生成 **PayloadAttributes** → 调用执行引擎得到 **ExecutionPayload** → 更新 forkchoice。
- **输出**：规范 L2 链（safe/finalized 头推进）；Verifier 完全依赖此路径，Sequencer 在 RecoverMode 下也与此一致。

**代码位置：** `op-node/rollup/derive/`（与 op-batcher 共享 `ChannelOut` 等）。

---

## 4. L1 合约与角色的对应

| L1 合约 / 概念 | 相关角色 | 作用 |
|----------------|----------|------|
| **DataAvailability 层（calldata / blob）** | Batcher 写入；op-node derivation 读取 | L2 交易数据可用性 |
| **OptimismPortal** | 存款/提款入口；Proposer 可能向旧版 Portal 提交 | 存款交易事件、提款证明验证 |
| **DisputeGameFactory** | Proposer 创建游戏；Challenger 参与游戏 | 创建 FaultDisputeGame、管理 root claim |
| **FaultDisputeGame / MIPS64 / PreimageOracle** | Challenger（及 Proposer）参与二分与单步裁决 | 争议游戏执行与结果 |
| **SystemConfig** | 所有需要链配置的组件 | 链 ID、区块时间、batch 等参数 |
| **L1CrossDomainMessenger** | 用户/合约跨链消息 | 与 Portal 配合完成 L1↔L2 消息 |

---

## 5. 配置维度上的区分（op-node）

| 配置项 | Sequencer 模式 | Verifier 模式 |
|--------|----------------|----------------|
| `sequencer.enabled` | true | false |
| `sequencer.stopped` | false（通常） | - |
| `verifier_conf_depth` | 可更激进 | 用于 L1 派生距离 |
| `sequencer_conf_depth` | 用于选择 L1 origin | - |
| 是否连接 Conductor | 多机 HA 时连接 | 不需要 |

同一 op-node 二进制，通过不同配置在「只验证」与「主动出块」之间切换，二者共享 derivation 与 Engine API 逻辑。

---

## 6. 小结

- **op-node**：同时承载 **Sequencer** 与 **Verifier**，是共识层核心；通过 **derivation** 消费 L1 上 Batcher 写入的数据。
- **op-batcher**：保证 L2 数据在 L1 可用，与 op-node 共享编码逻辑，形成「写入 ⇄ 读出」闭环。
- **op-proposer**：把 L2 状态承诺提交到 L1，供提款与争议使用。
- **op-challenger**：校验 Proposer 的承诺，错误时发起争议游戏，与 L1 合约和 op-program/Cannon 配合。
- **op-conductor**：多排序器场景下决定谁出块，提高可用性。
- **Execution Engine**：只与 op-node 对话，执行 EVM 并密封区块。

理解「角色 → 职能 → 模块 → 数据流」即可把握 OP Stack 各组件如何配合，以及 L1 合约在其中的锚定作用。
