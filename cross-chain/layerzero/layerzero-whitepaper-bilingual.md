# LayerZero 白皮书中英双语对照版

> 说明：本文件为逐段对照、偏直译版本。原始 PDF 下载名包含 `V2.1.0`，但正文首页标注为 `Version 1.1: Fix typos. (2024-01-23)`。本文件以 PDF 正文内容为准。

## Title

### LayerZero

Ryan Zarick, Bryan Pellegrino, Isaac Zhang, Thomas Kim, Caleb Banister  
LayerZero Labs

## Abstract

**English**  
In this paper, we present the first intrinsically secure and semantically universal omnichain interoperability protocol: LayerZero. Utilizing an immutable endpoint, append-only verification modules, and fully-configurable verification infrastructure, LayerZero provides the security, configurability, and extensibility necessary to achieve omnichain interoperability. LayerZero enforces strict application-exclusive ownership of protocol security and cost through its novel trust-minimized modular security framework which is designed to universally support all blockchains and use cases. Omnichain applications (OApps) built on the LayerZero protocol achieve frictionless blockchain-agnostic interoperation through LayerZero's universal network semantics.

**中文直译**  
本文提出首个同时具备内在安全性与语义通用性的全链互操作协议：`LayerZero`。LayerZero 通过不可变的 endpoint、只追加的验证模块以及完全可配置的验证基础设施，提供实现全链互操作所必需的安全性、可配置性与可扩展性。LayerZero 借助其新的、最小信任化的模块化安全框架，严格保证协议安全与成本由应用独占拥有；该框架被设计为可普遍支持所有区块链与各种使用场景。构建在 LayerZero 协议上的全链应用（`OApps`），通过 LayerZero 的通用网络语义，实现无摩擦、链无关的互操作。

## 1. Introduction

**English**  
Blockchain interoperability represents an ever-growing challenge as the diversity of chains continues to grow, and the importance of connecting the fragmented blockchain landscape is increasing as applications seek to reach users across a progressively wider set of chains.

**中文直译**  
随着链的多样性持续增加，区块链互操作性正成为一个不断扩大的挑战；而随着应用试图覆盖越来越广泛的链上用户群体，连接这一碎片化区块链格局的重要性也在不断提升。

**English**  
We present LayerZero, the first omnichain messaging protocol (OMP) to achieve a fully-connected mesh network that is scalable to all blockchains and use cases. In contrast to the monolithic security model of other cross-chain messaging services, the LayerZero protocol uses a novel modular security model to immutably implement security. This approach can still be extended to support new features and verification algorithms. Intrinsic security against censorship, replay attacks, denial of service, and in-place code modifications is designed into immutable Endpoints. Less fundamental extrinsic aspects of security (e.g., signature schemes) are isolated into independently-immutable modules. As a protocol, LayerZero is not bound to any infrastructure or blockchain; all components other than the endpoint can be interchanged and configured by applications built on LayerZero.

**中文直译**  
我们提出 `LayerZero`，它是首个实现全连接网状网络的全链消息协议（`OMP`），并且可扩展到所有区块链与各种使用场景。与其他跨链消息服务的单体式安全模型不同，LayerZero 协议采用一种新的模块化安全模型，以不可变的方式实现安全性。这一方法仍然可以扩展，以支持新的功能与验证算法。针对审查、重放攻击、拒绝服务以及原地代码修改的内在安全性，被直接设计进不可变的 `Endpoints` 中。安全性的较不基础的外在方面，例如签名方案，则被隔离进彼此独立且不可变的模块中。作为一种协议，LayerZero 不受任何基础设施或区块链绑定；除 endpoint 之外的所有组件，都可以被构建在 LayerZero 之上的应用替换和配置。

**English**  
We illustrate the omnichain fully-connected mesh network in Figure 1. Each chain is directly connected to every other chain, and while the extrinsic security (Section 2.1) may be different for different chain pairs, the guarantees of eventual, lossless, exactly-once packet delivery should be uniform and never change.

**中文直译**  
我们在图 1 中展示了全链全连接网状网络。每条链都与其他所有链直接相连，并且虽然不同链对的外在安全性（第 2.1 节）可以不同，但最终、无损、恰好一次的数据包交付保证应当是统一的，并且永远不应改变。

**English**  
LayerZero's network channel semantics, including execution features, configuration semantics, censorship resistance, and failure model, are universal. These universal semantics allows application developers to easily architect secure, chain agnostic omnichain applications (OApps).

**中文直译**  
LayerZero 的网络信道语义，包括执行特性、配置语义、抗审查能力以及失败模型，都是通用的。这些通用语义使应用开发者能够更容易地设计安全、链无关的全链应用（`OApps`）。

**English**  
The remainder of this paper is organized as follows. First, Section 2 explains the overarching fundamental principles underlying the LayerZero protocol. Section 3 describes the protocol design and highlights how each component is architected for security. Finally, Section 4 presents examples of how LayerZero can easily be extended to support a wide range of additional features in a blockchain-agnostic manner.

**中文直译**  
本文剩余部分安排如下。首先，第 2 节解释 LayerZero 协议背后的总体性基本原则。第 3 节描述协议设计，并强调各组件如何围绕安全性进行架构设计。最后，第 4 节给出示例，说明 LayerZero 如何以链无关方式轻松扩展，以支持广泛的附加功能。

### Figure 1

![Figure 1](assets/layerzero-whitepaper/figure-1.png)

**English**  
The omnichain fully-connected mesh network has universal network semantics for all connected chains and security specialized to each link.

**中文直译**  
全链全连接网状网络对所有已连接链都具有通用网络语义，而每条连接链路的安全性则可以专门化配置。

### Table 1

**English**  
We divide protocol integrity into four properties. Data liveness depends on the underlying blockchains and cannot be secured by the OMP.

**中文直译**  
我们把协议完整性划分为四种属性。数据活性依赖底层区块链，无法由 OMP 本身保障。

| English | 中文 |
| --- | --- |
| Channel validity | 信道有效性 |
| Packet censorship | 数据包审查 |
| Packet replay | 数据包重放 |
| Buggy updates | 有缺陷的更新 |
| Invalid reconfiguration | 无效的重配置 |
| Channel liveness | 信道活性 |
| Denial of service | 拒绝服务 |
| Infrastructure health | 基础设施健康性 |
| Administrator health | 管理员健康性 |
| Data validity | 数据有效性 |
| Cryptographic attack | 密码学攻击 |
| Malicious infrastructure | 恶意基础设施 |
| Data liveness | 数据活性 |
| Data loss on blockchain | 区块链上的数据丢失 |

## 2. Principles

**English**  
The responsibilities of an OMP can be condensed into two requirements: intrinsic security and universal semantics. Existing messaging services fail to implement one or both of the above requirements and thus suffer from two fundamental deficiencies: monolithic security and overspecialization. In the remainder of this section, we contextualize security and semantics within the cross-chain messaging paradigm, describe how existing cross-chain messaging systems fall short of these goals, and outline how LayerZero is designed from the ground-up to overcome these shortcomings.

**中文直译**  
OMP 的职责可以浓缩为两个要求：内在安全性与通用语义。现有消息服务未能实现上述其中一项或两项要求，因此存在两个根本缺陷：单体式安全与过度特化。在本节剩余部分，我们将结合跨链消息范式来讨论安全与语义，说明现有跨链消息系统为何未达到这些目标，并概述 LayerZero 如何从底层开始设计，以克服这些不足。

## 2.1 Security

