<!-- markdownlint-disable MD033 MD022 MD025 MD036 -->

# L2 链派生规范

> 原文：[`specs/protocol/derivation.md`](https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/derivation.md)
>
> 说明：本文为中文翻译版。为便于在本地 Markdown 中直接访问，原文里的仓库内相对链接已改写为 GitHub 绝对链接；代码块与大多数术语保持原样。

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- 不要直接编辑此部分；如需更新请重新运行 doctoc -->
**目录**

- [概览](#overview)
  - [即时区块派生](#eager-block-derivation)
  - [协议参数](#protocol-parameters)
- [批次提交](#batch-submission)
  - [排序与批次提交概览](#sequencing--batch-submission-overview)
  - [批次提交线格式](#batch-submission-wire-format)
    - [Batcher 交易格式](#batcher-transaction-format)
    - [帧格式](#frame-format)
    - [通道格式](#channel-format)
    - [批次格式](#batch-format)
- [架构](#architecture)
  - [L2 链派生流水线](#l2-chain-derivation-pipeline)
    - [L1 遍历](#l1-traversal)
    - [L1 检索](#l1-retrieval)
    - [帧队列](#frame-queue)
    - [通道银行](#channel-bank)
      - [修剪](#pruning)
      - [超时](#timeouts)
      - [读取](#reading)
      - [加载帧](#loading-frames)
    - [通道读取器（批次解码）](#channel-reader-batch-decoding)
    - [批次队列](#batch-queue)
    - [Payload Attributes 派生](#payload-attributes-derivation)
    - [Engine Queue](#engine-queue)
      - [Engine API 用法](#engine-api-usage)
        - [Bedrock、Canyon、Delta：API 用法](#bedrock-canyon-delta-api-usage)
        - [Ecotone：API 用法](#ecotone-api-usage)
      - [Forkchoice 同步](#forkchoice-synchronization)
      - [L1-consolidation：payload attributes 匹配](#l1-consolidation-payload-attributes-matching)
      - [L1-sync：payload attributes 处理](#l1-sync-payload-attributes-processing)
      - [处理 unsafe payload attributes](#processing-unsafe-payload-attributes)
    - [重置流水线](#resetting-the-pipeline)
      - [查找同步起点](#finding-the-sync-starting-point)
      - [重置派生阶段](#resetting-derivation-stages)
      - [Merge 之后关于 reorg 的说明](#about-reorgs-post-merge)
- [派生 Payload Attributes](#deriving-payload-attributes)
  - [派生交易列表](#deriving-the-transaction-list)
    - [网络升级自动化交易](#network-upgrade-automation-transactions)
  - [构建单个 Payload Attributes](#building-individual-payload-attributes)
  - [关于面向未来的交易日志派生](#on-future-proof-transaction-log-derivation)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

<!-- 本文件中用到的术语表引用。 -->

[g-derivation]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#l2-chain-derivation
[g-payload-attr]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#payload-attributes
[g-block]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#block
[g-exec-engine]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#execution-engine
[g-reorg]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#chain-re-organization
[g-receipts]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#receipt
[g-deposit-contract]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#deposit-contract
[g-deposited]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#deposited-transaction
[g-l1-attr-deposit]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#l1-attributes-deposited-transaction
[g-l1-origin]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#l1-origin
[g-user-deposited]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#user-deposited-transaction
[g-deposits]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#deposits
[g-sequencing]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#sequencing
[g-sequencer]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#sequencer
[g-sequencing-epoch]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#sequencing-epoch
[g-sequencing-window]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#sequencing-window
[g-sequencer-batch]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#sequencer-batch
[g-l2-genesis]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#l2-genesis-block
[g-l2-chain-inception]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#l2-chain-inception
[g-l2-genesis-block]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#l2-genesis-block
[g-batcher-transaction]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#batcher-transaction
[g-avail-provider]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#data-availability-provider
[g-batcher]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#batcher
[g-l2-output]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#l2-output-root
[g-fault-proof]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#fault-proof
[g-channel]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#channel
[g-channel-frame]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#channel-frame
[g-rollup-node]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#rollup-node
[g-block-time]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#block-time
[g-time-slot]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#time-slot
[g-consolidation]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#unsafe-block-consolidation
[g-safe-l2-head]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#safe-l2-head
[g-safe-l2-block]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#safe-l2-block
[g-unsafe-l2-head]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#unsafe-l2-head
[g-unsafe-l2-block]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#unsafe-l2-block
[g-unsafe-sync]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#unsafe-sync
[g-deposit-tx-type]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#deposited-transaction-type
[g-finalized-l2-head]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#finalized-l2-head
[g-system-config]: https://github.com/ethereum-optimism/specs/blob/main/specs/glossary.md#system-configuration

<a id="overview"></a>
# 概览

> **注意** 以下内容假设只有一个排序器（sequencer）和一个 batcher。未来会调整该设计以适配多个此类实体。

[L2 链派生][g-derivation]，即从 L1 数据派生 L2 [区块][g-block]，是 [rollup 节点][g-rollup-node] 的主要职责之一。无论在验证者模式下，还是在排序器模式下（此时派生既作为对排序行为的合理性检查，也用于检测 L1 链的[重组][g-reorg]），都是如此。

L2 链由 L1 链派生而来。具体来说，[L2 链创世开始][g-l2-chain-inception]之后的每个 L1 区块都会映射到一个[排序纪元][g-sequencing-epoch]，该纪元至少包含一个 L2 区块。每个 L2 区块恰好属于一个纪元，我们将对应的 L1 区块称为它的 [L1 起源][g-l1-origin]。该纪元的编号等于其 L1 起源区块的编号。

要派生编号为 `E` 的纪元中的 L2 区块，我们需要以下输入：

- 范围为 `[E, E + SWS)` 的 L1 区块，称为该纪元的[排序窗口][g-sequencing-window]，其中 `SWS` 为排序窗口大小。（注意，排序窗口之间是重叠的。）
- 排序窗口内各区块中的 [Batcher 交易][g-batcher-transaction]。
  - 这些交易使我们能够重建该纪元的[排序器批次][g-sequencer-batch]，每个批次将生成一个 L2 区块。注意：
    - L1 起源区块永远不会包含构造排序器批次所需的任何数据，因为每个批次[必须包含](#batch-format) L1 起源哈希。
    - 一个纪元可能没有任何排序器批次。
- 在 L1 起源中进行的 [Deposits][g-deposits]（表现为由 [deposit 合约][g-deposit-contract] 发出的事件）。
- 来自 L1 起源的 L1 区块属性（用于派生 [L1 属性存款交易][g-l1-attr-deposit]）。
- 前一个纪元最后一个 L2 区块之后的 L2 链状态；如果 `E` 是第一个纪元，则为 [L2 创世状态][g-l2-genesis]。

要从头开始派生整条 L2 链，我们以 [L2 创世状态][g-l2-genesis] 和 [L2 创世区块][g-l2-genesis-block] 作为第一个 L2 区块开始。然后按顺序从每个纪元派生 L2 区块，起点是 [L2 链创世开始][g-l2-chain-inception]之后的第一个 L1 区块。关于实际实现方式的更多信息，请参阅[架构章节][architecture]。L2 链可能包含 Bedrock 之前的历史，但此处的 L2 创世指的是 Bedrock L2 创世区块。

每个起源为 `l1_origin` 的 L2 `block` 都受到以下约束，其值单位均为秒：

- `block.timestamp = prev_l2_timestamp + l2_block_time`
  - `prev_l2_timestamp` 是紧接在该区块之前的 L2 区块时间戳。如果不存在前置区块，那么这就是创世区块，其时间戳会被显式指定。
  - `l2_block_time` 是一个可配置参数，表示 L2 区块之间的时间间隔（Optimism 上为 2 秒）。
- `l1_origin.timestamp <= block.timestamp <= max_l2_timestamp`，其中
  - `max_l2_timestamp = max(l1_origin.timestamp + max_sequencer_drift, prev_l2_timestamp + l2_block_time)`
    - `max_sequencer_drift` 是一个可配置参数，用于限制排序器最多可以领先 L1 多远。

最后，每个纪元必须至少包含一个 L2 区块。

第一条约束意味着，自 L2 链创世开始之后，每隔 `l2_block_time` 秒就必须存在一个 L2 区块。

第二条约束确保 L2 区块时间戳永远不会早于其 L1 起源区块时间戳，并且最多只会比其领先 `max_sequencer_drift`，除非出现一种不寻常的情况：若严格遵守该限制，将无法做到每隔 `l2_block_time` 秒产出一个 L2 区块。（例如，在工作量证明的 L1 上，若经历一段 L1 区块快速产出的时期，就可能出现这种情况。）无论哪种情况，当超过 `max_sequencer_drift` 时，排序器都会强制 `len(batch.transactions) == 0`。更多细节参见 [Batch Queue](#batch-queue)。

每个纪元至少必须有一个 L2 区块这一最终要求，确保来自 L1 的所有相关信息（例如 deposits）都能体现在 L2 中，即使该纪元没有任何排序器批次。

在 Merge 之后，以太坊的 [区块时间][g-block-time] 固定为 12 秒，尽管某些 slot 可能被跳过。在 L2 区块时间为 2 秒的情况下，我们预期每个纪元通常包含 `12/2 = 6` 个 L2 区块。不过，为了在 L1 出现跳槽或暂时失去连接时维持活性，排序器会生成更大的纪元。对于失去连接的情况，在连接恢复后也可能生成更小的纪元，以防止 L2 时间戳继续越来越超前。

<a id="eager-block-derivation"></a>
## 即时区块派生

派生一个 L2 区块要求我们已经构造出其排序器批次，并且已经派生出它之前的所有 L2 区块及状态更新。这意味着，我们通常可以在不等待完整排序窗口的情况下，_即时地_ 派生一个纪元中的 L2 区块。只有在最坏情况下，才需要等到完整排序窗口结束后才能进行派生，即该纪元第一个区块的排序器批次有一部分出现在窗口中的最后一个 L1 区块里。注意，这仅适用于_区块_派生。排序器批次本身仍然可以被派生并暂时排队，而无需立即由其派生区块。

<a id="protocol-parameters"></a>
## 协议参数

下表概述了一些协议参数，以及它们如何受到协议升级的影响。

| 参数 | Bedrock 默认值 | 最新默认值 | 变化 | 说明 |
| --- | --- | --- | --- | --- |
| `max_sequencer_drift` | 600 | 1800 | [Fjord](https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/fjord/derivation.md#constant-maximum-sequencer-drift) | 在 Fjord 中从链参数变更为常量。 |
| `MAX_RLP_BYTES_PER_CHANNEL` | 10,000,000 | 100,000,000 | [Fjord](https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/fjord/derivation.md#increasing-max_rlp_bytes_per_channel-and-max_channel_bank_size) | 常量在 Fjord 中提高。 |
| `MAX_CHANNEL_BANK_SIZE` | 100,000,000 | 1,000,000,000 | [Fjord](https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/fjord/derivation.md#increasing-max_rlp_bytes_per_channel-and-max_channel_bank_size) | 常量在 Fjord 中提高。 |
| `MAX_SPAN_BATCH_ELEMENT_COUNT` | 10,000,000 | 10,000,000 | 在 [Fjord](https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/fjord/derivation.md#increasing-max_rlp_bytes_per_channel-and-max_channel_bank_size) 中实际上被引入 | 元素数量。 |

---

<a id="batch-submission"></a>
# 批次提交

<a id="sequencing--batch-submission-overview"></a>
## 排序与批次提交概览

[排序器][g-sequencer]接收来自用户的 L2 交易，并负责将这些交易打包成区块。对于每个这样的区块，它还会创建一个对应的[排序器批次][g-sequencer-batch]。它同样负责通过其 [batcher][g-batcher] 组件，将每个批次提交到[数据可用性提供者][g-avail-provider]（例如以太坊 calldata）。

L2 区块与批次之间的区别很微妙，但非常重要：区块包含 L2 状态根，而批次只承诺某个给定 L2 时间戳（等价地说，L2 区块编号）下的交易。区块还包含对前一个区块的引用（\*）。

(\*) 这一点在某些边缘情况下非常重要，例如当发生 L1 重组时，一个批次可能会被重新发布到 L1 链上，而其前一个批次却没有；但 L2 区块的前驱区块则不可能发生这种变化。

这意味着，即使排序器错误地应用了某个状态转换，批次中的交易仍会被视为规范 L2 链的一部分。批次本身仍然需要通过有效性检查，例如编码必须正确；批次中的单笔交易也同样如此，例如签名必须有效。无效批次，以及处于一个原本有效批次中的无效单笔交易，都会被正确节点丢弃。

如果排序器错误地应用了状态转换并发布了一个 [output root][g-l2-output]，那么这个输出根将是不正确的。这个错误的输出根会被[故障证明][g-fault-proof]质疑，随后会被一个正确的输出根替换，**但针对的仍是现有的排序器批次。**

更多信息请参阅[批次提交规范][batcher-spec]。

[batcher-spec]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/batcher.md

<a id="batch-submission-wire-format"></a>
## 批次提交线格式

[wire-format]: #batch-submission-wire-format

批次提交与 L2 链派生密切相关，因为派生过程必须解码那些为了批次提交而编码出来的批次。

[batcher][g-batcher] 向[数据可用性提供者][g-avail-provider]提交 [batcher 交易][g-batcher-transaction]。这些交易包含一个或多个[通道帧][g-channel-frame]，也就是属于某个[通道][g-channel]的数据块。

一个[通道][g-channel]是若干个[排序器批次][g-sequencer-batch]（可对应任意 L2 区块）压缩后拼接而成的序列。将多个批次组合在一起的原因很简单：为了获得更高的压缩率，从而降低数据可用性成本。

通道可能太大，无法放进单个 [batcher 交易][g-batcher-transaction] 中，因此我们需要把它拆分成若干数据块，也就是[通道帧][g-channel-frame]。单个 batcher 交易也可以携带多个帧，可以属于同一个通道，也可以属于不同通道。

这种设计为我们如何将批次聚合为通道、以及如何将通道拆分到 batcher 交易中，提供了最大的灵活性。特别是，它让我们能够最大化 batcher 交易中的数据利用率：例如，可以把一个通道最后一个较小的帧，与下一个通道中的一个或多个帧一起打包。

还需要注意的是，我们使用的是流式压缩方案，因此在开启一个通道时，甚至在发送该通道的前几个帧时，并不需要预先知道这个通道最终会包含多少个批次。

并且，通过把通道拆分到多个数据交易中，L2 可以拥有比数据可用性层本身所支持的更大的区块数据量。

下图展示了上述内容，解释见下文。

![batch derivation chain diagram](https://raw.githubusercontent.com/ethereum-optimism/specs/main/specs/static/assets/batch-deriv-chain.svg)

第一行表示 L1 区块及其编号。L1 区块下方的方框表示该区块中包含的 [batcher 交易][g-batcher-transaction]。L1 区块下方的波浪线表示 [deposits][g-deposits]，更具体地说，是由 [deposit 合约][g-deposit-contract] 发出的事件。

方框中的每个彩色块表示一个[通道帧][g-channel-frame]。因此 `A` 和 `B` 是[通道][g-channel]，而 `A0`、`A1`、`B0`、`B1`、`B2` 是帧。请注意：

- 多个通道可以交错出现
- 帧不需要按顺序传输
- 单个 batcher 交易可以携带来自多个通道的帧

在下一行中，圆角方框表示从通道中提取出的单个[排序器批次][g-sequencer-batch]。其中四个蓝/紫/粉色的批次来自通道 `A`，其他的则来自通道 `B`。这些批次在这里按照它们从批次中解码出来的顺序表示，在这个例子中，`B` 会先被解码。

> **注意** 这里的图注写着“通道 B 先被看到，因此会先被解码为批次”，但这并不是强制要求。例如，实现也完全可以先查看各个通道，再优先解码包含更早批次的那个通道。

图的其余部分在概念上与前半部分不同，展示的是通道被重新排序之后的 L2 链派生过程。

第一行显示的是 batcher 交易。注意，在这个例子中，批次存在一种排序方式，使得通道中的所有帧都能连续出现。一般情况下并非如此。例如，在第二笔交易中，`A1` 和 `B0` 的位置完全可以互换，而结果完全相同，图的其余部分无需任何修改。

第二行显示按正确顺序重建出的通道。第三行显示从这些通道中提取出来的批次。由于各个通道是有序的，而一个通道内的各个批次又是顺序的，这意味着这些批次本身也是有序的。第四行展示了由每个批次派生出的 [L2 区块][g-block]。注意，这里展示的是批次到区块的 1:1 映射，但正如我们后面会看到的，在 L1 上发布的批次存在“空档”时，可能会插入那些不对应任何批次的空区块。

第五行展示了 [L1 attributes deposited transaction][g-l1-attr-deposit]；它在每个 L2 区块中记录与该 L2 区块 epoch 相匹配的 L1 区块信息。第一个数字表示 epoch/L1x 编号，第二个数字“sequence number”表示其在该 epoch 内的位置。

最后，第六行展示了由前面提到的 [deposit contract][g-deposit-contract] 事件派生出的 [user-deposited transactions][g-user-deposited]。

请注意图右下角的 `101-0` L1 attributes transaction。它之所以能出现在那里，只有在以下条件同时满足时才可能发生：帧 `B2` 表明它是该通道中的最后一帧，并且不需要插入空区块。

图中并未指定所使用的 sequencing window size，但我们可以由此推断，它至少必须是 4 个区块，因为通道 `A` 的最后一帧出现在区块 102 中，但它属于 epoch 99。

至于关于“security types”的注释，它解释了在 L1 和 L2 中对区块的分类方式。

- [Unsafe L2 blocks][g-unsafe-l2-block]
- [Safe L2 blocks][g-safe-l2-block]
- Finalized L2 blocks：指那些由 [finalized][g-finalized-l2-head] L1 数据派生出的区块。

这些安全级别对应于与 [execution-engine API][exec-engine] 交互时传输的 `headBlockHash`、`safeBlockHash` 和 `finalizedBlockHash` 值。

<a id="batcher-transaction-format"></a>
### Batcher 交易格式

Batcher 交易被编码为 `version_byte ++ rollup_payload`，其中 `++` 表示拼接。

| `version_byte` | `rollup_payload` |
| --- | --- |
| 0 | `frame ...`，一个或多个 frame 拼接在一起 |
| 1 | `da_commitment`，实验性，见 [alt-da](https://github.com/ethereum-optimism/specs/blob/main/specs/experimental/alt-da.md#input-commitment-submission) |

未知版本会使该 batcher 交易无效，rollup 节点必须忽略它。batcher 交易中的所有 frame 都必须能够被解析。如果其中任意一个 frame 解析失败，则该交易中的所有 frame 都会被拒绝。

批次交易的认证方式是验证交易的 `to` 地址是否与 batch inbox 地址匹配，以及 `from` 地址是否与读取该交易数据时对应的 L1 区块中的 [system configuration][g-system-config] 里的 batch-sender 地址匹配。

<a id="frame-format"></a>
### 帧格式

一个 [channel frame][g-channel-frame] 被编码为：

```text
frame = channel_id ++ frame_number ++ frame_data_length ++ frame_data ++ is_last

channel_id        = bytes16
frame_number      = uint16
frame_data_length = uint32
frame_data        = bytes
is_last           = bool
```

其中，`uint32` 和 `uint16` 都是大端序无符号整数。类型名称应按照 [Solidity ABI][solidity-abi] 来解释和编码。

[solidity-abi]: https://docs.soliditylang.org/en/v0.8.16/abi-spec.html

frame 中除 `frame_data` 之外的所有数据都是定长的。固定开销为 `16 + 2 + 4 + 1 = 23 bytes`。固定大小的 frame 元数据避免了与目标总数据长度之间的循环依赖，从而简化了对不同内容长度 frame 的打包。

其中：

- `channel_id` 是该通道的不透明标识符。它不应被复用，建议使用随机值；不过，除超时规则外，不会检查其有效性。
- `frame_number` 标识该 frame 在通道内的索引。
- `frame_data_length` 是 `frame_data` 的字节长度。其上限为 1,000,000 字节。
- `frame_data` 是属于该通道的一段字节序列，在逻辑上位于前面各个 frame 的字节之后。
- `is_last` 是单字节字段；若该 frame 是通道中的最后一个，则值为 1；若通道中后面还有 frame，则值为 0。任何其他值都会使该 frame 无效，rollup 节点必须忽略它。

<a id="channel-format"></a>
### 通道格式

[channel-format]: #channel-format

一个通道的编码方式是：对一组批次应用流式压缩算法：

```text
encoded_batches = []
for batch in batches:
    encoded_batches ++ batch.encode()
rlp_batches = rlp_encode(encoded_batches)
```

其中：

- `batches` 是输入，即一系列批次，每个批次都带有字节编码器 `.encode()`，具体见下一节“Batch Encoding”。
- `encoded_batches` 是一个字节数组，即所有已编码批次的拼接结果。
- `rlp_batches` 是对拼接后的已编码批次进行的 RLP 编码。

```text
channel_encoding = zlib_compress(rlp_batches)
```

其中 `zlib_compress` 是 ZLIB 算法，定义见 [RFC-1950][rfc1950]，且不使用字典。

[rfc1950]: https://www.rfc-editor.org/rfc/rfc1950.html

Fjord 升级引入了额外的[带版本的通道编码格式](https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/fjord/derivation.md#brotli-channel-compression)，以支持替代压缩算法。

在解压通道时，我们将解压后的数据量限制为 `MAX_RLP_BYTES_PER_CHANNEL`，其定义见[协议参数表](#protocol-parameters)，以避免 “zip-bomb” 类型的攻击，也就是很小的压缩输入被解压成极其巨量的数据。如果解压后的数据超出该限制，则其处理方式就像该通道只包含前 `MAX_RLP_BYTES_PER_CHANNEL` 个解压字节一样。该限制是在 RLP 解码层面施加的，因此，只要某些批次能够在 `MAX_RLP_BYTES_PER_CHANNEL` 范围内完成解码，那么即使通道大小大于 `MAX_RLP_BYTES_PER_CHANNEL`，这些批次仍会被接受。精确的要求是 `length(input) <= MAX_RLP_BYTES_PER_CHANNEL`。

虽然上面的伪代码暗示所有批次都需要预先已知，但实际上可以对 RLP 编码后的批次进行流式压缩和解压。这意味着在我们尚不知道通道最终会包含多少个批次以及多少个 frame 之前，就有可能先开始在 [batcher transaction][g-batcher-transaction] 中包含该通道的 frame。

<a id="batch-format"></a>
### 批次格式

[batch-format]: #batch-format

回顾一下，批次包含一组要被纳入某个特定 L2 区块的交易列表。

一个批次被编码为 `batch_version ++ content`，其中 `content` 取决于 `batch_version`。在 Delta 升级之前，所有批次的 `batch_version` 都为 0，并按如下方式编码。

| `batch_version` | `content` |
| --- | --- |
| 0 | `rlp_encode([parent_hash, epoch_number, epoch_hash, timestamp, transaction_list])` |

其中：

- `batch_version` 是单字节，前缀在 RLP 内容之前，类似于交易类型。
- `rlp_encode` 是按照 [RLP format] 对批次进行编码的函数，而 `[x, y, z]` 表示一个列表，其中包含项 `x`、`y` 和 `z`。
- `parent_hash` 是前一个 L2 区块的区块哈希。
- `epoch_number` 和 `epoch_hash` 是与该 L2 区块的 [sequencing epoch][g-sequencing-epoch] 对应的 L1 区块编号和哈希。
- `timestamp` 是该 L2 区块的时间戳。
- `transaction_list` 是按 [EIP-2718] 编码的交易所组成的 RLP 编码列表。

[RLP format]: https://ethereum.org/en/developers/docs/data-structures-and-encoding/rlp/
[EIP-2718]: https://eips.ethereum.org/EIPS/eip-2718

Delta 升级引入了额外的批次类型：[span batches][span-batches]。

[span-batches]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/delta/span-batches.md

未知版本会使批次无效，rollup 节点必须忽略它；内容格式错误也同样会导致无效。

> **注意** 如果批次版本和内容本身可以被正确地进行 RLP 解码，但在该批次之后还存在额外内容，那么这些附加数据在解析过程中可能会被忽略。位于各个 RLP 编码批次_之间_的数据则不能被忽略，因为它们会被视为格式错误的批次；但如果一个批次已经可以通过 RLP 解码被完整描述，那么额外内容不会使已解码出的该批次失效。

`epoch_number` 和 `timestamp` 还必须满足 [Batch Queue][batch-queue] 一节中列出的约束，否则该批次将被视为无效并被忽略。

---

<a id="architecture"></a>
# 架构

[architecture]: #architecture

以上内容主要描述了 L2 链派生中使用的一般编码方式，尤其是批次如何在 [batcher transactions][g-batcher-transaction] 中编码。

本节描述如何通过管线式架构，利用 L1 批次生成 L2 链。

验证者可以采用不同实现方式，但其语义必须等价，以避免与 L2 链发生分叉。

<a id="l2-chain-derivation-pipeline"></a>
## L2 链派生流水线

我们的架构将派生过程分解为由以下阶段组成的管线：

1. L1 Traversal
2. L1 Retrieval
3. Frame Queue
4. Channel Bank
5. Channel Reader（Batch Decoding）
6. Batch Queue
7. Payload Attributes Derivation
8. Engine Queue

数据从管线的起点，亦即外层，流向终点，也就是内层。而在最内层阶段，会从最外层阶段拉取数据。

但是，数据的_处理_顺序是反过来的。这意味着，如果最后一个阶段中有任何可处理的数据，它会被优先处理。处理以“步骤”的形式推进，每个阶段都可以执行若干步骤。我们会尽可能先在最后一个，也就是最内层阶段执行尽可能多的步骤，然后才会去执行其外层阶段中的步骤，依此类推。

这样可以确保我们优先使用已经拥有的数据，再去拉取更多数据，并将数据穿过派生管线的延迟最小化。

每个阶段都可以根据需要维护自己的内部状态。特别地，每个阶段都会维护一个 L1 区块引用，也就是编号加哈希，表示截至该 L1 区块为止，所有来源于更早区块的数据都已被完全处理，而该区块本身的数据正在被处理或已经被处理。这样，最内层阶段就可以追踪用于生成 L2 链的 L1 数据可用性的最终确定状态，并在 L2 链输入变得不可逆时，将其反映到 L2 链的 forkchoice 中。

下面我们简要描述管线中的每个阶段。

<a id="l1-traversal"></a>
### L1 遍历

在 _L1 Traversal_ 阶段，我们只是读取下一个 L1 区块的头部。在正常运行时，这些通常是新创建的 L1 区块；不过在同步过程中，或者在发生 L1 [re-org][g-reorg] 时，我们也可能读取旧区块。

在遍历该 L1 区块后，L1 retrieval 阶段所使用的 [system configuration][g-system-config] 副本会被更新，因此 batch-sender 的认证始终能够精确匹配该阶段正在读取的那个 L1 区块。

<a id="l1-retrieval"></a>
### L1 检索

在 _L1 Retrieval_ 阶段，我们读取从外层阶段，也就是 L1 traversal，获得的区块，并从其中的 [batcher transactions][g-batcher-transaction] 中提取数据。一个 batcher 交易需要满足以下属性：

- [`to`] 字段等于配置中的 batcher inbox 地址。
- 交易类型必须是 `0`、`1`、`2`、`3` 或 `0x7e` 之一，也就是 L2 [Deposited transaction type][g-deposit-tx-type]，用于支持嵌套 OP Stack 链上的 batcher 交易强制包含。
- 发送者地址由交易签名 `v`、`r` 和 `s` 恢复得到，且必须等于与该数据所属 L1 区块相匹配的 system config 中加载出的 batcher 地址。

每笔 batcher 交易都是带版本的，并包含一系列 [channel frames][g-channel-frame]，供 Frame Queue 读取，见 [Batch Submission Wire Format][wire-format]。区块中的每一笔 batcher 交易都会按照它们在区块中出现的顺序进行处理，并将其 calldata 传递给下一阶段。

[`to`]: https://github.com/ethereum/execution-specs/blob/3fe6514f2d9d234e760d11af883a47c1263eff51/src/ethereum/frontier/fork_types.py#L52C31-L52C31

<a id="frame-queue"></a>
### 帧队列

Frame Queue 一次缓冲一笔数据交易，并将其解码为 [channel frames][g-channel-frame]，供下一阶段消费。参见 [Batcher transaction format](#batcher-transaction-format) 和 [Frame format](#frame-format) 规范。

<a id="channel-bank"></a>
### 通道银行

_Channel Bank_ 阶段负责管理由 L1 retrieval 阶段写入的 channel bank 缓冲。channel bank 阶段中的一步会尝试从“已就绪”的通道中读取数据。

当前通道会被完整缓冲，直到被读取或丢弃；未来版本的 ChannelBank 可能会支持流式通道。

为限制资源使用，Channel Bank 会基于通道大小进行裁剪，并对旧通道执行超时清理。

通道会以 FIFO 顺序记录在一个称为 _channel queue_ 的结构中。某个通道在其所属的 frame 第一次出现时，就会被加入 channel queue。

<a id="pruning"></a>
#### 修剪

成功插入一个新 frame 后，会对 ChannelBank 进行裁剪：通道会按照 FIFO 顺序被丢弃，直到 `total_size <= MAX_CHANNEL_BANK_SIZE`，其中：

- `total_size` 是各个通道大小之和，而每个通道大小又是该通道中所有已缓冲 frame data 的总和，另外每个 frame 还要额外计入 `200` 字节的 frame-overhead。
- `MAX_CHANNEL_BANK_SIZE` 是在[协议参数表](#protocol-parameters)中定义的协议常量。

<a id="timeouts"></a>
#### 超时

通道开启时所在的 L1 origin 会作为 `channel.open_l1_block` 与该通道一同被记录，并决定该通道数据在被裁剪前最多可保留多少个 L1 区块跨度。

当满足以下条件时，通道会超时：`current_l1_block.number > channel.open_l1_block.number + CHANNEL_TIMEOUT`，其中：

- `current_l1_block` 是该阶段当前正在遍历的 L1 origin。
- `CHANNEL_TIMEOUT` 是 rollup 可配置参数，以 L1 区块数量表示。

对于已经超时的通道，新到达的 frame 不会被缓冲，而是会被丢弃。

<a id="reading"></a>
#### 读取

在读取时，只要最先开启的那个通道已经超时，就将其从 channel-bank 中移除。

在 Canyon 网络升级之前，一旦第一个已打开的通道存在、未超时且已就绪，则读取该通道并将其从 channel-bank 中移除。Canyon 网络升级之后，将按 FIFO 顺序，也就是按打开时间，扫描整个 channel bank，并返回第一个已就绪的通道，也就是未超时的通道。

当某个时间戳大于或等于 canyon time 的 L1 区块所对应的 frame 首次进入 channel queue 时，canyon 行为开始生效。

通道在满足以下条件时视为就绪：

- 该通道已关闭
- 该通道从起始到关闭 frame 之间具有连续的 frame 序列

如果没有通道就绪，则读取下一个 frame 并将其摄入 channel bank。

<a id="loading-frames"></a>
#### 加载帧

当某个 frame 所引用的 channel ID 尚不存在于 Channel Bank 中时，会打开一个新通道，使用当前 L1 区块进行标记，并将其附加到 channel-queue。

Frame 插入条件：

- 与已超时但尚未从 channel-bank 中剪除的通道匹配的新 frame 会被丢弃。
- 对于尚未从 channel-bank 中剪除的 frame，重复的 frame，也就是按 frame number 判断，会被丢弃。
- 重复的关闭 frame，指新的 frame `is_last == 1`，但该通道已见过一个关闭 frame 且尚未从 channel-bank 中剪除，也会被丢弃。

如果某个 frame 是关闭 frame，也就是 `is_last == 1`，则该通道中所有现存的、更高编号的 frame 都会被移除。

注意，虽然这允许在 channel ID 从 channel-bank 中剪除后被重用，但仍建议 batcher 实现使用唯一的 channel ID。

<a id="channel-reader-batch-decoding"></a>
### 通道读取器（批次解码）

在这个阶段，我们对从上一阶段拉取的通道进行解压缩，然后从解压后的字节流中解析 [batches][g-sequencer-batch]。

有关解压和解码规范，请参见 [Channel Format][channel-format] 和 [Batch Format][batch-format]。

<a id="batch-queue"></a>
### 批次队列

[batch-queue]: #batch-queue

在 _Batch Buffering_ 阶段，我们按时间戳对 batch 重新排序。如果某些[时间槽][g-time-slot]缺少 batch，并且存在一个时间戳更高的有效 batch，那么该阶段还会生成空 batch 来填补这些空缺。

每当存在一个时间戳紧接当前[safe L2 head][g-safe-l2-head]之后的顺序 batch 时，就会将 batch 推送到下一阶段。这里的 safe L2 head，指最后一个可从规范 L1 链推导出的区块。该 batch 的父哈希还必须与当前 safe L2 head 的哈希匹配。

注意，如果从 L1 推导出的 batch 中存在任何空缺，这意味着该阶段在生成空 batch 之前需要为整个 [sequencing window][g-sequencing-window] 进行缓冲，因为在最坏情况下，缺失的 batch 可能在该窗口最后一个 L1 区块中才包含数据。

一个 batch 可以有 4 种不同的有效性状态：

- `drop`：该 batch 无效，并且除非发生 reorg，否则它将始终无效。可以将其从缓冲区中移除。
- `accept`：该 batch 有效，应当被处理。
- `undecided`：我们缺少足够的 L1 信息，暂时无法继续进行 batch 过滤。
- `future`：该 batch 可能有效，但当前尚不能处理，应稍后再次检查。

Batch 按其在 L1 上的包含顺序处理：如果有多个 batch 可以被 `accept`，则应用第一个。实现可以将 `future` batch 延迟到后续推导步骤，以减少验证工作量。

Batch 的有效性按如下方式推导：

定义：

- `batch` 如 [Batch format section][batch-format] 中所定义。
- `epoch = safe_l2_head.l1_origin` 是与该 batch 关联的一个 [L1 origin][g-l1-origin]，其属性包括：`number`，L1 区块号；`hash`，L1 区块哈希；以及 `timestamp`，L1 区块时间戳。
- `inclusion_block_number` 是 `batch` 首次被_完整_推导出的 L1 区块号，也就是上一阶段已将其解码并输出时所在的 L1 区块号。
- `next_timestamp = safe_l2_head.timestamp + block_time` 是下一个 batch 应具有的预期 L2 时间戳，参见[区块时间信息][g-block-time]。
- `next_epoch` 可能尚未知晓，但如果可得，它将是 `epoch` 之后的那个 L1 区块。
- `batch_origin` 根据验证结果，取值为 `epoch` 或 `next_epoch`。

注意，可以将某个 batch 的处理延迟到 `batch.timestamp <= next_timestamp` 时再进行，因为无论如何都必须保留 `future` batch。

规则按验证顺序如下：

- `batch.timestamp > next_timestamp` -> `future`：该 batch 现在还不能处理。
- `batch.timestamp < next_timestamp` -> `drop`：该 batch 不能过旧。
- `batch.parent_hash != safe_l2_head.hash` -> `drop`：父哈希必须等于 L2 safe head 区块哈希。
- `batch.epoch_num + sequence_window_size < inclusion_block_number` -> `drop`：该 batch 必须及时被包含。
- `batch.epoch_num < epoch.number` -> `drop`：该 batch 的 origin 不能早于 L2 safe head 的 origin。
- `batch.epoch_num == epoch.number`：将 `batch_origin` 定义为 `epoch`。
- `batch.epoch_num == epoch.number+1`：
  - 若 `next_epoch` 尚未知晓 -> `undecided`：这意味着变更 L1 origin 的 batch 必须等到我们拿到对应的 L1 origin 数据后才能处理。
  - 若已知，则将 `batch_origin` 定义为 `next_epoch`。
- `batch.epoch_num > epoch.number+1` -> `drop`：每个 L2 区块的 L1 origin 最多只能前进一个 L1 区块。
- `batch.epoch_hash != batch_origin.hash` -> `drop`：batch 必须引用规范的 L1 origin，以防止 batch 被重放到非预期的 L1 链上。
- `batch.timestamp < batch_origin.time` -> `drop`：强制执行最小 L2 时间戳规则。
- `batch.timestamp > batch_origin.time + max_sequencer_drift`：强制执行 L2 时间戳漂移规则，但为保持上述最小 L2 时间戳不变式，存在例外：
  - `len(batch.transactions) == 0`：
    - `epoch.number == batch.epoch_num`：这意味着该 batch 尚未推进 L1 origin，因此必须基于 `next_epoch` 进行检查。
      - 若 `next_epoch` 尚未知晓 -> `undecided`：没有下一个 L1 origin，我们还无法判断时间不变式是否仍可保持。
      - 若 `batch.timestamp >= next_epoch.time` -> `drop`：该 batch 本可以采用下一个 L1 origin，同时不破坏 `L2 time >= L1 time` 不变式。
  - `len(batch.transactions) > 0` -> `drop`：当超过 sequencer 时间漂移限制时，绝不允许 sequencer 包含交易。
- `batch.transactions`：如果 `batch.transactions` 列表中包含以下交易，则 `drop`，因为它们要么无效，要么只能通过其他方式派生得到：
  - 任意空交易，亦即零长度字节串。
  - 任意[存款交易][g-deposit-tx-type]，通过交易类型前缀字节识别。
  - 任意未来类型且类型号大于 2 的交易。注意 [Isthmus adds support](https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/isthmus/derivation.md#activation) 支持类型 4 的 `SetCode` 交易。

如果没有任何 batch 可以被 `accept`，并且该阶段已经完成对高度为 `epoch.number + sequence_window_size` 的 L1 区块中所有可被完整读取的 batch 的缓冲，同时 `next_epoch` 已可用，那么可以推导出一个具有以下属性的空 batch：

- `parent_hash = safe_l2_head.hash`
- `timestamp = next_timestamp`
- `transactions` 为空，即没有 sequencer 交易。下一阶段可以再添加存款交易。
- 如果 `next_timestamp < next_epoch.time`：则重复使用当前 L1 origin，以保持 L2 时间不变式。
  - `epoch_num = epoch.number`
  - `epoch_hash = epoch.hash`
- 如果该 batch 是该 epoch 的第一个 batch，则使用当前 epoch，而不是推进到下一个 epoch，以确保每个 epoch 至少有一个 L2 区块。
  - `epoch_num = epoch.number`
  - `epoch_hash = epoch.hash`
- 否则：
  - `epoch_num = next_epoch.number`
  - `epoch_hash = next_epoch.hash`

<a id="payload-attributes-derivation"></a>
### Payload Attributes 派生

在 _Payload Attributes Derivation_ 阶段，我们将从上一阶段获得的 batch 转换为 [`PayloadAttributes`][g-payload-attr] 结构的实例。该结构编码了需要纳入区块的交易，以及其他区块输入，例如时间戳、fee recipient 等。Payload attributes 的推导细节见下方 [Deriving Payload Attributes section][deriving-payload-attr] 一节。

该阶段维护自己的一份[系统配置][g-system-config]副本，并独立于 L1 retrieval 阶段。每当 batch 输入所引用的 L1 epoch 发生变化时，系统配置会根据 L1 日志事件进行更新。

<a id="engine-queue"></a>
### Engine Queue

在 _Engine Queue_ 阶段，前面推导得到的 `PayloadAttributes` 结构会被缓冲，并发送到 [执行引擎][g-exec-engine] 中执行并转换为一个正式的 L2 区块。

该阶段维护对三个 L2 区块的引用：

- [finalized L2 head][g-finalized-l2-head]：直到并包括该区块在内的所有内容，都可以从 L1 链中已[finalized][l1-finality]，也就是规范且永久不可逆的部分完全推导出来。
- [safe L2 head][g-safe-l2-head]：直到并包括该区块在内的所有内容，都可以从当前规范的 L1 链完全推导出来。
- [unsafe L2 head][g-unsafe-l2-head]：safe 和 unsafe 头之间的区块是[unsafe blocks][g-unsafe-l2-block]，它们尚未从 L1 推导出来。这些区块要么来自排序，也就是 sequencer 模式，要么来自与 sequencer 的[unsafe sync][g-unsafe-sync]，也就是 validator 模式。这也被称为 “latest” 头。

此外，它还会缓冲最近处理过的一小段 safe L2 区块引用历史，以及每个区块是由哪些 L1 区块推导而来的引用。这段历史不必完整，但它使得后续的 L1 finality 信号可以转换为 L2 finality。

<a id="engine-api-usage"></a>
#### Engine API 用法

为了与执行引擎交互，使用[执行引擎 API][exec-engine]，其 JSON-RPC 方法如下：

[exec-engine]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/exec-engine.md

<a id="bedrock-canyon-delta-api-usage"></a>
##### Bedrock、Canyon、Delta：API 用法

- [`engine_forkchoiceUpdatedV2`]：如果 `headBlockHash` 不同，则更新 forkchoice，也就是链头，并且如果 payload attributes 参数不为 `null`，则指示执行引擎开始构建一个 execution payload。
- [`engine_getPayloadV2`]：获取先前请求构建的 execution payload。
- [`engine_newPayloadV2`]：执行一个 execution payload 以创建区块。

<a id="ecotone-api-usage"></a>
##### Ecotone：API 用法

- [`engine_forkchoiceUpdatedV3`]：如果 `headBlockHash` 不同，则更新 forkchoice，也就是链头，并且如果 payload attributes 参数不为 `null`，则指示执行引擎开始构建一个 execution payload。
- [`engine_getPayloadV3`]：获取先前请求构建的 execution payload。
- `engine_newPayload`
  - [`engine_newPayloadV2`]：执行 Bedrock/Canyon/Delta 的 execution payload 以创建区块。
  - [`engine_newPayloadV3`]：执行 Ecotone 的 execution payload 以创建区块。
  - [`engine_newPayloadV4`]：执行 Isthmus 的 execution payload 以创建区块。

当前版本的 `op-node` 使用 `v4` Engine API RPC 方法，以及 `engine_newPayloadV3` 和 `engine_newPayloadV2`，因为 `engine_newPayloadV4` 仅支持 Isthmus execution payload。`engine_forkchoiceUpdatedV4` 和 `engine_getPayloadV4` 都向后兼容 Ecotone、Bedrock、Canyon 和 Delta payload。

较早版本的 `op-node` 使用 `v3`、`v2` 和 `v1` 方法。

[`engine_forkchoiceUpdatedV2`]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/exec-engine.md#engine_forkchoiceupdatedv2
[`engine_forkchoiceUpdatedV3`]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/exec-engine.md#engine_forkchoiceupdatedv3
[`engine_getPayloadV2`]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/exec-engine.md#engine_getpayloadv2
[`engine_getPayloadV3`]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/exec-engine.md#engine_getpayloadv3
[`engine_newPayloadV2`]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/exec-engine.md#engine_newpayloadv2
[`engine_newPayloadV3`]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/exec-engine.md#engine_newpayloadv3
[`engine_newPayloadV4`]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/exec-engine.md#engine_newpayloadv4

execution payload 是 [`ExecutionPayloadV3`][eth-payload] 类型的对象。

[eth-payload]: https://github.com/ethereum/execution-apis/blob/main/src/engine/cancun.md

`ExecutionPayload` 具有以下要求：

- Bedrock
  - withdrawals 字段必须为 nil
  - blob gas used 字段必须为 nil
  - blob gas limit 字段必须为 nil
- Canyon、Delta
  - withdrawals 字段必须为非 nil
  - withdrawals 字段必须为空列表
  - blob gas used 字段必须为 nil
  - blob gas limit 字段必须为 nil
- Ecotone
  - withdrawals 字段必须为非 nil
  - withdrawals 字段必须为空列表
  - blob gas used 字段必须为 0
  - blob gas limit 字段必须为 0

<a id="forkchoice-synchronization"></a>
#### Forkchoice 同步

如果存在任何需要应用的 forkchoice 更新，那么在推导或处理额外输入之前，必须先将这些更新应用到执行引擎。

这种同步可能发生在以下情况：

- 某个 L1 finality 信号使一个或多个 L2 区块 finalized，从而更新 “finalized” L2 区块。
- unsafe L2 区块成功完成 consolidation，从而更新 “safe” L2 区块。
- 推导流水线重置后的第一件事，以确保执行引擎的 forkchoice 状态一致。

新的 forkchoice 状态通过在执行引擎 API 上调用 [fork choice updated](#engine-api-usage) 来应用。如果 forkchoice-state 有效性出现错误，则必须重置推导流水线以恢复到一致状态。

<a id="l1-consolidation-payload-attributes-matching"></a>
#### L1-consolidation：payload attributes 匹配

如果 unsafe head 超前于 safe head，则会尝试进行 [consolidation][g-consolidation]，以验证现有 unsafe L2 链是否与根据规范 L1 数据推导出的 L2 输入相匹配。

在 consolidation 期间，我们考虑最早的 unsafe L2 区块，即紧接在 safe head 之后的那个 unsafe L2 区块。如果 payload attributes 与这个最早的 unsafe L2 区块匹配，那么该区块就可以被视为 “safe”，并成为新的 safe head。

将检查以下已推导的 L2 payload attributes 字段是否与该 L2 区块相等：

- Bedrock、Canyon、Delta、Ecotone 区块
  - `parent_hash`
  - `timestamp`
  - `randao`
  - `fee_recipient`
  - `transactions_list`，先比较长度，再比较每一笔已编码交易的相等性，包括存款交易
  - `gas_limit`
- Canyon、Delta、Ecotone 区块
  - `withdrawals`，先比较是否存在，再比较长度，最后比较每一项已编码 withdrawals 的相等性
- Ecotone 区块
  - `parent_beacon_block_root`

如果 consolidation 成功，则 forkchoice 变更将按上一节所述进行同步。

如果 consolidation 失败，则会按下一节所述立即处理这些 L2 payload attributes。这些 payload attributes 会优先于先前的 unsafe L2 区块被选用，从而在当前 safe 区块之上创建一次 L2 链 reorg。立即处理这组新的替代 attributes，使得像 go-ethereum 这样的执行引擎能够落实该变更，因为它们可能不支持对链尖进行线性回退。

<a id="l1-sync-payload-attributes-processing"></a>
#### L1-sync：payload attributes 处理

[exec-engine-comm]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/exec-engine.md#engine-api

如果 safe 和 unsafe L2 头相同，无论是否由于 consolidation 失败导致，我们就会将这些 L2 payload attributes 发送给执行引擎，将其构建为一个正式的 L2 区块。然后，这个 L2 区块将同时成为新的 L2 safe 头和 unsafe 头。

如果从某个 batch 创建的 payload attributes 因验证错误而无法插入链中，也就是区块中存在无效交易或无效状态转换，则应丢弃该 batch，并且不应推进 safe head。Engine queue 将尝试从 batch queue 中使用同一时间戳的下一个 batch。如果找不到有效的 batch，rollup 节点将创建一个仅包含存款的 batch，这种 batch 应始终能通过验证，因为存款总是有效。

通过执行引擎 API 与执行引擎交互的细节见[与执行引擎通信][exec-engine-comm]一节。

随后，按以下顺序处理 payload attributes：

- 使用当前阶段的 forkchoice 状态以及用于开始构建区块的 attributes，执行 [Engine: Fork choice updated](#engine-api-usage)。
  - 必须禁用诸如 tx-pool 之类的非确定性来源，以重建期望的区块。
- 执行 [Engine: Get Payload](#engine-api-usage)，通过上一步结果中的 payload-ID 获取 payload。
- 执行 [Engine: New Payload](#engine-api-usage)，将新的 payload 导入执行引擎。
- 执行 [Engine: Fork Choice Updated](#engine-api-usage)，将新的 payload 设为规范链，此时 `safe` 和 `unsafe` 字段都改为引用该 payload，并且不再携带 payload attributes。

Engine API 错误处理：

- 遇到 RPC 类型错误时，应在后续步骤中重新尝试处理该 payload attributes。
- 遇到 payload 处理错误时，必须丢弃这些 attributes，并保持 forkchoice 状态不变。
  - 最终 derivation pipeline 会生成替代的 payload attributes，可能带 batch，也可能不带。
  - 如果 payload attributes 仅包含 deposits，那么这些 deposits 无效将构成严重的 derivation 错误。
- 遇到 forkchoice-state 有效性错误时，必须重置 derivation pipeline 以恢复到一致状态。

<a id="processing-unsafe-payload-attributes"></a>
#### 处理 unsafe payload attributes

如果已经没有 forkchoice 更新或 L1 数据需要处理，并且下一个可能的 L2 区块已经可以通过某个 unsafe 来源获得，例如 sequencer 通过 p2p 网络发布了它，那么就会乐观地将其处理为一个 “unsafe” 区块。这样在理想情况下，后续 derivation 的工作就只剩下与 L1 的整合，同时也让用户能比 L1 确认 L2 batches 更早看到 L2 链头。

要处理 unsafe payload，payload 必须满足：

- 区块号高于当前 safe L2 head。
  - safe L2 head 只能因为 L1 reorg 而被 reorg 掉。
- 父区块哈希必须与当前 unsafe L2 head 匹配。
  - 这可以防止执行引擎单独同步 unsafe L2 链中更大的缺口。
  - 这可以防止 unsafe L2 区块重组掉其他先前已验证的 L2 区块。
  - 将来的版本中，这个检查可能会改变，以采用例如 L1 snap-sync 协议。

随后，按以下顺序处理该 payload：

- Bedrock/Canyon/Delta Payloads
  - `engine_newPayloadV2`：处理该 payload。它此时尚不会变成规范链。
  - `engine_forkchoiceUpdatedV2`：将该 payload 设为规范的 unsafe L2 head，并保持 safe/finalized L2 heads 不变。
- Ecotone Payloads
  - `engine_newPayloadV3`：处理该 payload。它此时尚不会变成规范链。
  - `engine_forkchoiceUpdatedV3`：将该 payload 设为规范的 unsafe L2 head，并保持 safe/finalized L2 heads 不变。
- Isthmus Payloads
  - `engine_newPayloadV4`：处理该 payload。它此时尚不会变成规范链。

Engine API 错误处理：

- 遇到 RPC 类型错误时，应在后续步骤中重新尝试处理该 payload。
- 遇到 payload 处理错误时，必须丢弃该 payload，并且不得将其标记为规范链。
- 遇到 forkchoice-state 有效性错误时，必须重置 derivation pipeline 以恢复到一致状态。

<a id="resetting-the-pipeline"></a>
### 重置流水线

可以重置 pipeline，例如当我们检测到 L1 [reorg，也就是链重组][g-reorg] 时。**这使得 rollup node 能够处理 L1 链重组事件。**

重置会将 pipeline 恢复到一种状态：它产生的输出与完整的 L2 derivation 过程相同，但起点是一个现有的 L2 链，并且只向后回溯到足以与当前 L1 链重新对齐的位置。

请注意，该算法涵盖了几个重要用例：

- 在不从 0 开始的情况下初始化 pipeline，例如 rollup node 使用现有的执行引擎实例重启时。
- 当 pipeline 与执行引擎链不一致时恢复 pipeline，例如引擎发生同步或变化时。
- 当 L1 链发生重组时恢复 pipeline，例如某个较晚的 L1 区块变成孤块，或出现更大的 attestation 失败。
- 在 fault-proof program 内，初始化 pipeline 以推导一个存在争议的 L2 区块，并带上此前的 L1 与 L2 历史。

处理这些情况还意味着，节点可以被配置为在 0 个确认数时就急切地同步 L1 数据，因为如果之后 L1 并未将该数据认定为规范链，它可以撤销这些更改，从而实现安全的低延迟使用。

首先会重置 Engine Queue，以确定继续 derivation 的 L1 和 L2 起点。之后，其余阶段彼此独立地进行重置。

<a id="finding-the-sync-starting-point"></a>
#### 查找同步起点

为了找到起点，需要从链头向后遍历，并执行以下步骤：

1. 找到当前的 L2 forkchoice 状态。
   - 如果找不到 `finalized` 区块，则从 Bedrock genesis block 开始。
   - 如果找不到 `safe` 区块，则回退到 `finalized` 区块。
   - `unsafe` 区块应始终可用并与上述状态一致。在极少数引擎损坏恢复场景中可能不是这样，目前仍在审查中。
2. 找到第一个带有合理 L1 引用的 L2 区块，作为新的 `unsafe` 起点，从此前的 `unsafe` 向后遍历到 `finalized`，但不再更早。
   - 所谓合理，是指：该 L2 区块的 L1 origin 已知且为规范链，或者未知但其区块号领先于当前 L1。
3. 找到第一个其 L1 引用早于 sequencing window 的 L2 区块，作为新的 `safe` 起点，从上面找到的合理 `unsafe` head 开始，向后遍历到 `finalized`，但不再更早。
   - 如果在任意时刻发现某个 L1 origin 已知但不是规范链，则将 `unsafe` head 修正为当前区块的父区块。
   - 具有已知规范 L1 origin 的最高 L2 区块会被记为 `highest`。
   - 如果在任意时刻发现区块中的 L1 origin 相对于 derivation 规则已损坏，则报错。损坏包括：
     - 与父 L1 origin 相比，L1 origin 的区块号或 parent-hash 不一致。
     - L1 sequence number 不一致，L1 origin 变化时总是变为 `0`，否则应加 `1`。
   - 如果 L2 区块 `n` 的 L1 origin 比 `highest` 的 L1 origin 早超过一个 sequence window，且 `n.sequence_number == 0`，那么 `n` 的父 L2 区块将成为 `safe` 起点。
4. `finalized` L2 区块保留为 `finalized` 起点。
5. 找到第一个其 L1 引用早于 channel-timeout 的 L2 区块。
   - 该区块所引用的 L1 origin 记为 `l2base`，将作为 L2 pipeline derivation 的 `base`。从这里开始，各阶段可以缓冲任何必要数据，同时丢弃不完整的 derivation 输出，直到 L1 遍历追上实际的 L2 safe head。

在向后遍历 L2 链时，实现可以做合理性检查，确保起点不会相对于现有 forkchoice 状态设置得过于靠后，以避免因错误配置而导致代价高昂的重组。

实现者说明：步骤 1 到 4 被称为 `FindL2Heads`。步骤 5 目前属于 Engine Queue reset 的一部分。将来这可能会改变，以便将起点搜索与基础重置逻辑隔离开来。

<a id="resetting-derivation-stages"></a>
#### 重置派生阶段

1. L1 Traversal：从 L1 `base` 开始，作为下一阶段要拉取的第一个区块。
2. L1 Retrieval：清空此前的数据，并获取 `base` L1 数据，或者将获取工作延后到后续 pipeline 步骤。
3. Frame Queue：清空队列。
4. Channel Bank：清空 channel bank。
5. Channel Reader：重置所有 batch 解码状态。
6. Batch Queue：清空 batch queue，并使用 `base` 作为初始 L1 参考点。
7. Payload Attributes Derivation：清空所有 batch 和 attributes 状态。
8. Engine Queue：
   - 使用同步起点状态初始化 L2 forkchoice 状态，也就是 `finalized`、`safe`、`unsafe`。
   - 将该阶段的 L1 参考点初始化为 `base`。
   - 将 forkchoice update 设为首个任务。
   - 重置所有 finality 数据。

在必要时，从 `base` 开始的阶段可以根据 `l2base` 区块中编码的数据来初始化其 system-config。

<a id="about-reorgs-post-merge"></a>
#### Merge 之后关于 reorg 的说明

请注意，在 [merge] 之后，reorg 的深度将受到 [L1 finality delay][l1-finality] 的限制，也就是 2 个 L1 beacon epoch，约 13 分钟，除非超过 1/3 的网络持续不同意。新的 L1 区块可能会在每个 L1 beacon epoch，约 6.4 分钟，完成最终化，并且取决于这些 finality signals 和 batch inclusion，派生得到的 L2 链也会变得不可逆。

请注意，这种 finalization 形式只影响输入，之后节点可以主观地认为链已经不可逆，因为它们能够根据这些不可逆输入、既定的协议规则和参数来复现该链。

然而，这与发布到 L1 上的 outputs 完全无关，后者需要某种证明形式，例如 fault-proof 或 zk-proof 才能完成最终化。像在 L1 上的提款这类 optimistic-rollup outputs，只有在经过一周未被争议，也就是 fault proof challenge window 之后，才会被标记为 “finalized”，这与 proof-of-stake 的 finalization 存在命名冲突。

[merge]: https://ethereum.org/en/upgrades/merge/
[l1-finality]: https://ethereum.org/en/developers/docs/consensus-mechanisms/pos/#finality

---

<a id="deriving-payload-attributes"></a>
# 派生 Payload Attributes

[deriving-payload-attr]: #deriving-payload-attributes

对于每一个由 L1 数据派生出的 L2 区块，我们都需要构建[payload attributes][g-payload-attr]，它由 [`PayloadAttributesV2`][eth-payload] 对象的一个[扩展版本][expanded-payload]表示，其中额外包含 `transactions` 和 `noTxPool` 字段。

这一过程既发生在 verifier 节点运行的 payloads-attributes queue 中，也发生在 sequencer 节点运行的区块生产过程中。如果交易是以 batch 方式提交的，sequencer 可以启用 tx-pool 的使用。

[expanded-payload]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/exec-engine.md#extended-payloadattributesv1

<a id="deriving-the-transaction-list"></a>
## 派生交易列表

对于 sequencer 要创建的每个 L2 区块，我们从一个与目标 L2 区块号匹配的 [sequencer batch][g-sequencer-batch] 开始。如果 L1 链没有包含针对该目标 L2 区块号的 batch，那么这里也可能是一个自动生成的空 batch。请[记住][batch-format]，batch 中包含一个 [sequencing epoch][g-sequencing-epoch] 编号、一个 L2 时间戳和一份交易列表。

该区块属于某个 [sequencing epoch][g-sequencing-epoch]，其编号与某个 L1 区块的编号相同，该 L1 区块即其 _[L1 origin][g-l1-origin]_。这个 L1 区块用于派生 L1 attributes，以及对于该 epoch 中的第一个 L2 区块，派生用户 deposits。

因此，一个 [`PayloadAttributesV2`][expanded-payload] 对象必须包含以下交易：

- 一笔或多笔 [deposited transactions][g-deposited]，分为两类：
  - 一笔 _[L1 attributes deposited transaction][g-l1-attr-deposit]_，由 L1 origin 派生。
  - 对于该 epoch 中的第一个 L2 区块，零笔或多笔 _[user-deposited transactions][g-user-deposited]_，由 L1 origin 的 [receipts][g-receipts] 派生。
- 零笔或多笔 [network upgrade automation transactions]，用于执行网络升级的特殊交易。
- 零笔或多笔 _[sequenced transactions][g-sequencing]_，由 L2 用户签名并被包含在 sequencer batch 中的常规交易。

这些交易**必须**按此顺序出现在 payload attributes 中。

L1 attributes 从 L1 区块头中读取，而 deposits 从 L1 区块的 [receipts][g-receipts] 中读取。关于 deposits 如何编码为日志项的详细信息，请参见 [**deposit contract specification**][deposit-contract-spec]。

[deposit-contract-spec]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/deposits.md#deposit-contract

日志按如下所述的面向未来兼容的尽力推导流程从交易中派生：[关于面向未来的交易日志派生](#on-future-proof-transaction-log-derivation)。

<a id="network-upgrade-automation-transactions"></a>
### 网络升级自动化交易

[network upgrade automation transactions]: #network-upgrade-automation-transactions

某些网络升级要求在特定区块上自动执行合约变更或部署。为了实现自动化，同时又不向执行层引入持久性变更，可以在 derivation 过程中插入特殊交易。

<a id="building-individual-payload-attributes"></a>
## 构建单个 Payload Attributes

在派生出交易列表之后，rollup node 按如下方式构造一个 [`PayloadAttributesV2`][extended-attributes]：

- `timestamp` 设置为 batch 的时间戳。
- `random` 设置为 `prev_randao` L1 区块属性。
- `suggestedFeeRecipient` 设置为 Sequencer Fee Vault 地址。参见 [Fee Vaults] 规范。
- `transactions` 是派生出的交易数组，包括 deposited transactions 和 sequenced transactions，全部使用 [EIP-2718] 编码。
- `noTxPool` 设置为 `true`，以便在构造区块时精确使用上述 `transactions` 列表。
- `gasLimit` 设置为该 payload 的[系统配置][g-system-config]中当前的 `gasLimit` 值。
- 在 Canyon 之前，`withdrawals` 设置为 nil；在 Canyon 之后，设置为空数组。

[extended-attributes]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/exec-engine.md#extended-payloadattributesv1
[Fee Vaults]: https://github.com/ethereum-optimism/specs/blob/main/specs/protocol/exec-engine.md#fee-vaults

<a id="on-future-proof-transaction-log-derivation"></a>
## 关于面向未来的交易日志派生

如 [L1 Retrieval](#l1-retrieval) 所述，batcher transactions 的类型必须来自一个固定的 allow-list。

然而，我们希望即使 receipt 来自未来的交易类型，也能继续从中派生出 deposit transactions 和 `SystemConfig` 更新事件，前提是这些 receipts 可以通过一种尽力而为的流程被解码：

只要某个未来交易类型遵循 [EIP-2718](https://eips.ethereum.org/EIPS/eip-2718) 规范，就可以通过交易，或者其 receipt，二进制编码的第一个字节解码出其类型。然后我们可以按如下方式获取这类未来交易的日志；如果不满足条件，则将该交易的 receipt 视为无效并丢弃。

- 如果它是已知交易类型，也就是说，legacy，编码首字节在 `[0xc0, 0xfe]` 范围内，或其首字节位于 `[0, 4]` 或 `0x7e`，也就是 _deposited_ 范围内，那么它就不是 “future transaction”，我们已经知道如何解码其 receipt，因此该流程与之无关。
- 如果某笔交易的首字节位于 `[0x05, 0x7d]` 范围内，则预期它是一个 “future” 的 EIP-2718 交易，因此我们可以继续处理其 receipt。注意这里排除了 `0x7e`，因为那是已知的 deposit 交易类型。
- “future” receipt 编码的首字节必须与交易编码的首字节相同，否则该 receipt 会被视为无效并丢弃，因为我们要求它必须是一个 EIP-2718 编码的 receipt 才能继续。
- receipt payload 按照 `rlp([status, cumulative_transaction_gas_used, logs_bloom, logs])` 的方式进行解码，这也是已知非 legacy 交易类型的编码方式。
  - 如果该解码失败，则该交易的 receipt 会被视为无效并丢弃。
  - 如果该解码成功，则 `logs` 就已经获得，可以像已知交易类型的日志那样继续处理。

这种尽力解码流程的目的是让协议能够面向未来，兼容新的 L1 交易类型。
