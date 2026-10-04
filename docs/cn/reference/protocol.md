# MortarMQ v0 线协议

**版本** 1.0（2026-09-30；冻结后修订）

本文是 v0 线协议的**唯一事实来源**。修订遵循冻结规则：只有写得出理由的改动才进本文，且下面每条规则自身站得住，不依赖任何引用。

## 1. 帧格式与长度语义

```text
Frame = u32_be length || u8 op || payload[length - 1]
length: number of bytes that follow — the op byte plus payload (NOT the total frame size)
valid range: 1..=MAX_FRAME_LEN
```

| Constant | Value | Description |
|---|---:|---|
| `MAX_FRAME_LEN` | 16 MiB (16777216) | Frame cap (including the op byte); neither broker nor client may raise it |
| `MAX_VALUE_LEN` | 16 MiB − 1 KiB (16776192) | Cap on PUB/MSG value; reserves 1 KiB for field headers + max key + future trailer fields. A 16 MiB value does not fit in a 16 MiB frame — the two caps must be staggered |
| `MAX_KEY_LEN` | 255 B | Key cap (UTF-8 not enforced) |
| `MAX_TOPIC_LEN` | 255 B | Topic-name cap (UTF-8) |
| `MAX_ERR_MESSAGE` | 512 B | Cap on ERR diagnostic text |
| `MAX_OK_RESULT_LEN` | 16 MiB − 6 B (16777210) | Cap on OK result; reserves the op byte, `request_op`, and `result_len` |
| `WIRE_VERSION` | 1 | First field of CONNECT |
| Keepalive | 30 s | The server closes the connection after 1.5×30 s without a complete frame (semantics aligned with MQTT §3.1.2.10) |
| Half-frame timeout | 10 s | Close on timeout; never attempt resynchronization |

- 所有多字节整数都是大端；v0 帧不带 CRC（TCP 校验和够用；安全边界见[威胁模型](../concepts/security.md)）。
- `length=0`、`length=MAX+1`、半帧、半帧超时**全部**是 golden 用例。
- 背压 / 流控只在**完整帧边界**上执行 —— 绝不在帧中间停止读取。

## 2. Op 表（15 个 op：9 核心 + 6 扩展）

核心 op `0x01–0x09`（客户端命令面 + 常用响应）；扩展 op `0x0A–0x0F`（投递 / 消费 / 流控面）。`0x00` 非法，必须断开连接；`0x10–0x7F` 预留给新业务 op；`0x80–0xFE` 预留给管理/内部 op；`0xFF` 非法。

> **计数规则：** **「9 核心 op + 6 扩展 op = 15 op」**。丢掉这个拆分的说法一律算错。

| Op | Value | Direction | Payload (field order = byte order) | Success response | Main errors |
|---|---:|---|---|---|---|
| CONNECT | 0x01 | C→S | `protocol_version:u8, client_flags:u16, token_len:u16, token:bytes, reserved:u32` | OK | 0x0004 / 0x0006 / 0x0007 |
| DECLARE | 0x02 | C→S | `topic_len:u16, topic:bytes, partition_count:u16, flags:u16` | OK.result=`topic_id:u16, partition_count:u16, created:u8` (0=CREATED, 1=IDEMPOTENT_OK) | 0x2001 / 0x2003 |
| PUB | 0x03 | C→S | `topic_id:u16, partition:u16, producer_id:u64, producer_seq:u64, flags:u16, key_len:u16, key:bytes, value_len:u32, value:bytes` | OK.result=`sequence:u64, durability:u8, leader_epoch:u64, commit_seq:u64, result_flags:u8` (bit0=deduplicated) | 0x0010–0x0013 / 0x4001–0x4004 / 0x6xxx |
| SUB | 0x04 | C→S | `group_len:u16, group:bytes, topic_id:u16, partition:u16, start_policy:u8, credit_count:u16, credit_bytes:u32, flags:u16` | OK.result=`subscription_id:u16, member_id:u64, membership_epoch:u32, assignment_epoch:u32` | 0x0024 / 0x2002 / 0x2005 |
| ACK | 0x05 | C→S | `subscription_id:u16, topic_id:u16, partition:u16, seq:u64, delivery_id:u64, ownership_epoch:u64, flags:u16` | OK | 0x0020 / 0x0022 / 0x0023 |
| NACK | 0x06 | C→S | `subscription_id:u16, topic_id:u16, partition:u16, seq:u64, delivery_id:u64, ownership_epoch:u64, reason:u8, flags:u16` | OK | same as ACK |
| PING | 0x07 | C→S | empty | OK | — |
| ERR | 0x08 | both | `code:u16, request_op:u8, message_len:u16, message:bytes` | none | — |
| OK | 0x09 | both | `request_op:u8, result_len:u32, result:bytes` | none | — |
| MSG | 0x0A | S→C | `subscription_id:u16, topic_id:u16, partition:u16, sequence:u64, delivery_id:u64, attempt:u16, ownership_epoch:u64, producer_id:u64, producer_seq:u64, flags:u16, key_len:u16, key:bytes, value_len:u32, value:bytes` | none (client answers with ACK/NACK) | — |
| PULL | 0x0B | C→S | `subscription_id:u16, member_id:u64, membership_epoch:u32, assignment_epoch:u32, ownership_epochs_len:u16, ownership_epochs:[]u64, max_msgs:u16, max_bytes:u32, wait_ms:u16, min_bytes:u32` | OK(empty), or MSG×N then OK | 0x0020 / 0x0021 / 0x4001 |
| HEARTBEAT | 0x0C | C→S | `subscription_id:u16, member_id:u64, membership_epoch:u32, assignment_epoch:u32, state:u8` (0=ACTIVE, 1=LEAVE) | OK | 0x0020 / 0x0026 |
| NOTICE | 0x0D | S→C | `notice_id:u64, kind:u8, group_id:u16, membership_epoch:u32, assignment_epoch:u32, ownership_epoch:u64, topic_id:u16, partition:u16, member_id:u64` (kind: 0=ASSIGN, 1=REVOKE) | none (client answers with CONTROL_ACK) | — |
| CONTROL_ACK | 0x0E | C→S | `notice_id:u64, notice_kind:u8, group_id:u16, membership_epoch:u32, assignment_epoch:u32, ownership_epoch:u64, result:u8` (0=OK, 1=STALE, 2=ERROR) | OK | 0x0020 |
| CREDIT | 0x0F | C→S | `subscription_id:u16, membership_epoch:u32, ownership_epoch:u64, mode:u8, credit_count:u16, credit_bytes:u32, reserved:u32` (mode: 0=SET, 1=ADD) | OK.result=`granted_count:u16, granted_bytes:u32, outstanding_count:u16, outstanding_bytes:u32, credit_epoch:u64` | 0x0020 / 0x4005 |

