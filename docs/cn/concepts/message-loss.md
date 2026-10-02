# 消息丢失

消息在什么条件下**可能**丢失 —— 以及怎么证明它没丢。

> 先读[基础概念 §一条消息走过的路](./basics.md#一条消息走过的路-全链路)，下面每一条都指向那条链路上的某个阶段。

## 什么时候丢不了

设计刻意关上了三扇门：

1. **`PUB_OK` 之前。** 写入只在多数派 fsync 完成后才被确认（第 4 阶段）。本地 fsync 与 quorum 提交之间崩溃，意味着**生产者从没被告知它成功了** —— 重试是正确行为，不是丢数据。
2. **消费者侧卡住。** 消费者停止 ACK 会导致租约超时 → 重投 → DLQ。消息仍然存在，只是换了状态。
3. **保留策略。** v0 **没有**日志截断和自动保留 —— segment 只增不减。所以没有任何后台策略会删它。（代价是 `data_dir` 会涨满；那是可用性问题，不是丢失问题。）

## 什么时候可能丢

| 条件 | 怎么会走到这一步 | 怎么避免 |
|---|---|---|
| **所有副本在同一块盘上** | 三台共用一个 `data_dir`，或三个 `data_dir` 在同一个物理卷 | 每节点一个 `data_dir`，且分属不同故障域 |
| **显式接受不干净确认** | 降级 level −1：`min_in_sync=1` 且开启降级 ack | **默认不实现。** 你若打开它，就是拿持久性换可用性 —— 把这个选择写下来 |
| **失去 quorum 的节点丢失** | 3 台里丢 2 台 | 这不是**已确认**数据的丢失，但是一次停摆 |
| **台账有 bug** | 投递台账没把 `DELIVER`/`ACK` 持久化 | 仿真专门在第 3–5 阶段之间注入 `kill -9` 来抓这个 |

前两条是**配置选择**，不是缺陷。第三条是持久性下限。第四条是测试套件存在的理由。

## 怎么检测

**守恒恒等式就是丢失检测器。** 静默窗口内：

```
produced = delivered + dropped + dlq + Δdepth
```

如果 `produced` 大于右边之和，说明有消息没对上账 —— 这就是「丢失」的定义。恒等式在抓取时刻成立，是因为右边每一项都是单调 counter，`Δdepth` 是两个 gauge 之差。

两条单调性检查能更早抓到同一类故障：

- `mortarmq_partition_last_seq` 绝不能下降 —— 下降是 `fatal`，不是警告。
- `mortarmq_leader_epoch` 只增；下降说明有故障。

```text
# 「健康」长这样
mortarmq_topic_messages_produced_total{topic="orders"}        1000
mortarmq_topic_messages_delivered_total{topic="orders"}        980
mortarmq_topic_messages_dropped_total{topic="orders"}           15
mortarmq_topic_messages_dlq_total{topic="orders"}               15
mortarmq_partition_depth{topic="orders",partition="0"}           5
# 980 + 15 + 15 + 5 = 1015  ← 要查：15 条消息对不上账
```

这套算术就是全部的监控策略。你不需要一个单独的「丢失」指标 —— 你需要让已有的那四个加得上。

::: warning 目前还没有代码
没有 broker 在跑，这个恒等式从未在生产中被求值过。它是**验收线**：性质套件断言它，失败算正确性缺陷，不算指标缺陷。
:::

## 相关

- 链路本身：[基础概念](./basics.md)
- quorum 丢失怎么办：[RB-1](../guides/runbook.md)
- 计数器定义：[指标](../reference/metrics.md)
