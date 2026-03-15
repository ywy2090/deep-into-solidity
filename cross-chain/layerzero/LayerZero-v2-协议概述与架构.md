# LayerZero v2 协议概述与架构

- 作者：Roman Yarlykov
- 身份：Solidity 开发者
- 发布时间：2024 年 11 月 28 日
- 阅读时长：23 分钟
- 原文地址：<https://metalamp.io/magazine/article/overview-and-architecture-of-the-layerzero-v2-protocol>

![文章封面](./assets/layerzero-v2-protocol/article-cover.png)

LayerZero 是一个不可变、抗审查、无许可的协议，允许任意区块链用户把消息发送到受支持的目标网络，并在目标网络上完成验证与执行。

文档里确实是这么定义它的，但如果只停留在这句话上，其实很难真正理解它在做什么。LayerZero **不是** 一条独立的区块链，也不是传统意义上的跨链桥。正如 LayerZero Labs CEO Brian Pellegrino 所说，它不是一个跨链消息标准，而是一套数据传输协议，只不过数据是以消息的形式来传递。除了负责“把数据送过去”，它还提供了消息在传输过程中的验证与执行基础设施。

如果把视角拉高一点，LayerZero 其实是在尝试回答区块链互操作性问题：怎样在不牺牲太多安全性的前提下，让不同链之间可靠通信。它的核心特点有三个：可扩展、可按应用自定义安全配置，以及把“验证”和“执行”明确拆开。第二版协议把自己定位为一套全链方案，也就是 **Omnichain Messaging Protocol（OMP，全链消息协议）**。

这里说的“互操作性”（interoperability），指的是一个系统在接口开放的前提下，能够与其他系统相互协作、共同运行，而不需要额外的接入限制或实现限制。

