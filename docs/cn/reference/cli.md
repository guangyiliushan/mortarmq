# 命令行（CLI）

运维与脚本如何驱动 `mortarmq` CLI —— 7 个命令、稳定的 TSV 列序、退出码与 `--api-version`。

> **事实来源：** 设计已冻结；CLI 落地之前没有任何命令可执行。

## 看退出码，别看文字

```bash
mortarmq topics list --topic orders >/dev/null 2>&1
case $? in
  0) echo "成功" ;;
  2) echo "参数错 —— 改调用方式" ;;
  3) echo "服务不可达 —— broker 起了吗" ;;
  4) echo "服务端拒绝 —— 看错误文本" ;;
esac
```

四个码，各一个含义：**0** 成功 · **2** 参数错 · **3** 服务不可达 · **4** 服务端拒绝。脚本分支看 `$?`，人读文本 —— 两者必须一致。

## 7 个命令

| 命令 | 参数 | 作用 | 后端通道 | 输出格式（TSV 列序） | 退出码 |
|---|---|---|---|---|---|
| `mortarmq topics create <name> --partitions N` | `--partitions` 默认取配置 | 创建 topic（幂等） | wire `DECLARE` | `created` \| `existed` \| `mismatch` + `topic_id` | 0 / 4 |
| `mortarmq topics delete <name>` | — | tombstone 删除 | wire `DECLARE(del)` | `deleted` \| `not_found` | 0 / 4 |
| `mortarmq topics list` | — | 列出全部 topic | admin HTTP | `name` `partitions` `state` `created_epoch` | 0 / 3 |
| `mortarmq groups list [--topic T]` | `--topic` 可选过滤 | 列出消费组 | admin HTTP | `group` `topic` `lag` `state` | 0 / 3 |
| `mortarmq groups describe <g>` | — | 组成员 / assignment / epoch 明细 | admin HTTP | `member` `assignment_epoch` `ownership_epoch` `lag` | 0 / 3 / 4 |
| `mortarmq leader get` | — | 当前 leader 与 quorum 状态 | admin HTTP | `leader_id` `leader_epoch` `quorum_state` | 0 / 3 |
| `mortarmq broker status` | — | 本节点连接数 / uptime / 版本 | admin HTTP | `node_id` `uptime_s` `connections` `version` | 0 / 3 |

## 输出与版本规则

- **默认 TSV**，按需 `--json`。上表列序**永不变** —— golden 测试逐命令锁死，按位置解析的脚本因此一直能用。
- 改列序必须 bump `--api-version`。
- 写路径（`topics create` / `delete`）复用线协议，读路径走 admin HTTP。这个切分正是两组命令失败模式不同的原因：写可能失败于 `4`（服务端拒绝），读只会失败于 `3`（不可达）。

::: warning 目前还没有代码
今天没有任何命令能跑。这张表是**契约** —— CLI 落地时，这七个命令、它们的列序与退出码就是验收线。
:::
