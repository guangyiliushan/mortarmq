# 升级与回滚

运维如何安全地升级或降级 —— 8 case 升级矩阵、`finalize` 语义、降级前置检查。

> **事实来源：** 升级矩阵是**冻结设计**，不是实现状态。每个 case 都是发布门禁：**矩阵红 = 阻断发布**，不接受「文档里加个脚注」这种处理。

## 先定方向：我在往哪边走

- **兼容档内升级**（F1、F2、F4、F5、F6）→ 滚动升级，一次一台；复制协议取 `min(双方版本)`。
- **跨不兼容档升级**（F3）→ **单向**。旧二进制**拒绝**读新 segment，而不是猜着读；这个拒绝本身就是安全特性。
- **降级**（R1、R2）→ 必须先过下面的前置检查。只要存在不可逆的元数据变更，R2 就拒绝，并告诉你是哪一条。

## 8 case 矩阵

| # | 旧格式 | 新格式 | 方向 | 期望行为 | 诊断要求 | 来源依据 |
|---|---|---|---|---|---|---|
| F1 | `segment format_version=1` | `segment format_version=1` | 同版本 | 正常读写 | — | 基线 |
| F2 | `segment format_version=1` | `segment format_version=2`（兼容档） | v1 读 v0 | 必须可读；golden 测试锁定字节级行为 | — | Kafka 降级规则（无 metadata 变更才可降级） |
| F3 | `segment format_version=1` | `segment format_version=2`（不兼容档） | v0 读 v1 | 拒绝启动或拒绝该 segment；`SEGMENT_VERSION_TOO_NEW` | 错误**必须含文件路径 + version 值** | NSQ `LoadMetadata` 解析失败报错先例 |
| F4 | metadata log `MMML v1` | `MMML v2` | v0 读 v1 | 同 F3；未知 record type 按 version 规则处理 | 同 F3 | Kafka `MetadataVersion` 布尔位 |
| F5 | client protocol v0 | broker protocol v1 | 旧客户端 | 协商降级，或以 `UNSUPPORTED_VERSION`（`0x0004`）拒绝 | 错误码必须可行动（RocketMQ #504 教训） | — |
| F6 | 混合滚动中的 broker | leader v1 / follower v0 | 复制流 | 复制协议取 `min(双方版本)`；记录 deprecation 警告 | 警告必须点名双方版本 | Kafka 滚动升级逐台先例（`upgrade.md:94`） |
| R1 | 兼容档 | v2 → v1 | 回滚 | 允许；先跑降级前置检查 | — | RabbitMQ `COMPATIBILITY` 区间记法；Kafka `upgrade.md:96` |
| R2 | 不兼容档 | v2 → v1 | 回滚 | **拒绝**，并点名哪些 metadata 变更不可逆 | 必须列出不可逆项 | KIP-848（采用新协议后只能降级到 3.4.1+）；Kafka `upgrade.md:294` |

### 最该读懂的两个方向

**F3 才是关键。** 不兼容读不是「先把数据写坏再说」，而是一次**拒绝**，而且这次拒绝必须**可行动**：不给文件路径和版本号，运维面对 64 MiB 的 segment 根本不知道是哪一个出问题。这就是为什么「诊断要求」是硬性要求而不是锦上添花。

**R2 是诚实边界。** 不是每次降级都可能，假装可以正是集群被搞挂的方式。R2 **按设计拒绝**，并点名不可逆变更 —— 与[威胁模型](../concepts/security.md)里「诚实边界」是同一套纪律。

## `finalize` 语义

> 占位：复制流的 `finalize` 规则尚未定义；升级是两阶段的（Kafka 滚动升级模型）。

## 降级前置检查

- [ ] `wire_version` 未递增
- [ ] segment / 元数据 `format_version` 仍在兼容档内
- [ ] 没有残留的 `quarantine/` 目录
- [ ] 档位边界之后没有新增的 metadata record type（否则 R2 在这一行就该拒绝）

::: warning 目前还没有代码
今天没有二进制可以升级。这张矩阵是**发布门禁** —— 升级矩阵脚本落地后，这 8 个 case 进 CI，任一行红就阻断发布。
:::