**English**  
The first and most important requirement of OMPs is that they should be secure. We divide security into intrinsic and extrinsic security, and while all messaging systems implement extrinsic security, few provide intrinsic security. Intrinsic security refers to protocol-level invariants of lossless (censorship resistance), exactly-once (no replay), eventual (liveness) delivery. Extrinsic security encompasses all other security properties, such as signature and verification algorithms.

**中文直译**  
OMP 的第一个也是最重要的要求，是它必须安全。我们把安全划分为内在安全与外在安全；虽然所有消息系统都实现某种外在安全，但很少提供内在安全。内在安全指协议层面的交付不变量：无损（抗审查）、恰好一次（无重放）、最终可达（活性）交付。外在安全则涵盖其他所有安全属性，例如签名与验证算法。

**English**  
Most existing messaging services have taken an ad-hoc approach to security, continuously updating a single monolithic end-to-end security model to accommodate chains as they are added to their network. These services invariably utilize forced, in-place updates to a shared security model, and thus cannot provide long-term security invariants for OApps to build upon. To provide long-term security invariants in LayerZero, we chose instead to modularize security and enforce strict immutability for all modules.

**中文直译**  
大多数现有消息服务在安全性上采取了临时拼凑式方法，不断更新单一的单体端到端安全模型，以适配不断加入网络的新链。这些服务不可避免地对共享安全模型执行强制性的原地更新，因此无法为 OApps 提供可依赖的长期安全不变量。为了在 LayerZero 中提供长期安全不变量，我们选择将安全模块化，并对所有模块施加严格的不可变性约束。

**English**  
Table 1 illustrates how we divide protocol integrity into channel and data integrity. Each of these integrity layers is further subdivided into validity and liveness properties. We more formally define intrinsic security to cover channel validity and liveness, and extrinsic security to cover data validity. In this paper, we refer to the extrinsic security configuration as the Security Stack. Monolithic shared security systems force the same Security Stack on all applications, while isolated security systems allow a different Security Stack per OApp.

**中文直译**  
表 1 展示了我们如何将协议完整性划分为信道完整性和数据完整性。每个完整性层又进一步细分为有效性与活性属性。更正式地说，我们将内在安全定义为覆盖信道有效性与活性，将外在安全定义为覆盖数据有效性。本文中，我们把外在安全配置称为 `Security Stack`。单体共享安全系统会强制所有应用使用同一套安全栈，而隔离式安全系统则允许每个 OApp 使用不同的安全栈。

**English**  
Intrinsic security can and should be universally secured based on first principles. In contrast, optimal, trustless communication across blockchains is impossible, and the continuous advancement in verification algorithms and blockchain design necessitates extensibility and configurability of extrinsic security. This is true even in special cases such as L1-L2 rollups; the possibility of hard forks necessitates L2 contract upgradability, thus making the L2 contract owner a trusted entity.

**中文直译**  
内在安全性可以而且应当基于第一性原理被普遍保障。相比之下，跨区块链的最优、无信任通信是不可能的，而验证算法与区块链设计的持续演进，使得外在安全必须具备可扩展性与可配置性。即使在 L1-L2 Rollup 这类特殊场景中也是如此；硬分叉的可能性要求 L2 合约可升级，从而使 L2 合约所有者成为一个被信任实体。

**English**  
It is infeasible to formally verify the extrinsic security of any nontrivial code given the many underlying layers of execution and the reliance of cryptographic algorithms on the computational intractability of NP problems. As a result, the most practical measure of security is an economic one: a non-upgradable smart contract's security is directly proportional to how many assets it has secured and for how long.

**中文直译**  
考虑到执行环境存在多层底层依赖，且密码学算法建立在某些 NP 问题在计算上不可处理这一前提之上，因此对任何非平凡代码的外在安全进行形式化验证都是不可行的。结果是，衡量安全性最现实的标准是一种经济标准：一个不可升级智能合约的安全性，与其已经保护了多少资产以及保护了多长时间直接成正比。

**English**  
Thus, the implications of extrinsic security isolation are clear: OMPs must guarantee indefinite access to well-established, extrinsically secure code while still allowing protocol maintainers to extend the protocol. The impossibility of trustless communication thus implies that extrinsic security exists on a constantly shifting pareto frontier and should be customizable to OApp-specific requirements.

**中文直译**  
因此，外在安全隔离的含义非常明确：OMP 必须保证应用能够无限期访问那些经过长期验证、具备外在安全性的代码，同时仍允许协议维护者扩展协议。无信任通信的不可能性意味着，外在安全始终处于不断变化的帕累托前沿之上，因此应当能够根据 OApp 的特定需求进行定制。

**English**  
To provide intrinsic security, the OMP must guarantee that an OApp's Security Stack only changes when the OApp owner opts in to the change. This implies that systems designed to allow in-place code upgrades can never be intrinsically secure. Replaceability of existing code permits the permanent deprecation of well-established extrinsically secure code and the potential introduction of vulnerable code. Current approaches to in-place secure upgrades involve careful testing and audits, but history has shown that this process is not foolproof and can overlook severe vulnerabilities. To guarantee long-term security invariants, OMPs must be architected to isolate each OApp's Security Stack from software updates and other OApps' configurations.

**中文直译**  
为了提供内在安全，OMP 必须保证：只有在 OApp 所有者主动选择变更时，该 OApp 的安全栈才会发生变化。这意味着，任何被设计为允许原地代码升级的系统，都不可能具备内在安全性。现有代码的可替换性，使得那些已被长期验证、具备外在安全的代码可能被永久废弃，也可能引入有漏洞的新代码。当前原地安全升级的方法通常依赖仔细测试与审计，但历史表明，这一流程并非万无一失，并且可能忽视严重漏洞。为了保证长期安全不变量，OMP 必须在架构上将每个 OApp 的安全栈与软件更新以及其他 OApps 的配置隔离开来。

### Figure 2

![Figure 2](assets/layerzero-whitepaper/figure-2.png)

**English**  
The pareto frontier of extrinsic security vs cost continually changes due to advancements in technology.

**中文直译**  
随着技术进步，外在安全性与成本之间的帕累托前沿会持续变化。

## 2.2 Universal Semantics

**English**  
The second requirement of OMPs is universal semantics, or the ability to extend and adapt the network primitive to all additional use cases and blockchains.

**中文直译**  
OMP 的第二项要求是通用语义，也就是能够把这一网络原语扩展并适配到所有新增使用场景与所有区块链。

**English**  
Execution semantics (i.e., feature logic) should be both chain-agnostic and sufficiently expressive to allow any OApp-required functionality. A key insight we had when designing LayerZero is that feature logic (execution) can be fully isolated from security (verification). This not only simplified protocol development, but also eliminates concerns about impact to protocol security when designing and implementing execution features.

**中文直译**  
执行语义，也就是功能逻辑，应当既是链无关的，又具有足够的表达能力，以允许任何 OApp 所需的功能。我们在设计 LayerZero 时的一个关键洞察是，功能逻辑（执行）可以与安全性（验证）完全隔离。这不仅简化了协议开发，也消除了在设计和实现执行特性时对协议安全影响的担忧。

**English**  
The other aspect of universal semantics is universal compatibility of the OMP interface and network semantics with all existing and future blockchains. The importance of semantic unification cannot be understated, as OApps cannot scale if every additional blockchain in the network incurs significant engineering cost to accommodate different interfaces and network consistency models. In practice, an OMP must have a unified interface, transmission semantics, and execution behavior regardless of the source and destination blockchain characteristics.

**中文直译**  
通用语义的另一面，是 OMP 接口与网络语义对所有现有及未来区块链的通用兼容性。语义统一的重要性怎么强调都不为过，因为如果网络中每多接入一条区块链都需要付出显著工程成本去适配不同接口和网络一致性模型，那么 OApps 就无法扩展。实际中，OMP 无论面对何种源链与目标链特性，都必须提供统一接口、统一传输语义与统一执行行为。

