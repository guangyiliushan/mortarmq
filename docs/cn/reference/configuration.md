# 配置

运维如何书写并校验 broker 配置 —— 白名单里的每一个键。

> **事实来源：** 18 键白名单是**冻结设计**，不是实现状态 —— 一个键出现在这里，是因为「先写得出理由，才配这个键」，而不是因为已经有 broker 在读它。

## 已冻结的决策

- 格式：**JSON**（直接用 `moonbitlang/core` 的 json）；文件头部的 `_comment` 键数组承载人写的注记。
- 解析**快速失败**：**未知键一律拒绝**（白名单外的键会让 CI 变红）；无热加载（v0 边界）。
- **18 个键全部 `update_mode = read-only`** —— 三级更新分类（read-only / 热加载 / 动态）的占位；v0 中任何键都必须重启才能变。

## 白名单（18 键）

| # | 配置项 | 类型 | 默认值 | 为什么必须有（写不出理由就不配） | update_mode |
|---:|---|---|---|---|---|
| 1 | `node_id` | `u16` | 静态分配 | 集群身份与静态成员表的主键；没有它复制/选主无法寻址 | read-only |
| 2 | `peers` | `[node_id; addr]` | 3 项静态表 | v0 静态 3 节点；成员变更属于 v2（Redpanda 的 members 管理已证明复杂） | read-only |
| 3 | `leader_priority` | `u16` 数组 | 按 `peers` 顺序 | 静态首选 leader；lease 超时降级的确定性来源 | read-only |
| 4 | `listen_client` | `addr` | `0.0.0.0:7188` | client wire 入口 | read-only |
| 5 | `listen_peer` | `addr` | `0.0.0.0:7189` | 复制 + 心跳入口；与 client 流量隔离 | read-only |
| 6 | `data_dir` | `path` | `./data` | 所有 segment / metadata / snapshot 的根；唯一持久化位置 | read-only |
| 7 | `segment_max_bytes` | `u64` | `67108864`（64 MiB） | segment 轮转边界；不设则 segment 无界增长 | read-only |
| 8 | `partition_default_count` | `u16` | `4` | DECLARE 未指定时的缺省；显式指定时忽略此项 | read-only |
| 9 | `delivery_max_attempts` | `u32` | `5` | 重试上限；DLQ 前最后一次机会 | read-only |
| 10 | `delivery_lease_ms` | `u32` | `30000` | 消息租约；超时重投是 at-least-once 的活性来源 | read-only |
| 11 | `poll_max_wait_ms` | `u32` | `5000` | long poll 上限；防止连接空挂 | read-only |
| 12 | `credit_initial_count` | `u32` | `256` | 初始 credit 窗口（count）；`credit_bytes` = 2 MiB 按同一比例派生。**冻结后修订：** 原 `64` 与旧名作废 | read-only |
| 13 | `metadata_snapshot_records` | `u32` | `8192` | snapshot 阈值；不设则 log 无界重放 | read-only |
| 14 | `metrics_enabled` | `bool` | `true` | `/metrics` 开关；关闭即省采样开销 | read-only |
| 15 | `log_level` | `enum` | `info` | 排障最低需求；再多的可观测归 `/metrics` | read-only |
| 16 | `listen_ws` | `addr` | **未启用**（可选） | 浏览器 demo 需要 WS 监听；默认关闭；`wss` 留位 | read-only |
| 17 | `listen_admin` | `addr` | `127.0.0.1:7190` | admin HTTP（`/metrics` `/healthz` `/stats` + CLI 读路径）入口；默认绑 localhost | read-only |
| 18 | `ws_origins` | `[str]` | `localhost` / `127.0.0.1` 白名单 | WS Origin 白名单（空 = 拒绝全部）；防跨站 WS 劫持 | read-only |

### 命名提示

这个键叫 `listen_client`，**不是** `listen_tcp`。两处权威源 —— 本白名单与 WebSocket 最小规范（「同进程不同端口」）—— 用的都是 `listen_client`；这个区分有意义，因为同一进程还暴露着 `listen_peer` 和 `listen_admin`。

## 条目模板（每个键都带全字段）

| Field | Type | Default | Rationale | update_mode |
|---|---|---|---|---|
| … | | | | read-only |

## 拒绝示例

```json
{ "listen_https": "…" }
```

→ 启动被拒：`unknown key: listen_https`（在白名单之外）。

::: warning 目前还没有代码
今天没有任何 broker 读这个文件。上面每个默认值都是**冻结设计值**；配置解析器落地时，这 18 个键就是验收线 —— 表外的键必须让启动失败，表内的键解析器不认识，那是解析器的缺陷。
:::
