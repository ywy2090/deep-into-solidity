# CCIP DON 网络与消息验证的关联

> 本文档聚焦于：**Chainlink DON（去中心化预言机网络）的节点如何参与 CCIP 跨链消息验证**，串联 OCR3 协议、CommitteeVerifier 签名机制、RMN 网络三条主线，揭示"消息真实性"背后的完整信任链。

---

## 1. 什么是 CCIP 的 DON

DON（Decentralized Oracle Network）是 Chainlink 的去中心化节点网络，由多个独立运营的 Oracle 节点组成。在 CCIP 中，DON 节点负责：

```text
DON 节点的核心职责（CCIP 上下文）
═════════════════════════════════

每个节点独立地：
  ① 观察源链事件（OnRamp 发出的消息）
  ② 验证消息格式与内容
  ③ 与其他节点进行 P2P 通信
  ④ 参与 OCR3 共识，达成一致
  ⑤ 产生签名（Signer Key 签名）
  ⑥ 有时负责向目标链提交报告（Transmitter Key）
```

> **关键理解**：DON 节点不保存消息内容，它们的作用是对"消息哈希"进行签名，证明这批消息确实在源链上发生了。

---

## 2. 多个独立的 DON / 网络协同工作

从当前仓库源码可直接确认，CCIP 至少涉及两类 OCR3 插件网络，以及一个独立的 RMN 安全网络：

```text
┌─────────────────────────────────────────────────────────────┐
│                    CCIP DON 体系                             │
│                                                              │
│  ┌──────────────────────┐    ┌──────────────────────────┐  │
│  │  Commit DON          │    │  Execute DON             │  │
│  │  （Commit Plugin）   │    │  （Execute Plugin）      │  │
│  │                      │    │                          │  │
│  │  职责：              │    │  职责：                  │  │
│  │  • 观察源链消息      │    │  • 读取已 Commit 的报告  │  │
│  │  • 计算 Merkle Root  │    │  • 从源链读取完整消息    │  │
│  │  • 提交 CommitReport │    │  • 构建 ExecuteReport    │  │
│  │  • 与 RMN 交互      │    │  • 参与 transmit 流程    │  │
│  │                      │    │                          │  │
│  │  → 证明消息"存在"    │    │  → 触发消息"执行"        │  │
│  └──────────────────────┘    └──────────────────────────┘  │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  RMN DON（Risk Management Network）                   │  │
│  │                                                       │  │
│  │  职责：                                               │  │
│  │  • 独立观察源链，监控可疑活动                          │  │
│  │  • 参与 Commit 相关的独立背书/签名流程               │  │
│  │  • 在异常情况下"诅咒"某条链                            │  │
│  │                                                       │  │
│  │  → 提供独立的安全保障层                                │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. OCR3 框架：DON 协调的底层

### 3.1 OCR3 六阶段生命周期

每条跨链消息的处理，都经历 OCR3 的多轮共识，每轮包含以下阶段：

```text
OCR3 单轮共识流程
═════════════════

Leader（轮次领导者，由算法选举）         Follower（其他节点）
                │                              │
   1. Query     │── 广播 Query ──────────────→ │ 所有节点接收查询
                │                              │
   2. Observation│← 所有节点各自观察源链      ─ │ 每个节点独立读链
                │  产生 Observation            │
                │                              │
   3. ObservationQuorum                        │
                │── 聚合 2F+1 个 Observations →│ 共识：达到法定人数
                │                              │
   4. Outcome   │── Leader 计算 Outcome ──────→│ 所有节点验证 Outcome
                │                              │
   5. Reports   │── Leader 生成 Report ───────→│ 每个节点验证并签名
                │                              │  (使用 Signer Key)
   6. Transmit  │                              │ Transmitter 节点广播
                │                              │ 已签名报告上链
