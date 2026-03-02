# Pre-Interop 与 Post-Interop 深度解析

## 1. 概述

**Interop（互操作性）** 是 OP Stack 的一个硬分叉（Hardfork），在硬分叉时间线中位于最末端。它的核心目标是将多条独立的 L2 链连接成一个互联互通的 **Superchain 集群**，支持安全的跨链消息传递和统一的状态证明。

- **Pre-Interop**：Interop 硬分叉**激活之前**，每条 L2 链独立运行，没有原生跨链能力。
- **Post-Interop**：Interop 硬分叉**激活之后**，多条 L2 链组成 Superchain 集群，共享聚合状态证明，支持 L2↔L2 安全消息传递。

### 1.1 硬分叉时间线

```
OP Stack 硬分叉演进（按时间顺序）：

Bedrock → Regolith → Canyon → Delta → Ecotone → Fjord
   → Granite → Holocene → Isthmus → Jovian → Interop
                                                 ▲
                                           当前最新的硬分叉
```

> 源码参考: `op-core/forks/forks.go`

### 1.2 激活机制

每条链通过 `InteropTime` 配置激活时间。当 L2 区块的时间戳 `>=` `InteropTime` 时，Interop 功能生效：

```go
// op-node/rollup/types.go
// InteropTime sets the activation time for an experimental feature-set, activated like a hardfork.
// Active if InteropTime != nil && L2 block timestamp >= *InteropTime, inactive otherwise.
InteropTime *uint64 `json:"interop_time,omitempty"`
```

---

## 2. 核心区别对比

| 维度 | Pre-Interop | Post-Interop |
|------|-------------|--------------|
| **链间关系** | 每条 L2 独立运行 | 多条 L2 组成 Superchain 集群 |
| **跨链消息** | 不支持 L2↔L2 直接通信 | 支持 L2↔L2 安全消息传递 |
| **状态证明** | Output Root（单链） | Super Root（多链聚合） |
| **提案序号 (SequenceNum)** | L2 block number | L2 timestamp |
| **数据源** | op-node（单链 RPC） | op-supervisor / op-supernode（多链 RPC） |
| **争议游戏** | 单链验证（CANNON 等） | 跨链验证（SUPER_CANNON 等） |
| **安全等级** | 仅 Unsafe / Safe / Finalized | 增加 CrossUnsafe / CrossSafe |
| **L1 合约** | OptimismPortal2 | OptimismPortalInterop + ETHLockbox |
| **L2 预部署** | 无跨链合约 | CrossL2Inbox、L2ToL2CrossDomainMessenger 等 |

---

## 3. 状态证明体系

### 3.1 Pre-Interop：Output Root（单链状态根）

Output Root 代表**一条 L2 链**在某个 **block number** 时的状态。

```
OutputRoot = keccak256(version ++ state_root ++ message_passer_storage_root ++ block_hash)
```

```go
// op-service/eth/output.go
type OutputV0 struct {
    StateRoot                Bytes32     // L2 状态树根
    MessagePasserStorageRoot Bytes32     // L2ToL1MessagePasser 存储根（用于提款证明）
    BlockHash                common.Hash // L2 区块哈希
}

func (o *OutputV0) Marshal() []byte {
    var buf [128]byte
    version := o.Version()
    copy(buf[:32], version[:])           // 32 bytes: version (全零)
    copy(buf[32:], o.StateRoot[:])       // 32 bytes: state root
    copy(buf[64:], o.MessagePasserStorageRoot[:])  // 32 bytes: message passer storage root
    copy(buf[96:], o.BlockHash[:])       // 32 bytes: block hash
    return buf[:]                        // 共 128 bytes
}
```

### 3.2 Post-Interop：Super Root（多链聚合状态根）

Super Root 代表**整个 Superchain 集群**在某个 **timestamp** 时的聚合状态。

```
SuperRoot = keccak256(
    version           // 1 byte: 版本号
    ++ timestamp      // 8 bytes: L2 时间戳
    ++ chain_A_id ++ chain_A_output_root   // 32 + 32 bytes
    ++ chain_B_id ++ chain_B_output_root   // 32 + 32 bytes
    ++ ...
)
```

