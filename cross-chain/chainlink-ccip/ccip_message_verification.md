# CCIP 跨链消息验证机制深度解析

> 本文档回答一个核心问题：**目标链如何相信跨链消息的真实性？**  
> 覆盖范围：CCV 架构、签名验证流程、RMN 安全层、OnRamp 来源绑定、重放保护，以及完整的链上验证流程图。

---

## 1. 验证的根本问题

跨链消息的核心安全挑战：

```text
源链（Chain A）                    目标链（Chain B）
┌──────────────────┐               ┌──────────────────┐
│  合约 A 发送消息  │               │  合约 B 收到消息  │
│  "转移 100 USDC  │  ─── ??? ──→  │  合约 B 信任这    │
│   给地址 0xABC"  │               │  条消息是真实的？ │
└──────────────────┘               └──────────────────┘
```

问题核心：

- **没有共享状态**：Chain B 无法直接读取 Chain A 上的事件
- **任意人可提交**：任何人都可以调用 `OffRamp.execute`
- **内容可伪造**：如果没有加密证明，攻击者可以构造虚假消息

---

## 2. CCIP v2 的验证架构总览

CCIP v2 采用**模块化多层验证**架构，抛弃了旧版的"单一 CommitStore + Merkle proof"模式，改为：

```text
                    验证责任分层
                    ════════════

┌─────────────────────────────────────────────────────────┐
│  Layer 1: RMN（风险管理网络）                             │
│  独立的安全监控层，可在紧急情况下"诅咒"（Curse）某条链   │
│  阻止所有消息的执行。当前分支里 commit-side RMN 已被      │
│  显式降级/禁用，但 curse 检查仍然存在。                   │
└─────────────────────────────────────────────────────────┘
                         │
┌─────────────────────────────────────────────────────────┐
│  Layer 2: CCVs（Cross-Chain Verifiers，跨链验证器）       │
│  - CommitteeVerifier：OCR3 委员会签名验证（默认）         │
│  - CCTPVerifier：Circle CCTP 原生证明验证                │
│  - LombardVerifier：Lombard 协议专用验证器               │
│  - 自定义：任何实现 ICrossChainVerifierV1 的合约         │
└─────────────────────────────────────────────────────────┘
                         │
┌─────────────────────────────────────────────────────────┐
│  Layer 3: OnRamp 白名单                                   │
│  目标链 OffRamp 只信任已注册的源链 OnRamp 发出的消息       │
└─────────────────────────────────────────────────────────┘
                         │
┌─────────────────────────────────────────────────────────┐
│  Layer 4: 重放保护                                        │
│  每条消息只能被执行一次（基于 messageId 的状态机）         │
└─────────────────────────────────────────────────────────┘
```

---

## 3. 消息 ID：验证的"锚点"

### 消息 ID 的计算

```solidity
// OffRamp.sol
bytes32 messageId = keccak256(encodedMessage);
```

`encodedMessage` 是完整的 `MessageV1` 结构体的 ABI 编码，包含：

| 字段 | 说明 |
| ---- | ---- |
| `sourceChainSelector` | 源链标识符 |
| `destChainSelector` | 目标链标识符 |
| `messageNumber` | 序列号（防止重放） |
| `ccvAndExecutorHash` | CCV 地址列表的哈希（防篡改） |
| `onRampAddress` | 发送端合约地址 |
| `offRampAddress` | 接收端合约地址 |
| `sender` | 原始发送方地址 |
| `receiver` | 目标接收方地址 |
| `data` | 应用层数据 |
| `tokenTransfer` | 代币转移信息 |
| … | 其他字段 |

**关键安全属性**：消息中的每个字段都参与 `messageId` 的计算。任意一个字节被修改，`messageId` 就会不同，导致 CCV 签名验证失败。

---

## 4. ccvAndExecutorHash：防篡改的承诺

### 字段定义

```solidity
// MessageV1Codec.sol:141
struct MessageV1 {
    ...
    bytes32 ccvAndExecutorHash; // Hash of the verifiers and executor addresses.
    ...
}
```

### 计算方式