> 注：如果你想进一步了解互操作性、它的几种常见实现思路，以及 cross-chain、multichain、omnichain 的区别，可以读这篇文章：[Omnichain vs Multichain vs CrossChain: What Are They?](https://hackernoon.com/omnichain-vs-multichain-vs-crosschain-what-are-they)

简单来说，cross-chain 关注的是两条链之间如何通过桥来交互；multichain 指一个 DApp 同时部署在多条链上，包括模块化区块链；omnichain 则更进一步，尝试在更底层建立一套统一的跨链消息语义，让不同链和不同应用都可以在同一套机制下通信。全链方案的优势就在这里：消息传递逻辑是统一的，但每条链连接的安全策略又可以单独配置。

![Cross-chain 与 Omnichain 的区别](./assets/layerzero-v2-protocol/crosschain-vs-omnichain.png)

*Cross-chain 与 Omnichain 的区别。来源：LayerZero v2 白皮书。*

这张图大致可以这样理解：

- **Cross-chain（左侧）**：网络之间通过一座座独立的桥分别连接。每多一条链，连接关系就更复杂一层；如果不同兼容组之间还要互通，还得额外再接安全层和集成层。这种模式的本质是“点对点拼接”，复杂度会随着连接数量迅速上升。
- **Omnichain（右侧）**：每条链都通过统一语义直接与其他链通信。在 LayerZero 的设计里，这意味着跨链连接的接口是标准化的，但每一条连接的安全模型仍然可以单独调整。

## LayerZero 的基本原则

Omnichain Messaging Protocol（OMP）建立在两个核心原则上：**安全性** 和 **通用语义**。

### 安全性

LayerZero 把安全拆成两层：内部安全和外部安全。很多协议只强调外部验证，比如签名机制、预言机、验证者网络，但对消息通道本身的约束考虑得没那么完整。LayerZero 的区别就在于，它把“通道自身必须满足哪些不变量”也纳入了安全模型。

**内部安全** 包括三个关键不变量：

1. **Lossless（无损传输）**：消息在传输过程中不能丢、不能被改。
2. **Exactly-once（恰好一次）**：一条消息只能被处理一次，不能重放。
3. **Eventual delivery（最终送达 / 活性）**：即使中途出现暂时故障，消息最终也应该送达。

**外部安全** 则是签名算法、验证机制这类内容。它不是固定不变的，而是可以根据应用需求灵活替换和组合。

从协议完整性的角度看，还可以再细分成两部分：**传输通道的完整性** 和 **消息数据本身的完整性**。这两部分都涉及两个问题：正确性（validity）和活性（liveness）。内部安全负责通道的正确性与活性，外部安全负责数据本身的正确性。白皮书里对应的是下面这张图：

![协议完整性的关键维度](./assets/layerzero-v2-protocol/protocol-integrity.png)

*协议完整性的关键维度。来源：LayerZero v2 白皮书。*

> 注：这里的 packet 指一组待传输的数据，后文会继续展开。

这些内容组合起来，就形成了一个模块化安全栈。每个 OApp（omnichain application，全链应用）都可以自己决定安全栈怎么配。和单体式系统相比，这种设计的好处很明显：某个模块升级出问题，不会直接拖垮整个协议。

这也是 LayerZero 一直强调“不可变代码”的原因。安全模块不会被原地修改，升级通过发布新版本完成，旧版本仍然保留并继续可用。这样一来，配置变更由 OApp 拥有者自己承担，也被严格限定在自己的作用域里，不容易演变成系统性风险。

### 通用语义

协议如果想支持任意区块链，就不能把行为建立在某条链的特定语义上。换句话说，底层结构必须足够通用，才能保证跨链交互在不同环境里仍然保持一致。

LayerZero 试图做的，就是把跨链交互这件事标准化。运行在 LayerZero 上的应用，不应该依赖某条具体链的实现细节，不管目标链是 EVM 还是非 EVM。这里所谓“通用语义”，主要包含两层意思：

- **执行语义（Execution semantics）**：也就是 OApp 自己的业务逻辑。它最好尽量不依赖底层链的特性，同时又要足够灵活，能承载真实业务。
- **接口统一（Interface unification）**：不同链之间需要一套统一的消息发送接口。否则，每多接一条链，开发者就得额外适配一次，扩展成本会越来越高。

缺少统一接口和统一消息语义，会让多链应用开发变得很别扭。LayerZero 的价值就在这里：它试图把这些“每条链都不一样”的地方，尽量收敛到一套统一抽象里。

## 架构

LayerZero 的目标其实很直接：**把一条消息可靠地从一条链送到另一条链**。这条消息本身包含两部分：要传输的数据负载（payload）和与之对应的路由信息。

![消息传输的高层示意图](./assets/layerzero-v2-protocol/message-transmission-overview.png)

*消息传输的高层示意图。来源：LayerZero 文档。*

### Endpoint

整个流程从源链上的 OApp 开始，到目标链上的 OApp 结束。对于 OApp 来说，最直接的交互对象就是智能合约 [Endpoint](https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/protocol/contracts/EndpointV2.sol)。

![与 Endpoint 的交互方式](./assets/layerzero-v2-protocol/endpoint-interaction.png)

*与 Endpoint 的交互方式。*

Endpoint 负责处理入站和出站消息。消息在传输过程中都会被封装成 packet。

一个 packet 分成两部分：header 和 body。header 里放的是路由信息和一些服务字段，body 里放的才是真正的消息内容。

![Packet 结构](./assets/layerzero-v2-protocol/packet-structure.png)

*Packet 结构。来源：LayerZero v2 白皮书。*

Endpoint 的职责主要包括：

1. **收取费用**：向 OApp 收取消息发送成本，既可以用链原生币，也可以用 ERC20 形式的 `lzToken`。
2. **发送前构造 packet**，这个过程又包含几个步骤：
   - **分配 nonce 和 GUID**：每条消息都会拿到一个唯一的 `nonce`，用于保证消息只执行一次；同时还会生成一个 [GUID](https://github.com/LayerZero-Labs/LayerZero-v2/blob/7aebbd7c79b2dc818f7bb054aed2405ca076b9d6/packages/layerzero-v2/evm/protocol/contracts/libs/GUID.sol#L10)，用于跟踪消息状态。GUID 的计算方式是 `keccak256(nonce, srcId, sender, dstId, receiver)`，其中 `srcId` 和 `dstId` 是网络标识，因为不是所有链都有 `chainId`。
   - **消息序列化和 packet 组装**：把消息体和路由信息编码成可以在 LayerZero 中传输的 packet。

```solidity
struct Packet {
    uint64 nonce; // 唯一交易序号，严格递增
    uint32 srcEid; // 源网络标识
    address sender; // 发送方地址
    uint32 dstEid; // 目标网络标识
    bytes32 receiver; // 接收方地址
    bytes32 guid; // GUID
    bytes message; // 消息体
}
```

3. **发送通知**：消息发出后触发 `PacketSent` 事件。
4. **校验入站 packet**：验证接收到的 packet 是否完整、合法。
5. **执行消息**：Endpoint 中包含 [`lzReceive`](https://github.com/LayerZero-Labs/LayerZero-v2/blob/7aebbd7c79b2dc818f7bb054aed2405ca076b9d6/packages/layerzero-v2/evm/protocol/contracts/EndpointV2.sol#L172)，用于把 packet 真正投递到目标链。
6. **保证 packet 被正确处理**：这部分是消息通道活性的关键，也是内部安全的一部分。

> 注：GUID 用来跟踪消息状态，也会在链下和链上的后续流程里被继续使用。

### 无损通道

Endpoint 最重要的职责之一，就是保证消息通道本身是可靠的。为了做到这一点，通道至少要满足两个要求：一是**无损传输**，二是由 [`MessagingChannel`](https://github.com/LayerZero-Labs/LayerZero-v2/blob/7aebbd7c79b2dc818f7bb054aed2405ca076b9d6/packages/layerzero-v2/evm/protocol/contracts/MessagingChannel.sol) 维护的顺序约束。

每条消息都有一个唯一且递增的 `nonce`。系统虽然允许乱序投递，但不能破坏“前面的消息最终都要处理到”这个基本约束。LayerZero 这里引入了一个叫作 `lazyInboundNonce` 的概念，可以把它理解成“截至当前，之前所有消息都已经被处理或显式跳过”的最大 nonce。`lazyInboundNonce` 从 0 开始，只有当从 `lazyInboundNonce` 到当前 nonce 之间的 packet 都完成验证，当前 packet 才允许执行。

例如，如果 nonce 为 `1` 和 `2` 的 packet 还没有完成验证，那么 nonce 为 `3` 的 packet 就不能执行。

但一旦 nonce 为 `1`、`2`、`3` 的 packet 都完成了验证，即便 nonce `2` 在执行时失败了，比如 gas 不足或业务逻辑报错，nonce `3` 仍然可以继续执行。

![乱序 packet 投递](./assets/layerzero-v2-protocol/out-of-order-packet-delivery.png)

*乱序 packet 投递。来源：LayerZero v2 白皮书。*

**注意：** 已验证的 packet 可以乱序执行。如果业务确实需要，也可以配置成严格顺序执行。

为了更灵活地管理 nonce，协议还提供了 `skip`、`clear`、`nilify`、`burn` 等函数：

- 当消息有误或明显恶意时，OApp 可以用 **clear** 跳过某条消息的投递，也可以用 **skip** 同时跳过验证和投递。
- **nilify** 会把一条已经验证过的 packet 作废。在新的 `MessageLib` 消息重新写入之前，它都不能执行。这个机制可以用来撤销由被攻破 DVN 产生的恶意 packet。
- **burn** 则允许 OApp 在不知道 packet 内容的情况下直接删掉它。如果错误的安全栈在 Endpoint 上记录了错误哈希，或者 OApp 想清理一条之前被 `nilify` 的 nonce，就会用到它。

### MessageLib

[MessageLib](https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/messagelib/contracts/SendLibBaseE2.sol) 是 LayerZero 外部安全的核心组件。每个 OApp 都要指定自己使用哪一个 `MessageLib`。如果没有显式配置，就会落到默认库，比如 ULN。协议内部还维护了一个 `MessageLib Registry`，专门用来管理这些消息库。理论上库可以有很多种，但如果两个 OApp 想互相通信，双方在两条链上必须使用兼容的同类消息库。

![通过 MessageLib 处理消息的流程](./assets/layerzero-v2-protocol/messagelib-processing.png)

*通过 MessageLib 处理消息的流程。来源：LayerZero 文档。*

每个 `MessageLib` 都可以实现自己的验证逻辑，只要遵守协议接口 [`ISendLib`](https://github.com/LayerZero-Labs/LayerZero-v2/blob/main/packages/layerzero-v2/evm/protocol/contracts/interfaces/ISendLib.sol)。这点很重要，因为它避免了协议把安全性压在单一验证机制上，而这正是很多跨链系统最脆弱的地方。

`MessageLib` 的主要职责，是在发送和接收 packet 的过程中，检查它是否满足 OApp 配置的外部安全要求。

那些不在安全关键路径上的功能，则被交给 executor。这样 `MessageLib` 本身能保持足够精简，未来扩展新能力时，也可以通过 executor 来做，而不必频繁改动核心安全逻辑。

![源网络中的 MessageLib 交互](./assets/layerzero-v2-protocol/messagelib-source-network.png)

*源网络中的 MessageLib 交互。*

消息经过 `MessageLib` 处理后，会再回到 Endpoint，由 Endpoint 发出事件，通知相关参与方。

在目标网络上，`MessageLib` 会先验证 packet，并把验证结果写进 Endpoint。只有到了这一步，`Endpoint::lzReceive()` 才能被调用。

![目标网络中的 MessageLib 交互](./assets/layerzero-v2-protocol/messagelib-destination-network.png)

*目标网络中的 MessageLib 交互。*

### 库版本与迁移

一旦某个库被加入 `MessageLib` 注册表，就没人能修改或删除它，包括 LayerZero 管理员自己。为了既支持外部安全持续扩展，又不影响已经上线的 OApp，`MessageLib Registry` 采用的是 append-only 模式：只能新增库和新增版本，不能原地覆盖旧版本。

LayerZero 中每个 `MessageLib` 都有唯一 ID 和版本号，格式是 `major.minor`，例如 `1.0`。只有当两个 Endpoint 使用相同主版本的 `MessageLib` 时，消息才能在它们之间传递。

- **主版本（Major）**：决定 packet 编码和解码是否兼容。
- **次版本（Minor）**：用于修 bug 或做不破坏兼容性的改动。

每个 LayerZero packet 版本都绑定到某个特定的 `MessageLib` 版本。这样一来，DVN 在目标链验证 packet 时，就能明确该调用哪一个消息库。

库版本采用三段式编号，最后一位表示 Endpoint 版本：

- **第一位**：库的主版本。不同主版本之间不兼容。如果源链和目标链主版本不同，它们之间就不能互发消息。
- **第二位**：库的次版本。不同次版本之间兼容。
- **第三位**：Endpoint 版本。比如 LayerZero v2 对应的就是 `2`。

当前 ULN（默认消息库）的版本如下：

```solidity
function version() external pure override returns (uint64 major, uint8 minor, uint8 endpointVersion) {
    return (3, 0, 2);
}
```

不同主版本之间的迁移是渐进式进行的，这样既能控制风险，也便于处理异步迁移场景。

## 安全栈

LayerZero 的安全栈由 DVN（Decentralized Verifier Networks，去中心化验证网络）、`MessageLib` 和 OApp 配置共同组成，但其中最关键的还是 DVN。因为只要涉及跨链，问题就绕不开：谁来负责在两条链之间做验证。

**DVN（去中心化验证网络）** 可以理解为一组验证者组成的网络。它们通过分布式共识，从源链读取 packet 哈希，并对其进行确认。这个设计有个很现实的优点：同一个 DVN 内部可以支持不同类型的客户端，不容易因为单一客户端故障把整个验证系统拖垮。

![DVN 参与的 packet 发送流程](./assets/layerzero-v2-protocol/dvn-packet-sending.png)

*DVN 参与的 packet 发送流程。来源：LayerZero 文档。*

每个 OApp 都可以自己配置安全栈。安全栈里既可以包含必须参与的 DVN，也可以包含可选 DVN，用来共同验证 `payloadHash`。同时，还可以设置一个可选阈值，只有达到阈值，这条 packet 才算验证通过。

DVN 本身既可以包含链上组件，也可以包含链下组件，或者两者混合。一个安全栈里理论上可以接入任意数量的 DVN。DVN 还可以基于 ZKP、侧链、原生区块链等不同路线实现，所以整体配置空间非常大。

![DVN 验证 packet 的过程](./assets/layerzero-v2-protocol/dvn-packet-verification.png)

*DVN 验证 packet 的过程。来源：LayerZero 文档。*

每个 DVN 都会按自己的验证方式检查 `payloadHash`。只有当目标网络中的 `MessageLib` 确认这些验证结果满足要求时，packet 才会被正式视为已验证。

当所有必选 DVN 都确认了 `payloadHash`，并且额外 DVN 也达到了设定阈值之后，这条 packet 的 `nonce` 和 `payloadHash` 就会被写入 Endpoint，状态变成已验证。再往后，Executor 才能继续执行消息。

可用 DVN 列表可以参考这里：[DVN Addresses](https://docs.layerzero.network/v2/developers/evm/technical-reference/dvn-addresses)

这个设计还有一个很实用的好处：哪怕现有 DVN 因软件故障、安全事件、自然灾害或治理问题全部停摆，OApp 开发者仍然可以自己部署新的 DVN，把系统继续跑起来。

### Ultra Light Node

**Ultra Light Node（ULN）** 是每次 LayerZero 部署都会自带的基础消息库，也就是默认的 `MessageLib`。ULN 通过一个可定制的双层仲裁系统，最多可以支持 `254` 个 DVN。

ULN 只实现了验证所需的最小功能集，因此适配面非常广。对于使用 ULN 的 OApp，它的安全栈通常包括：

- 必选 DVN
- 可选 DVN，以及可选验证者阈值 `OptionalThreshold`

一条 packet 想通过验证，必须同时满足两个条件：所有必选 DVN 都签署了 payload hash，且可选 DVN 中至少有 `OptionalThreshold` 个完成签署。一旦 ULN 收到足够多的 DVN 签名，这条 packet 就可以记录到 Endpoint。

![ULN 中 DVN 工作示例](./assets/layerzero-v2-protocol/uln-dvn-example.png)

*ULN 中 DVN 工作示例。来源：白皮书。*

在这个例子里，OApp 的安全栈包含：

- 一个必选 DVN（`DVN_A`），拥有否决权
- N-1 个可选 DVN（`DVN_B`、`DVN_C` 等），可选阈值 `OptionalThreshold` 设为 `2`

这意味着，要确认一条 packet，必须满足：

- **`DVN_A` 必须确认**，因为它拥有否决权
- **可选 DVN 里至少还要有一个确认**
- **nonce `1`** 已经写入消息通道，状态为 `Verified`
- **nonce `2`、`3`、`6`** 满足安全条件，因此可以记录，但只有在 Executor 调用 `commitVerification` 后才会最终确认
- **nonce `4` 和 `5`** 不能被记录，因为 `4` 没满足必选验证要求，`5` 没达到可选 DVN 阈值

### Executor

LayerZero 通过**把验证和执行分开**，来解决外部安全代码越来越重、越来越难扩展的问题。凡是不属于安全关键路径的逻辑，都会被放到独立组件里，这个组件就是 **executor**。executor 是无许可运行的，并且和 packet 验证流程相互隔离。

![执行层与安全层分离](./assets/layerzero-v2-protocol/verification-vs-execution.png)

*执行层与安全层分离。来源：白皮书。*

这种把 **安全代码**（位于 `MessageLib`）和 **功能代码**（位于 executor）拆开的做法，有两个很直接的好处：

1. **更容易扩展**：开发者可以增加新功能，而不用碰安全关键路径。因为 Endpoint 会阻止未验证或验证不完整的消息进入执行阶段，所以验证流程和执行流程天然隔离。
2. **安全性和活性分离**：即使 executor 出现故障，也不会阻止消息最终送达，系统的韧性会更好。排查问题时也更清楚，能比较容易地区分故障出在验证层还是执行层。

当 OApp 发送一条消息时，会把所有外部执行者（例如 executor、DVN）及其参数编码进一个名为 `Message Options` 的字节数组，由 `MessageLib` 解析。executor 会一直等待，直到安全栈确认这条 packet 已通过验证，然后才执行对应动作。

由于验证和执行是分开的，消息通道的可靠性也更高。即便某个 Executor 失效，通道本身依然可以恢复。一旦安全栈完成验证，任何愿意支付 gas 的人都可以在不需要额外授权的前提下执行这条消息。这意味着当 executor 出问题时，最终用户甚至可以手动帮 OApp 把流程恢复起来。

可用 executor 列表可以在这里查看：[Deployed Contracts](https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts)

## 从发送者到接收者的完整消息路径

前面的模块看起来有点散，放到一条完整路径里就清楚多了：

1. 源链上的 OApp 调用 Endpoint 的 `lzSend`，传入 packet 的路由信息，以及目标链上执行该 packet 所需的 gas 参数。
   - Endpoint 先构造 packet，分配 nonce 和 GUID，再把 packet 发给该 OApp 配置的 `MessageLib`。
   - 消息库（这里以 ULN 为例）会根据配置判断由哪些 DVN 负责验证、由哪个 Executor 负责执行，并计算出相应费用返回给 Endpoint。
   - Endpoint 向用户收取费用，并发出 `PacketSend` 事件。

```solidity
event PacketSent(bytes encodedPayload, bytes options, address sendLibrary);
```

2. DVN 和 Executor 会监听这个事件。DVN 在目标网络上通过 `MessageLib`（这里是 ULN）验证 packet，并用签名确认其有效性。达到要求的验证数量后，流程才能继续。
3. Executor 持续观察验证状态。消息库中有一个 `verifiable` 函数，用于检查 packet 是否已经完成全部验证。验证完成后，Executor 会调用 `commitVerification`，这时目标链上的 Endpoint 会校验 nonce。
4. 如果检查都通过，Executor 就会调用 `lzReceive`，把 packet 真正投递到目标链上的 OApp。如果 packet 的 options 里还包含 `lzCompose` 相关信息，那么后续的附加调用也会继续执行。

![从源链到目标链的 packet 投递流程](./assets/layerzero-v2-protocol/packet-delivery-end-to-end.png)

*从源链到目标链的 packet 投递流程。来源：白皮书。*

## Gas 计算

对所有跨链桥来说，gas 费用怎么估算都是绕不开的问题。LayerZero 把这部分成本拆成了四块：

1. 源链上的初始交易成本
2. 安全栈（DVN）的服务费用
3. Executor 的服务费用
4. 目标链执行交易的 gas 成本，以及必要时为目标链购买原生代币的费用

其中最麻烦的是最后一项。源链并不知道目标链当前的状态，因此没法在源链上精确模拟目标链交易，也就很难提前算准目标链到底要消耗多少 gas。再加上不同链使用不同原生代币支付 gas、gas price 又时刻在变，这件事就更复杂了。

所以，开发者在发消息之前，必须自己预估目标链上 `_lzReceive` 可能消耗多少 gas，并把这个值编码进 options。如果 packet 里还包含多笔组合调用，那么 `lzCompose` 的 gas 也得分别指定。

比如，在一条 EVM 链上投递一条简单消息，大概需要 `50,000` gas，对应的 options 可以这样写：

```solidity
// addExecutorLzReceiveOption(GAS_LIMIT, MSG_VALUE)
bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(50000, 0);
```

> 注：`addExecutorLzReceiveOption` 的第二个参数表示希望一并转到目标链的原生代币数量。这个参数是可选的，也可以不传。至于 `msg.value` 的细节，原文没有展开。

Endpoint 合约还提供了一个 `quote` 方法，用于预估发送这条消息要花多少钱。大多数 OApp 也会在自己的实现中复用这套逻辑。

```solidity
// LayerZero Endpoint 的报价接口
function quote(MessagingParams calldata _params, address _sender) external view returns (MessagingFee memory);
```

这个函数接收一个 `MessagingParams` 结构体，并返回一个 `MessagingFee`：

```solidity
struct MessagingParams {
    uint32 dstEid; // 目标网络标识
    bytes32 receiver; // 接收 packet 的 OApp 地址
    bytes message; // 传输数据
    bytes options; // 指定 gas 数量和 msg.value 的参数
    bool payInLzToken; // 是否用 lzToken 支付费用
}

struct MessagingFee {
    uint256 nativeFee; // 以 wei 计价的原生币费用
    uint256 lzTokenFee; // 如果 payInLzToken == true，则为 lzToken 费用
}
```

其基本估算思路如下。

假设我们要从 Ethereum 向 Polygon 发送一条消息，需要估算在源链上大概要支付多少 ETH：

已知条件：

1. ETH 价格：`$2500`
2. POL 价格：`$0.5`
3. Polygon 上的 gas price：`50 GWei`
4. 计划给目标链预留的 gas：`50,000`

![Gas 计算示例](./assets/layerzero-v2-protocol/gas-calculation-example.png)

理论上，这个金额足以覆盖 Polygon 上的执行成本。但在真实环境里，你还得把安全栈费用算进去，也就是参与验证的 DVN 服务费，以及目标链上 Executor 的服务费。Executor 收多少钱，和它自己的实现也有关系，所以实际波动可能很大。还有一点容易被忽略：没花完的 gas 会留在 Executor 那里。当然，如果你有需要，也可以部署自己的 Executor 来优化这部分成本。

所以，总成本大致可以写成：

```text
网络 A 上的执行逻辑成本 + 验证与执行服务费 + 网络 B 上的执行逻辑成本
```

作者给了一个实际例子：他曾经从 Arbitrum 向 Polygon 发过一条消息，可以在 [LayerZero Scan](https://layerzeroscan.com/tx/0x55615e9ee9be40614756fed61af5e5ad35b4e63cceefce4e3d49a6ccf0cf9f95) 上看到。大致成本如下：

- Arbitrum 上的交易手续费：`$0.009`
- 预付给 Polygon 的 gas：`$0.0555`（而按公式估算只有约 `$0.0008`）
- 支付给两个 DVN 的费用：`$0.0025`（每个 `$0.00125`）
- Polygon 上执行交易本身的成本：约 `$0.001`
- 剩余部分归 Executor：约 `$0.053`

也就是说，发送一条 `Hello, Polygon!` 的总成本大约是：

源链费用 `$0.009` + 验证费用 `$0.0025` + Executor 费用约 `$0.053`，总计 `$0.0645`。

这里有多少算是 Executor 的“净利润”，其实不太好判断，因为它不只是负责在目标链执行交易，还得处理价格获取、原生代币兑换等额外工作。作者提到，LayerZero 未来计划在 [LayerZero Scan](https://layerzeroscan.com/) 里把这些费用拆得更细。

根据 Tenderly 的测算，Polygon 上 `_lzReceive` 本身消耗了 `50,102` gas。注意，作者只给它分配了 `50,000`。而整笔交易最终总共消耗了 `85,925` gas，但对应的 `gasLimit` 却被设置到了 `295,812`。

![Tenderly 面板示例](./assets/layerzero-v2-protocol/tenderly-dashboard-example.png)

*来源：dashboard.tenderly.co*

官方文档还提供了一张估算表，用来参考目标链上不同操作的大致 gas 成本：[tx pricing profiling](https://docs.layerzero.network/v2/developers/evm/technical-reference/tx-pricing#profiling)

## 协议能力

LayerZero 提供了相当丰富的跨链交互能力。默认情况下，它定义了三类核心 OApp 标准，同时还给出多种消息设计模式，帮助开发者在不同区块链之间构建实际交互。

1. **Omnichain Application（OApp）**：标准 [OApp](https://github.com/LayerZero-Labs/LayerZero-v2/blob/7aebbd7c79b2dc818f7bb054aed2405ca076b9d6/packages/layerzero-v2/evm/oapp/contracts/oapp/OApp.sol) 提供统一的发送和接收接口，用来在部署于不同链上的合约之间传递消息。这是最底层的通用能力，基于它可以做 DeFi、DAO 投票以及各种业务逻辑。
2. **Omnichain Fungible Token（OFT）**：允许你在所有支持该标准的区块链上创建“同一个”ERC20 资产，对应实现见 [OFT](https://github.com/LayerZero-Labs/LayerZero-v2/blob/7aebbd7c79b2dc818f7bb054aed2405ca076b9d6/packages/layerzero-v2/evm/oapp/contracts/oft/OFT.sol)。因为消息语义被标准化，协议又能保证 packet 送达，所以理论上可以在不同链之间迁移整个代币总供应量。默认实现采用 burn/mint：源链销毁，目标链铸造。对已经存在的代币，还可以用 [OFTAdapter](https://github.com/LayerZero-Labs/LayerZero-v2/blob/7aebbd7c79b2dc818f7bb054aed2405ca076b9d6/packages/layerzero-v2/evm/oapp/contracts/oft/OFTAdapter.sol)，按 lock/mint 和 burn/unlock 的经典模式工作。
3. **Omnichain Non-Fungible Token（ONFT）**：和 OFT 类似，但面向 ERC721 类型的 NFT。

关于 OFT 的更多内容，可以继续看官方文档：[OFT quickstart](https://docs.layerzero.network/v2/developers/evm/oft/quickstart)

### 设计模式

LayerZero 的设计模式不只是“把消息从链 A 发到链 B”。真正有意思的地方在于，它提供了一套可以拼装的跨链交互原语。这些模式可以单独用，也可以组合在一起用。

#### ABA

[ABA 模式](https://docs.layerzero.network/v2/developers/evm/oapp/message-design-patterns#aba) 指的是一种嵌套调用路径：消息从链 `A` 发往链 `B`，再由 `B` 回到 `A`，也就是 `A -> B -> A`。它常常也被称作 ping-pong。

常见用途包括：

- **条件式合约执行**：链 `A` 上的合约只有在链 `B` 上某个条件成立时才继续执行，因此先向 `B` 发消息检查条件，再根据返回结果决定下一步。
- **全链数据源**：链 `A` 上的合约到链 `B` 上取数，再回来完成自身逻辑。
- **跨链认证**：用户或合约先在链 `A` 上完成认证，再去链 `B` 上执行依赖该认证的动作，最后由 `B` 返回确认结果或某种凭证。

#### Batch Send

[Batch Send 模式](https://docs.layerzero.network/v2/developers/evm/oapp/message-design-patterns#batch-send) 指的是把同一条消息同时发往多条目标链。

![单个 packet 发送到多个网络的流程](./assets/layerzero-v2-protocol/batch-send-process.png)

*单个 packet 发送到多个网络的流程。来源：LayerZero 文档。*

典型场景有：

- **全链同步更新**：例如同时更新多个网络上的治理参数或预言机数据。
- **DeFi 策略执行**：例如多链协议同时完成流动性再平衡或收益策略切换。
- **聚合数据广播**：例如预言机或数据服务商把价格、事件结果一次广播到多条链。

#### Composed

[Composed 模式](https://docs.layerzero.network/v2/developers/evm/oapp/message-design-patterns#composed) 不只是一个设计模式，本身也是协议的重要能力。除了 `lzReceive`，LayerZero 还提供了 `lzCompose` 接口，用来做交易编排。对于基于 MoveVM 的链，比如 Aptos、Sui，由于它们不像 EVM 那样支持单笔交易内多次调用，这个能力尤其有用。

`lzCompose` 的工作方式可以概括成两步：

- 接收方第一次执行 `lzReceive` 时，通过 `sendCompose` 把收到的数据先存到 Endpoint。
- 后续再把这些数据从注册表中取出，通过一笔独立交易里的 `lzCompose` 回调交给后续逻辑。

![lzReceive 与 lzCompose 的顺序调用](./assets/layerzero-v2-protocol/lzreceive-lzcompose-sequence.png)

*`lzReceive` 与 `lzCompose` 的顺序调用。来源：LayerZero 文档。*

> 注：这个过程本身还可以继续组合。

它的优点主要有三点：

- **可扩展**：`lzCompose` 是一类比较通用的原语，不依赖某条特定链。
- **更稳妥**：不同合约调用彼此隔离，一处失败不至于把后面的步骤一起拖垮。
- **Gas 更好管**：每个调用都可以单独分配 gas，调试起来也更直观。

需要注意的是，`lzReceive` 总是先执行。它会先把后续 `lzCompose` 要用到的数据放进 Executor 的待执行队列。

整个顺序如下：

```text
_lzSend(source chain) -> _lzReceive(dest chain) -> sendCompose(dest) -> lzCompose(dest)
```

常见场景包括：

- **全链 DeFi 策略**：先把资产发到目标链，再在目标链上继续接借贷、流动性等协议。
- **NFT 交互**：NFT 跨链后，自动触发许可证签发或某项服务。
- **DAO 协调**：DAO 把资金发到另一条链上的合约，并继续发起投资或投票流程。

#### Composed ABA

[Composed ABA 模式](https://docs.layerzero.network/v2/developers/evm/oapp/message-design-patterns#composed-aba) 是多种模式的组合。它可以形成 `A -> B1 -> B2 -> A`，也可以形成 `A -> B1 -> B2 -> C` 这样的多跳执行路径。

常见用途包括：

- **全链数据验证**：链 `A` 请求链 `B` 验证某个数据；验证完成后，链 `B` 上的合约继续执行，并把结果再发回 `A`。
- **全链抵押品管理**：链 `A` 上锁定或释放抵押品后，链 `B` 上相应触发借贷或解锁流程，最后再通知 `A` 完成闭环。
- **游戏和收藏品里的多步交互**：比如某个 NFT 从链 `A` 发往链 `B` 后，链 `B` 上的合约据此解锁新关卡，随后再把确认信息或奖励返回链 `A`。

![Composed ABA 执行示意图](./assets/layerzero-v2-protocol/composed-aba-execution.png)

*Composed ABA 执行示意图。来源：LayerZero 文档。*

#### Message Ordering 与 Rate Limit

这两个模式原文没有展开太多，但也值得一提：

- [Message Ordering](https://docs.layerzero.network/v2/developers/evm/oapp/message-design-patterns#message-ordering)：允许 packet 在不破坏验证顺序的前提下异步执行；如果业务需要，也可以强制严格顺序发送和执行。
- [Rate Limit](https://docs.layerzero.network/v2/developers/evm/oapp/message-design-patterns#rate-limiting)：允许对消息或代币传输做流量限制。

### Token Bridging

如果你想做的是经典意义上的“桥”，也就是代币跨链转移，那么更合适的做法通常是直接使用 OFT 或 ONFT 标准。这些标准也可以和上面的设计模式组合。例如，你可以实现一个 `Composed OFT`，把 OFT 的代币能力和其他跨链模式拼在一起。

## 总结

作者的判断是，LayerZero 已经非常接近于解决所谓的 [互操作性三难困境](https://medium.com/connext/the-interoperability-trilemma-657c2cf69f17)。它把安全层和执行层拆开，再加上内部安全与外部安全这两层约束，最终搭出了一条相当可靠的数据传输通道。与此同时，协议又允许开发者针对应用场景灵活配置安全级别。LayerZero 支持任意数据传输，而统一接口也给 EVM 之外的生态留出了空间，尽管目前最活跃的依然还是 EVM 世界，原因也很简单：L2 足够多。

尤其值得注意的是，LayerZero 让“全链应用”真正变得可操作，而这在理论上有机会缓解流动性碎片化问题。随着 L2 越来越多，这个问题只会越来越明显。白皮书里还提到一个应用层安全扩展，叫 `Pre-Crime`（第 4.3 节，Application-level security）。它可以在应用部署的所有链上同时检查不变量，一旦发现违反条件，就阻止 packet 继续投递。

当然，这套方案不是没有代价。LayerZero 本身足够灵活，可配置项也很多，所以如果要做一个复杂的全链应用，工程难度不会低。但如果只是使用标准安全栈做基础的跨链消息传递，或者做代币跨链，那么对 Solidity 开发者来说，它已经相当实用了。更何况，它连代币跨链标准都直接给出来了。

归根到底，LayerZero 提供的是一套高度灵活的底层系统，用来构建安全、去中心化的跨链协议。它在跨链世界里的潜在位置，有点像 Chainlink 在预言机世界里的位置：不一定直接面向最终用户，但很可能会成为很多上层协议绕不过去的基础设施。

## 参考链接

- [Whitepaper: LayerZero v2](https://layerzero.network/publications/LayerZero_Whitepaper_V2.1.0.pdf)
- [Docs: LayerZero v2](https://docs.layerzero.network/v2)
- [Github: LayerZero v2](https://github.com/LayerZero-Labs/LayerZero-v2)
- [Article: Omnichain vs Multichain vs CrossChain: What Are They?](https://hackernoon.com/omnichain-vs-multichain-vs-crosschain-what-are-they)
- [Video: Intro to LayerZero V2 & Omnichain Apps for Beginners](https://www.youtube.com/watch?v=W0J_Jz76apE)