```go
// op-service/eth/super_root.go
type SuperV1 struct {
    Timestamp uint64             // 所有链共享的 L2 时间戳
    Chains    []ChainIDAndOutput // 每条链的 ID 和 Output Root，按 ChainID 升序排列
}

func (o *SuperV1) Marshal() []byte {
    buf := make([]byte, 0, 9+len(o.Chains)*chainIDAndOutputLen)
    buf = append(buf, o.Version())                      // 1 byte: version
    buf = binary.BigEndian.AppendUint64(buf, o.Timestamp) // 8 bytes: timestamp
    for _, o := range o.Chains {
        buf = append(buf, o.Marshal()...)                // 64 bytes per chain
    }
    return buf
}
```

### 3.3 为什么 Post-Interop 用 timestamp 而非 block number？

- 不同链的区块号之间没有对齐关系（Chain A 的 #1000 和 Chain B 的 #1000 时间可能完全不同）
- 在跨链聚合语义里，timestamp 是天然的统一坐标；而 block number 只能表达单链进度
- Super Root 需要在同一时刻聚合所有链的状态，只有 timestamp 能做到这一点

---

## 4. 争议游戏类型

合约层面通过 `GameType` ID 区分 Pre/Post-Interop：

```solidity
// packages/contracts-bedrock/src/dispute/lib/Types.sol
library GameTypes {
    // ── Pre-Interop（单链 Output Root）──
    GameType internal constant CANNON                    = GameType.wrap(0);
    GameType internal constant PERMISSIONED_CANNON       = GameType.wrap(1);
    GameType internal constant ASTERISC                  = GameType.wrap(2);
    GameType internal constant ASTERISC_KONA             = GameType.wrap(3);
    GameType internal constant OP_SUCCINCT               = GameType.wrap(6);
    GameType internal constant CANNON_KONA               = GameType.wrap(8);

    // ── Post-Interop（多链 Super Root）──
    GameType internal constant SUPER_CANNON              = GameType.wrap(4);
    GameType internal constant SUPER_PERMISSIONED_CANNON = GameType.wrap(5);
    GameType internal constant SUPER_ASTERISC_KONA       = GameType.wrap(7);
    GameType internal constant SUPER_CANNON_KONA         = GameType.wrap(9);
}
```

Go 代码中通过 GameType 列表强制校验数据源配置：

```go
// op-proposer/proposer/config.go

// Pre-Interop game types → 必须配置 rollup-rpc（单链 op-node）
preInteropGameTypes = []uint32{0, 1, 2, 3, 6, 254, 255, 1337}

// Post-Interop game types → 必须配置 supervisor-rpcs 或 supernode-rpcs
postInteropGameTypes = []uint32{4, 5}
```

**规律**：名字中带 `SUPER_` 前缀的都是 Post-Interop 游戏类型，它们验证的是 Super Root。

> 注意区分两层语义：
> - **协议/合约层定义**：`Types.sol` 中定义了多个 `SUPER_*` 类型（如 `4/5/7/9`）；
> - **当前 proposer 代码约束**：`op-proposer` 目前仅把 `4/5` 识别为 post-interop 强约束类型，其它类型按“unknown game type”路径处理。

---

## 5. 安全等级体系

### 5.1 Pre-Interop：三级安全模型

```
Unsafe  →  Safe  →  Finalized
  │          │          │
  │          │          └─ L1 数据已 finalized
  │          └─ 可从 L1 数据重现（derived from L1）
  └─ 排序器刚产生，尚未提交到 L1
```

### 5.2 Post-Interop：五级安全模型