```solidity
// MessageV1Codec.sol:186-218
function _computeCCVAndExecutorHash(
    address[] memory ccvs,
    address executor
) internal pure returns (bytes32) {
    uint256 encodedLength = 1 + ccvs.length * 20 + 20;
    bytes memory encoded = new bytes(encodedLength + 12);
    encoded[0] = bytes1(uint8(20)); // EVM 地址长度标记

    uint256 offset = 33;
    for (uint256 i = 0; i < ccvs.length; ++i) {
        assembly {
            mstore(add(encoded, offset), shl(96, ccvsAddress))
            offset := add(offset, 20)
        }
    }
    // ... executor 地址追加
    return keccak256(encoded);
}
```

### 作用

`ccvAndExecutorHash` 在 **OnRamp** 中设置（源链），作为消息体的一部分被签名：

```solidity
// OnRamp.sol:276-278
// Set the ccvAndExecutorHash now that the CCV list is finalized.
newMessage.ccvAndExecutorHash =
    MessageV1Codec._computeCCVAndExecutorHash(resolvedExtraArgs.ccvs, resolvedExtraArgs.executor);
```

这确保了：

- **CCV 列表是源链在 OnRamp 时确定的**，不能被执行者篡改
- 攻击者不能"替换"验证器（例如用一个弱验证器替换强验证器）
- CCV 签名会覆盖 `ccvAndExecutorHash`，从而间接保护 CCV 列表的完整性

---

## 5. CCV（Cross-Chain Verifier）体系

### 5.1 CCV 的角色与接口

CCV 是 CCIP v2 的核心可扩展验证接口：

```solidity
// ICrossChainVerifierV1.sol
interface ICrossChainVerifierV1 is IERC165 {
    /// @notice 验证消息的真实性
    /// @param message    完整的 MessageV1 结构体
    /// @param messageId  keccak256(encodedMessage)，消息指纹
    /// @param verifierResults  验证器特定的证明数据（签名、ZK proof 等）
    function verifyMessage(
        MessageV1Codec.MessageV1 memory message,
        bytes32 messageId,
        bytes memory verifierResults
    ) external;

    /// @notice 源链钩子：消息发出时通知 CCV
    function forwardToVerifier(
        MessageV1Codec.MessageV1 calldata message,
        bytes32 messageId,
        address feeToken,
        uint256 feeTokenAmount,
        bytes calldata verifierArgs
    ) external returns (bytes memory verifierData);

    /// @notice 返回链下存储位置（供 Executor 找到证明数据）
    function getStorageLocations() external view returns (string[] memory);
}
```

**设计哲学**：CCV 是一个开放接口，可以用签名、ZK 证明、原生互操作协议（如 CCTP）等任何方式来证明消息真实性。

### 5.2 CommitteeVerifier：默认实现

`CommitteeVerifier` 是 Chainlink 提供的默认 CCV，使用**委员会多签**验证：

#### 验证逻辑

```solidity
// CommitteeVerifier.sol:76-110
function verifyMessage(
    MessageV1Codec.MessageV1 calldata message,
    bytes32 messageHash,           // = keccak256(encodedMessage)
    bytes calldata verifierResults // = [版本号(4B) | 签名数量(2B) | 签名列表]
) external view {
    // 1. 检查 RMN 是否诅咒了源链
    _assertNotCursedByRMN(message.sourceChainSelector);

    // 2. 验证 verifierResults 格式
    bytes4 verifierVersion = bytes4(verifierResults[:4]);
    if (verifierVersion != VERSION_TAG_V2_0_0) {
        revert InvalidCCVVersion(verifierVersion);
    }

    // 3. 提取签名列表，验证委员会签名
    // 签名对象 = keccak256(verifierVersion ++ messageHash)
    _validateSignatures(
        message.sourceChainSelector,
        keccak256(bytes.concat(verifierVersion, messageHash)),
        signatures
    );
}
```

#### 签名验证（ECDSA 多签）