```

> **法定人数（Quorum）**：需要 `2*F+1` 个节点的 Observation 才能继续，其中 `F = FChain`（最大容错节点数）。

### 3.2 节点的三类密钥

```go
// internal/reader/home_chain.go:405-409
type OCR3Node struct {
    P2pID          [32]byte `json:"p2pId"`
    SignerKey      []byte   `json:"signerKey"`      // ECDSA 签名密钥
    TransmitterKey []byte   `json:"transmitterKey"` // 用于发送链上交易
}
```

| 密钥类型 | 用途 | 链上注册 |
| ------- | ---- | -------- |
| `P2pID` | P2P 网络通信身份 | 无 |
| `SignerKey` | 对 OCR3 报告等对象进行签名 | 可作为链上委员会签名者的候选来源，但当前 repo 未展示自动同步链路 |
| `TransmitterKey` | 作为 EOA 发送链上交易（transmit） | 用于调用链上合约 |

**关键联系**：`OCR3Node.SignerKey` 与 `CommitteeVerifier` 的 `s_signerConfigs` 在语义上是兼容的签名者地址格式，但当前仓库里没有展示“从 `CCIPHome` 自动同步到 `CommitteeVerifier.applySignatureConfigs()`”的生产代码，因此这里只能说两者**可能由同一批运营者统一管理**，不能直接断言它们在本仓库中已形成自动绑定。

---

## 4. Commit DON：消息存在性证明

### 4.1 Commit 插件阶段状态机

```text
Commit Plugin 阶段
═════════════════

Round N:
  Query:       Leader 查询待处理消息的 SeqNum 范围
  Observation: 每个节点独立观察源链，收集：
               - 新消息的 messageId 列表
               - Gas 价格
               - Token 价格
  Outcome:     聚合 ≥ 2F+1 个 Observation，计算：
               - Merkle Root（所有消息 messageId 的 Merkle 树）
               - Gas 定价更新
               - Token 定价更新
  Reports:     构建 CommitReport，包含：
               - MerkleRoot
               - SeqNumRange
               - RMNSignatures（如果链启用了 RMN）
  Transmit:    Transmitter 节点将 CommitReport 提交到目标链对应提交入口
```

### 4.2 Merkle Root 的生成与意义

```go
// execute/report/report.go:50-62（Merkle 树构建）
tree, err := ConstructMerkleTree(report, lggr)

// 每个叶子节点是 messageId = keccak256(encodedMessage)
// Merkle Root = 所有消息 ID 的 Merkle 树根

// 验证：
hash := tree.Root()
if !bytes.Equal(hash[:], report.MerkleRoot[:]) {
    // 树根不匹配：说明消息数据有误
}
```

**Merkle Root 的意义**：

- Commit DON 将一批消息的摘要（Merkle Root）写入目标链
- 任何人都可以用 Merkle Proof 证明某条消息属于这批消息
- Commit DON 节点通过 OCR3 协议对这个 Root 达成共识（`≥2F+1` 节点同意）

```text
Commit DON 对消息真实性的贡献：
═══════════════════════════════

✅ 共识：至少 `2F+1` 个节点对同一批观察达成法定人数
✅ 不可篡改：任意改动消息 → Merkle Root 不同 → 不匹配 CommitStore
✅ 完整性：只有 Commit 报告覆盖的消息才能被执行
```

---

## 5. Execute DON：消息执行触发

### 5.1 Execute 插件阶段状态机

Execute 插件使用三阶段状态机（跨多轮 OCR3 轮次）：

```text
Execute Plugin 状态机（跨多轮）
═══════════════════════════════

【State: GetCommitReports】
  各节点观察目标链上已提交但未执行的 CommitReport
  输出：CommitData 列表

         ↓ 下一轮

【State: GetMessages】
  各节点从源链获取 CommitReport 中的完整消息内容
  输出：Messages + TokenData（CCTP 证明等）

         ↓ 下一轮

【State: Filter】
  过滤不可执行的消息（已执行、nonce 不连续、gas 不足等）
  构建 ExecuteReport：
    ├─ Messages：要执行的消息列表
    ├─ Proofs：Merkle 证明（每条消息属于 CommitRoot）
    ├─ ProofFlagBits：Merkle 证明标志位
    └─ OffchainTokenData：链下 Token 数据（CCTP 证明等）

         ↓ Reports 阶段，节点对 ExecuteReport 达成 OCR3 报告共识

