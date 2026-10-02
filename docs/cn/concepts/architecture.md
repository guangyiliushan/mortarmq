# 架构

各模块如何拼在一起、哪些依赖规则让它们保持解耦，以及完整图集在哪。

## 你现在在哪个包里？

先看你想改的是什么，然后**只**进一个包：

| 如果你要改… | 你在 | 因为 |
|---|---|---|
| 帧格式、某个 op、某个错误码 | `protocol/` | 它是唯一事实来源；其他包只能消费它，谁都不许自己定义一套 |
| 字节怎么落盘 —— segment、索引、checkpoint | `storage/` | 刻意做成独立可复用，对 topic 一无所知 |
| topic 名、分区、路由、消费者组 | `broker/` | 持有内存视图；自己从不写字节 |
| 复制、lease、选举 | `cluster/` | 只走 `listen_peer` —— 刻意与客户端端口分开 |
| 客户端库的任何行为 | `client/` | 一个库，三种形态（native / JS backend / wasm-gc 纯核心） |
| 基准测试或 `kill -9` 注入 | `bench/` | 仅测试用；生产代码不得 import 它 |
| 开发工具（`hash-token`、dump） | `tools/` | 永不在热路径上 |

如果你的改动需要**两个**包，那是接缝错了的信号 —— 加新 import 之前先看下面的依赖规则。

## 源码包布局

| 包 | 职责 | 关键设计 |
|---|---|---|
| `protocol/` | 帧编解码 + op 状态机（目标：< 32 KB 逻辑） | 唯一事实来源；golden 帧 |
| `storage/` | segment 日志引擎（独立、可复用） | 64 MiB 轮转 + 稀疏索引 + 原子 checkpoint |
| `broker/` | topic / 分区 / 消费者组 / 路由 | 不可变路由快照 |
| `cluster/` | quorum 复制 + 静态成员 + lease | 多数派 fsync；epoch 围栏 |
| `client/` | 客户端库，三种形态 | native / JS backend / wasm-gc 纯核心 |
| `bench/` | 基准测试 + `kill -9` 注入 | 基准矩阵 |
| `tools/` | 开发工具：hash-token、dump 之类 | — |

## 模块依赖规则（import 断言）

- 只允许单向：`storage` / `broker` / `cluster` / `client` → `protocol`。横切抽象（`Conn` / `Clock` / `Net` / `Disk` / `Rng`）一律走 trait。
- `moon info --target …` 的 diff 门禁就是 import 断言的执行者；白名单之外的依赖不得合入。

## 图集（Mermaid）

四个页面，按「各自回答什么问题」分组 —— 完整清单见[图集索引](./diagrams/)，其中也标了哪些散文表格承载着图里没有的信息。

1. [用例与流程](./diagrams/use-cases-and-flows.md) —— 角色 × 目标，发布与消费的控制流
2. [关键时序](./diagrams/sequences.md) —— 发布→投递、增量 rebalance、lease 超时选举
3. [状态、时限与不变量](./diagrams/states-timing-invariants.md) —— 三台状态机、延迟预算、运行时快照
4. [结构](./diagrams/structure.md) —— 包级拆分、依赖规则、核心类型
