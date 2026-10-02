# 使用指南

任务导向的操作说明。每一页只回答一个「我该怎么……」的问题，并且默认你已经知道 topic、consumer group 和 epoch 是什么 —— 不知道就先读 [核心概念](../concepts/index.md)。

与 [入门](../getting-started/index.md) 不同，本章各页**没有先后顺序**。在表里找到你的任务，做完，离开。

## 本章内容

| 我想…… | 页面 |
|---|---|
| 承载真实流量之前把每一行勾掉 | [生产就绪清单](./production-checklist.md) |
| 架起 3 节点集群 —— 端口、启动顺序、验证 | [部署集群](./deploy-cluster.md) |
| 处理 broker 故障 —— quorum 丢失、元数据隔离、`kill -9` 恢复 | [故障处置手册](./runbook.md) |
| 把一个错误码变成一个修法 | [故障排查](./troubleshooting.md) |
| 不打断客户端地升级或回滚 | [升级与回滚](./upgrade.md) |
| 正确地写生产者 / 消费者 | [最佳实践](./best-practices.md) |
| 要一个是/否的行为答案 | [常见问题](./faq.md) |

## 计划中的页面

- **管理 topic 与 consumer group** —— 创建、列出、查看、删除
- **观测** —— 怎么读 15 项指标白名单、该对什么告警
- **备份与恢复** —— segment 文件、元数据日志与快照

## 相关章节

- 精确的命令语法与退出码：[命令行](../reference/cli.md)
- 指标名称、类型与守恒关系：[指标](../reference/metrics.md)