Transmit → 进入后续执行/提交流程
```

> 注意：`OffRamp.execute` 的参数中**没有 Merkle Proof**（这是 CCIP v2 的设计变化，见第 5.2 节）。

### 5.2 Merkle Proof 的作用（当前 execute 插件仍会构造）

```go
// execute/report/report.go:97-102（报告中仍有 Proof）
finalReport := ccipocr3.ExecutePluginReportSingleChain{
    Messages:          msgInRoot,
    Proofs:            proofsCast,           // Merkle 证明
    ProofFlagBits:     ...,                  // 证明标志位
    OffchainTokenData: offchainTokenData,
}
```

Execute 插件仍然会生成 Merkle Proof，但当前 `OffRamp.execute` 接口的参数只有 `encodedMessage / ccvs / verifierResults / gasLimitOverride`，并不直接接收这些 proof。  

因此，更准确的说法是：

- 这个仓库里的 execute 插件**仍然产出** Merkle Proof
- 但目标链 `OffRamp.execute` 的验证接口**不直接消费**这组 proof
- 这说明 execute 插件与最终执行入口之间，还存在一个未在当前仓库中完整展开的衔接层或兼容层；不能简单写成“execute 插件直接把 proof 传给 `OffRamp.execute`”

---

## 6. CommitteeVerifier 委员会：DON 节点的"链上代理"

这是 DON 网络与消息验证关联的**核心链路**。

### 6.1 委员会成员与 DON 节点 Signer Key 的关系

```text
DON 节点                            CommitteeVerifier
═══════════                        ══════════════════

OCR3Node {                         s_signerConfigs[sourceChainSelector] {
  P2pID: 0x...                       signers: [
  SignerKey: 0xAAA  ──────→──────      0xAAA,  ← 节点0的 ECDSA 公钥地址
  TransmitterKey: 0x...                0xBBB,  ← 节点1的 ECDSA 公钥地址
}                                       ...
                                        0xPPP,  ← 节点15的 ECDSA 公钥地址
OCR3Node {                           ],
  P2pID: 0x...                       threshold: 9  ← 至少需要9个签名
  SignerKey: 0xBBB  ──────→──────  }
  TransmitterKey: 0x...
}

...（16个节点）
```

**当前源码能确认的事实**：

1. `CCIPHome` / `home_chain.go` 定义了 OCR3 节点配置，里面有 `SignerKey`
2. `CommitteeVerifier` / `SignatureQuorumValidator` 维护独立的 `s_signerConfigs`
3. `CommitteeVerifier.applySignatureConfigs()` 可以把一组地址注册为某源链的有效签名者

**当前源码不能直接确认的事实**：

- 没有看到生产代码把 `CCIPHome.OCR3Config.Nodes[].SignerKey` 自动写入 `CommitteeVerifier.applySignatureConfigs()`

因此更稳妥的理解是：**委员会成员地址与 OCR3 SignerKey 在格式和职责上高度兼容，实际部署中可能重合，但这种绑定关系在当前 repo 中并未完整展示。**

```solidity
// SignatureQuorumValidator.sol 中的委员会管理
function applySignatureConfigs(
    uint64[] calldata sourceChainSelectorsToRemove,
    SignatureConfig[] calldata signatureConfigs  // {sourceChain, threshold, signers[]}
) external onlyOwner {
    // ...更新 s_signerConfigs[sourceChainSelector]
}
```

### 6.2 签名的产生时机与内容

**关键问题**：这些 `CommitteeVerifier` 签名是在仓库里的哪一层产生的？

这里要严格区分两件事：

- OCR3 协议自己的报告签名
- `CommitteeVerifier.verifyMessage()` 所消费的 `verifierResults` 签名

当前仓库源码只明确展示了后者的**链上验证格式**，以及 `ICrossChainVerifierV1.getStorageLocations()` 这个接口约定：

- `getStorageLocations()` 告诉外部执行者去哪里查找证明数据
- `OffRamp.execute()` 接收 `verifierResults`
- `CommitteeVerifier.verifyMessage()` 消费 `verifierResults`

但当前仓库中的 execute 插件代码**没有展示**：

- 去读取 `getStorageLocations()`
- 去拉取 `verifierResults`
- 去直接拼出 `OffRamp.execute(encodedMessage, ccvs, verifierResults, ...)`

所以，这里更准确的表述应是：`verifierResults` 的生产和获取**很可能属于仓库外的 executor / 集成层 / 运维侧组件**，而不是当前 repo 中 execute plugin 的已展示职责。

```solidity
// CommitteeVerifier.sol 中的 storageLocations 概念（来自 BaseVerifier）
// 这是给外部执行者/集成层使用的 proof data 存储位置标识
function getStorageLocations() external view returns (string[] memory) {
    return s_storageLocations; // e.g., ["ipfs://...", "https://ccip-proofs.chainlink.com/..."]
}
```

### 6.3 verifierResults 的完整格式

```text
CommitteeVerifier 的 verifierResults 格式：
════════════════════════════════════════