```solidity
// SignatureQuorumValidator.sol:62-100
function _validateSignatures(
    uint64 sourceChainSelector,
    bytes32 signedHash,           // keccak256(version ++ messageId)
    bytes calldata signatures     // 紧密编码的 64 字节签名列表（r+s，无 v）
) internal view {
    SignerConfig storage cfg = s_signerConfigs[sourceChainSelector];
    uint256 threshold = cfg.threshold; // 例如：需要 9/16 签名

    // 防分叉保护
    if (i_chainID != block.chainid) revert ForkedChain(i_chainID, block.chainid);

    uint256 numberOfSignatures = signatures.length / SIGNATURE_LENGTH;
    if (numberOfSignatures < threshold) revert WrongNumberOfSignatures();

    uint160 lastSigner = 0; // 签名必须按地址升序排列（防重复）

    for (uint256 i; i < threshold; ++i) {
        // v 值强制为 27（利用 ECDSA 延展性）
        address signer = ecrecover(signedHash, 27, r, s);

        if (!cfg.signers.contains(signer)) revert UnauthorizedSigner();
        if (uint160(signer) <= lastSigner) revert NonOrderedOrNonUniqueSignatures();
        lastSigner = uint160(signer);
    }
}
```

**签名内容详解**：

```text
什么被签名？
keccak256(
    VERSION_TAG_V2_0_0 (4 bytes)     // "CommitteeVerifier 2.0.0" 版本标签
    ||
    keccak256(encodedMessage)         // 完整消息的哈希
)
```

版本标签被包含在签名内容中，原因：
> 防止有人在签名生成后，替换 verifierResults 中的版本字节，伪装成另一个版本的验证器

#### 委员会成员配置

```solidity
// SignatureQuorumValidator.sol
struct SignerConfig {
    EnumerableSet.AddressSet signers; // 委员会成员地址集合
    uint8 threshold;                   // 最少需要多少个签名
}

// 配置示例（从合约配置角度）：
// sourceChainSelector: Ethereum Mainnet (5009297550715157269)
// signers: [OCR3节点0地址, OCR3节点1地址, ..., OCR3节点15地址]
// threshold: 9  ← 需要 9/16 签名
```

> **更稳妥的表述**：委员会成员地址与 OCR3 / DON 节点运营体系通常强相关，但当前仓库没有展示“从 `CCIPHome.OCR3Config.Nodes[].SignerKey` 自动同步到 `CommitteeVerifier.applySignatureConfigs()`”的生产代码，因此不应写成源码已证明的一一绑定。

### 5.3 VersionedVerifierResolver：版本路由

当 CCV 地址实际上是一个 `VersionedVerifierResolver` 时，`OffRamp` 会先通过解析器找到真实的验证器：

```solidity
// OffRamp.sol:344-352（executeSingleMessage 内）
address implAddress = ICrossChainVerifierResolver(ccvsToQuery[i])
    .getInboundImplementation(verifierResults[verifierResultsIndex[i]]);
// ↑ 解析器从 verifierResults 的前 4 字节（版本标签）找到对应实现

if (implAddress == address(0)) {
    revert InboundImplementationNotFound(...);
}

ICrossChainVerifierV1(implAddress).verifyMessage({...});
```

```solidity
// VersionedVerifierResolver.sol:57-63
function getInboundImplementation(
    bytes calldata verifierResults
) external view returns (address) {
    if (verifierResults.length < 4) revert InvalidVerifierResultsLength();
    // 前 4 字节是版本标签，用于查找对应的 Verifier 合约地址
    return s_versionToInboundImplementation[bytes4(verifierResults[:4])];
}
```

这使 CCV 的实现可以无缝升级，而无需更改 OffRamp 配置。

---

## 6. 链上验证流程（OffRamp.execute）

### 流程概览

```text
OffRamp.execute(encodedMessage, ccvs[], verifierResults[], gasLimitOverride)
    │
    ├─[防线1] 结构合法性检查
    ├─[防线2] OnRamp 白名单检查（来源合法性）
    ├─[防线3] OffRamp 自引用检查
    ├─[防线4] 目标链检查
    ├─[防线5] 重放保护（执行状态检查）
    ├─[防线6] RMN 诅咒检查
    │
    └─→ executeSingleMessage(message, messageId, ccvs, verifierResults, ...)
            │
            ├─[防线7] CCV 法定人数检查（_ensureCCVQuorumIsReached）
            └─[防线8] CCV 签名验证（ICrossChainVerifierV1.verifyMessage）
```

