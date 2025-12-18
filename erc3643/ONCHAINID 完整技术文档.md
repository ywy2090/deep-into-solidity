
# ONCHAINID 完整技术文档

## 一、核心概念

### 1.1 什么是 ONCHAINID？

**ONCHAINID** 是一个基于 **ERC-734**（密钥管理）和 **ERC-735**（声明管理）标准的**去中心化自主身份（Self-Sovereign Identity, SSI）系统**[ref:1,2,3]。

#### 定义特征
- **自主身份**：由身份所有者完全控制，无需依赖中心化机构
- **链上存储**：身份存储在 Polygon 网络（可部署到任何 EVM 兼容链）
- **不可删除**：一旦部署，任何组织或服务都无法删除或撤销访问权限
- **终身有效**：身份跨越整个生命周期
- **信息聚合器**：可聚合来自多个可信第三方的认证信息
- **合规化匿名性**：实现 "Compliant Pseudonymity"，在保护隐私的同时满足监管要求[ref:1]

---

### 1.2 核心架构组成

ONCHAINID 系统由三层架构构成：

```
┌─────────────────────────────────────────────────────┐
│           应用层（Application Layer）                │
│  • 用户界面   • DApp 集成   • API/SDK                │
└─────────────────────┬───────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────┐
│         智能合约层（Smart Contract Layer）           │
│  • ERC-734 Key Management                           │
│  • ERC-735 Claim Holder                             │
└─────────────────────┬───────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────┐
│         数据层（Data Layer）                         │
│  • 链上：声明签名、公钥、元数据                        │
│  • 链下：敏感数据（IPFS/私有服务器）                   │
└─────────────────────────────────────────────────────┘
```

---

## 二、ERC-734 密钥管理标准

### 2.1 标准概述

**ERC-734** 定义了一个密钥管理器合约，允许身份持有者管理用于不同目的的多个密钥[ref:11]。

#### 密钥用途（Key Purposes）
- **Purpose 1: MANAGEMENT** - 管理密钥，可以添加/删除其他密钥
- **Purpose 2: EXECUTION** - 执行密钥，可以执行交易、签署文档、登录等
- **Purpose 3+**: 可自定义其他用途

#### 密钥类型（Key Types）
- **Type 1: ECDSA** - 以太坊标准椭圆曲线签名
- **Type 2: RSA** - RSA 加密密钥
- **Type 3+**: 其他加密算法

---

### 2.2 数据结构

```solidity
struct Key {
    uint256[] purposes;    // 密钥用途数组，一个密钥可有多个用途
    uint256 keyType;       // 密钥类型（ECDSA, RSA等）
    bytes32 key;          // 公钥（长密钥存储其 keccak256 哈希）
}
```

**存储结构**：
```solidity
mapping(bytes32 => Key) keys;                      // 密钥ID → 密钥数据
mapping(uint256 => bytes32[]) keysByPurpose;       // 用途 → 密钥ID列表
```

---

### 2.3 核心函数

#### 查询函数

```solidity
// 获取密钥完整信息
function getKey(bytes32 _key) 
    public 
    constant 
    returns(
        uint256[] purposes, 
        uint256 keyType, 
        bytes32 key
    );

// 检查密钥是否具有特定用途
function keyHasPurpose(bytes32 _key, uint256 purpose) 
    public 
    constant 
    returns (bool exists);

// 获取特定用途的所有密钥
function getKeysByPurpose(uint256 _purpose) 
    public 
    constant 
    returns(bytes32[] keys);

// 获取执行特定操作所需的密钥数量（多签）
function getKeysRequired(uint256 purpose) 
    external 
    view 
    returns(uint256);
```

#### 管理函数

```solidity
// 添加密钥（仅限 MANAGEMENT 密钥或身份合约自身）
function addKey(
    bytes32 _key, 
    uint256 _purpose, 
    uint256 _keyType
) returns (bool success);

// 移除密钥（仅限 MANAGEMENT 密钥或身份合约自身）
function removeKey(
    bytes32 _key, 
    uint256 _purpose
) returns (bool success);

// 修改多签所需密钥数量
function changeKeysRequired(
    uint256 purpose, 
    uint256 number
) external;
```

#### 执行函数

```solidity
// 提交待批准的执行请求
function execute(
    address _to, 
    uint256 _value, 
    bytes _data
) returns (uint256 executionId);

// 批准执行请求（多签）
function approve(
    uint256 _id, 
    bool _approve
) returns (bool success);
```