```go
// op-supervisor/supervisor/types/types.go
const (
    Finalized   SafetyLevel = "finalized"     // 所有依赖均来自 finalized L1 数据
    CrossSafe   SafetyLevel = "safe"          // LocalSafe + 所有跨链依赖也已验证
    LocalSafe   SafetyLevel = "local-safe"    // 可从 L1 重现，但跨链依赖未验证
    CrossUnsafe SafetyLevel = "cross-unsafe"  // LocalUnsafe + 跨链依赖至少是 CrossUnsafe
    LocalUnsafe SafetyLevel = "unsafe"        // 排序器刚产生
    Invalid     SafetyLevel = "invalid"       // 消息/区块不匹配
)
```

升级路径：

```
LocalUnsafe → CrossUnsafe → LocalSafe → CrossSafe → Finalized
     │              │             │            │           │
     │              │             │            │           └─ L1 finalized + 所有依赖 finalized
     │              │             │            └─ L1 derived + 所有跨链依赖 CrossSafe
     │              │             └─ 可从 L1 数据重现（单链视角）
     │              └─ 排序器产生 + 跨链依赖已验证（至少 CrossUnsafe）
     └─ 排序器刚产生（单链视角）
```

Post-Interop 新增了 `CrossUnsafe` 和 `CrossSafe` 两个级别，它们的核心含义是：
- **Cross** 前缀 = 不仅本链状态已验证，该区块引用的所有跨链消息的**来源链**状态也已验证
- 由 `op-supervisor` 或 `op-supernode` 负责跟踪和推进

---

## 6. 组件架构对比

### 6.1 Pre-Interop 部署架构

每条链独立运行完整的组件栈：

```
Chain A:                           Chain B:
┌──────────┐  ┌──────────┐       ┌──────────┐  ┌──────────┐
│ op-node  │──│ op-geth  │       │ op-node  │──│ op-geth  │
└────┬─────┘  └──────────┘       └────┬─────┘  └──────────┘
     │                                │
┌────┴─────┐                    ┌─────┴────┐
│op-proposer│                   │op-proposer│   ← 各自独立
└────┬─────┘                    └─────┬────┘
     │                                │
     └────── L1 (DisputeGameFactory) ─┘

进程数: 每条链 4 个（op-node + op-geth + op-proposer + op-batcher）
L1 连接: 每个 op-node / op-proposer / op-batcher 都需要各自访问 L1（可通过共享 RPC 端点汇聚）
```

### 6.2 Post-Interop 部署架构

#### 方案 A：op-supervisor 模式（Legacy）

```
┌──────────┐  ┌──────────┐       ┌──────────┐  ┌──────────┐
│ op-node-A│──│ op-geth-A│       │ op-node-B│──│ op-geth-B│
└────┬─────┘  └──────────┘       └────┬─────┘  └──────────┘
     │           RPC                  │           RPC
     └─────────────┬──────────────────┘
                   │
          ┌────────▼────────┐
          │  op-supervisor  │    ← 外部索引服务，通过 RPC 连接 op-node
          └────────┬────────┘
                   │
          ┌────────▼────────┐
          │   op-proposer   │    ← 共享一个，从 supervisor 获取 Super Root
          └────────┬────────┘
                   │
              L1 (DGF)
```

#### 方案 B：op-supernode 模式（Replacement）

```
┌─────────────────────────────────────────────┐
│              op-supernode                     │    ← 单进程运行所有链的 CL
│                                              │
│  ┌─ Chain Container A ────────────────────┐  │
│  │  VirtualNode (内嵌 op-node-A 逻辑)     │  │
│  └────────────────────────────────────────┘  │
│  ┌─ Chain Container B ────────────────────┐  │
│  │  VirtualNode (内嵌 op-node-B 逻辑)     │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  共享 L1 Client ──── 仅 1 个 L1 连接        │
└──────────┬──────────────┬───────────────────┘
           │              │
      op-geth-A      op-geth-B

          ┌──────────────┐
          │  op-proposer  │   ← 共享一个，从 supernode 获取 Super Root
          └──────┬───────┘
                 │
            L1 (DGF)
```

### 6.3 组件角色变化