### 6.1 第一道防线：结构合法性检查

```solidity
// OffRamp.sol:200-225
MessageV1Codec.MessageV1 memory message = MessageV1Codec._decodeMessageV1(encodedMessage);

// 目标链必须是当前链
if (message.destChainSelector != i_chainSelector) {
    revert InvalidMessageDestChainSelector(message.destChainSelector);
}

// OffRamp 地址必须是自身
if (message.offRampAddress.length != 20 || address(bytes20(message.offRampAddress)) != address(this)) {
    revert InvalidOffRamp(address(this), message.offRampAddress);
}

// receiver 必须是合法的 EVM 地址（20 字节）
if (message.receiver.length != 20) {
    revert Internal.InvalidEVMAddress(message.receiver);
}

// verifierResults 和 ccvs 长度必须匹配
if (ccvs.length != verifierResults.length) {
    revert InvalidVerifierResultsLength(ccvs.length, verifierResults.length);
}
```

### 6.2 第二道防线：来源合法性（OnRamp 白名单）

```solidity
// OffRamp.sol:203-207
// 源链必须已启用
if (!s_sourceChainConfigs[message.sourceChainSelector].isEnabled) {
    revert SourceChainNotEnabled(message.sourceChainSelector);
}

// OnRamp 地址必须在白名单中
if (!s_allowedOnRampHashes[message.sourceChainSelector].contains(keccak256(message.onRampAddress))) {
    revert InvalidOnRamp(message.onRampAddress);
}
```

**白名单管理**（OffRamp 管理员操作）：

```solidity
// OffRamp.sol:906-945（applySourceChainConfigUpdates）
EnumerableSet.Bytes32Set storage allowedOnRampHashes = s_allowedOnRampHashes[...];
allowedOnRampHashes.clear();
for (uint256 j = 0; j < configUpdate.onRamps.length; ++j) {
    bytes32 onRampHash = keccak256(onRamp);
    allowedOnRampHashes.add(onRampHash);
}
```

> 这确保只有已被 Chainlink 协议注册的 `OnRamp` 合约发出的消息才能被执行。攻击者即使能模拟消息内容，也无法伪造 `onRampAddress` 字段（因为它参与了 `messageId` 的计算，改变它会使签名失效）。

### 6.3 第三道防线：CCV 法定人数检查

```solidity
// OffRamp.sol:339-340（executeSingleMessage 内）
(address[] memory ccvsToQuery, uint256[] memory verifierResultsIndex) =
    _ensureCCVQuorumIsReached(message, receiver, ccvs, isTokenOnlyTransfer);
```

`_ensureCCVQuorumIsReached` 的逻辑（简化版）：

```text
1. 调用 _getCCVsForMessage() 确定此消息需要哪些 CCVs：
   ├─ 从 TokenPool 获取 requiredPoolCCVs
   ├─ 从 Receiver 合约获取 requiredReceiverCCVs + optionalCCVs + optionalThreshold
   ├─ 加上 Lane 强制 CCVs (laneMandatedCCVs)
   └─ 如果有 address(0)，替换为默认 CCVs (defaultCCVs)

2. 检查调用者提供的 ccvs[] 是否覆盖了所有 required CCVs
   └─ 任一 required CCV 缺失 → revert RequiredCCVMissing(...)

3. 检查 optional CCVs 是否达到法定人数 (optionalThreshold)
   └─ 不足 → revert OptionalCCVQuorumNotReached(...)
```

### 6.4 第四道防线：CCV 签名验证

