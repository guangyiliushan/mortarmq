# 用例与流程

「**发生了什么**」的两个视角。用例图说**谁**要达成**哪个目标**；活动流程说 broker 为此**做了什么**。

> **与[关键时序](./sequences.md)的关系：** 那一页把同一条发布/消费链路画成具名参与者之间的消息交换。本页回答「走了哪条分支、守住了什么守恒」，[关键时序](./sequences.md) 回答「谁按什么次序对谁说话」。两者是同一条链路的两种记法 —— 谁也不是谁的子集。

> UML 说明：mermaid 没有原生用例图，这里用 flowchart 近似 —— `([ ])` 胶囊是用例，具名节点是 actor，include/extend 用虚线标注。同理，mermaid flowchart 承载活动图语义（圆角=动作，菱形=判定，并行用 subgraph 表达）。

## 用例

```mermaid
flowchart LR
    subgraph Actors["Actors"]
        DEV_PROD["Application developer (producer)"]
        DEV_CONS["Application developer (consumer)"]
        OPS["Operator"]
        JUDGE["Judge / browser user"]
        CLID["CLI user"]
    end

    subgraph MortarMQ["MortarMQ system boundary"]
        UC1(["PUB publish a message"])
        UC2(["SUB subscribe + PULL fetch"])
        UC3(["ACK / NACK acknowledge"])
        UC4(["DECLARE idempotent topic/group creation"])
        UC5(["Incremental consumer-group rebalance"])
        UC6(["View metrics /metrics"])
        UC7(["Health check /healthz"])
        UC8(["CLI management (7 commands)"])
        UC9(["kill -9 crash recovery"])
        UC10(["Browser live-subscribe demo"])
        UC11(["Continue produce/consume across leader failover"])
        UC12(["DLQ dead-letter delivery"])
    end

    DEV_PROD --> UC1
    DEV_PROD --> UC4
    DEV_CONS --> UC2
    DEV_CONS --> UC3
    DEV_CONS --> UC5
    OPS --> UC6
    OPS --> UC7
    OPS --> UC8
    OPS --> UC9
    JUDGE --> UC10
    JUDGE --> UC11
    UC2 -.include.-> UC3
    UC1 -.extend.-> UC12
    UC2 -.extend.-> UC5
```

### Actor × Goal 表（语义基线）

下表而非图，才是用例的**事实来源**。

| 角色 | 目标 | 前置条件 | 后置条件 / 例外 |
|---|---|---|---|
| 生产者开发者 | PUB 落盘持久化（多数派 fsync） | token 合法、quorum 健康 | quorum 丢失 → `READ_ONLY_DEGRADED`（可行动错误） |
| 生产者开发者 | 幂等地创建 topic | — | 同名同配置 → IDEMPOTENT_OK；同名不同配置 → MISMATCH |
| 消费者开发者 | 有序拉取并确认 | 组已 DECLARE | credit 耗尽 → 调度暂停（绝不静默丢弃） |
| 消费者开发者 | 5 次失败后进 DLQ | — | DLQ 环路检测 |
| 运维 | 观测健康与延迟 | — | 15 项指标白名单 + 只读状态可见 |
| 运维 | 节点崩溃后恢复 | — | 自动重新选举 / 元数据隔离处置手册 |
| 评委 | 5 分钟内在浏览器看到实时消息与延迟 | `moon run` | — |
| CLI 用户 | 脚本化管理 | broker 可达 | 退出码 0/2/3/4 |

### v2 用例（MVP 边界之外）

TLS 加密连接、ACL 授权管理、动态配置变更、在线分区扩容、通配符订阅 —— 见内部设计档案中对应的接口预留条目。

## 活动流程 A：发布（含落盘与降级分支）

```mermaid
flowchart TD
    A["client issues PUB"] --> B["codec decodes the frame"]
    B --> C{"Authenticated? (checked at CONNECT)"}
    C -- "No" --> X1["ERR NOT_AUTHENTICATED (close connection; AUTH_FAILED belongs to the CONNECT stage)"]
    C -- "Yes" --> D{"mode == ReadOnly?"}
    D -- "Yes" --> X2["ERR READ_ONLY_DEGRADED (data-plane semantics; never hidden)"]
    D -- "No" --> E["Resolve topic → route to partition (FNV-1a)"]
    E --> F["storage append + local fsync"]
    F --> G["replication APPEND → followers"]
    G --> H{"quorum flushed (2/3)?"}
    H -- "Yes" --> I["commit: visible[s]=true"]
    I --> J["PUB_OK (commit_seq, leader_epoch)"]
    H -- "No (timeout)" --> K["degrade → ReadOnly + ERR QUORUM_LOST"]
    J --> L["delivery: dispatch to consumers with credit > 0"]
```

## 活动流程 B：消费与确认（含重投与 DLQ）

```mermaid
flowchart TD
    S0["consumer PULL (credit > 0)"] --> S1["delivery picks messages after the ACK floor"]
    S1 --> S2["MSG dispatched (consumes credit)"]
    S2 --> S3{"ACK received?"}
    S3 -- "Yes" --> S4["ledger records ACK (batched fsync) → ack_floor advances"]
    S4 --> S5{"Credit low watermark / 32 msgs / 1 MiB / 20 ms?"}
    S5 -- "Yes" --> S6["client sends CREDIT to return budget"]
    S5 -- "No" --> S0
    S3 -- "Timeout / NACK" --> S7{"retry count < 5?"}
    S7 -- "Yes" --> S8["redeliver (RetryScheduled, backoff)"]
    S8 --> S2
    S7 -- "No" --> S9["write to the DLQ topic (loop detection)"]
    S9 --> S10["dropped_total + 1; conservation P1 holds"]
```

## 关键语义说明

1. 两条流程的守恒交集是 CM1：`produced = delivered + dropped + dlq + Δdepth`（在静默窗口内成立）。
2. 每一个错误出口（X1/X2/K/S9）都是**可行动的错误码** —— 不允许静默丢弃。
3. 并发：流程 A 与 B 在不同角色间并发执行；broker 内部由每分区单写者协程序列化它们。
