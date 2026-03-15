# LayerZero v2 协议学习笔记

这份笔记不是逐段翻译，而是面向“读源码”和“搭脑图”的学习版整理。目标是把 LayerZero v2 里最值得记住的对象、流程和约束拎出来，方便后续对照官方文档、白皮书和代码仓库继续深入。

对应原文：

- `docs/LayerZero-v2-协议概述与架构.md`
- `docs/LayerZero-v2-协议概述与架构-出版版.md`

## 先记住五个结论

1. **LayerZero 不是桥，而是跨链消息协议。**
   它解决的是“消息如何从链 A 到链 B 并被安全执行”，而不是只解决“资产怎么跨链”。

2. **LayerZero v2 把验证和执行拆开了。**
   `MessageLib` 负责安全关键路径，`Executor` 负责非安全关键的执行逻辑。这是它的核心架构思想。

3. **内部安全和外部安全是两回事。**
   内部安全关注消息通道本身是否可靠；外部安全关注谁来验证消息、用什么方式验证。

4. **Endpoint 是消息通道的枢纽。**
   消息的发送、接收、nonce 管理、验证落账、最终投递，基本都绕不开 Endpoint。

5. **每个 OApp 都可以自定义安全栈。**
   具体用哪些 DVN、阈值多少、用哪个 MessageLib，不是协议统一拍板，而是应用自己选。

如果只想先有一个整体印象，记住这五点就够了。

## 用一句话概括 LayerZero v2

LayerZero v2 想做的是：**在不同区块链之间提供一条可配置、可验证、可恢复的消息通道。**

这里面最重要的不是“发消息”本身，而是：

- 消息怎么编号
- 消息怎么验证
- 验证通过后谁来执行
- 执行失败后系统还能不能继续往前走

理解 LayerZero，本质上就是理解这四个问题是如何被分层处理的。

## 先建立对象表

看源码前，先把几个核心对象记牢。

### 1. OApp

OApp 是构建在 LayerZero 之上的应用。

可以把它理解成“使用跨链消息能力的业务合约”。协议本身不关心你的业务逻辑，它只负责把消息可靠地送过去。

### 2. Endpoint

Endpoint 是协议入口，也是消息通道的中枢。

它负责：

- 接收 OApp 发出的消息
- 给消息分配 `nonce`
- 组装 packet
- 记录验证结果
- 调用 `lzReceive`
- 维护入站 / 出站消息状态

学习建议：**读 LayerZero 源码时，先从 Endpoint 入手。**

### 3. Packet

packet 就是协议层里的“标准消息单元”。

一条 packet 至少包含：

- `nonce`
- 源链标识 `srcEid`
- 发送者 `sender`
- 目标链标识 `dstEid`
- 接收者 `receiver`
- `guid`
- `message`

记忆方式：

> packet = 路由信息 + 消息体

### 4. MessageLib

MessageLib 是安全关键路径里的核心模块。

它不直接代表某一种验证方案，而是“验证逻辑的承载体”。只要实现了协议要求的接口，不同的 MessageLib 就可以使用不同的验证方式。

记忆方式：

> MessageLib 解决的是“这条消息怎么算验证通过”。

### 5. DVN

DVN 全称是 Decentralized Verifier Networks，去中心化验证网络。

它的职责是读取源链上的 packet 哈希，并在目标链侧参与确认。

记忆方式：

> DVN 是验证者集合，不是执行者。

### 6. Executor

Executor 负责在消息验证通过之后执行后续动作。

它不是安全层的核心，而是执行层的核心。

记忆方式：

> Executor 解决的是“消息已经可信之后，谁来把动作真正跑起来”。

## 架构图应该怎么看

![消息传输的高层示意图](./assets/layerzero-v2-protocol/message-transmission-overview.png)

*图 1：消息传输的高层示意图。*

这张图不要试图一次看懂所有箭头。更好的办法是按下面三个层次看：

### 第一层：业务层

- 源链 OApp
- 目标链 OApp

这是应用真正关心的层。

### 第二层：协议层

- Endpoint
- MessageLib

这是 LayerZero 自己负责的抽象层。

### 第三层：验证 / 执行层

- DVN
- Executor

这是让消息“可信”和“可执行”的支持层。

所以整条链路可以压缩成一句话：

> OApp 把消息交给 Endpoint，Endpoint 交给 MessageLib，DVN 负责验证，Executor 负责执行，最后再回到目标链 OApp。

## Endpoint：为什么它最值得先读

如果你只打算精读一个模块，就先读 Endpoint。

原因很简单：LayerZero 最核心的状态管理几乎都在这里。

Endpoint 关心三件事：

1. **消息如何发出去**
2. **消息何时算验证通过**
3. **消息什么时候能真正执行**

![与 Endpoint 的交互方式](./assets/layerzero-v2-protocol/endpoint-interaction.png)

*图 2：与 Endpoint 的交互方式。*

### 读 Endpoint 时，重点看什么