```solidity
// OffRamp.sol:344-352（executeSingleMessage 内）
for (uint256 i = 0; i < ccvsToQuery.length; ++i) {
    // 通过 Resolver 找到真实的验证器实现地址
    address implAddress = ICrossChainVerifierResolver(ccvsToQuery[i])
        .getInboundImplementation(verifierResults[verifierResultsIndex[i]]);

    if (implAddress == address(0)) {
        revert InboundImplementationNotFound(ccvsToQuery[i], verifierResults[...]);
    }

    // 调用实际的验证器进行验证
    ICrossChainVerifierV1(implAddress).verifyMessage({
        message: message,
        messageId: messageId,     // = keccak256(encodedMessage)
        verifierResults: verifierResults[verifierResultsIndex[i]]
    });
    // 若验证失败，verifyMessage 会 revert
}
```

对于 `CommitteeVerifier`，验证内容等同于：

```text
验证 ≥ threshold 个委员会成员对以下内容进行了签名：
    keccak256(
        bytes4(keccak256("CommitteeVerifier 2.0.0"))  // 版本标签
        ||
        keccak256(encodedMessage)                      // 完整消息哈希
    )
```

### 6.5 第五道防线：RMN 诅咒检查

**两处 RMN 检查**：

① 在 `OffRamp.execute` 的最开始：

```solidity
// OffRamp.sol:198
if (i_rmnRemote.isCursed(bytes16(uint128(message.sourceChainSelector)))) {
    revert CursedByRMN(message.sourceChainSelector);
}
```

② 在 `CommitteeVerifier.verifyMessage` 中：

```solidity
// CommitteeVerifier.sol:81
_assertNotCursedByRMN(message.sourceChainSelector);
```

> RMN 是 CCIP 的独立安全层，由运行专用软件的节点组成，监控链上活动，当发现异常时可"诅咒"某条链，阻止所有消息执行。

### 6.6 第六道防线：重放保护（执行状态）

```solidity
// OffRamp.sol:228-238
bytes32 messageId = keccak256(encodedMessage);
Internal.MessageExecutionState originalState = s_executionStates[messageId];

// 只允许 UNTOUCHED 或 FAILURE 状态的消息被执行
if (!(originalState == Internal.MessageExecutionState.UNTOUCHED
      || originalState == Internal.MessageExecutionState.FAILURE)) {
    revert SkippedAlreadyExecutedMessage(messageId, ...);
}

// 立即设置为 IN_PROGRESS，防止重入
s_executionStates[messageId] = Internal.MessageExecutionState.IN_PROGRESS;
```

**状态机**：

```text
UNTOUCHED ──→ IN_PROGRESS ──→ SUCCESS   (终态)
                          └──→ FAILURE  (可重试)
```

---

## 7. RMN（Risk Management Network）

### 架构

```text
RMN 节点网络（独立于 OCR3 节点）
    │
    ├─ 监控源链的 OnRamp 事件
    ├─ 独立观察和验证跨链消息
    ├─ 参与 Commit 相关的独立签名/背书流程
    └─ 在发现异常时可对链施加 curse
            │
            ↓
    RMNRemote 合约（目标链）
        │
        ├─ isCursed(chainSelector)  ← OffRamp 检查此状态
        └─ 为安全熔断提供链上状态来源
```

### RMN 对 Commit 报告的影响

```go
// commit/internal/builder/report.go:76-90
// Merkle roots 分为两类：
// - blessedMerkleRoots：经过 RMN 签名认可的 roots
// - unblessedMerkleRoots：尚未经过 RMN 认可的 roots

if outcome.MerkleRootOutcome.RMNEnabledChains[r.ChainSel] {
    blessedMerkleRoots = append(blessedMerkleRoots, r)
} else {
    unblessedMerkleRoots = append(unblessedMerkleRoots, r)
}
```

对于 RMN 相关签名，当前仓库需要区分两层：

- **RMN observation 签名**：代码中明确使用 `Ed25519`
- **进入 `RMNSignatures` / 报告验证流程的签名**：代码路径里会被解析为 `ECDSA`

另外，当前 `commit/plugin.go` 会把 `RMNEnabled` 强制改成 `false`，因此这里描述的 bless 流程更适合作为架构说明或保留逻辑理解，而不是当前分支的默认活跃路径。

### IRMNRemote 接口