## 3. Core protocol design

**English**  
We divide LayerZero into four components: an immutable Endpoint that implements censorship resistance, an append-only collection of onchain verification modules (MessageLib Registry), a permissionless set of Decentralized Verifier Networks (DVNs) to verify data across blockchains, and permissionless executors to execute feature logic in isolation to the cross-chain message verification context. Tying the components together is the OApp Security Stack, which defines the extrinsic security configuration of the protocol and is modifiable exclusively by the OApp owner.

**中文直译**  
我们将 LayerZero 划分为四个组件：一个实现抗审查能力的不可变 `Endpoint`，一个只追加的链上验证模块集合（`MessageLib Registry`），一组用于跨链验证数据的无许可 `Decentralized Verifier Networks (DVNs)`，以及一组与跨链消息验证上下文相隔离、用于执行功能逻辑的无许可执行器。把这些组件连接起来的是 `OApp Security Stack`，它定义协议的外在安全配置，并且只能由 OApp 所有者修改。

**English**  
Messages in LayerZero are composed of a payload and routing information (path). These messages are serialized into packets before they are transmitted across the mesh network. Packets are verified by the verification layer on the destination blockchain before they are committed into the lossless channel. The packets are then read from the channel and delivered by executing the lzReceive callback on the destination OApp contract.

**中文直译**  
LayerZero 中的消息由负载和路由信息（`path`）组成。这些消息在跨网状网络传输前，会被序列化为数据包。数据包会先在目标区块链上由验证层验证，然后才被提交到无损信道中。之后，这些数据包会从信道中被读取，并通过在目标 OApp 合约上执行 `lzReceive` 回调完成投递。

**English**  
The LayerZero Endpoint secures channel validity through OApp-exclusive Security Stack ownership in conjunction with an immutable channel that implements censorship resistance, exactly-once delivery, and guaranteed liveness. Endpoint immutability guarantees that no external entity or organization can ever forcibly change the security characteristics an OApp's Security Stack.

**中文直译**  
LayerZero Endpoint 通过两种机制保障信道有效性：一是 OApp 独占的安全栈所有权，二是实现了抗审查、恰好一次交付和活性保证的不可变信道。Endpoint 的不可变性保证任何外部实体或组织都不能强制改变某个 OApp 安全栈的安全特征。

**English**  
Individually immutable MessageLibs collectively form the MessageLib Registry, and each MessageLib is an extrinsically secure interface that verifies packet data integrity before allowing messages to be committed to the Endpoint. Existing MessageLibs cannot be modified, thus making the MessageLib Registry append-only, and each Security Stack specifies exactly one MessageLib. Security Stack ownership semantics in conjunction with MessageLib immutability enable applications to potentially use the same Security Stack forever.

**中文直译**  
各个独立不可变的 MessageLib 共同构成 MessageLib Registry，而每个 MessageLib 都是一个具备外在安全性的接口，会在允许消息提交到 Endpoint 之前验证数据包的数据完整性。已有 MessageLib 不能被修改，因此 MessageLib Registry 成为只追加结构，并且每个安全栈都恰好指定一个 MessageLib。安全栈所有权语义与 MessageLib 不可变性相结合，使应用理论上能够永久使用同一套安全栈。

**English**  
Each DVN is an aggregation of verifiers that collectively verify the integrity of data shared between two independent blockchains. DVNs can include both offchain and onchain components, and each Security Stack can theoretically include an unbounded number of DVNs. The underlying DVN structure can leverage any verification mechanism, including but not limited to zero-knowledge, side chains, K-of-N consensus, and native bridges.

**中文直译**  
每个 DVN 都是一组验证器的聚合体，这些验证器共同验证两条独立区块链之间共享数据的完整性。DVN 既可以包含链下组件，也可以包含链上组件；每个安全栈在理论上都可以包含无限数量的 DVNs。DVN 的底层结构可以利用任何验证机制，包括但不限于零知识、侧链、K-of-N 共识以及原生桥。

**English**  
Channel liveness (eventual delivery) is guaranteed through permissionless execution in conjunction with Security Stack reconfiguration. Assuming the liveness of the source and destination blockchains, LayerZero channel liveness can only be temporarily compromised if the DVNs in the Security Stack experience faults, or the configured executor stops delivering messages. If too many configured DVNs stop verifying messages, the OApp can regain liveness by reconfiguring its Security Stack to use different DVNs. Packet delivery is permissionless, so any party willing to pay execution gas costs can deliver packets to restore channel liveness.

**中文直译**  
信道活性（最终交付）通过无许可执行与安全栈重配置共同保障。只要源链和目标链本身具备活性，LayerZero 的信道活性只有在以下情形下才会暂时受损：安全栈中的 DVNs 发生故障，或者被配置的执行器停止投递消息。如果停止验证消息的 DVNs 数量过多，OApp 可以通过重配置安全栈、改用其他 DVNs 来恢复活性。数据包交付是无许可的，因此任何愿意支付执行 gas 成本的一方都可以交付数据包，从而恢复信道活性。

**English**  
Interaction between LayerZero components is minimized and standardized to reduce software bug surfaces. LayerZero's modularization and configurability also enables quick prototyping of the protocol on new chains.

**中文直译**  
LayerZero 各组件之间的交互被尽量最小化并标准化，以减少软件缺陷暴露面。LayerZero 的模块化与可配置性也使得协议能够在新链上快速完成原型实现。

### Figure 3

![Figure 3](assets/layerzero-whitepaper/figure-3.png)

**English**  
LayerZero is divided into execution and verification layers. The verification layer securely transmits data between blockchains, and the execution layer interprets this data to form a secure, censorship resistant messaging channel.

**中文直译**  
LayerZero 被划分为执行层与验证层。验证层在区块链之间安全地传输数据，而执行层解释这些数据，从而形成一条安全且抗审查的消息信道。

## 3.0.1 LayerZero packet transmission

**English**  
Before describing each component in detail, we present an overview of how packets are transmitted in LayerZero. The LayerZero mesh network is formed by the deployment by a protocol administrator of a LayerZero Endpoint on each connected blockchain. In this example, the OApp sends a LayerZero message from a sender contract to a receiver contract across the LayerZero mesh network. For illustration purposes, the MessageLib we use in this example is the Ultra Light Node (ULN).

**中文直译**  
在详细描述各个组件之前，我们先概述 LayerZero 中数据包的传输方式。LayerZero 网状网络是通过协议管理员在每条已连接区块链上部署一个 LayerZero Endpoint 而形成的。在这个示例中，OApp 通过 LayerZero 网状网络，把一条 LayerZero 消息从发送合约发送到接收合约。为便于说明，本例使用的 MessageLib 是 `Ultra Light Node (ULN)`。

**English**  
During initial setup, the OApp configures its Security Stack on the LayerZero Endpoint on the source and destination blockchains. The MessageLib version configured in the Security Stack determines the packet version.

**中文直译**  
在初始设置阶段，OApp 会在源链和目标链上的 LayerZero Endpoint 中配置其安全栈。安全栈中配置的 MessageLib 版本决定了数据包版本。

**English**  
In step 1, the sender calls lzSend on the source chain LayerZero Endpoint, specifying the message payload and the path. This path is associated with an independent censorship resistant channel, and is composed of the sender application address, the source Endpoint ID, the recipient application address, and the destination Endpoint ID.

**中文直译**  
在步骤 1 中，发送方在源链的 LayerZero Endpoint 上调用 `lzSend`，指定消息负载和路径。该路径关联一条独立的抗审查信道，并由发送应用地址、源 Endpoint ID、接收应用地址和目标 Endpoint ID 组成。

