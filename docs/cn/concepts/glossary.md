# 术语表

MortarMQ 术语与命名的活页词典。执行规则只有一条：**同义同名、异义异名**。

## 1. 磁盘格式魔数

规则：`MM` 前缀 + 2–3 字母类别码。每一种持久化文件格式都有自己的魔数；魔数永不复用，版本字段紧跟在魔数之后。**新格式必须先登记进本表，再动手实现。**

| 魔数 | 文件 | 助记 |
|---|---|---|
| `MMQS` | 分区 segment（消息日志段） | **Q**ueue **S**egment |
| `MMQC` | 分区 checkpoint | **Q**ueue **C**heckpoint |
| `MMML` | 元数据日志（事实来源 metadata log） | **M**eta **M**utation **L**og |
| `MMMS` | 元数据快照（`mmms-<offset>-<epoch>.bin`） | **M**eta Meta**s**tate |
| `MMLQ` | 投递台账（`delivery.mql`） | **L**edger（**Q**ueue 投递语义） |
| `MMCU` | 游标 checkpoint（`cursor.mqc`） | **Cu**rsor |
| `MMDL` | DLQ 信封 | **D**ead **L**etter |
| `MMCUP` | Follower 追赶状态 | **C**atch-**up** |

> 历史勘误：对象图曾把 `MMQS` 误写成 `MMRS`（2026-10-01 已更正）。这张表就是抓这类错误的标尺。

## 2. Epoch / 序号命名

本项目里最容易搞混的几组命名：

| 术语 | 语义 |
|---|---|
| `cluster_epoch` | 静态成员**配置**的版本 |
| `leader_epoch` | 复制组 leader 版本（Prepare/Install 后递增）；**围栏（fencing）边界** |
| `promised_leader_epoch` | 本地持久化的 promise 水位 |
| `membership_epoch` | **成员集合**的版本（加入/离开/订阅变更时递增） |
| `assignment_epoch` | 目标分配（target assignment）的版本 |
| `installed_assignment_epoch` | **成员实际已装载**的分配版本（⚠️ 原名 `member_epoch`；2026-10-01 改名，因为它与 `membership_epoch` 只差 4 个字符、语义却完全正交。线上字段名仍为 `assignment_epoch`） |
| `ownership_epoch` | 单分区归属版本（**消费侧**围栏） |
| `cursor_epoch` | 游标 checkpoint 版本 |
| `mutation_id` | 单调递增的元数据变更序号（故障切换下限） |
| `commit_seq` / `visible_seq` | quorum 提交点 / 消费者可见上界 |
| `last_appended` / `flushed_seq` | 本地写入点 / 本地持久化点 |
| `ack_floor` / `next_scan` / `first_retained_seq` | 连续 ack 水位 / 扫描位置 / 保留起始位 |
| `delivery_id` | 一次投递实例的 id（**消费侧**围栏 —— **不是**业务幂等键） |
| `producer_id` / `producer_seq` | 生产者幂等键（业务去重用这一对，**不要**用 `delivery_id`） |

## 3. ID 体系对照表

本站正文中反复出现的编号。每一个都由随站发布的页面定义，或标注在随站发布的页面上 —— 文档里的编号不指向本仓库之外的任何文档。

| 前缀 | 含义 |
|---|---|
| `UC1`–`UC12` | 用例（[图集](./diagrams/)） |
| `INV-001`…`INV-014` | 不变量登记册（三条方法论的单一事实来源） |
| CM / CB / CL / CF / CS / CQ | 性质套件：指标守恒 / rebalance / 时钟 / 帧 / 客户端状态机 / quorum 一致性 |
| Golden n | 各组件的黄金用例 |
| `P0` / `P1` / `P2` | 优先级层：P0 阻断依赖它的工作，P1 必须在那项工作开始前收口，P2 需要先跑探针 |
| `0x0/2/4/6xxx` | 错误码四段（协议 / 元数据 / 背压 / 复制）—— 见[错误码注册表](../reference/errors.md) |

## 4. 待补清单

以下条目随实现稳定后补入：配置白名单的 18 个键名、15 个指标名、7 个 CLI 命令的 TSV 列名。三者都是机器可读的；本词典只收在对话中反复出现的缩写。