```solidity
// BaseVerifier.sol:59
IRMNRemote internal immutable i_rmn;

// BaseVerifier.sol:256-261
function _assertNotCursedByRMN(uint64 destChainSelector) internal view virtual {
    if (i_rmn.isCursed(bytes16(uint128(destChainSelector)))) {
        revert CursedByRMN(destChainSelector);
    }
}
```

---

## 8. CCV 来源的多样性

`_getCCVsForMessage` 从**四个来源**聚合所需的 CCV 列表：

### 8.1 接收方合约指定 CCVs

接收方合约可以实现 `IAny2EVMMessageReceiverV2` 接口，声明自己需要哪些验证器：

```solidity
// OffRamp.sol:700-720
if (receiver._supportsInterfaceReverting(type(IAny2EVMMessageReceiverV2).interfaceId)) {
    (requiredCCV, optionalCCVs, optionalThreshold, minBlockConfirmations) =
        IAny2EVMMessageReceiverV2(receiver).getCCVsAndMinBlockConfirmations(
            sourceChainSelector, sender
        );
}
```

应用场景：

- DeFi 协议需要 **2 个以上的 CCV** 进行高价值操作
- 某协议集成了 Circle CCTP，要求使用 `CCTPVerifier` 来验证 USDC 转账
- 协议想在 CommitteeVerifier 之外，额外要求 Lombard 验证器

### 8.2 Token Pool 指定 CCVs

```solidity
// OffRamp.sol:763-772
if (pool._supportsInterfaceReverting(type(IPoolV2).interfaceId)) {
    requiredCCV = IPoolV2(pool).getRequiredCCVs(
        localToken, sourceChainSelector, amount, finality, extraData,
        IPoolV2.MessageDirection.Inbound
    );
}

// 如果池没有指定 CCV，回退到默认
if (requiredCCV.length == 0) {
    return new address[](1); // address(0) 代表"用默认 CCV"
}
```

应用场景：

- USDC Lock/Mint Pool 可以要求 CCTPVerifier，确保 Circle 原生验证
- 高价值代币池要求额外的 RMN 签名（Blessed）

### 8.3 Lane 强制 CCVs

管理员可以为某条 Lane 配置必须使用的 CCVs：

```solidity
// OffRamp.sol:536-550（_getCCVsForMessage）
address[] storage laneMandatedCCVs = s_sourceChainConfigs[sourceChainSelector].laneMandatedCCVs;

for (uint256 i = 0; i < laneMandatedCCVsLength; ++i) {
    allRequiredCCVs[index++] = laneMandatedCCVs[i];
}
```

### 8.4 默认 CCVs 与 address(0) 回退

```solidity
// address(0) 是"使用默认 CCV"的标记
address[] storage defaultCCVs = s_sourceChainConfigs[sourceChainSelector].defaultCCVs;

// 如果任意 required CCV 是 address(0)，用 defaultCCVs 替换
for (uint256 i = 0; i < index; ++i) {
    if (allRequiredCCVs[i] == address(0)) {
        for (uint256 j = 0; j < defaultCCVsLength; ++j) {
            allRequiredCCVs[index++] = defaultCCVs[j]; // 通常是 CommitteeVerifier
        }
        break;
    }
}
```

这个设计保证了**向后兼容**：旧版本的 Pool 和 Receiver 不需要指定 CCV，自动使用协议级别的默认验证器。

---

## 9. 完整验证流程图

