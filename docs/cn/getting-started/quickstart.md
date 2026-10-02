# 快速开始

跑通一个 MortarMQ 闭环。本页是**教程** —— 从头读到尾，不要跳步。

> **状态：** 第 1 步今天就能跑；第 2–5 步是 broker 落地时必须兑现的契约。每个未实现的步骤都写清了**成功长什么样**，这样它上线那天你能自己验证。

## 开始之前

| 需要 | 为什么 | 怎么检查 |
|---|---|---|
| MoonBit 工具链 `moonc >= 0.10.14` | 这里的一切都靠它编译 | `moon version --all` |
| Git | 用来 clone | `git --version` |
| 一个现代浏览器 | 只有第 5 步需要 | — |

除此之外什么都不用。没有数据库，没有 ZooKeeper，没有 Docker。

## 第 1 步：克隆并验证工具链（现在就能跑）

```bash
git clone https://github.com/guangyiliushan/mortarmq
cd mortarmq
moon check --deny-warn --target all
moon test
```

**你会看到：**

```text
# moon test → 全绿
# protocol 包的 golden 套件与性质测试是准入门槛：
#   - 错误码注册表锁（每个已注册码都在，无空洞）
#   - 常量锁（MAX_FRAME_LEN 之类不会悄悄漂移）
#   - 解码单射性质（seed=20261001）
```

这一步 `moon test` 就是红的，**停下来** —— 后面一切都建立在这套测试是绿的之上。

## 第 2 步：启动 3 节点 broker（契约）

```bash
# not runnable yet -- the broker package has no main.
```

**怎么算成功：**

```bash
mortarmq broker status
# 期望：node_id  uptime_s  connections  version
#       uptime_s > 0，version 与你刚启动的二进制一致
```

> **进程起来了 ≠ 节点加入了。** `broker status` 回答「它起来了吗」，只有 `leader get` 回答「它进 quorum 了吗」。

```bash
mortarmq leader get
# 期望：leader_id  leader_epoch  quorum_state=0
```

`quorum_state=0` 是健康。`1` 是有 follower 落后，`2` 是只读 —— 两种都在[故障处置手册](../guides/runbook.md)里有处置步骤。

## 第 3 步：建 topic 并发布（契约）

```bash
mortarmq topics create orders --partitions 4
# 期望：created | existed   + topic_id
# 成功退出码 0，服务端拒绝为 4
```

```bash
# 用客户端库发一条消息，然后：
mortarmq topics list
# 期望列：name  partitions  state  created_epoch
#   orders  4  active  1
```

**怎么算成功：** `state=active`，且 `/metrics` 上 `mortarmq_topic_messages_produced_total{topic="orders"}` 读出来是 `1`。

## 第 4 步：消费它（契约）

```bash
# 消费者加入组 "billing"，拉取并 ACK
# 期望：正常路径下这条消息只到一次；
#       若 broker 在途重启，它可能再来一次 —— 这是 at-least-once，
#       不是 bug（见「消息语义保证」）
```

**怎么算成功：**

```text
mortarmq_group_lag{topic="orders",group="billing"}  0   ← 已消费完
mortarmq_topic_messages_delivered_total{topic="orders"}  1
```

`lag` 回到 `0`，就是闭环打通的信号。

## 第 5 步：浏览器 demo（契约）

demo 页随本站发布在 `/demo/`，通过 `ws://` 连接。有两个配置键卡着它，而且**默认都是关的**：

```json
{ "listen_ws": "0.0.0.0:7188", "ws_origins": ["http://localhost:4173"] }
```

空的 `ws_origins` 是**拒绝所有**来源，不是「全部允许」。见[故障排查 §6](../guides/troubleshooting.md#_6-浏览器-demo-连不上)。

## 刚刚发生了什么

`topics create` 是幂等的 `DECLARE` —— 跑两次返回 `existed` 而不是报错。发布走 15 op 线协议，在返回 `PUB_OK` 之前已经 fsync 并复制到多数派；消费者的 `ACK` 推进 `ack_floor`，而 `partition_depth` 正是拿它做差算出来的。

## 第一次跑常见问题

| 现象 | 原因 | 怎么修 |
|---|---|---|
| `moon: command not found` | 工具链不在 `PATH` | 到 <https://cli.moonbitlang.com> 重装 |
| 第 1 步 `moon test` 红 | 本地状态坏了，或真是回归 | `moon clean && moon test`；仍红就提 issue |
| 第 2 步 `unknown key: listen_https` | 配置里有 18 键白名单之外的键 | [故障排查 §1](../guides/troubleshooting.md#_1-启动被拒-unknown-key) |
| 第 3 步 `0x0008 UNKNOWN_TOPIC` | SUB 不隐式 DECLARE | 先跑 `topics create` —— [故障排查 §2](../guides/troubleshooting.md#_2-0x0008-unknown-topic) |

## 接下来

- 搞懂刚刚发生了什么 → [基础概念](../concepts/basics.md)
- 真的把它部署起来 → [部署集群](../guides/deploy-cluster.md)
- 查一个确切的值 → [参考手册](../reference/index.md)