---

### 2.4 事件定义

```solidity
event KeyAdded(
    bytes32 indexed key, 
    uint256 indexed purpose, 
    uint256 indexed keyType
);

event KeyRemoved(
    bytes32 indexed key, 
    uint256 indexed purpose, 
    uint256 indexed keyType
);

event ExecutionRequested(
    uint256 indexed executionId, 
    address indexed to, 
    uint256 indexed value, 
    bytes data
);

event Executed(
    uint256 indexed executionId, 
    address indexed to, 
    uint256 indexed value, 
    bytes data
);

event Approved(
    uint256 indexed executionId, 
    bool approved
);

event KeysRequiredChanged(
    uint256 purpose, 
    uint256 number
);
```

---

### 2.5 典型使用场景

#### 场景1：多密钥管理
```
用户部署 ONCHAINID
    ↓
添加管理密钥（手机、硬件钱包、恢复密钥）
    ↓
添加执行密钥（日常交易钱包）
    ↓
设置多签要求：2/3 管理密钥批准才能修改身份
```

#### 场景2：密钥恢复
```
用户丢失主密钥
    ↓
使用恢复密钥（2/3 多签）
    ↓
调用 removeKey() 移除丢失的密钥
    ↓
调用 addKey() 添加新密钥
    ↓
身份控制权恢复
```

---

## 三、ERC-735 声明管理标准

### 3.1 标准概述

**ERC-735** 定义了声明持有者接口，允许 DApps 和智能合约验证第三方对身份持有者的声明[ref:19,20,21]。

#### 声明（Claim）的本质
- **定义**：签发者对身份持有者的**可验证陈述**
- **信任转移**：信任从身份转移到声明的签发者
- **类型**：自我声明 或 第三方签发

---

### 3.2 数据结构

```solidity
struct Claim {
    uint256 topic;        // 声明主题（KYC、居住地、学历等）
    uint256 scheme;       // 验证方案（如何验证此声明）
    address issuer;       // 签发者地址（ONCHAINID 或 EOA）
    bytes signature;      // 签名：sign(identityAddress + topic + data)
    bytes data;          // 声明数据哈希或实际数据
    string uri;          // 数据位置（IPFS、HTTP等）
}
```

#### 字段详解

**1. topic（主题）**
标准主题编号（可自定义扩展）：
- `1`: 生物特征数据
- `2`: 永久地址证明
- `3`: KYC 验证
- `4`: 合格投资者资格
- `5`: AML 检查
- `100+`: 自定义主题

**2. scheme（验证方案）**
- `1`: ECDSA 签名验证
- `2`: RSA 签名验证
- `3`: 智能合约验证（调用 `issuer` 合约）
- 其他：自定义验证逻辑

**3. issuer（签发者）**
- 外部账户（EOA）：直接验证签名
- 身份合约（ONCHAINID）：检查签名密钥是否在合约中
- 验证合约：调用合约的验证函数

**4. signature（签名）**
签名消息结构：
```solidity
bytes32 message = keccak256(
    abi.encodePacked(
        identityHolderAddress,  // 声明主体
        topic,                  // 声明主题
        data                    // 声明数据
    )
);
signature = sign(message, issuerPrivateKey);
```

**5. data（数据）**
根据 `scheme` 可以是：
- 声明数据的哈希（保护隐私）
- 实际声明数据
- 智能合约调用数据
- 位掩码标志

**6. uri（统一资源标识符）**
指向声明详细数据的位置：
- `ipfs://Qm...` - IPFS 哈希
- `https://kyc.provider.com/claims/123` - HTTP 链接
- `ar://...` - Arweave 存储
- 空字符串 - 所有数据在链上

---

### 3.3 核心函数

#### 查询函数

```solidity
// 根据 ID 获取声明
function getClaim(bytes32 _claimId) 
    public 
    constant 
    returns(
        uint256 topic, 
        uint256 scheme, 
        address issuer, 
        bytes signature, 
        bytes data, 
        string uri
    );

// 根据主题获取所有声明 ID
function getClaimIdsByTopic(uint256 _topic) 
    public 
    constant 
    returns(bytes32[] claimIds);
```

#### 管理函数