**English**  
The source Endpoint then assigns a gapless, monotonically-increasing nonce to the packet. This nonce is concatenated with the path, then the result is hashed to calculate the global unique ID (GUID) of the packet. This GUID is used by offchain and onchain workers to track the status of LayerZero messages and trigger actions.

**中文直译**  
随后，源 Endpoint 会给该数据包分配一个无空洞、单调递增的 `nonce`。这个 nonce 与 path 拼接后，再对结果进行哈希，以计算该数据包的全局唯一标识 `GUID`。这个 GUID 会被链下和链上工作者用来跟踪 LayerZero 消息的状态并触发动作。

**English**  
The source Endpoint reads the OApp Security Stack to determine the correct source MessageLib to encode the packet. The source MessageLib processes the packet based on the configured Security Stack, rendering payment to the configured DVNs to verify the message on the destination MessageLib and optionally specified executors to trigger offchain actions. These DVN and executor identifiers along with any relevant arguments are serialized by MessageLib into an unstructured byte array called Message Options. After the ULN encodes the packet and returns it to the Endpoint, the Endpoint emits the packet to conclude the LayerZero send transaction.

**中文直译**  
源 Endpoint 接着读取 OApp 的安全栈，以确定用于编码数据包的正确源 MessageLib。源 MessageLib 会基于配置好的安全栈处理该数据包，并向配置的 DVNs 支付费用，使其在目标 MessageLib 上验证消息；还可以选择性地向指定执行器支付费用，以触发链下动作。这些 DVN 和执行器标识符，以及相关参数，会由 MessageLib 序列化进一个名为 `Message Options` 的非结构化字节数组中。ULN 对数据包完成编码并将其返回给 Endpoint 后，Endpoint 会发出该数据包，从而结束 LayerZero 的发送交易。

**English**  
In step 2, the configured DVNs each independently verify the packet on the destination MessageLib; for ULN, this constitutes storing the hash of the packet payload. After a threshold of DVNs verify the payload, a worker commits the packet to the Endpoint in step 3. The Endpoint checks that the payload verification reflects the OApp-configured Security Stack before committing to the lossless channel.

**中文直译**  
在步骤 2 中，已配置的 DVNs 会各自独立地在目标 MessageLib 上验证该数据包；对 ULN 而言，这意味着存储该数据包负载的哈希。当足够数量的 DVNs 验证了该负载后，某个工作者会在步骤 3 中把该数据包提交到 Endpoint。Endpoint 会先检查该负载验证是否反映了 OApp 配置的安全栈，然后才将其提交到无损信道中。

**English**  
Finally, in step 4, an executor calls lzReceive on the committed message to execute the Receiver OApp logic on the packet. Step 4 will revert to prevent censorship if the channel cannot guarantee lossless exactly-once delivery.

**中文直译**  
最后，在步骤 4 中，执行器会对已提交消息调用 `lzReceive`，以在该数据包上执行接收方 OApp 的逻辑。如果信道无法保证无损且恰好一次的交付，步骤 4 将回滚，以防止审查。

### Figure 4

![Figure 4](assets/layerzero-whitepaper/figure-4.png)

**English**  
Steps to send a message using LayerZero.

**中文直译**  
使用 LayerZero 发送消息的步骤。

### Table 2

**English**  
LayerZero packets are composed of a header and body. The header includes the packet version and path. The body is composed of the actual message payload. Packets are identified by their globally unique identifier (GUID).

**中文直译**  
LayerZero 数据包由头部和主体组成。头部包含数据包版本和路径。主体由实际消息负载构成。数据包通过其全局唯一标识符（`GUID`）进行识别。

| Field name | Type |
| --- | --- |
| Packet version | `uint8` |
| Nonce | `uint64` |
| Source Endpoint ID | `uint32` |
| Sender | `uint256` |
| Destination Endpoint ID | `uint32` |
| Receiver | `uint256` |
| GUID | `uint256` |
| Message Payload | `bytes[]` |

## 3.1 LayerZero Endpoint

**English**  
The LayerZero Endpoint, implemented as an immutable open-source smart contract and deployed in one or more instances per chain, provides a stable application-facing interface, the abstraction of a lossless network channel with exactly-once guaranteed delivery, and manages OApp Security Stacks. The immutability of the LayerZero Endpoint guarantees long-term channel validity by enforcing update isolation, configuration ownership, and channel integrity. The Security Stack is key to LayerZero's channel liveness guarantee, as it mediates the trust-cost relationship between OApps and the permissionless set of DVNs.

**中文直译**  
LayerZero Endpoint 以不可变的开源智能合约形式实现，并且每条链上可部署一个或多个实例。它提供稳定的面向应用接口、具有恰好一次交付保证的无损网络信道抽象，并负责管理 OApp 安全栈。LayerZero Endpoint 的不可变性通过强制执行更新隔离、配置所有权和信道完整性，来保障长期的信道有效性。安全栈是 LayerZero 保证信道活性的关键，因为它调节着 OApps 与无许可 DVN 集合之间的信任-成本关系。

**English**  
OApps call send on the Endpoint to queue a message to be sent through LayerZero, specifying the path, the message payload, and an optional byte array called Message Options containing serialized options to be interpreted by MessageLib. Message Options is purposely unstructured, improving extensibility. The complement to send is lzReceive, which is executed on the destination chain to consume the message with the specified GUID.

**中文直译**  
OApps 通过调用 Endpoint 上的 `send` 来排队一条将通过 LayerZero 发送的消息，参数包括路径、消息负载，以及一个可选字节数组 `Message Options`，其中包含供 MessageLib 解释的序列化选项。Message Options 被有意设计为非结构化形式，以提升可扩展性。与 `send` 对应的是 `lzReceive`，它在目标链上执行，用于消费指定 GUID 的消息。

**English**  
On the destination chain, the Endpoint handles calls to lzReceive and getInboundNonce, enforcing lossless exactly-once delivery to protect the integrity of the message channel. lzReceive delivers the verified payload of this message to the OApp, provided the message can be losslessly delivered. getInboundNonce returns the highest losslessly deliverable nonce, computing the highest nonce such that all messages with preceding nonces have been verified, skipped, or delivered.

**中文直译**  
在目标链上，Endpoint 负责处理 `lzReceive` 和 `getInboundNonce` 调用，通过强制执行无损且恰好一次的交付来保护消息信道的完整性。`lzReceive` 会把该消息已验证的负载交付给 OApp，前提是该消息能够被无损交付。`getInboundNonce` 返回当前可无损交付的最高 nonce，也就是这样一个最高 nonce：其之前所有更小 nonce 的消息都已经被验证、跳过或者交付。

**English**  
To handle erroneously sent messages or malicious packets, OApps either call clear to skip delivery of the packet in question or skip to skip both verification and delivery. In addition to clear and skip, the Endpoint provides two convenience functions nilify and burn. Nilify invalidates a verified packet, preventing the execution of this packet until a new packet is committed from MessageLib; this function can be used to proactively invalidate maliciously generated packets from compromised DVNs. Burn allows OApps to clear a packet without knowing the packet contents.

**中文直译**  
为了处理误发送的消息或恶意数据包，OApps 可以调用 `clear` 来跳过该数据包的投递，或者调用 `skip` 来同时跳过验证与投递。除了 `clear` 与 `skip` 之外，Endpoint 还提供两个便捷函数：`nilify` 和 `burn`。`nilify` 会使一个已验证的数据包失效，从而阻止其执行，直到 MessageLib 再次提交一个新的数据包；这个函数可以用来主动使来自被攻陷 DVNs 的恶意生成数据包失效。`burn` 则允许 OApps 在不知道数据包内容的情况下清除该数据包。