字节偏移   长度        内容
─────────  ──────────  ─────────────────────────────────────────
[0:4]      4 bytes     VERSION_TAG = 0xe9a05a20
                       （keccak256("CommitteeVerifier 2.0.0")的前4字节）

[4:6]      2 bytes     signatureLength（后面签名总字节数）

[6:6+sigLen] sigLen    签名列表（每个签名 64 字节，r(32B) + s(32B)）
             bytes     签名必须按签名者地址升序排列（防重复攻击）
```

### 6.4 链上签名验证流程

```text
DON节点 (N个)                   CommitteeVerifier (链上合约)
                                OffRamp.execute()
                                  │
                                  ↓ messageId = keccak256(encodedMessage)
                                  │
                                  ↓ ICrossChainVerifierV1.verifyMessage()
                                  │
                    verifierResults  ↓
                    传入 ──────→  CommitteeVerifier.verifyMessage():
                                  ├─ 检查 RMN 诅咒
                                  ├─ 解析 VERSION_TAG
                                  ├─ 提取 signatureLength 个签名
                                  └─ _validateSignatures():
                                     signedHash = keccak256(VERSION_TAG ++ messageId)
                                     ─────────────────────────────────────────
                                     对每个签名（前 threshold 个）：
                                       signerAddr = ecrecover(signedHash, 27, r, s)
                                       ✓ signerAddr 在 s_signerConfigs[srcChain].signers 中？
                                       ✓ signerAddr > lastSignerAddr（防重放/重复）
                                     ─────────────────────────────────────────
                                     ✓ 验证通过：DON 节点已证明此消息真实
```

**签名内容解析**：

```text
被签名的数据 = keccak256(
    bytes4(keccak256("CommitteeVerifier 2.0.0"))     // 绑定版本
    ||
    keccak256(encodedMessage)                         // 绑定完整消息
)
```

这意味着：每个参与签名的 DON 节点，都在声明：
> "我，Oracle 节点 X，用我的 ECDSA Signer Key 签名确认：
> 编码后哈希为 `messageId` 的这条消息，在版本 CommitteeVerifier 2.0.0 的语义下，是真实有效的。"

---

## 7. RMN DON：独立的安全审计层

### 7.1 RMN 节点的观察机制

RMN（Risk Management Network）节点是**完全独立**于 Commit/Execute DON 的另一批节点，运行专用软件：

```text
RMN 节点的工作流程：
═══════════════════

1. 独立观察源链 OnRamp
   ├─ 监控每个已发出消息的 messageId
   └─ 构建自己的消息哈希集合（独立于 Commit DON）

2. 收到 Commit DON 提交的 Merkle Root 请求
   ├─ 验证 Merkle Root 与自己观察到的消息一致
   └─ 参与 RMN 报告签名流程

3. RMN 签名被聚合后附在 CommitReport 中
   └─ 目标链侧再做对应的链上/链下校验
```

```go
// commit/merkleroot/rmn/controller.go:67-90（RMN 控制器接口）
type Controller interface {
    // 向 RMN 节点发送 ObservationRequest，请求它们观察源链
    // 然后发送 ReportSignaturesRequest，获取 RMN 签名
    ComputeReportSignatures(
        ctx context.Context,
        requestedUpdate requestedChainUpdate,
        requestsEnabledMap map[cciptypes.ChainSelector]bool,
    ) (ReportSignatures, error)
}
```

### 7.2 RMN 对 Commit 报告的影响

```go
// commit/internal/builder/report.go（报告构建）
// Merkle roots 分为两类：
// - blessedMerkleRoots：经过 RMN 签名认可的根
// - unblessedMerkleRoots：尚未经过 RMN 认可的根