| 组件 | Pre-Interop | Post-Interop |
|------|-------------|--------------|
| **op-node** | 独立运行 | 受 supervisor/supernode 管理 |
| **op-proposer** | 每链一个，连接 op-node | 可共享，连接 supervisor/supernode |
| **op-challenger** | 单链 Trace Provider | Super Root Trace Provider |
| **op-batcher** | 每链一个 | 每链一个（不变） |
| **op-supervisor** | 不存在 | 跨链安全监控 + Super Root 计算（Legacy） |
| **op-supernode** | 不存在 | 多链聚合节点 + Super Root 计算（Replacement） |

---

## 7. Proposal 数据源

`op-proposer` 通过 `ProposalSource` 接口获取提案数据，根据模式不同选择不同的实现：

```go
// op-proposer/proposer/source/source.go
type Proposal struct {
    Root        common.Hash  // 提案哈希（Output Root 或 Super Root）
    SequenceNum uint64       // Pre-Interop: L2 block number; Post-Interop: L2 timestamp
    Super       eth.Super    // 仅 Super Root 提案时存在
    CurrentL1   eth.BlockID
}

// ExtraData 根据提案类型返回不同的额外数据
func (p *Proposal) ExtraData() []byte {
    if p.Super != nil {
        return p.Super.Marshal()   // Post-Interop: 序列化 Super Root 原始数据
    } else {
        var extraData [32]byte
        binary.BigEndian.PutUint64(extraData[24:], p.SequenceNum) // Pre-Interop: L2 block number
        return extraData[:]
    }
}
```

三种 `ProposalSource` 实现：

| 实现 | 模式 | 数据来源 | 返回类型 |
|------|------|---------|---------|
| `RollupProposalSource` | Pre-Interop | 单个 op-node RPC | Output Root |
| `SupervisorProposalSource` | Post-Interop | op-supervisor RPC（支持多实例容错） | Super Root |
| `SuperNodeProposalSource` | Post-Interop | op-supernode RPC（支持多实例容错） | Super Root |

---

## 8. L1 合约变化

### 8.1 Pre-Interop

- **OptimismPortal2**：处理 L1→L2 存款和 L2→L1 提款证明/最终确认
- **DisputeGameFactory**：创建和管理单链争议游戏
- 提款证明基于单链 Output Root

### 8.2 Post-Interop 新增/升级合约

- **OptimismPortalInterop**：OptimismPortal2 的 Interop 增强版
  - 支持 Super Root 作为提款证明的基础
  - 集成 ETHLockbox 实现跨链 ETH 共享流动性
- **ETHLockbox**：跨链 ETH 流动性池
  - 所有 Superchain 链的 ETH 存入统一的 Lockbox
  - 解决了跨链 ETH 转移时的流动性碎片化问题
- **SuperchainConfig**：Superchain 全局配置
  - Guardian 全局暂停机制（一键暂停所有链）

---

## 9. L2 预部署合约（Post-Interop 新增）

Post-Interop 在 L2 上新增了一系列预部署合约，支持跨链消息传递和资产转移：

| 合约 | 功能 | 说明 |
|------|------|------|
| **CrossL2Inbox** | 跨链消息验证 | 低层级合约，基于 EIP-2930 access list 验证跨链消息 |
| **L2ToL2CrossDomainMessenger** | 跨链消息传递 | 高层级合约，提供重放保护和域绑定 |
| **SuperchainTokenBridge** | ERC20 跨链转移 | 基于 ERC-7802 的 SuperchainERC20 跨链桥 |
| **SuperchainETHBridge** | ETH 跨链转移 | 通过 ETHLiquidity 实现跨链 ETH 转移 |
| **ETHLiquidity** | 虚拟 ETH 流动性 | 提供无限虚拟 ETH 流动性，不修改 EVM |

跨链消息传递的分层架构：

```
应用层:   SuperchainTokenBridge / SuperchainETHBridge
            │                          │
消息层:   L2ToL2CrossDomainMessenger（重放保护、域绑定）
            │
验证层:   CrossL2Inbox（EIP-2930 access list 验证）
            │
共识层:   op-supervisor / op-supernode（安全等级推进）
```

---

## 10. 迁移策略

### 10.1 GameType 迁移

