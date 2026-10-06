# API 参考

给客户端作者与二次开发者查的公共 API。

> **状态：** 占位 —— 本目录在客户端接口冻结后，由 CI 里的 `moon doc` 生成。`Op` 与帧边界 codec 接口已可用，并由 `moon info` 锁定。

## 当前公共接口面（人工速览）

- `protocol` 包：线协议常量（`MAX_FRAME_LEN`、`MAX_OK_RESULT_LEN` 等 9 项）与分段的 `ErrCode` 注册表（`ErrCode::from_uint16` / `ErrCode#to_uint16`）。
- `protocol` 包：`Op` 通过 `Op::from_byte` / `Op#to_byte` 映射 15 个已分配操作字节；保留字节一律返回 `None`。
- `protocol` 包：`decode_frame` 返回 `Need`、借用视图的 `Frame` 或 `DecodeError`；未知 op 在五字节帧头可见时立即拒绝。
- `protocol` 包：`WirePayload` 覆盖全部 15 个 op 的请求、响应和推送 payload；`decode_wire_payload` / `encode_wire_payload` 执行字段序、边界、尾字节和 op 匹配检查。
- `protocol` 包：`decode_ws_message` 解码 websocket 帧子集（仅二进制数据帧，按 `WsPeer` 方向校验），返回 `Need`、借用视图的 `Message`、`PeerClose` 或 `WsError`；`encode_ws_binary_frame` 与 `encode_ws_close_frame` 生成服务端帧。
- `storage` 包：v0 记录头使用 56 字节冻结布局；`decode_record_header` 校验长度一致、value 上限、保留位与 replication kind。
- `storage` 包：`validate_segment_identity` 校验 `MMQS`、format version 和 header version。
- `storage` 包：`encode_record_header` 计算 CRC32C；`decode_record_header` 验证 CRC、key-present 一致性、长度、value 上限、保留位和 replication kind。
- `harness` 包：提供确定性 `FakeClock`、`FakeNet`、`FakeDisk` 与 `SplitMix64`，覆盖虚拟时间、FIFO 投递、能力感知故障和可复现随机数。
- `harness` 包：`SimEnv` 以单个种子打包时钟、网络、磁盘与随机流；`reproducible` 在两个同种子新环境上各跑一遍场景并报告是否一致。
- `broker` 包：`TopicRegistry` 保存 DECLARE 背后的内存态 topic 元数据；`declare_topic` 幂等重放相同声明，并拒绝分区数不一致的声明。
- `net` 包：`Conn` trait（`read_exact` / `write_all` / `close`）是 broker 与 cluster 的字节管道接缝；`net/tcp` 子包提供 native `TcpConn` 传输与 `connect`。
- client、broker、storage runtime、cluster、tools、bench 等接口随实现落地由 `moon doc` 补入。