### Table 3

#### English / 中文

- `send`  
  `path`, `payload`, `Message Options`  
  Sends a message through LayerZero. / 通过 LayerZero 发送消息。
- `getInboundNonce`  
  `path`  
  Returns the largest nonce with all predecessors received. / 返回其所有前序 nonce 都已收到时的最大 nonce。
- `skip`  
  `path`, `nonce`  
  Called by the receiver to skip verification and delivery of a nonce. / 由接收方调用，跳过某个 nonce 的验证与交付。
- `clear`  
  `path`, `guid`, `message`  
  Called by the receiver to skip a nonce that has been verified. / 由接收方调用，跳过一个已经被验证的 nonce。
- `lzReceive`  
  `path`, `nonce`, `GUID`, `message`, `extraData`  
  Called by the executor to receive a message from the channel. / 由执行器调用，从信道中接收消息。
- `nilify`  
  `path`, `nonce`, `payloadHash`  
  Invalidates a verified packet. / 使一个已验证数据包失效。
- `burn`  
  `path`, `nonce`, `payloadHash`  
  Clears a packet without requiring full packet contents. / 在不需要完整数据包内容的情况下清除一个数据包。

## 3.1.1 Out-of-order lossless delivery

**English**  
We lay out two non-negotiable consistency requirements for LayerZero's message channel: lossless and exactly-once delivery. Censorship resistant channels must be lossless, and exactly-once delivery is required to prevent replay attacks. Both of these requirements are crucial for network integrity, and are guaranteed by the protocol provided the underlying blockchain is not faulty.

**中文直译**  
我们为 LayerZero 的消息信道提出两项不可妥协的一致性要求：无损交付与恰好一次交付。抗审查信道必须是无损的，而恰好一次交付则是防止重放攻击所必需的。这两项要求对网络完整性都至关重要，并且只要底层区块链本身没有故障，协议就会保障它们。

**English**  
Channels in LayerZero are necessarily separated and isolated by path, as any lossless channel shared by two different OApps must sacrifice channel validity or liveness. Each channel maintains a logical clock implemented by a gapless, strictly monotonically increasing positive integer nonce, and each message sent over the channel is assigned exactly one nonce. On the destination Endpoint, each nonce is mapped to exactly one verified payload hash, and the channel enforces that each delivered payload corresponds to the verified hash of the relevant nonce.

**中文直译**  
LayerZero 中的信道必须按路径彼此分离和隔离，因为任何被两个不同 OApp 共享的无损信道都必须牺牲信道有效性或活性。每条信道都维护一个逻辑时钟，其实现方式是一个无空洞、严格单调递增的正整数 nonce，并且每条通过该信道发送的消息都被分配恰好一个 nonce。在目标 Endpoint 上，每个 nonce 只映射到一个已验证的负载哈希，而该信道会强制每次交付的负载都必须对应于相关 nonce 的已验证哈希。

**English**  
LayerZero guarantees that the delivery of a packet implies all other packets on the same channel with lower nonces are delivered, deliverable, or skipped. This is the weakest possible, and by extension most flexible, condition for losslessness. Stronger conditions such as strictly in-order delivery can be imposed on top of this abstraction if desired.

**中文直译**  
LayerZero 保证：一个数据包被交付，意味着同一信道上所有更低 nonce 的数据包都已经被交付、可交付，或者被跳过。这是实现无损性的最弱条件，也因此是最灵活的条件。如果需要，还可以在这一抽象之上施加更强的条件，例如严格按序交付。

**English**  
Censorship resistance is implemented by enforcing that no nonce can be delivered unless all previous nonces have been committed or skipped. We term the largest nonce that can be executed to be the inbound nonce.

**中文直译**  
抗审查性是通过如下约束实现的：除非所有前序 nonce 都已经被提交或跳过，否则任何 nonce 都不能被交付。我们把当前可执行的最大 nonce 称为 `inbound nonce`。

**English**  
Lossless and exactly-once delivery can be achieved using strictly in-order verification and execution. However, delivery order enforcement can result in artificial throughput limits on certain blockchains and complicates offchain infrastructure. In LayerZero we relax this ordering constraint, implementing out-of-order delivery that maintains channel integrity and does not introduce any additional onchain computational overhead.

**中文直译**  
无损且恰好一次的交付可以通过严格按序的验证与执行来实现。然而，强制交付顺序会在某些区块链上带来人为的吞吐限制，并使链下基础设施变得复杂。在 LayerZero 中，我们放宽了这一顺序约束，实现了乱序交付，同时维持信道完整性，并且不引入任何额外的链上计算开销。

**English**  
The only efficient onchain implementation of an uncensorable channel with lossless, exactly-once, out-of-order delivery is to track the highest delivered nonce, which we term the lazy inbound nonce. The lazy inbound nonce begins at zero, and packets can only be executed if all packets starting from the lazy inbound nonce until the packet nonce are verified.

**中文直译**  
在链上高效实现一条不可审查、无损、恰好一次、支持乱序交付的信道，唯一可行的方法是追踪最高已交付 nonce，我们将其称为 `lazy inbound nonce`。惰性入站 nonce 初始为零，并且只有当从惰性入站 nonce 到目标数据包 nonce 之间的所有数据包都已经验证完成时，该数据包才可以执行。

**English**  
Updating the lazy inbound nonce upon verification rather than execution does not work in practice, because a single packet commit could result in an arbitrarily large update in the lazy inbound nonce. On the other hand, updating the lazy inbound nonce on execution can indeed run into computational limits, but permissionlessly retrying execution at a lower nonce will succeed. Undeliverable messages can be skipped by the OApp owner calling clear.

**中文直译**  
在验证阶段而不是执行阶段更新惰性入站 nonce，在实践中不可行，因为一次数据包提交就可能导致惰性入站 nonce 出现任意大的跳跃。相对地，在执行阶段更新惰性入站 nonce 确实可能遇到计算限制，但只要从更低 nonce 无许可地重试执行，就可以成功。那些不可交付的消息，则可以由 OApp 所有者通过调用 `clear` 来跳过。

**English**  
To enforce exactly-once delivery, we flag each packet after it is successfully received. In LayerZero, this is implemented by deleting the verified hash of a packet from the lossless channel after it is delivered and disallowing verification of nonces less than or equal to the lazy inbound nonce.

**中文直译**  
为了强制实现恰好一次交付，我们会在每个数据包成功接收后对其进行标记。在 LayerZero 中，这通过以下方式实现：在数据包交付后，从无损信道中删除该数据包的已验证哈希，并且禁止再次验证小于或等于惰性入站 nonce 的 nonce。

### Figure 5

![Figure 5](assets/layerzero-whitepaper/figure-5.png)

**English**  
A packet is Sent after source transaction increments the nonce, Verified after it is committed into the Endpoint, and Received after delivery (execution).

**中文直译**  
一个数据包在源链交易递增 nonce 后处于 `Sent` 状态，在被提交到 Endpoint 后处于 `Verified` 状态，在完成交付（执行）后处于 `Received` 状态。

## 3.2 MessageLib

**English**  
The MessageLib Registry is a collection of MessageLibs, each of which are responsible for securely emitting packets on the source chain and verifying them on the destination MessageLib. Each standalone MessageLib implements extrinsic security, necessitating adaptation to underlying environmental changes and precluding a fully immutable design of the MessageLib Registry.

**中文直译**  
MessageLib Registry 是一组 MessageLib 的集合，其中每个 MessageLib 都负责在源链上安全地发出数据包，并在目标链上的对应 MessageLib 上验证这些数据包。每个独立 MessageLib 都实现外在安全，因此它必须适应底层环境变化，这也使整个 MessageLib Registry 不可能是完全不可变的设计。