```text
源链（Chain A）                                      目标链（Chain B）
═══════════════                                     ═══════════════════

1. 用户调用 Router.ccipSend()
   │
   ↓
2. OnRamp.forwardFromRouter()
   ├─ 调用 CCV.forwardToVerifier()（源链钩子）
   ├─ 计算 ccvAndExecutorHash
   ├─ 构建 MessageV1（包含 ccvAndExecutorHash）
   └─ emit CCIPMessageSent(encodedMessage, receipts)
                │
                │  encodedMessage 被记录在源链事件日志中
                │
                ↓ (OCR3 Commit 插件观察)
3. Commit 插件运行：
   ├─ 各 OCR3 节点观察源链，收集消息哈希
   ├─ 计算 Merkle Root (for RMN chains)
   ├─ 向 RMN 节点请求签名（如果启用 RMN）
   ├─ OCR3 达成共识，生成 CommitReport
   └─ 将 CommitReport 提交到目标链（OCR3 transmit）
                │
                │
                ↓ (OCR3 Execute 插件准备执行)
4. Execute 插件运行（针对每条消息）：
   ├─ 从已提交的 CommitReport 中读取消息并构建 ExecuteReport
   ├─ 当前仓库里它直接产出的结构包含：
   │      ┌──────────────────────────────────────────────┐
   │      │  ExecutePluginReportSingleChain              │
   │      │  • Messages                                  │
   │      │  • OffchainTokenData                         │
   │      │  • Proofs                                    │
   │      │  • ProofFlagBits                             │
   │      └──────────────────────────────────────────────┘
   └─ 当前 repo 的 execute plugin 代码没有展示：
      • 去读取 `CCV.getStorageLocations()`
      • 去拉取 `verifierResults`
      • 去直接拼出 `OffRamp.execute(encodedMessage, ccvs[], verifierResults[], 0)`

   因此，更合理的理解是：`verifierResults` 的获取和最终执行交易的组织，可能由仓库外的 executor / 集成层负责。
                │
                ↓ 链上执行
5. OffRamp.execute() 验证链（目标链）：
   │
   ├─[检查1] RMN 未诅咒源链？ ← isCursed(sourceChainSelector)
   ├─[检查2] 源链已启用？ ← isEnabled
   ├─[检查3] OnRamp 地址在白名单中？ ← s_allowedOnRampHashes
   ├─[检查4] OffRamp 地址是自身？ ← address(this)
   ├─[检查5] destChainSelector 是当前链？ ← i_chainSelector
   ├─[检查6] 消息未被执行过？ ← s_executionStates[messageId]
   │
   └─→ executeSingleMessage()
         │
         ├─[检查7] _ensureCCVQuorumIsReached()
         │          ├─ 获取 required CCVs（来自 Pool + Receiver + Lane + Default）
         │          ├─ 确认提供的 ccvs[] 覆盖了所有 required CCVs
         │          └─ 确认 optional CCVs 达到 threshold
         │
         └─[检查8] 对每个 CCV 调用 verifyMessage()
                    │
                    ├─ Resolver.getInboundImplementation(verifierResults)
                    │  └→ CommitteeVerifier（或其他实现）
                    │
                    └─ CommitteeVerifier.verifyMessage():
                       ├─ 检查 RMN 未诅咒源链
                       ├─ 解析 verifierResults（版本 + 签名列表）
                       └─ _validateSignatures():
                          ├─ 检查链 ID（防分叉）
                          ├─ 检查签名数 ≥ threshold
                          └─ 对每个签名，ecrecover 并验证：
                             • 签名者在委员会中
                             • 签名按地址升序排列（防重复）
                             • 签名内容 = keccak256(VERSION_TAG ++ messageId)
                               其中 messageId = keccak256(encodedMessage)
```

---

## 10. 安全属性分析

### 10.1 消息不可伪造

攻击者如果想伪造一条消息：

- 必须控制 ≥ threshold 个委员会成员的私钥
- 这些节点由 Chainlink DON 运营，受 Chainlink 安全机制保护

### 10.2 消息不可篡改

即使消息在传输中被截获，任何修改（哪怕一个字节）都会：

1. 改变 `messageId = keccak256(encodedMessage)`
2. 使委员会签名验证失败（签名是针对原始 messageId 的）

### 10.3 CCV 列表不可替换

`ccvAndExecutorHash` 字段是消息体的一部分，被包含在 `messageId` 中。攻击者如果想替换 CCV：

1. 必须改变 `ccvAndExecutorHash` 字段
2. 这会改变 `messageId`
3. 导致签名验证失败

### 10.4 重放不可能

`s_executionStates[messageId]` 是一个单调递增的状态机：

- 成功执行后变为 `SUCCESS`（终态），无法再次执行
- 即使不同的 Executor 在不同时间调用，第二次调用会 `revert SkippedAlreadyExecutedMessage`