从 Pre-Interop 过渡到 Post-Interop 的关键是 **切换 DisputeGameFactory 中的 Respected Game Type**：

```
Pre-Interop:  CANNON (0) 或 PERMISSIONED_CANNON (1)  →  验证 Output Root
Post-Interop: SUPER_CANNON (4) 或 SUPER_PERMISSIONED_CANNON (5) → 验证 Super Root
```

### 10.2 op-proposer 迁移

```
Pre-Interop 配置:
  --rollup-rpc=http://op-node:8547          # 连接单链 op-node
  --game-type=1                              # PERMISSIONED_CANNON

Post-Interop 配置（supervisor 模式）:
  --supervisor-rpcs=http://supervisor:8547    # 连接 op-supervisor
  --game-type=5                              # SUPER_PERMISSIONED_CANNON

Post-Interop 配置（supernode 模式）:
  --supernode-rpcs=http://supernode:8547      # 连接 op-supernode
  --game-type=5                              # SUPER_PERMISSIONED_CANNON
```

### 10.3 配置校验

`op-proposer` 会根据 GameType 自动校验数据源配置是否正确：

```go
// op-proposer/proposer/config.go
// Pre-Interop game types（0,1,2,3,6,254,255,1337）→ 必须配置 rollup-rpc
// Post-Interop game types（当前仅 4,5）→ 必须配置 supervisor-rpcs 或 supernode-rpcs
// Unknown game types → 不做 pre/post 强约束，但要求三类 source 至少配置一种
// 且三类 source 全局互斥（rollup / supervisor / supernode 只能三选一）
```

等价理解：

- `game-type ∈ preInteropGameTypes`：缺 `rollup-rpc` 会报错；
- `game-type ∈ postInteropGameTypes`：缺 `supervisor-rpcs` 且缺 `supernode-rpcs` 会报错；
- 其它 `game-type`：走 unknown 分支，不强制 pre/post 来源，但仍必须满足“至少一个来源 + 三选一互斥”。

---

## 11. 总结

```
┌────────────────────────────────────────────────────────────────────┐
│                     Pre-Interop（每链独立）                         │
│                                                                    │
│  Chain A          Chain B          Chain C                         │
│  ┌──────┐        ┌──────┐        ┌──────┐                        │
│  │Output│        │Output│        │Output│     ← 各自独立证明       │
│  │Root A│        │Root B│        │Root C│                         │
│  └──┬───┘        └──┬───┘        └──┬───┘                        │
│     │               │               │                             │
│  DGF-A            DGF-B           DGF-C       ← 各自独立争议      │
│                                                                    │
│  没有原生跨链能力，只能通过 L1 中继实现 L2↔L2 通信                  │
└────────────────────────────────────────────────────────────────────┘

                        ║  Interop 硬分叉激活  ║

┌────────────────────────────────────────────────────────────────────┐
│                    Post-Interop（Superchain 集群）                  │
│                                                                    │
│  Chain A          Chain B          Chain C                         │
│  ┌──────┐        ┌──────┐        ┌──────┐                        │
│  │Output│        │Output│        │Output│                         │
│  │Root A│        │Root B│        │Root C│                         │
│  └──┬───┘        └──┬───┘        └──┬───┘                        │
│     │    L2↔L2     │    L2↔L2     │       ← 原生跨链消息传递      │
│     └───────┬───────┴───────┬─────┘                               │
│             │               │                                      │
│     ┌───────▼───────────────▼──────┐                              │
│     │  Super Root (聚合状态根)      │     ← 统一证明               │
│     │  = hash(A_root + B_root + C) │                              │
│     └──────────────┬───────────────┘                              │
│                    │                                               │
│           DGF (SUPER_CANNON)              ← 统一争议               │
└────────────────────────────────────────────────────────────────────┘
```

**一句话总结**：Pre-Interop 是"孤岛模式"，每条链自证清白；Post-Interop 是"联邦模式"，所有链联合出具一份聚合状态证明，并通过原生的跨链消息通道实现安全的 L2↔L2 通信。