**English**  
MessageLib verifies the payload hash of each packet, committing the verified payload hash to the Endpoint after the extrinsic security requirement is fulfilled. To provide extensibility for extrinsic security while protecting existing OApps against in-place updates, we structure the MessageLib Registry as an append-only registry of immutable libraries, each of which can implement any arbitrary verification mechanism so long as it conforms to the protocol interface.

**中文直译**  
MessageLib 会验证每个数据包的负载哈希，并在满足外在安全要求后，将该已验证负载哈希提交到 Endpoint。为了在保护现有 OApps 不受原地更新影响的同时，提供外在安全的可扩展性，我们将 MessageLib Registry 设计为一个由不可变库组成的只追加注册表，其中每个库都可以实现任意验证机制，只要它符合协议接口即可。

**English**  
This design may seem counterintuitive at first, as it precludes any in-place software updates and thus appears to prevent the protocol admin from addressing software bugs. However, giving a single entity the power to unilaterally fix issues in-place also gives them the ability to introduce new vulnerabilities. This in turn invalidates any long-term protocol security invariants.

**中文直译**  
这种设计起初看上去似乎有些反直觉，因为它禁止任何原地软件更新，因此看起来也阻止了协议管理员修复软件缺陷。然而，给予单一实体单方面原地修复问题的权力，也同样给予了其引入新漏洞的能力。而这反过来会使任何长期协议安全不变量失效。

**English**  
We argue this append-only design is the only way to implement intrinsic security without compromising extensibility. OMPs must allow extensions, but at the same time guarantee that the extrinsic security of previous versions is never impacted by these code additions.

**中文直译**  
我们认为，这种只追加设计是在不牺牲可扩展性的前提下实现内在安全性的唯一方式。OMP 必须允许扩展，但同时也必须保证此前版本的外在安全绝不会受到这些新增代码的影响。

**English**  
Each MessageLib operates independently and handles the following tasks: accept the message from the Endpoint, encode and emit the packet to DVNs and executors while paying any necessary fees, verify the packet on the destination chain, and commit the verified message to the destination Endpoint. All other tasks are handled by executors.

**中文直译**  
每个 MessageLib 都独立运行，并负责以下任务：从 Endpoint 接收消息；对数据包进行编码并将其发给 DVNs 与执行器，同时支付必要费用；在目标链上验证数据包；以及把已验证消息提交给目标 Endpoint。其余所有任务都由执行器处理。

**English**  
Note that losslessness is enforced in the immutable endpoint, not in MessageLib. MessageLib can commit verified packet hashes into the endpoint out of order and with gaps. However, packets cannot be consumed from the lossless channel if there are gaps in the sequence of verified packets.

**中文直译**  
需要注意的是，无损性是由不可变的 endpoint 保证的，而不是由 MessageLib 保证的。MessageLib 可以以乱序且存在空洞的方式，把已验证数据包哈希提交进 endpoint。但是，如果已验证数据包序列中存在空洞，这些数据包就不能从无损信道中被消费。

## 3.2.1 Ultra Light Node

**English**  
The Ultra Light Node (ULN) is the baseline MessageLib included in every LayerZero deployment, and allows the composition of up to 254 DVNs through customizable two-tier quorum semantics. ULN implements the minimal set of fundamental features necessary for any verification algorithm and is thus universally compatible with all blockchains.

**中文直译**  
`Ultra Light Node (ULN)` 是每个 LayerZero 部署中都包含的基础 MessageLib，并且通过可定制的双层法定人数语义，支持最多组合 254 个 DVNs。ULN 实现了任何验证算法所必需的最小基础功能集，因此与所有区块链都具有普遍兼容性。

**English**  
Each OApp Security Stack that is configured to use the ULN includes a set of required DVNs, optional DVNs, and a threshold. A packet can only be delivered if all required DVNs and at least the optional threshold of optional DVNs have signed the corresponding payload hash.

**中文直译**  
每个被配置为使用 ULN 的 OApp 安全栈，都包含一组必选 DVNs、一组可选 DVNs，以及一个阈值。只有在所有必选 DVNs 和至少达到可选阈值数量的可选 DVNs 都签署了对应负载哈希后，该数据包才能被交付。

**English**  
The required DVN model allows OApps to place a lower bound on the extrinsic security of the verification layer, as no message can be verified without a signature from the most secure DVN in the required set. This composable verification primitive gives OApps the ability to trade off cost and security, allows OApps to easily configure client diversity in their DVN set, and minimizes the engineering cost of upgrading extrinsic security.

**中文直译**  
必选 DVN 模型使 OApps 能够为验证层的外在安全设定一个下界，因为如果没有必选集合中最安全 DVN 的签名，任何消息都不能被验证。这一可组合验证原语使 OApps 能够在成本与安全之间进行权衡，使 OApps 能够轻松为其 DVN 集配置客户端多样性，并把升级外在安全的工程成本降到最低。

### Figure 6

![Figure 6](assets/layerzero-whitepaper/figure-6.png)

**English**  
The Ultra Light Node enforces onchain the configured required DVNs, optional DVNs, and OptionalThreshold. Verification is neither lossless nor ordered, and messages can be committed to the channel as soon as the Security Stack is fulfilled.

**中文直译**  
Ultra Light Node 会在链上强制执行所配置的必选 DVNs、可选 DVNs 以及 `OptionalThreshold`。验证本身既不是无损的，也不要求有序；只要满足安全栈要求，消息就可以被提交到信道中。

## 3.2.2 MessageLib versioning and migration

**English**  
MessageLibs are identifiable through a unique ID paired with semantic version, and a message can only be sent between two Endpoints if both implement a MessageLib with the same major version. Major versions determine packet serialization and deserialization compatibility, while minor versions are reserved for bugfixes and other non-breaking changes.

**中文直译**  
每个 MessageLib 都通过唯一 ID 与语义化版本号共同标识。只有当两个 Endpoint 都实现了主版本号相同的 MessageLib 时，消息才能在两者之间发送。主版本决定数据包序列化与反序列化兼容性，而次版本保留给 bug 修复以及其他非破坏性更改。

**English**  
Each OApp Security Stack specifies the sendLibrary and receiveLibrary to use for each chain it spans. This configurability enables OApps to customize Security Stack cost and security based on their individual needs. For rapid prototyping, LayerZero implements an opt-in mechanism to allow OApps to lazily resolve their Security Stack to the defaults chosen and maintained by the LayerZero admin, but OApp owners are strongly encouraged to explicitly set their Security Stack for production applications.

**中文直译**  
每个 OApp 安全栈都会为其跨越的每条链指定要使用的 `sendLibrary` 和 `receiveLibrary`。这种可配置性使 OApps 能够根据自身需要定制安全栈的成本与安全属性。为了便于快速原型开发，LayerZero 实现了一种 opt-in 机制，使 OApps 可以把其安全栈懒解析为由 LayerZero 管理员选定并维护的默认配置，但对于生产应用，强烈建议 OApp 所有者显式设置自己的安全栈。

**English**  
The impossibility of coordinating atomic transactions over an asynchronous network necessitates a live migration protocol when reconfiguring the OApp Security Stack. Upgrading to a MessageLib with the same major version but a different minor version is simple. Migrating between different major versions is more involved and requires a grace period for the old receiveLibrary to continue receiving in-flight messages.

