# 指标

SRE 如何观测 broker —— `/metrics`、`/healthz`、`/stats` 上的 15 项指标白名单，以及把它们绑在一起的守恒关系。

> **事实来源：** 设计已冻结；注册表驱动 —— 这张表之外的指标在评审阶段被拒。

## 端点

- `GET /metrics` —— Prometheus 文本格式，**15 项指标白名单**。
- `GET /healthz` —— 状态枚举，与 `quorum_state` 同源。
- `GET /stats` —— 必须带 filter 参数（NSQ 式）。
- 延迟分位数：NSQ 式双缓冲估计器，p50/p90/p99 可选启用（三操作接口）。

## 白名单（15 项指标）

| name | type | labels | 语义 | 守恒 / 派生关系 | 来源对照 |
|---|---|---|---|---|---|
| `mortarmq_broker_uptime_seconds` | gauge | — | 进程存活秒数 | — | NSQ `$SYS/broker/version+uptime` |
| `mortarmq_connections` | gauge | — | 当前活跃 client 连接数 | — | NATS `connz`；RocketMQ proxy-admin |
| `mortarmq_leader_epoch` | gauge | — | 当前 leader epoch（单调） | 只增不减；回退 = 故障 | NATS `jsz` raft leader |
| `mortarmq_quorum_state` | gauge | — | `0`=healthy `1`=soft `2`=read_only | 与降级矩阵一致 | — |
| `mortarmq_topic_messages_produced_total` | counter | `topic` | PUB 落盘总数 | **守恒恒等式左边** | Kafka `-total` 规则；Mosquitto `received` |
| `mortarmq_topic_messages_delivered_total` | counter | `topic` | 成功投递给 consumer 的 ACK 总数 | 守恒右边 | Kafka `records-consumed-total` |
| `mortarmq_topic_messages_dropped_total` | counter | `topic` | 超过 `max_attempts` 进入 DLQ 的失败数（不含 DLQ 成功） | 守恒右边 | Mosquitto `dropped` |
| `mortarmq_topic_messages_dlq_total` | counter | `topic` | 成功写入 DLQ 的消息数 | 守恒右边；`dlq_total <= dropped_total` | — |
| `mortarmq_topic_bytes_total` | counter | `topic` | 落盘字节总数 | — | Kafka `BytesInPerSec`；NSQ `message_bytes` |
| `mortarmq_partition_depth` | gauge | `topic`, `partition` | 分区未消费深度 = `last_seq - ack_floor` | lag 的分区级来源 | NSQ `depth` / `backend_depth` |
| `mortarmq_partition_last_seq` | gauge | `topic`, `partition` | 分区最新 durable sequence | 单调；回退 = fatal | — |
| `mortarmq_group_lag` | gauge | `topic`, `group` | 组滞后 = max partition depth | `>= 0` 且与 `ack_floor` 一致 | — |
| `mortarmq_group_in_flight` | gauge | `topic`, `group` | 组在途未 ACK 消息数 | `in_flight <= max_in_flight` | — |
| `mortarmq_group_retries_total` | counter | `topic`, `group` | 重投递总数 | — | — |
| `mortarmq_e2e_latency_ms` | gauge | `quantile=p50\|p90\|p99` | 端到端 PUB → ACK 延迟分位（窗口 60 s） | `p50 <= p90 <= p99` | NSQ `e2e_processing_latency` |

## 守恒恒等式（P1）

在静默窗口内 —— 没有在途生产者，也没有在途消费者：

```
produced = delivered + dropped + dlq + Δdepth
```

右边每一项都是**只增不减的 counter**，`Δdepth` 是两个 gauge 之差。这就是为什么该恒等式在**抓取时刻就可检验**，而不是文档里的一句口号。任何指标语义变更必须在**同一个 commit** 里更新这个恒等式 —— 这里一旦对不上，说明数字在说谎。

`dlq_total <= dropped_total` 是更紧的第二道检查：一条消息不可能没被计入 dropped 就落进 DLQ。

::: warning 目前还没有代码
今天没有任何端点在服务。这张表是**契约**：15 个名字、它们的类型与 label 都已冻结，上面的守恒恒等式就是性质测试要断言的东西。
:::
