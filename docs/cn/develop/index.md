# 开发

写给要改代码的人：模块怎么接线、测试金字塔怎么跑、性能结论允许写成什么样子。

贡献者流程（分支模型、提交格式、CLA、PR 检查单）放在仓库根目录的 [CONTRIBUTING.md](https://github.com/guangyiliushan/mortarmq/blob/main/CONTRIBUTING.md) —— GitHub 会在 PR 侧栏渲染它。

## 本章内容

| 页面 | 你会得到什么 |
|---|---|
| [测试](./testing.md) | 测试金字塔 —— 单元、golden、性质、仿真、模型检查、升级矩阵 —— 以及复现纪律 |
| [基准测试](./benchmarks.md) | 基准矩阵、噪声控制协议、以及下结论的规则 |

## 计划中的页面

- **模块边界与扩展点** —— 如何新增一个 op、一个指标或一个配置键而不破坏白名单
- **存储内部** —— segment 格式、稀疏索引、checkpoint 重放

## 相关章节

- 包布局与依赖规则：[架构](../concepts/architecture.md)
- 设计背后的图：[图集](../concepts/diagrams/index.md)