```solidity
// 添加或更新声明
function addClaim(
    uint256 _topic, 
    uint256 _scheme, 
    address _issuer, 
    bytes _signature, 
    bytes _data, 
    string _uri
) public returns (uint256 claimRequestId);

// 移除声明（仅限签发者或身份持有者）
function removeClaim(bytes32 _claimId) 
    public 
    returns (bool success);
```

**声明 ID 生成规则**：
```solidity
bytes32 claimId = keccak256(
    abi.encodePacked(issuer, topic)
);
```
> 注意：同一签发者对同一主题只能有一个声明（自动覆盖）

---

### 3.4 事件定义

```solidity
event ClaimRequested(
    uint256 indexed claimRequestId, 
    uint256 indexed topic, 
    uint256 scheme, 
    address indexed issuer, 
    bytes signature, 
    bytes data, 
    string uri
);

event ClaimAdded(
    bytes32 indexed claimId, 
    uint256 indexed topic, 
    uint256 scheme, 
    address indexed issuer, 
    bytes signature, 
    bytes data, 
    string uri
);

event ClaimRemoved(
    bytes32 indexed claimId, 
    uint256 indexed topic, 
    uint256 scheme, 
    address indexed issuer, 
    bytes signature, 
    bytes data, 
    string uri
);

event ClaimChanged(
    bytes32 indexed claimId, 
    uint256 indexed topic, 
    uint256 scheme, 
    address indexed issuer, 
    bytes signature, 
    bytes data, 
    string uri
);
```

---

### 3.5 声明验证流程

#### 链上验证步骤

```
1. 获取声明
   ↓
2. 提取签发者地址
   ↓
3. 重构签名消息
   message = keccak256(identityAddress + topic + data)
   ↓
4. 恢复签名者
   signer = ecrecover(message, signature)
   ↓
5. 验证签发者
   if (issuer is EOA):
       check signer == issuer
   else if (issuer is Identity Contract):
       check issuer.keyHasPurpose(signer, EXECUTION)
   ↓
6. 检查声明有效期（如果数据包含过期时间）
   ↓
7. 验证通过 ✓
```

---

## 四、ONCHAINID 在 ERC-3643 中的应用

### 4.1 三种身份角色

在 ERC-3643 生态中，ONCHAINID 服务于三种实体：

```
┌──────────────────────────────────────────────────┐
│  1. 投资者 ONCHAINID                               │
│     • 存储 KYC/AML 声明                            │
│     • 链接钱包地址                                  │
│     • 管理个人信息访问权限                           │
└──────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────┐
│  2. 代币 ONCHAINID                                 │
│     • 存储发行条款                                  │
│     • 记录公司行为（分红、拆股等）                    │
│     • 保存监管文档哈希                              │
└──────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────┐
│  3. KYC 提供商 ONCHAINID                           │
│     • 证明其合法身份                                │
│     • 存储认证资质                                  │
│     • 记录审计历史                                  │
└──────────────────────────────────────────────────┘
```

---

### 4.2 身份验证集成

#### Identity Registry 如何使用 ONCHAINID

```solidity
function isVerified(address _userAddress) 
    public 
    view 
    returns (bool) 
{
    // 1. 从 Storage 获取用户的 ONCHAINID 地址
    address userOID = identityStorage.storedIdentity(_userAddress);
    if (userOID == address(0)) return false;
    
    // 2. 获取必需的声明主题列表
    uint256[] memory topics = topicsRegistry.getClaimTopics();
    
    // 3. 遍历每个主题
    for (uint i = 0; i < topics.length; i++) {
        uint256 topic = topics[i];
        
        // 4. 从 ONCHAINID 获取该主题的声明
        IIdentity identity = IIdentity(userOID);
        bytes32[] memory claimIds = identity.getClaimIdsByTopic(topic);
        
        if (claimIds.length == 0) return false;
        
        // 5. 验证至少有一个有效声明
        bool foundValid = false;
        for (uint j = 0; j < claimIds.length; j++) {
            (
                uint256 claimTopic,
                uint256 scheme,
                address issuer,
                bytes memory sig,
                bytes memory data,
                string memory uri
            ) = identity.getClaim(claimIds[j]);
            
            // 6. 检查签发者是否可信
            if (!issuersRegistry.isTrustedIssuer(issuer)) continue;
            
            // 7. 检查签发者是否授权签发该主题
            if (!issuersRegistry.hasClaimTopic(issuer, topic)) continue;
            
            // 8. 验证签名（简化版）
            bytes32 dataHash = keccak256(abi.encode(userOID, topic, data));
            address signer = recoverSigner(dataHash, sig);
            
            // 如果签发者是身份合约，检查签名者密钥
            if (isContract(issuer)) {
                IIdentity issuerIdentity = IIdentity(issuer);
                if (!issuerIdentity.keyHasPurpose(
                    keccak256(abi.encode(signer)), 
                    2  // EXECUTION purpose
                )) continue;
            } else {
                // EOA 直接对比
                if (signer != issuer) continue;
            }
            
            // 9. 检查声明是否过期（如果数据包含时间戳）
            // ... 解析 data，检查有效期 ...
            
            foundValid = true;
            break;
        }
        
        if (!foundValid) return false;
    }
    
    return true;
}
```