- `lzSend` 怎么组装 packet
- nonce 在哪里分配
- `PacketSent` 在哪里发出
- 验证结果落在什么存储结构里
- `lzReceive` 的执行前提是什么

### 一句记忆

> Endpoint 是消息通道的账本和调度器。

## 为什么 LayerZero 要强调“内部安全”

很多跨链方案更强调“谁来验证这条消息”，也就是外部安全。

LayerZero 额外强调一件事：**即使验证者没问题，消息通道本身也必须有自己的不变量。**

这就是内部安全。

内部安全里最重要的三个词：

- `Lossless`
- `Exactly-once`
- `Eventual delivery`

你可以把它们翻成三个更好记的问句：

1. 消息会不会丢？
2. 消息会不会被执行两次？
3. 消息失败后还有没有机会最终送达？

如果这三个问题答不清楚，消息通道就不可靠。

## nonce 和 lazyInboundNonce：这是必考点

理解 LayerZero 消息顺序，核心就是理解这两个量：

- `nonce`
- `lazyInboundNonce`

### nonce 是什么

每条消息的顺序编号，严格递增。

### lazyInboundNonce 是什么

可以把它理解成：

> 截至当前，之前的消息都已经处理掉或显式跳过时，对应的最大入站 nonce。

它的价值在于：

- 系统允许乱序投递
- 但不会允许“跳过前置验证”直接执行后面的消息

![乱序 packet 投递](./assets/layerzero-v2-protocol/out-of-order-packet-delivery.png)

*图 3：乱序 packet 投递。*

### 一个最容易记住的例子

如果 `1`、`2` 还没验证，`3` 就不能执行。

但如果 `1`、`2`、`3` 都验证过了，而 `2` 在执行阶段失败了，那么 `3` 仍然可以执行。

这说明一件事：

> LayerZero 对“验证顺序”要求严格，但对“执行顺序”允许一定程度的解耦。

这是个非常关键的设计点。

## MessageLib：不要把它看成“某个具体库”

很多人第一次读时，会把 MessageLib 理解成一个固定实现。

更准确的理解是：

> MessageLib 是一类抽象接口下的实现集合。

它的作用不是替协议“做所有事情”，而是专门处理安全相关的验证逻辑。

![通过 MessageLib 处理消息的流程](./assets/layerzero-v2-protocol/messagelib-processing.png)

*图 4：通过 MessageLib 处理消息的流程。*

### MessageLib 重点解决什么问题

- 消息如何被验证
- 哪些验证结果算满足安全要求
- 验证结果如何回写给 Endpoint

### 为什么要把它单独拎出来

因为“验证”是安全关键路径。

如果把一堆与安全无关的扩展逻辑也塞进这里：

- 合约会更重
- 风险面会更大
- 升级和审计都会更困难

所以 LayerZero 的做法是：

> 把安全关键逻辑放进 MessageLib，把非安全关键的执行逻辑交给 Executor。

## DVN：安全栈的核心可配置部件

DVN 是 LayerZero v2 里最值得关注的模块化能力之一。

![DVN 参与的 packet 发送流程](./assets/layerzero-v2-protocol/dvn-packet-sending.png)

*图 5：DVN 参与的 packet 发送流程。*

![DVN 验证 packet 的过程](./assets/layerzero-v2-protocol/dvn-packet-verification.png)

*图 6：DVN 验证 packet 的过程。*

### 学习时要抓住两个概念

1. **必选 DVN**
2. **可选 DVN + 阈值**

这意味着安全栈不是“全有或全无”的，而是可以分层配置的。

比如：

- 某个 DVN 可以拥有否决权
- 其余 DVN 作为额外确认来源
- 只有当必选 DVN 全部确认，且可选 DVN 达到阈值，消息才视为验证通过

这和很多“单一验证者 + 全局默认配置”的跨链系统非常不一样。

### 学习角度下的结论

> LayerZero v2 的一个核心卖点，不是“验证方式有多强”，而是“验证方式可以按应用自己组合”。

## ULN：默认 MessageLib，学习时要看懂它的仲裁模型

ULN 是默认的 MessageLib。

读 ULN 时，不要一上来陷入实现细节。先记住它的结构：

- 必选 DVN
- 可选 DVN
- 可选阈值 `OptionalThreshold`

![ULN 中 DVN 工作示例](./assets/layerzero-v2-protocol/uln-dvn-example.png)

*图 7：ULN 中 DVN 工作示例。*

### 怎么记

把 ULN 想成一个“两层门禁”：

- 第一层门禁：必选 DVN 必须全过
- 第二层门禁：可选 DVN 至少过够阈值

只要这个比喻记住了，ULN 的大方向就不会丢。

## Executor：它解决的是“最后一公里”

很多人第一次看 LayerZero，会把注意力都放在 DVN 和 MessageLib 上。

但如果不理解 Executor，整个消息路径其实是不完整的。

![执行层与安全层分离](./assets/layerzero-v2-protocol/verification-vs-execution.png)

*图 8：执行层与安全层分离。*

### Executor 的角色

它负责在消息已经被验证之后，真正推动执行发生。