if outcome.MerkleRootOutcome.RMNEnabledChains[r.ChainSel] {
    blessedMerkleRoots = append(blessedMerkleRoots, r)  // 需要 RMN 签名
} else {
    unblessedMerkleRoots = append(unblessedMerkleRoots, r)  // 不需要
}
```

对于 RMN 相关签名，当前仓库需要区分两类算法：

- **RMN observation 签名**：`Ed25519`
- **进入 `RMNSignatures` / 报告验证流程的签名**：当前代码路径里会解析成 `ECDSA`

另外需要强调：当前 `commit/plugin.go` 已把 `RMNEnabled` 强制降为 `false`，因此这条 bless 流程在当前分支上更像是**保留/兼容逻辑**，不是默认活跃路径。

> **注意**：根据代码中的注释，RMN 在 CCIP 1.6 版本中因一次事故（`INCIDENT-2243`）被**暂时禁用**，`offchainCfg.RMNEnabled` 会被强制设为 `false`：
>
> ```go
> // commit/plugin.go:
> if offchainCfg.RMNEnabled {
>     lggr.Warnw("RMN has been deprecated, RMNEnabled is being set to false", ...)
>     offchainCfg.RMNEnabled = false
> }
> ```

### 7.3 RMN "诅咒"机制

```text
RMN "诅咒"（Curse）流程：
═══════════════════════

RMN 节点发现异常             目标链
     │                          │
     │ 达成"诅咒"共识            │
     │   ───────────────────→   │  RMNRemote.curse(chainSelector)
     │                          │    └─ isCursed[chainSelector] = true
     │                          │
     │                          │  OffRamp.execute() 检查 isCursed(srcChain)
     │                          │    └─ revert CursedByRMN(srcChain)
     │                          │
     │                          │  所有来自该源链的消息执行被阻止
     ↓                          ↓
  异常被遏制              安全保障生效
```

---

## 8. CCIPHome：DON 配置的重要来源

`CCIPHome` 是 OCR3 / DON 配置的重要链上来源之一：

```text
CCIPHome 合约（链上注册中心）
════════════════════════════

存储内容：
  ├─ OCR3Config：
  │    ├─ pluginType（Commit=0, Execute=1）
  │    ├─ chainSelector（目标链）
  │    ├─ fRoleDON（容错 F 值）
  │    ├─ nodes[]：
  │    │    ├─ p2pId（P2P 身份）
  │    │    ├─ signerKey（ECDSA 公钥）
  │    │    └─ transmitterKey（发送交易）
  │    └─ offchainConfig（链下配置）
  │
  └─ VersionedConfig（Active + Candidate 双版本）

在当前 repo 中可直接确认的读取链路：
  CCIPHome.getOCRConfig(donID, pluginType)
       ↓
  homeChainPoller（Go 代码轮询）
       ↓
  OCR3Config.Nodes[].SignerKey / TransmitterKey

但从这里到 `CommitteeVerifier.applySignatureConfigs(...)` 的自动同步链路，当前仓库没有展示完整生产实现，因此不应写成已被源码证明的闭环。
```

```go
// internal/reader/home_chain.go:414-429
type OCR3Config struct {
    PluginType            uint8                   // 0=Commit, 1=Execute
    ChainSelector         cciptypes.ChainSelector // 目标链
    FRoleDON              uint8                   // F 值（容错数量）
    OffchainConfigVersion uint64
    OfframpAddress        []byte                  // OffRamp 合约地址
    RmnHomeAddress        []byte                  // RMNHome 地址
    Nodes                 []OCR3Node              // DON 节点列表
    OffchainConfig        []byte                  // 链下配置
}

type OCR3Node struct {
    P2pID          [32]byte // P2P 网络身份
    SignerKey      []byte   // ECDSA 签名密钥
    TransmitterKey []byte   // 发送交易的地址
}
```

---

## 9. 完整信任链路图

```text
┌─────────────────────────────────────────────────────────────────────┐
│                    完整信任链：从 DON 到链上验证                       │
└─────────────────────────────────────────────────────────────────────┘

【链上配置层】
CCIPHome 合约
  └─ OCR3Config.Nodes[i].SignerKey = 0xAAA, 0xBBB, ..., 0xPPP

CommitteeVerifier 合约
  └─ s_signerConfigs[sourceChain] = {
       signers: [...],
       threshold: 9
     }

两者在职责上可能由同一套运维/治理流程协同配置，
但当前 repo 没有展示“CCIPHome → CommitteeVerifier 自动同步”的完整生产代码。

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

