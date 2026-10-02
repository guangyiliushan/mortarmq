# 运维操作手册（Runbook）

出问题时谁在多少步内做什么 —— 启停、3 节点拓扑、只读/隔离处置、备份与恢复。

> **事实来源：** RB-1 的触发表是**冻结设计**，不是实现状态。RB-2 / RB-3 走同一模板，随各自实现落地补全。

## 条目怎么读

每条按顺序回答五个问题：**什么告警了 → 对读者意味着什么 → broker 已经自动做了什么 → 我该敲什么 → 怎么验证恢复了**。答不出最后一条的条目，就是没写完。

## RB-1：quorum 降级 → 只读

**告警来源：** `mortarmq_quorum_state` 离开 `0`（healthy），或 `mortarmq_leader_epoch` 停止推进。**影响面：** 生产者收到错误；消费者可见上界（`commit_seq`）冻结 —— 但**永不回退**。

### 触发表

| level | 条件 | total | in-sync | min ISR | 生产者响应 | 消费者可见性 | 客户端错误 | 运维动作 |
|---|---|---:|---:|---:|---|---|---|---|
| 2 | leader + 至少 1 个 follower 在 hard gap 内 flush | 3 | 2 | 2 | `OK durability=quorum` | `commit_seq` | none | 正常 |
| 1 | quorum 可达成但有 follower 落后 > soft gap | 3 | 2 | 2 | `OK durability=quorum` + `FOLLOWER_LAG` 警告 | `commit_seq` | `FOLLOWER_LAG` | 启动追赶并观察 |
| 0（soft timeout） | quorum ack 在超时内未完成 | 3 | 2 | 2 | `ERR READ_ONLY_DEGRADED` | `commit_seq` 冻结 | `READ_ONLY_DEGRADED` | 查 follower 磁盘 / 网络 |
| 0（no follower） | hard gap 内没有任何 follower flush | 3 | 1 | 2 | `ERR IN_SYNC_REPLICAS_NOT_ENOUGH` | `commit_seq` 冻结 | `IN_SYNC_REPLICAS_NOT_ENOUGH` | **先修 follower，再恢复写入** |
| −1（explicit） | 运维显式设 `min_in_sync=1` 并开启降级 ack | 3 | 1 | 1 | `OK durability=min_iris` | 实现必须定义；**默认不实现** | none | 显式承担 unclean 风险 |
| −2（conflict） | 分歧出现在 `commit_seq` 及以下 | 3 | n/a | 2 | `ERR QUARANTINED` | 分区被隔离 | `DIVERGENT_COMMITTED` | 从审计日志人工对账 |

### broker 已经自动做了什么

level 0 及以上**不需要人工介入来保护数据** —— broker 选择拒绝写入，而不是承认一件它提交不了的事。这正是设计意图：失败模式是一次**看得见的错误**，不是静默丢数据。

唯一需要人在恢复正常运作**之前**出手的是 **0（no follower）**：`min ISR` 是 2 而只有 1 个副本在同步中，follower 修好之前写入一律被拒。

### 人工步骤

1. 确认你在哪一级 —— `mortarmq leader get` 打印 `leader_id`、`leader_epoch`、`quorum_state`。
2. 若是 level 0（soft timeout）：查 follower 的**磁盘与网络** —— fsync 延迟是常见元凶，follower 上的 `mortarmq_partition_last_seq` 会显示它卡住。
3. 若是 level 0（no follower）：**先**修 follower，等追赶完成，**再**恢复写入。
4. 若是 level −2：什么都别重启。从审计日志人工对账；这里任何「自动修复」都是错的。

### 验证恢复

- `mortarmq leader get` → `quorum_state` 回到 `0`，`leader_epoch` 不变或恰好因一次选举递增。
- `mortarmq_broker_uptime_seconds` 仍在增长（进程从未重启）。
- `/metrics` 上 `mortarmq_quorum_state` gauge = `0`。

### 升级路径

只有 level −2 需要人工介入 metadata log。其他任何在一个追赶窗口内没恢复的情况，转 RB-2（元数据隔离）。

## RB-2：元数据隔离处置

- **触发：** `0x2004 METADATA_QUARANTINED`，或 `data/metadata/` 下出现 `quarantine/` 目录。
- **自动行为：** broker 已经隔离该分区并停止服务它（即上表 level −2）。
- **人工步骤：** 目录布局 —— `data/metadata/quarantine/` 存放被拒状态供检查，**绝不**自动重放。

## RB-3：`kill -9` 后 leader 恢复

- **触发：** leader 进程未经正常关停而消失。
- **自动行为：** 重启后 broker 重放 segment 日志与投递台账；重投定时器从台账重建，因此 at-least-once 扛过这次崩溃。
- **人工步骤：** 用 `mortarmq leader get` 确认恢复后的 `leader_epoch`。

::: warning 目前还没有代码
今天没有 broker 在跑，所以没有任何条目被实战验证过。触发表是冻结设计，三条条目是**未来每条条目必须长成的样子** —— 其中 `验证恢复` 那一段是永远不许留空的部分。
:::
