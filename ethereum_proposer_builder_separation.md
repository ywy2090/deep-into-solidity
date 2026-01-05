```
flowchart TD
    subgraph Users ["用户层"]
        U1["用户 A"] -->|"交易 T1"| EL1
        U2["用户 B"] -->|"交易 T2"| EL1
        U3["用户 C"] -->|"交易 T3"| EL2
    end

    subgraph Executors ["执行层节点 / 网络"]
        EL1["执行节点 1<br/>(普通节点)"] -->|"广播"| Mempool
        EL2["执行节点 2<br/>(普通节点)"] -->|"广播"| Mempool
        Mempool[("公共内存池<br/>P2P 网络")]
    end

    subgraph Searchers ["MEV 搜索者"]
        S1["搜索者 1"] -->|"Bundle B1"| BB1
        S2["搜索者 2"] -->|"Bundle B2"| BB1
        S3["搜索者 3"] -->|"Bundle B3"| BB2
    end

    subgraph Builders ["区块构建者 - 多个并行"]
        BB1["构建者 1<br/>(如 Flashbots Builder)"] -->|"构造 Payload P1"| R1
        BB1 -->|"同时提交"| R2
        BB2["构建者 2<br/>(如 bloXroute Builder)"] -->|"构造 Payload P2"| R1
        BB2 -->|"同时提交"| R3
        BB3["构建者 3"] -->|"Payload P3"| R2
    end

    subgraph Relays ["中继 - 多对多连接"]
        R1["中继 1<br/>(Flashbots)"]
        R2["中继 2<br/>(bloXroute)"]
        R3["中继 3<br/>(Eden)"]
    end

    subgraph Consensus ["共识层 - 验证者集合"]
        Vpool[("&gt;1,000,000 验证者")]
        Vpool -->|"每 slot 随机选择"| Proposer
        Proposer["提议者<br/>(当前 slot 的 1 个验证者)"]
        Proposer -->|"通过 MEV-Boost"| R1
        Proposer -->|"同时监听"| R2
        Proposer -->|"同时监听"| R3

        Attesters[("数千 Attester<br/>验证者委员会")]
    end

    %% 数据流
    Mempool -->|"交易流"| BB1
    Mempool -->|"交易流"| BB2
    Mempool -->|"交易流"| BB3

    R1 -->|"提供区块头 H1 + 出价"| Proposer
    R2 -->|"提供区块头 H2 + 出价"| Proposer
    R3 -->|"提供区块头 H3 + 出价"| Proposer

    Proposer -->|"选择最高出价<br/>(e.g., H2)"| BB2
    BB2 -->|"交付完整 Payload P2"| Proposer

    Proposer -->|"广播完整区块"| BeaconChain[("信标链网络")]
    BeaconChain --> Attesters
    Attesters -->|"投票确认"| Finalized["区块最终确认"]

    classDef user fill:#fff8dc,stroke:#daa520;
    classDef exec fill:#f0f8ff,stroke:#4682b4;
    classDef searcher fill:#ffe4b5,stroke:#d2691e;
    classDef builder fill:#d4f7e5,stroke:#2e8b57;
    classDef relay fill:#e6e6fa,stroke:#333;
```
