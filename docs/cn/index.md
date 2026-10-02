---
layout: home

hero:
  name: MortarMQ
  text: 用 MoonBit 原生实现的消息队列
  tagline: 完整 MQ 闭环 —— 协议接入、生产/消费、分区 topic、at-least-once 投递（DLQ）、持久化崩溃恢复
  actions:
    - theme: brand
      text: 快速开始
      link: /cn/getting-started/quickstart
    - theme: alt
      text: 线协议（v0）
      link: /cn/reference/protocol
    - theme: alt
      text: 30 秒演示
      link: /demo/

features:
  - title: 15 op 线协议
    details: 9 核心 + 6 扩展；帧格式 [u32_be len][u8 op][payload]；四段式错误码注册表；codec golden 用例全绿是准入门槛。
  - title: at-least-once 投递
    details: 投递台账与消息记录分离；5 次重试后进 DLQ；kill -9 后的重放恢复由确定性仿真把关。
  - title: 增量 rebalance
    details: broker 侧协调器；membership / assignment / epoch 三层版本；只有受影响的分区才会移动。
  - title: 诚实的边界
    details: v0 不含 TLS / 热加载 / authz / Raft 元数据 —— 每一项裁剪都附带文档化的升级路径。
---

## 本站按「你要做什么」组织，而不是按「你是谁」

每一章是一种**性质不同**的文档。找到匹配你当前任务的那一章，其余可以跳过。

| 章节 | 什么时候读 | 从这里开始 |
|---|---|---|
| **[入门](./getting-started/index.md)** | 想最快跑通一个闭环 | [快速开始](./getting-started/quickstart.md) |
| **[核心概念](./concepts/index.md)** | 想弄懂系统为什么这么表现 | [架构](./concepts/architecture.md) |
| **[使用指南](./guides/index.md)** | 有具体的运维任务：部署、升级、恢复 | [故障处置手册](./guides/runbook.md) |
| **[参考手册](./reference/index.md)** | 要查一个确切的值：帧布局、配置项、退出码 | [线协议](./reference/protocol.md) |
| **[开发](./develop/index.md)** | 要改代码或提 PR | [测试](./develop/testing.md) |

第一次来？按 **快速开始 → 架构 → 回到本表** 走。

::: tip 关于翻译
中英是**两棵平行树**：[`/cn/`](./index.md) 与 [`/en/`](../en/index.md) 同名文件两边都有，`/` 是语言选择页，谁也不占根。**代码围栏**（mermaid、ASCII 时间线、规范记法）与 **`reference/` 章的表格**在两种语言下都保持英文（标识符、配置键、CLI 子命令与错误码统一用英文，这是项目惯例）。
:::