---

### 4.3 完整生命周期示例

#### 场景：投资者购买证券型代币

```
阶段1：身份创建
──────────────────────────────────────────
投资者
  ↓ 部署 ONCHAINID 合约
ONCHAINID (0xABC...)
  ↓ 添加管理密钥
  • Desktop Wallet: 0x111...
  • Mobile Wallet: 0x222...
  • Recovery Key: 0x333...


阶段2：KYC 验证
──────────────────────────────────────────
投资者 → KYC 提供商
  ↓ 提交：护照、地址证明、自拍
KYC 提供商 (0xKYC...)
  ↓ 验证通过
  ↓ 构造声明
  Claim {
    topic: 1 (KYC verified),
    scheme: 1 (ECDSA),
    issuer: 0xKYC...,
    signature: sign(0xABC... + 1 + dataHash),
    data: keccak256(verificationData),
    uri: "ipfs://Qm..."
  }
  ↓ 投资者授权后添加到 ONCHAINID
ONCHAINID (0xABC...)
  ↓ 存储声明
  claims[keccak256(0xKYC... + 1)] = Claim


阶段3：注册到代币
──────────────────────────────────────────
代币发行方
  ↓ 检查投资者 ONCHAINID
  ↓ 验证所有必需声明存在
  ↓ 调用
identityRegistry.registerIdentity(
  0x111...,      // 投资者钱包
  0xABC...,      // 投资者 ONCHAINID
  840            // 国家代码 (美国)
)
  ↓ 存储映射
Identity Registry Storage:
  0x111... → Identity {
    identityContract: 0xABC...,
    country: 840
  }


阶段4：接收代币
──────────────────────────────────────────
发行方 → token.transfer(0x111..., 1000)
  ↓ 转账前检查
Token Contract
  ↓ 调用
identityRegistry.isVerified(0x111...)
  ↓ 返回 true（所有声明有效）
  ↓ 调用
compliance.canTransfer(sender, 0x111..., 1000)
  ↓ 返回 true（符合发行规则）
  ↓ 执行转账
balances[0x111...] += 1000
  ↓ 完成 ✓


阶段5：声明更新（1年后）
──────────────────────────────────────────
KYC 提供商
  ↓ 定期审查
  ↓ 投资者仍符合资格
  ↓ 签发新声明（延长有效期）
ONCHAINID (0xABC...)
  ↓ 覆盖旧声明（相同 topic + issuer）
  claims[keccak256(0xKYC... + 1)] = NewClaim
```

---

## 五、隐私保护机制

### 5.1 数据分层存储

ONCHAINID 采用**混合存储模式**[ref:1]：

```
链上存储（公开）              链下存储（私密）
────────────────────        ────────────────────
• 声明签名                   • 护照扫描件
• 声明主题                   • 银行账单
• 签发者地址                 • 身份证照片
• 数据哈希                   • 生物特征数据
• 元数据 URI                 • 详细 KYC 报告
```

### 5.2 访问控制

```
默认状态：所有人可见声明存在，但无法访问详细数据
    ↓
DApp 请求访问
    ↓
投资者授权（链下签名）
    ↓
DApp 使用授权令牌访问 KYC 提供商 API
    ↓
KYC 提供商验证授权签名
    ↓
返回解密数据
```

### 5.3 选择性披露

投资者可以选择：
- 向代币 A 披露 KYC 声明
- 向代币 B 披露居住地声明
- 向 DeFi 协议 C 披露资产证明声明
- 不同实体看到不同的信息子集

---

## 六、与传统 KYC 的对比

