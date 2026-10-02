# 故障排查

出了什么问题、它意味着什么、该敲什么 —— 每条都是 `Problem` → `Solution` 对，按你实际看到的错误码归档。

> **这些条目怎么来的：** 下面每个 `Problem` 都是冻结设计里**已规定**的失败 —— 有文档记录的错误码，或有文档记录的启动规则。具体日志措辞由实现落地时决定；但**错误码**和**修法**已经定死了。

## 1. 启动被拒：`unknown key`

> **Problem：** broker 启动即退出，报 `unknown key: listen_https`。

**意味着什么：** 解析是快速失败，白名单是**封闭**的 —— [18 个键](../reference/configuration.md)之外的任何键都是错误而非警告。这是刻意的：被静默忽略的键，会让人以为配置生效了而其实没有。

**怎么办：** 对照白名单查键名。常见情况：

| 你写的 | 正确的 |
|---|---|
| `listen_tcp` | `listen_client` |
| `listen_https` | v0 不支持（无 TLS） |
| 任何 camelCase 键 | 键名是 `snake_case` |

**验证：** 进程起来了，且 `mortarmq broker status` 返回 `uptime_s > 0`。

## 2. `0x0008 UNKNOWN_TOPIC`

> **Problem：** 发布或订阅失败，错误码 `0x0008`。

**意味着什么：** topic 不存在。**SUB 不隐式 DECLARE** —— 对任何从「订阅即建 topic」的 broker 过来的人，这是最反直觉的一条。

**怎么办：**

```bash
mortarmq topics create orders --partitions 4
```

错误文本里也带这个提示。

**验证：** `mortarmq topics list` 里 `orders` 的 `state=active`。

## 3. `0x2003 METADATA_READ_ONLY`

> **Problem：** 写操作开始失败并返回 `0x2003`，读仍然正常。

**意味着什么：** 正在进行故障切换或隔离。读不受影响是刻意的 —— 系统宁可「现在写不进去」，也不写一件之后可能要收回的东西。

**怎么办：** 退避重试等待。如果超过一个选举窗口还没恢复，那就不是暂态了 —— 转 [RB-1](./runbook.md#rb-1-quorum-降级-→-只读)。

**验证：** `mortarmq leader get` 的 `quorum_state` 回到 `0`。

## 4. `0x4006 NO_CREDIT` 或 `0x4005 MESSAGE_EXCEEDS_CREDIT`

> **Problem：** 消费者被 `0x4006` 拒绝，或大消息被 `0x4005` 拒绝。

**意味着什么：** 流控由 credit 窗口管辖，而它是慢消费者与 broker 内存无界膨胀之间**唯一的**闸门。`0x4006` = 你把预算用光了却没还；`0x4005` = 单条消息比 `credit_bytes` 还大。

**怎么办：**

- `0x4006` → 发 `CREDIT` 归还预算。窗口在 32 ACK / 1 MiB / 低水位 / 20 ms 任一触发时自动归还。
- `0x4005` → 调大 `credit_bytes`；或者接受 v0 的 credit 窗口固定在 256 条 / 2 MiB，按此批量。

**验证：** `/metrics` 上 `mortarmq_group_in_flight` 降回窗口以内。

## 5. `0x6002 READ_ONLY_DEGRADED`

> **Problem：** 生产者收到 `0x6002`；消费者仍能收到一切已提交的消息。

**意味着什么：** quorum 未达成。broker **选择拒绝写入**，而不是承认一件它提交不了的事。**没有丢数据** —— 消费者可见上界是冻结，不是回退。

**怎么办：** 这是 runbook 的活，不是客户端的活。去 [RB-1](./runbook.md#rb-1-quorum-降级-→-只读) 按触发表处置。

**验证：** `mortarmq_broker_uptime_seconds` 全程都在增长 —— 进程从未重启。

## 6. 浏览器 demo 连不上

> **Problem：** WebSocket 握手失败，或浏览器报 origin 被拒。

**意味着什么：** 两道闸门之一 —— `listen_ws` 默认关闭；而 `ws_origins` **在列表为空时拒绝一切**。

**怎么办：** 两个都设上：

```json
{
  "listen_ws": "0.0.0.0:7188",
  "ws_origins": ["http://localhost:4173"]
}
```

空的 `ws_origins` 不是「全部允许」，是「全部拒绝」。方向是刻意选的：默认放行就等于给跨站 WebSocket 劫持开了口子。

**验证：** `/demo/` 页面出现实时消息流。

## 7. 升级被拒：版本过新

> **Problem：** 升级数据目录后，旧二进制拒绝启动，报告某个 segment 版本它读不了。

**意味着什么：** **跨不兼容档**读取（升级 case F3）。拒绝是正确行为 —— 另一条路是按猜测的格式去解释字节。

**怎么办：** 不要降级数据；要么完成升级，要么从备份恢复。错误**必须**给出文件路径和版本号 —— 如果没给，那是值得提 issue 的缺陷：没有这两项你根本定位不到是哪个 segment。

**验证：** 升级完成后 `mortarmq broker status` 报出新的 `version`。

## 8. `0x0006 AUTH_FAILED`

> **Problem：** 连接在首帧就被关闭。

**意味着什么：** token 摘要不匹配，或者 CONNECT 不是首帧。服务端**刻意**给通用回复并加 100 ms 延迟 —— 它从不区分「token 错了」和「没有这个 token」，因为那个区分本身就是个预言机。

**怎么办：** 检查 token（`tools/hash-token`），并确认连接上没有东西排在 CONNECT 前面。

**验证：** 重连后 `/metrics` 上 `mortarmq_connections` 递增。

::: warning 目前还没有代码
没有任何条目被实战踩过。已经定死的是：错误码、它意味着什么、怎么修 —— 三者都规定在[错误码注册表](../reference/errors.md)与设计里。实现还欠的，是那一行日志的准确措辞。
:::