**中文直译**  
由于在异步网络上协调原子事务是不可能的，因此在重配置 OApp 安全栈时，必须采用一种在线迁移协议。升级到主版本相同但次版本不同的 MessageLib 很简单。而在不同主版本之间迁移则更复杂，需要为旧的 `receiveLibrary` 设置一个宽限期，以便它继续接收仍在途中的消息。

## 3.3 Decentralized Verifier Network

**English**  
The datalink in LayerZero is designed on the fundamental observation that connecting two blockchains without the assumption of synchrony requires communication through one or more third parties. A consequence of the potentially offchain nature of DVNs is the impossibility of guaranteeing long-term immutability and availability, and as such a permissioned verification model is inherently unable to provide strong guarantees of channel liveness.

**中文直译**  
LayerZero 中的数据链路设计建立在一个基本观察之上：在不假设同步性的情况下连接两条区块链，必然需要通过一个或多个第三方进行通信。由于 DVNs 可能天然包含链下部分，因此不可能保证其长期不可变性和可用性；也因此，许可式验证模型天生无法对信道活性给出强保证。

**English**  
Thus, we have opted to implement a permissionless, configurable verification model in LayerZero, where anyone can operate and permissionlessly integrate their own DVN with LayerZero. Decentralized Verifier Networks are composed internally of a set of verifiers that collectively perform distributed consensus to safely and reliably read packet hashes from the source blockchain.

**中文直译**  
因此，我们选择在 LayerZero 中实现一种无许可、可配置的验证模型，任何人都可以运行自己的 DVN，并以无许可方式将其接入 LayerZero。Decentralized Verifier Networks 在内部由一组验证器组成，这些验证器通过分布式共识，安全可靠地从源区块链读取数据包哈希。

**English**  
This model overcomes two glaring shortcomings of other messaging services: shared security and finite fault tolerance. Through permissionless operation of DVNs, LayerZero is able to provide a practically unbounded degree of fault tolerance. Even if all existing DVNs lose liveness, OApp developers can operate their own DVNs to continue operation of the protocol.

**中文直译**  
这一模型克服了其他消息服务的两个明显缺陷：共享安全与有限容错。通过 DVNs 的无许可运行，LayerZero 能够提供近乎无界的容错能力。即使现有所有 DVNs 都失去活性，OApp 开发者仍然可以运行自己的 DVNs，使协议继续运行。

### Figure 7

![Figure 7](assets/layerzero-whitepaper/figure-7.png)

**English**  
OApps can easily reconfigure their Security Stack to exclude faulty DVNs.

**中文直译**  
OApps 可以轻松重配置其安全栈，把有问题的 DVNs 排除在外。

## 3.4 Executors

**English**  
Implementing and updating extrinsically secure code is resource-intensive due to stringent security testing and auditing requirements. This stands in conflict with our goal of making LayerZero easily extensible to support the needs of a wide variety of omnichain applications.

**中文直译**  
由于需要严格的安全测试和审计，实现和更新具备外在安全性的代码会消耗大量资源。这与我们希望 LayerZero 易于扩展、能够支持各种全链应用需求的目标存在冲突。

**English**  
LayerZero solves this problem by separating verification from execution; any code that is not security-critical is factored out into executors, which are permissionless and isolated from the packet verification scope. This provides two main benefits. First, developers can use, implement, and compose feature extensions without considering security. Second, it decouples security and liveness in LayerZero, ensuring that a faulty executor cannot unilaterally prevent message delivery.

**中文直译**  
LayerZero 通过把验证与执行分离来解决这个问题；任何非安全关键代码都会被拆分到执行器中，而执行器是无许可的，并且与数据包验证作用域隔离。这带来两个主要好处。第一，开发者可以在不考虑安全性的情况下使用、实现和组合功能扩展。第二，它把 LayerZero 中的安全性与活性解耦，确保有缺陷的执行器无法单方面阻止消息交付。

**English**  
When an OApp sends a LayerZero message, it specifies all offchain workers and corresponding arguments through a MessageLib-interpreted byte array called Message Options. The executors then wait for the Security Stack to verify the packet before taking action based on the commands encoded in Message Options.

**中文直译**  
当 OApp 发送一条 LayerZero 消息时，它会通过一个由 MessageLib 解释的字节数组 `Message Options` 指定所有链下工作者以及相应参数。执行器随后会等待安全栈完成该数据包的验证，然后再根据 Message Options 中编码的命令执行动作。

**English**  
The isolation of executors from any verification-related code indirectly improves channel validity, and permissionless execution directly improves channel liveness. Once a message is verified by the Security Stack, anyone willing to pay the gas cost can permissionlessly execute the message.

**中文直译**  
执行器与任何验证相关代码的隔离，间接提升了信道有效性；而无许可执行则直接提升了信道活性。一旦消息被安全栈验证，任何愿意支付 gas 成本的人都可以无许可地执行该消息。

### Figure 8

![Figure 8](assets/layerzero-whitepaper/figure-8.png)

**English**  
lzCompose enables chain-agnostic composition with liveness and safety closures.

**中文直译**  
`lzCompose` 使链无关组合成为可能，并带来活性与安全性的闭包特性。

## 4. Extensions

**English**  
In this section, we illustrate the flexibility of LayerZero through several examples of how the protocol can be extended with additional execution features.

**中文直译**  
在本节中，我们通过若干示例来展示 LayerZero 的灵活性，以及协议如何通过附加执行特性得到扩展。

## 4.1 Message Options

**English**  
While there is no single standard format for serializing arguments into Message Options, we do not expect developers to write specialized code to support Message Options for every MessageLib. To address this, LayerZero currently defines three standardized formats for Message Options to facilitate backwards-compatibility between library versions.

**中文直译**  
虽然并不存在一种统一标准格式来规定如何把参数序列化到 Message Options 中，但我们并不期望开发者为每个 MessageLib 都编写专门支持 Message Options 的代码。为了解决这一点，LayerZero 目前定义了三种标准化的 Message Options 格式，以便在不同库版本之间保持向后兼容。

**English**  
Types 1 and 2 specify arguments for a single executor to execute commonly-required functionality, while type 3 encodes a list of worker tuples to allow for an arbitrary number of arguments passed to an arbitrary number of workers. Any message delivered by an executor has already been verified by the verification layer.

**中文直译**  
类型 1 和类型 2 为单个执行器执行常见功能指定参数，而类型 3 则编码一个工作者元组列表，以便把任意数量的参数传递给任意数量的工作者。任何由执行器交付的消息，在此之前都已经由验证层验证过。

### Table 4

| Type | Structure |
| --- | --- |
| Execution gas | `[TYPE 1, executionGas]` |
| Gas and native drop | `[TYPE 2, executionGas, nativedropAmount, receiverAddress]` |
| Composite | `[TYPE 3, [workerID, opType, length, command], ...]` |

**English**  
Type 1 and 2 are specialized for setting execution gas limits and sending additional native gas tokens as part of an omnichain transaction respectively. Type 3 embeds arguments for an arbitrary set of offchain workers.

**中文直译**  
类型 1 和类型 2 分别专用于设置执行 gas 限额，以及在全链交易中附带发送额外原生 gas 代币。类型 3 则用于为任意一组链下工作者嵌入参数。

## 4.2 Semantically uniform composition

**English**  
LayerZero defines a universally standardized interface for cross-chain composition: lzCompose. Composing the destination chain delivery transaction with other contracts may seem trivial to those familiar only with EVM, but even existing MoveVM-based blockchains do not natively support this feature, invalidating the universality of EVM-style runtime dispatch composition semantics.

**中文直译**  
LayerZero 为跨链组合定义了一个普遍标准化的接口：`lzCompose`。对只熟悉 EVM 的人来说，把目标链上的交付交易与其他合约组合似乎是件很简单的事，但即便是现有的基于 MoveVM 的区块链，也并不原生支持这一功能，因此 EVM 风格运行时调度组合语义并不具备通用性。

