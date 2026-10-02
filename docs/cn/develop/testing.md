# 测试

测试金字塔怎么跑 —— 单元 / golden / 性质 / 仿真 / 模型检查 / 升级矩阵，以及每一层必须跨过的门槛。

> **状态：** 骨架页；仿真台架与性质套件随实现增量落地。

## 金字塔与当前状态

| 层 | 手段 | 怎么跑 | 门槛 | 状态 |
|---|---|---|---|---|
| L1 单元 / golden | codec golden 帧、注册表锁 | `moon test` | 全绿 | ✅ 协议错误码注册表锁 / 常量锁 |
| L2 性质 | `@quickcheck`（seed/count 固定） | `moon test`（seed 已提交） | 每日条数增长单独分层 | ✅ 解码单射性质（seed=20261001） |
| 仿真 | Clock/Net/Disk/Rng trait + buggify | seed 重放 | repro_rate=100%；≥ 10 个回归 seed | ⬜ 待实现 |
| 模型检查 | `protocol.qnt` / `lease.qnt`（quint） | `quint verify` | MaxSeq=4 全绿 | ⬜ 待实现 |
| L4 升级矩阵 | 8-case 脚本 | CI / 手动 | 矩阵全绿 | ⬜ 待实现 |

## 复现纪律

- 任何失败的 seed 在重放时必须**逐位复现**（验收场景 ③）；回归 seed 冻结进 `test/m1/regression/`。