也就是说：

- MessageLib 回答“能不能信”
- Executor 回答“现在怎么执行”

### 为什么执行层要独立

因为执行逻辑里会掺杂很多不属于安全核心的东西，比如：

- gas 管理
- 附加调用
- 组合执行
- 恢复流程

把这些都塞进验证层，会让安全关键代码膨胀得很快。

### 一句记忆

> Executor 是 LayerZero 里负责“把可信消息落地”的组件。

## 完整消息路径：建议背成 8 步

如果你要讲清楚 LayerZero 的主流程，最好的办法是背下面这 8 步：

1. OApp 调用 `lzSend`
2. Endpoint 构造 packet，并分配 `nonce` / `GUID`
3. Endpoint 把 packet 交给 `MessageLib`
4. Endpoint 发出 `PacketSent`
5. DVN 监听并验证 packet
6. 验证通过后，Executor 调用 `commitVerification`
7. 目标链 Endpoint 校验 nonce
8. Executor 调用 `lzReceive`，把消息交给目标 OApp

如果有组合调用，则在这之后继续进入 `lzCompose`。

![从源链到目标链的 packet 投递流程](./assets/layerzero-v2-protocol/packet-delivery-end-to-end.png)

*图 9：从源链到目标链的 packet 投递流程。*

## Gas 这一节，重点不是公式，而是“为什么难算”

Gas 估算这一节最容易陷入算式细节，但学习时真正要记的是：**它为什么难算。**

主要有三个原因：

1. 源链不知道目标链当时的状态
2. 不同链用不同原生代币支付 gas
3. 目标链 gas price 和执行路径都不稳定

所以 LayerZero 的做法不是“精确替你算出来”，而是提供一套：

- 参数编码方式
- 报价接口
- 目标链预留 gas 的方法

```solidity
bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(50000, 0);
```

### 学习时真正该记住的结论

> LayerZero 的 gas 计价本质上是“预估 + 预留 + 服务费叠加”，不是确定性报价。

另外，Gas 费用通常不只包含目标链执行本身，还包括：

- DVN 服务费
- Executor 服务费
- 必要时的目标链原生代币兑换成本

## 几种设计模式，怎么记最省力

### 1. ABA

记成一句话就行：

> A 发给 B，B 再回给 A。

适合：

- 条件式执行
- 跨链认证
- 跨链取数

### 2. Batch Send

> 一条消息，同时打到多条链。

适合：

- 多链同步更新
- 多链广播

![单个 packet 发送到多个网络的流程](./assets/layerzero-v2-protocol/batch-send-process.png)

*图 10：单个 packet 发送到多个网络的流程。*

### 3. Composed

> 先收消息，再分步执行后续动作。

本质上是：

- `lzReceive`
- `sendCompose`
- `lzCompose`

![lzReceive 与 lzCompose 的顺序调用](./assets/layerzero-v2-protocol/lzreceive-lzcompose-sequence.png)

*图 11：`lzReceive` 与 `lzCompose` 的顺序调用。*

### 4. Composed ABA

> 多步跨链调用再回流。

适合更复杂的多跳业务流程。

![Composed ABA 执行示意图](./assets/layerzero-v2-protocol/composed-aba-execution.png)

*图 12：Composed ABA 执行示意图。*

## 如果你要读源码，推荐顺序

不要按仓库目录从头啃。推荐顺序如下：

1. **先读 Endpoint**
   先搞清楚消息怎么发、怎么收、状态怎么落。

2. **再读 MessagingChannel / nonce 相关逻辑**
   重点理解 `lazyInboundNonce`、验证顺序和执行顺序的关系。

3. **再读 MessageLib / ULN**
   搞清楚验证通过到底意味着什么。

4. **再看 DVN 配置与阈值模型**
   理解安全栈是怎么被应用自定义的。

5. **最后看 Executor 和 lzCompose**
   这部分更偏执行编排和工程实现。

如果按这个顺序读，理解成本会比“按文件顺序扫”低很多。

## 最后做一个总复盘

把 LayerZero v2 再压缩一遍，可以得到下面这张脑图式总结：

- **协议目标**：提供跨链消息通道
- **入口对象**：Endpoint
- **消息单元**：packet
- **安全关键模块**：MessageLib
- **验证者集合**：DVN
- **默认验证库**：ULN
- **执行层**：Executor
- **关键顺序控制**：nonce / lazyInboundNonce
- **消息扩展执行**：lzCompose
- **应用侧抽象**：OApp / OFT / ONFT

如果你已经能把上面十个词串起来，LayerZero v2 的大框架基本就建立起来了。

## 后续建议

如果后面你要继续做源码阅读，我建议下一步直接衔接这三件事：

1. 画一张“`lzSend -> PacketSent -> DVN -> commitVerification -> lzReceive`” 的调用链图
2. 单独整理一份 `Endpoint` 存储结构和 nonce 相关状态表
3. 再对照 ULN 合约，把“必选 DVN / 可选 DVN / 阈值”映射到具体代码实现
