# 测试

测试金字塔怎么跑 —— 单元 / golden / 性质 / 仿真 / 模型检查 / 升级矩阵，以及每一层必须跨过的门槛。

> **状态：** 骨架页；仿真台架与性质套件随实现增量落地。

## 金字塔与当前状态

| 层 | 手段 | 怎么跑 | 门槛 | 状态 |
|---|---|---|---|---|
| L1 单元 / golden | codec golden 帧、注册表锁 | `moon test` | 全绿 | ✅ 协议错误码注册表锁 / 常量锁 |
| L2 性质 | `@quickcheck`（seed/count 固定） | `moon test`（seed 已提交） | 每日条数增长单独分层 | ✅ 解码单射（seed=20261001）+ 帧编解码 CF1-CF4（钉 seed 20261010-13）；CF4 每日档以落日志的 run 唯一 seed 跑 count=1000 |
| 仿真 | Clock/Net/Disk/Rng trait + buggify | seed 重放 | repro_rate=100%；≥ 10 个回归 seed | ⬜ 待实现 |
| 模型检查 | `fencing.qnt` / `lease.qnt` / `protocol.qnt`（quint 0.33.0） | `quint parse` / `typecheck` / `run --invariant=...` | fencing 双不变量 MaxSeq=4 全绿 | ✅ fencing 双不变量（`promiseCoversEveryAppliedEntry`、`appliedIsPrefix`）实跑绿；lease 与 protocol parse/typecheck 过（protocol 仍是骨架）；`quint verify`（Apalache）此处未实跑 |
| L4 升级矩阵 | 8-case 脚本 | CI / 手动 | 矩阵全绿 | ⬜ 待实现 |

## 复现纪律

- 任何失败的 seed 在重放时必须**逐位复现**（验收场景 ③）；回归 seed 冻结进 `test/m1/regression/`。