### 10.5 来源链欺骗不可能

OnRamp 白名单（`s_allowedOnRampHashes`）确保：

- 只有已注册的、真实部署的 OnRamp 合约发出的消息才会被接受
- 攻击者无法构造一条"来自" Chainlink 官方 OnRamp 的虚假消息

### 10.6 链重放保护（Fork Protection）

```solidity
// SignatureQuorumValidator.sol:75
if (i_chainID != block.chainid) revert ForkedChain(i_chainID, block.chainid);
```

如果目标链发生分叉（Chain B 分叉为 B 和 B'），在 B 上有效的签名不能在 B' 上使用（链 ID 不同）。

---

## 11. 与 CCIP v1（旧版）架构对比

| 特性 | CCIP v1 | CCIP v2 |
| ---- | ------- | ------- |
| 验证方式 | CommitStore + Merkle Proof | CCV 签名（模块化） |
| 消息提交 | Executor 提供 Merkle 证明 | Executor 提供 CCV 证明 |
| 可扩展性 | 单一验证机制 | 多种 CCV 并存（CCTP、ZK、etc.） |
| 自定义安全 | 不支持 | 接收方可声明所需 CCVs |
| 代币池集成 | 独立 | 池可声明所需 CCVs |
| 升级机制 | 需修改 CommitStore | VersionedVerifierResolver 无缝升级 |

---

## 12. 常见问题

### Q1：Executor 是可信的吗？

**不。** Executor 是无许可的（任何人都可以调用 `OffRamp.execute`）。Executor 只是一个搬运工，负责将消息和 CCV 证明提交到链上。即使 Executor 恶意修改消息内容，CCV 签名验证也会失败。

### Q2：如果委员会 9/16 的节点被攻破，会怎样？

如果 ≥ threshold 个委员会节点被攻破，攻击者可以：

- 对任意构造的消息进行签名，让 CommitteeVerifier 通过
- 但 RMN 是独立的安全层，可以"诅咒"该链，阻止执行

因此，CCIP 的安全性是 **CommitteeVerifier 安全性 AND RMN 安全性** 的组合。

### Q3：CCV 地址是谁决定的？

源链 `OnRamp` 调用 `_mergeCCVLists`，合并以下来源的 CCV：

1. 用户在 `extraArgs` 中指定的 CCVs
2. Token Pool 要求的 CCVs
3. Lane 管理员设置的强制 CCVs

最终的 CCV 列表被哈希为 `ccvAndExecutorHash`，作为消息的一部分被签名，目标链不能更改。

### Q4：verifierResults 中的签名是谁产生的？

当前仓库源码只能明确证明两件事：

- `CommitteeVerifier.verifyMessage()` 期望 `verifierResults` 中带有版本号和签名
- `ICrossChainVerifierV1.getStorageLocations()` 为外部执行者提供 proof data 定位接口

但当前 repo 中的 execute plugin 没有展示“如何拉取这些签名并组装成 `verifierResults`”的实现。因此更准确的说法是：

- 这些签名应由 `CommitteeVerifier` 对应的链下系统/委员会成员离线产生
- `verifierResults` 的获取和提交，属于当前仓库之外的 executor / 集成层职责，至少在本 repo 中没有完整实现闭环

### Q5：为什么 `verifierResults` 中需要包含版本标签？

```solidity
// CommitteeVerifier.sol:103-105
// The version is included so that a resolver can return the correct verifier implementation on destination.
// The version must be signed, otherwise any version could be inserted post-signatures.
keccak256(bytes.concat(verifierVersion, messageHash))
```

如果版本不被签名，攻击者可以先获取旧版签名，然后替换版本标签，让 Resolver 路由到另一个（可能更弱的）验证器实现。

---

*文档版本：基于 chainlink-ccip 代码库，CCV 架构版本 2.0.0*  
*关联文档：[消息阶段分析](./ccip_cross_chain_message_phases.md) | [Gas 深度解析](./ccip_gas_deep_dive.md) | [审计排障指南](./ccip_cross_chain_message_audit_debug.md) | [DON 网络与验证关联](./ccip_don_and_verification.md)*