### 2.1 字段语义说明

1. **PUB 幂等字段**：`producer_id=0 && producer_seq=0` 允许（非幂等发布，计入指标）；`producer_id=0 && producer_seq>0` 被拒（0x0013）；其余情况按 `(topic_id, partition, producer_id)` 窗口去重。
2. **MSG 携带 `ownership_epoch`**：客户端**不解释**它 —— 只在 ACK/NACK 里原样回显，由接收端用来围栏 owner。`attempt` 首次投递为 1。MSG 是服务端**推送**而非响应，因此不占用单连接 FIFO 的请求槽（NOTICE 同理）。
3. **ACK flags bit0=PROGRESS**：刷新工作截止时间，**不**消耗投递次数，也**不**归还 credit。此举取代 v0.1 的 `NACK(reason=SLOW)`（SLOW=3 已保留但未实现）。
4. **NOTICE 携带 `notice_id`**：CONTROL_ACK 必须原样回显，这样乱序到达的控制确认才可归属。
5. **SUB 不隐式 DECLARE**：对不存在的 topic 发 SUB 返回 0x0008。v0 中 `partition` 字段必须是 `0xFFFF`（归属由协调器分配）；其他取值预留给 v1 的直连分区模式。`credit_count` 与 `credit_bytes` 一起设定初始 credit 窗口（默认 256 条 / 2 MiB）。
6. **单连接 FIFO**：请求与响应严格交错，靠 `request_op` 归属响应。v0 无 request_id（要并发就开多条连接）。
7. **先认证**：CONNECT 之前只允许 CONNECT/PING/ERR；第二次 CONNECT 被拒。

## 3. 错误码注册表（全局注册）

注册表是**查表**而非叙述 —— 四个已注册段落共 49 个码，每行都带「客户端该做什么」列。它单独成页，为的是查它时不必读规范。

→ **[错误码注册表](./errors.md)** —— `0x0xxx` 协议/会话 · `0x2xxx` 元数据 · `0x4xxx` 背压/配额 · `0x6xxx` 复制。

段落按固定的四段划分；**未注册的段一律保留**。上面的码有两条规矩：BACKPRESSURE / QUOTA_EXCEEDED 落在 `0x4xxx` 而不是 `0x000a`/`0x000b`，让背压与配额码集中在同一段（wire_version=1 尚未发布，无兼容负担）；复制占用 `0x6001–0x600b`。

## 4. 版本规则

1. **兼容变更**：可选字段只能追加在载荷尾部 + 用 flags 位声明；旧对端忽略未知尾部。
2. **破坏性变更**：新增 op / 改字段顺序 / 改长度语义 → 递增 `wire_version`。
3. 错误码只增不改：已发布码的语义永不变化，码也永不复用。

## 5. 范围边界

- 复制 RPC（APPEND/PREPARE/INSTALL/…）走 `listen_peer`，**不属于本协议**；客户端只会见到 `0x6xxx` 错误码。
- 管理 HTTP（`/metrics`、`/healthz`、`/stats`）与 CLI 读路径不使用本协议。CLI 写路径（`topics create`/`delete`）复用本文定义的 DECLARE 等 op。

## 6. 修订历史

| Date | Change |
|---|---|
| 2026-09-30 | 9 ops → 15 ops consolidation; PUB gains `producer_id`/`producer_seq`; ACK/NACK gain `subscription_id`/`delivery_id`/`ownership_epoch`; new MSG/PULL/HEARTBEAT/NOTICE/CONTROL_ACK/CREDIT |
| 2026-09-30 | Added `MAX_VALUE_LEN = 16 MiB − 1 KiB`, resolving the frame/value cap clash |
| 2026-09-30 | Full error-code registry adopted; BACKPRESSURE/QUOTA moved to 0x4xxx; 0x600b added; AUTH_FAILED naming unified |
| 2026-09-30 | ACK flags=PROGRESS; NOTICE `notice_id`; SUB no implicit DECLARE + `credit_bytes`; SLOW=3 reserved |
