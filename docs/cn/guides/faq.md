# 常见问题（FAQ）

先直接回答，再给细节 —— 按你实际在做的决定分组。

## 1. 它是什么

### 1. MortarMQ 需要 ZooKeeper、etcd 或任何外部协调器吗？

**不需要。** 成员关系是配置里的一张静态 `peers` 表，元数据存在 broker 自己的 `MMML` 日志 + 快照里（`data/metadata/`）。没有外部进程要跑 —— 代价是**也没有动态成员**，这正是「不需要 ZooKeeper」这笔交换的另一面。见 [`peers`](../reference/configuration.md)。

### 2. 它和 Kafka 兼容吗？

**不兼容。** 线协议是自己的 15 op 二进制协议（`[u32_be len][u8 op][payload]`），不是 Kafka 线格式。没有客户端即插即用兼容，v0 也不打算做。

### 3. 为什么要做这个？

因为目标是 **MoonBit 原生**的 MQ —— 整条闭环（codec、storage、broker、client）从同一份代码同时编译到 native **和**浏览器。浏览器目标为什么选 JS backend 而不是 wasm-gc。

## 2. 投递语义

### 4. 投递是 at-least-once 还是 exactly-once？

**at-least-once**，带死信路径。生产者靠 `(producer_id, producer_seq)` 去重窗口获得幂等；消费者靠租约超时获得重投。超过 `delivery_max_attempts`（5 次）进 DLQ，而不是无限重试。消费者组级别的 exactly-once **不提供**。

### 5. 一条消息失败 5 次会怎样？

写入 DLQ topic，并计入 `mortarmq_topic_messages_dlq_total`。不变量 `dlq_total <= dropped_total` 成立 —— 不计入 dropped 就不可能进 DLQ。

### 6. broker 崩溃会丢数据吗？

设计意图是不丢：segment 走 fsync，quorum 提交要求多数派 flush 后 `commit_seq` 才推进。投递台账与消息记录分离，所以重投定时器扛得住 `kill -9`。这正是仿真要注入的场景，也是 [RB-3](./runbook.md#rb-3-kill-9-后-leader-恢复) 覆盖的内容。

## 3. v0 边界

### 7. 支持 TLS 吗？

**不支持。** `wss` 是保留位，v1 才上。在不可信网络上请用别的加密通道包着跑 —— v0 到底防什么、不防什么，见[威胁模型](../concepts/security.md)。

### 8. 有认证吗？授权呢？

认证**有**：CONNECT 帧携带静态 token，服务端只存 SHA-256 摘要并做常量时间比较。授权（按 topic 的 ACL）**没有** —— v2。

### 9. 配置能热加载吗？

**不能。** 18 个键全部 `update_mode = read-only`，改一个要重启。热加载是 v1 事项。

### 10. 能改 topic 的分区数吗？

**v0 不能。** 分区数在 DECLARE 时定死。建 topic 之前想清楚 —— 见[最佳实践 §1.3](./best-practices.md#_1-3-分区数只定一次)。

### 11. 订阅支持通配符吗？

**v0 不支持。** topic 名只做精确匹配；通配符是留给后面的接口预留。

### 12. 元数据层是 Raft 吗？

**不是。** 元数据用 broker 自己的 `MMML` 变更日志，靠 `mutation_id` 围栏 + 定期快照，不是 Raft 实现。Raft 元数据 quorum 明确在 v0 范围之外。

## 4. 使用

### 13. SUB 会顺带创建 topic 吗？

**不会。** 对不存在的 topic 发 SUB 返回 `0x0008 UNKNOWN_TOPIC` —— 必须先 `DECLARE`。如果你来自「订阅即建 topic」的 broker，这是最反直觉的一条。

### 14. 浏览器里能用吗？

**能** —— 这就是主线目标：客户端库跑在 JS backend 上、走 WebSocket，wasm-gc 纯核心是 stretch 目标。

### 15. `0x4006 NO_CREDIT` 是不是出问题了？

没问题，这是正常流控：你的消费者把 credit 预算用光了却没归还。见[故障排查 §4](./troubleshooting.md#_4-0x4006-no-credit-或-0x4005-message-exceeds-credit)。

## 5. 诚实回答

### 16. 比 Kafka / RocketMQ / Redpanda 快吗？

**不知道，且不做任何声称。** 没跑过任何基准 —— 项目还没有可执行的 broker。[基准矩阵与噪声协议](../develop/benchmarks.md)规定了这样的数字**将来**怎么才算可以报：≥ 10 轮、`mean±σ`、σ/mean > 3% 作废、差异 < 5% 不下结论。

### 17. v0 明确不含什么？

TLS/wss、动态 token、authz ACL、配置热加载、日志截断/自动保留、元数据 quorum、动态集群成员、topic 通配符、分区数变更、WS 压缩。每一项都有文档化的升级路径 —— 见[升级与回滚](./upgrade.md)。

::: warning 目前还没有代码
上面每一条都来自冻结设计，不是来自跑起来的软件。行为与文档不一致时，**错的是文档** —— [请提 issue](https://github.com/guangyiliushan/mortarmq/issues)。
:::