**English**  
When composing contracts, the receiver first stores a composed payload into the endpoint by sendCompose, after which it is retrieved from the ledger and passed to the composed callback by calling lzCompose. This design, while superficially inefficient on EVM-based chains, unifies composition semantics across all blockchains.

**中文直译**  
在进行合约组合时，接收方首先会通过 `sendCompose` 将一个组合负载存入 endpoint，之后再从账本中取出，并通过调用 `lzCompose` 把它传递给被组合的回调。虽然这一设计在基于 EVM 的链上表面上显得不够高效，但它统一了所有区块链上的组合语义。

**English**  
lzCompose provides a semantically universal standard composition primitive that inherits the same only-once lossless execution semantics of LayerZero messaging, and allows OApps to define a single application architecture that universally scales to all existing and future blockchains.

**中文直译**  
`lzCompose` 提供了一种语义通用的标准组合原语，它继承了 LayerZero 消息同样的恰好一次、无损执行语义，并允许 OApps 定义一套统一的应用架构，将其普遍扩展到所有现有与未来区块链。

**English**  
The lzCompose primitive is a powerful tool for defining closures for data validity and channel liveness, isolating each composed contract from potential integrity violations by other contracts. An additional benefit of lzCompose is a uniform interface for tracing and analysis of a potentially deep call stack for complex multihop omnichain transactions.

**中文直译**  
`lzCompose` 原语是定义数据有效性闭包与信道活性闭包的强大工具，它把每个被组合的合约与其他合约可能造成的完整性违规隔离开来。`lzCompose` 的另一个好处是，它为复杂多跳全链交易中可能很深的调用栈提供了统一的追踪与分析接口。

## 4.3 Application-level security

**English**  
It is impossible to use the Message Options interface to extend the verification scope to include additional data, but OApps can use it to detect and filter out verified-yet-malicious messages. We introduce our novel offchain application-level security mechanism called Pre-Crime, which provides an additional layer of application-specific packet filtering on top of the existing LayerZero protocol.

**中文直译**  
不可能通过 Message Options 接口把验证范围扩展到额外数据，但 OApps 可以利用它来检测并过滤那些虽然已经通过验证、却仍然具有恶意的消息。我们提出一种新的链下应用层安全机制，称为 `Pre-Crime`，它在现有 LayerZero 协议之上增加了一层面向应用的、特定于数据包的过滤能力。

**English**  
Pre-Crime enables any subset of peers to enforce application security invariants after simulating the result of packet delivery. The invariant check results are collated by an offchain worker, which halts delivery of the corresponding packet if any peer reports a violated invariant.

**中文直译**  
Pre-Crime 允许任意一个对等体子集在模拟数据包交付结果之后，对应用安全不变量进行约束。某个链下工作者会汇总这些不变量检查结果；如果任何一个对等体报告不变量被破坏，它就会停止相应数据包的交付。

**English**  
Figure 9 illustrates the example of checking the total outstanding token count in a 3-chain token bridge. Chain A is compromised and tries to request an additional mint on chain B without locking additional assets. Pre-Crime detects this and isolates the security breach to a single chain. It is important to note that Pre-Crime does not add any additional protocol security, and cannot protect data integrity against malicious DVNs or blockchain-level faults.

**中文直译**  
图 9 展示了一个三链代币桥中检查总代币发行量的例子。链 A 被攻陷，并试图在没有额外锁定资产的情况下请求在链 B 上额外增发。Pre-Crime 会检测到这一点，并把这次安全破坏隔离在单条链上。需要强调的是，Pre-Crime 并不会增加额外的协议级安全性，也无法在面对恶意 DVNs 或区块链层故障时保护数据完整性。

### Figure 9

![Figure 9](assets/layerzero-whitepaper/figure-9.png)

**English**  
Pre-Crime rejects malicious and malformed messages by checking OApp-specified invariants.

**中文直译**  
Pre-Crime 通过检查 OApp 指定的不变量，拒绝恶意或格式错误的消息。

## 5. Conclusion

**English**  
In this paper, we presented the design and implementation of the LayerZero protocol. LayerZero provides intrinsically secure cross-chain messaging with universal semantics to enable a fully connected omnichain mesh network that connects all blockchains within and across compatibility groups.

**中文直译**  
本文介绍了 LayerZero 协议的设计与实现。LayerZero 提供具备通用语义的内在安全跨链消息能力，从而实现一个全连接的全链网状网络，连接兼容组内与兼容组之间的所有区块链。

**English**  
By isolating intrinsic security from extrinsic security, LayerZero guarantees long-term stability of channel integrity and gives OApps universal network semantics across the entire mesh network. LayerZero's universal network semantics and intrinsic security guarantees enable secure chain-agnostic interoperation.

**中文直译**  
通过把内在安全与外在安全隔离开来，LayerZero 保证了信道完整性的长期稳定，并为 OApps 提供覆盖整个网状网络的通用网络语义。LayerZero 的通用网络语义与内在安全保证，使安全的链无关互操作成为可能。

**English**  
Our novel onchain verification module, MessageLib, implements extensible extrinsic security in an intrinsically secure manner. Each OApp has exclusive permission to modify its Security Stack, which defines the extrinsic security of their messaging channel. The immutability of existing MessageLibs ensures that no entity, including the protocol administrator, can unilaterally compromise OApp security.

**中文直译**  
我们新的链上验证模块 `MessageLib`，以一种内在安全的方式实现了可扩展的外在安全。每个 OApp 都独占拥有修改其安全栈的权限，而安全栈定义了其消息信道的外在安全。现有 MessageLib 的不可变性确保没有任何实体，包括协议管理员，能够单方面破坏 OApp 的安全性。

**English**  
LayerZero's isolation of execution features from packet verification allows a near-unlimited degree of freedom to implement additional features without affecting security. In addition, the separation of execution and verification in LayerZero reduces engineering costs, attack surfaces, and improves overall protocol liveness. Together, these components create a highly extensible protocol that can provide universal messaging semantics across existing and future blockchains.

**中文直译**  
LayerZero 将执行特性与数据包验证隔离开来，因此几乎可以在不影响安全性的前提下自由实现附加功能。此外，LayerZero 中执行与验证的分离降低了工程成本、减少了攻击面，并提升了整体协议活性。这些组件共同构成了一个高度可扩展的协议，能够在现有与未来区块链之间提供通用消息语义。

## References

1. BEHNKE, R. *Explained: The nomad hack (August 2022).*  
   <https://www.halborn.com/blog/post/explained-the-nomad-hack-august-2022>
2. GMYTRASIEWICZ, P. J., AND DURFEE, E. H. *Decision-theoretic recursive modeling and the coordinated attack problem.* Proceedings of the First International Conference on Artificial Intelligence Planning Systems, 1992.
3. HACXYK. *Wormhole $10m bounty.*  
   <https://twitter.com/Hacxyk/status/1529389391818510337>
4. THORCHAIN. *Post-mortem: Eth router exploits 1 & 2, and premature return to trading incident.*  
   <https://medium.com/thorchain/post-mortem-eth-router-exploits-1-2-and-premature-return-to-trading-incident-2908928c5fb>
5. ZAMYATIN, A. et al. *SoK: Communication Across Distributed Ledgers.*  
   <https://eprint.iacr.org/2019/1128>
6. ZARICK, R., PELLEGRINO, B., AND BANISTER, C. *LayerZero: Trustless Omnichain Interoperability Protocol.*  
   <https://layerzero.network/pdf/LayerZero_Whitepaper_Release.pdf>