【链下执行层】
源链 OnRamp
  └─ emit CCIPMessageSent(encodedMessage)
                    │
                    ↓ OCR3 Commit DON（多节点独立观察）
                    │  各节点计算 messageId = keccak256(encodedMessage)
                    │  达成 ≥2F+1 共识 → 计算 Merkle Root
                    │  Transmitter 提交 CommitReport 到目标链
                    │
                    ↓ OCR3 Execute DON（多节点独立观察）
                    │  GetCommitReports → GetMessages → Filter
                    │  构建 ExecuteReport（含 Messages / OffchainTokenData / Proofs）
                    │
                    ↓ 后续执行层 / 外部集成层
                    │  （当前 repo 未展示其如何获取 verifierResults）
                    │
OffRamp.execute(encodedMessage, ccvs, verifierResults)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

【链上验证层】
OffRamp.execute()
  ├─ RMNRemote.isCursed(srcChain)?    ← RMN DON 的安全保障
  ├─ OnRamp 白名单检查
  ├─ messageId = keccak256(encodedMessage)
  └─ CommitteeVerifier.verifyMessage(message, messageId, verifierResults)
       ├─ 解析 verifierResults
       └─ _validateSignatures(srcChain, keccak256(VERSION + messageId), sigs)
            ├─ ecrecover → 得到签名者地址
            └─ 签名者地址在 s_signerConfigs[srcChain].signers 中？
                                         ↑
                            这组地址与 DON 节点 SignerKey
                            在部署上可能重合，但当前 repo 未展示自动绑定链路

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

【信任结论】
目标链相信消息真实，因为：
  ✅ ≥threshold 个委员会签名者对该消息哈希给出了有效签名
  ✅ 独立观察到这条消息在源链上存在
  ✅ 对其 messageId（完整消息的哈希）进行了 ECDSA 签名
  ✅ 这些签名在链上通过 CommitteeVerifier 验证通过
  ✅ RMN 网络没有对源链发出"诅咒"
```

---

## 10. 常见问题

### Q1：CommitteeVerifier 的委员会成员是怎么确定的？

由 Chainlink 协议治理决定：

1. `CommitteeVerifier` 的委员会成员最终由 `applySignatureConfigs()` 设置
2. 这个过程是**可审计的**，因为会发出 `SignatureConfigSet` 事件
3. `CCIPHome` 中也维护 OCR3 节点的 `SignerKey`，两套配置在部署上可能协同，但当前 repo 没有展示二者的自动映射过程

### Q2：OCR3 节点签名与 CommitteeVerifier 签名是同一个吗？

**有区别，但来自同一密钥对**：

- OCR3 协议本身有自己的报告签名（用于 OCR3 内部共识验证）
- CommitteeVerifier 中消费的签名是对 `keccak256(VERSION_TAG ++ messageId)` 的签名
- 两者都使用节点的 `SignerKey`（ECDSA），但签名的内容不同

### Q3：如果一个 DON 节点被攻破，会怎样？

假设攻击者控制了 K 个节点的 `SignerKey`：

- 如果 K < threshold：无法伪造有效签名
- 如果 K ≥ threshold：可以对任意构造的消息签名，但 RMN 独立监控可以发出"诅咒"阻止执行
- 如果 K ≥ threshold **并且** RMN 也被控制：此时安全性已被完全破坏

实际上，CCIP 的安全性依赖于：DON 节点由不同运营商在不同地理位置运营，共谋攻击成本极高。

### Q4：Commit DON 和 Execute DON 是同一批节点吗？

可以是，也可以不是。两者都通过 `CCIPHome.OCR3Config` 配置，可以配置不同的节点集合。实际部署中，通常使用同一批节点但配置两个独立的 OCR3 实例（不同的 DON ID）。

### Q5：为什么需要 RMN 这个独立的安全层？

**深度防御（Defense in Depth）**：

- Commit/Execute DON 负责正常的消息流通
- RMN 负责异常检测和紧急制动

如果 Commit DON 的足够多节点被攻破，理论上可能推动错误的提交结果。RMN 作为独立网络，设计目标是检测这种异常并通过"诅咒"机制阻止后续执行，为人工介入争取时间。需要注意的是，当前分支中 commit-side RMN 逻辑已被显式降级/禁用。

---

*文档版本：基于 chainlink-ccip 代码库，OCR3 + CommitteeVerifier 架构*  
*关联文档：[消息阶段分析](./ccip_cross_chain_message_phases.md) | [消息验证机制](./ccip_message_verification.md) | [Gas 深度解析](./ccip_gas_deep_dive.md)*
