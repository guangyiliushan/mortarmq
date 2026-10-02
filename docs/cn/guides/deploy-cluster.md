# 部署 3 节点集群

如何架起一个 3 节点 MortarMQ 集群 —— 拓扑、端口、启动顺序，以及每一步怎么确认成功。

> **事实来源：** 端口、配置键与 peer 表来自[配置白名单](../reference/configuration.md)。命令在 broker 可执行文件落地前标 `TODO`。

## 先选拓扑

MortarMQ v0 **只支持一种**拓扑。这是刻意裁剪，不是遗漏：

| 拓扑 | v0 | 为什么 |
|---|---|---|
| 单节点 | ✅ 仅开发 | 没有 quorum，`durability=quorum` 无意义 —— 演示可以，正经数据不行 |
| **3 节点静态集群** | ✅ **支持** | 多数派 fsync quorum；「能扛住一台挂掉」真正成立的最小规模 |
| 5+ 节点 | ❌ | `min ISR` 抬高写路径成本，v0 换不来好处 |
| 动态成员（运行时增删节点） | ❌ v2 | Redpanda 的 members 管理已经证明这有多复杂 —— 见 `peers` |

**你接受的取舍：** peer 表是静态的。加第四台要改配置 + 重启，而不是发一个 join 请求。

## 端口

| 键 | 默认值 | 绑定 | 承载 |
|---|---|---|---|
| `listen_client` | `0.0.0.0:7188` | 所有网卡 | 客户端线协议（生产者、消费者、CLI 写路径） |
| `listen_peer` | `0.0.0.0:7189` | 所有网卡 | 复制 + 心跳 —— **绝不**对客户端开放 |
| `listen_admin` | `127.0.0.1:7190` | **仅本机** | `/metrics` `/healthz` `/stats` + CLI 读路径 |
| `listen_ws` | 未启用 | — | 浏览器 demo 的 WebSocket；需显式开启 |

admin 只绑本机不是图方便 —— 它是把观测面挡在网外的那道控制（见[威胁模型](../concepts/security.md)）。`listen_peer` 单独一个端口，是为了让你能把复制流量和客户端流量分开防火墙隔离。

## 启动顺序

**1) 每台写配置** —— 各自不同的 `node_id`，三台用**同一张** 3 项 `peers` 表；若共用一台主机，`listen_*` 端口要错开。

```bash
# TODO: 每节点一份 config.json；全部 18 个键见 reference/configuration
```

**2) 启动三个 broker**

```bash
# not runnable yet -- the broker package has no main.
```

**3) 验证每台都起来了** —— 这一步最容易被跳过：

```bash
# TODO: mortarmq broker status
# 期望：node_id  uptime_s  connections  version  —— uptime_s > 0，version 与二进制一致
```

> **验证规矩：** 进程起来了 ≠ 节点加入了。`broker status` 回答「它起来了吗」；只有下一条命令回答「它进集群了吗」。

**4) 验证 quorum 并找出 leader**

```bash
# TODO: mortarmq leader get
# 期望：leader_id  leader_epoch  quorum_state=0
```

`quorum_state=0` 为健康；`1` 表示有 follower 落后（仍可写），`2` 表示只读 —— 每种情况怎么处理见 [RB-1](./runbook.md#rb-1-quorum-降级-→-只读)。

**5) 然后建 topic、发一条消息** —— 见[快速开始](../getting-started/quickstart.md)。

## 停机顺序

先停 follower，最后停 leader。先停 leader 会触发一次选举 —— 能工作，但会多一次 epoch 递增，你还得在 `leader get` 输出里解释它。

## 常见部署错误

- **把 `listen_peer` 暴露到公网。** 它跑的是复制流量：独立共享密钥、**没有**客户端认证。防火墙挡掉。
- **三台共用一个 `data_dir`。** 它们会互相破坏对方的 segment。
- **跳过第 3 步。** `nohup` 返回不等于成功 —— 去看 `uptime_s`。
- **为了看仪表盘方便把 `listen_admin` 绑到 `0.0.0.0`。** v0 的指标面**没有认证**。

::: warning 目前还没有代码
上面没有一条命令今天能跑。已经定死的是：拓扑选择、四个端口、绑定地址，以及每一步必须做的验证。命令是 broker 必须兑现的契约。
:::