| 维度 | 传统 KYC | ONCHAINID |
|------|---------|-----------|
| **身份所有权** | 平台拥有 | 用户拥有 |
| **数据存储** | 中心化数据库 | 去中心化 + 链上签名 |
| **重复验证** | 每个平台重新 KYC | 一次验证，多处复用 |
| **隐私保护** | 平台完全访问 | 选择性披露 |
| **可移植性** | 无法转移 | 跨平台通用 |
| **审计透明度** | 不透明 | 链上可审计 |
| **密钥恢复** | 平台重置密码 | 多签恢复机制 |
| **合规性** | 依赖平台 | 自动化验证 |

---

## 七、实际应用案例

### 7.1 T-REX 证券代币生态

**规模数据**：
- 代币化资产规模：280 亿美元[ref:4]
- ONCHAINID 部署网络：Polygon（主网）
- 复用率：一个 ONCHAINID 可用于无限多个 ERC-3643 代币

### 7.2 ComplyDeFi

将无许可 DeFi 协议转换为许可协议[ref:8]：
```
Uniswap Pool (无限制)
    ↓ 添加 ComplyDeFi 层
Permissioned Pool
    ↓ 交易前检查
只有持有有效 ONCHAINID + KYC 声明的用户才能交易
```

### 7.3 跨平台身份复用

```
投资者完成一次 KYC
    ↓
获得 ONCHAINID + 声明
    ↓
可立即使用于：
    • 多个 Security Token 项目
    • 合规 DEX
    • 许可型借贷协议
    • 受监管的稳定币
```

---

## 八、技术优势与局限性

### 优势

1. **真正的自主权**：用户完全控制身份，无法被剥夺
2. **可组合性**：与 ERC-3643、DeFi 协议无缝集成
3. **效率提升**：消除重复 KYC 流程
4. **隐私优先**：敏感数据不上链，仅存储证明
5. **抗审查**：去中心化存储，无单点故障
6. **互操作性**：基于开放标准（ERC-734/735）

### 局限性

1. **Gas 成本**：部署身份合约和添加声明需要支付 Gas
2. **用户体验**：需要教育用户理解密钥管理
3. **标准化不足**：声明主题编号缺乏统一规范
4. **链外依赖**：仍依赖链下 KYC 提供商服务
5. **撤销机制**：已添加的声明只能通过过期或移除，无法追溯撤销

---

## 九、未来发展方向

### 9.1 与 DID 标准整合

整合 W3C Decentralized Identifiers (DIDs) 标准：
```
did:onchainid:polygon:0xABC...
```

### 9.2 零知识证明集成

使用 zk-SNARKs 实现：
- 证明"我已满 18 岁"而不透露确切年龄
- 证明"我的资产超过 100 万"而不透露具体金额

### 9.3 跨链身份

通过跨链桥实现：
```
Polygon ONCHAINID ←→ Ethereum ←→ Arbitrum ←→ Avalanche
```

### 9.4 可撤销凭证（Revocable Credentials）

引入链上撤销注册表：
```solidity
mapping(bytes32 => bool) public revokedClaims;
```

---

## 十、开发者资源

### 官方文档
- ONCHAINID Docs: https://docs.onchainid.com/
- GitHub: https://github.com/onchain-id/solidity
- ERC-734: https://github.com/ethereum/EIPs/issues/734
- ERC-735: https://github.com/ethereum/EIPs/issues/735

### NPM 包
```bash
npm install @onchain-id/solidity
```

### 部署示例
```solidity
import "@onchain-id/solidity/contracts/Identity.sol";

// 部署用户身份
Identity userIdentity = new Identity(
    userManagementKey,  // 初始管理密钥
    false               // 不使用代理
);

// 添加声明
userIdentity.addClaim(
    1,                  // topic: KYC
    1,                  // scheme: ECDSA
    kycProviderAddress, // issuer
    signature,
    data,
    "ipfs://..."       // uri
);
```

---

## 总结

ONCHAINID 通过 **ERC-734**（密钥管理）和 **ERC-735**（声明管理）两个标准，构建了一个功能完整的去中心化身份系统，实现了：

✅ **自主身份控制**：用户拥有身份而非平台  
✅ **隐私保护**：链上验证 + 链下存储  
✅ **互操作性**：跨平台复用身份和认证  
✅ **合规性**：满足 KYC/AML 监管要求  
✅ **灵活性**：模块化设计，可扩展声明类型  

作为 ERC-3643 的核心基础设施，ONCHAINID 使得**受监管的资产代币化**成为可能，为真实世界资产（RWA）上链铺平了道路。
