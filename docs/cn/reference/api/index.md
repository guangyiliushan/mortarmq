# API 参考

给客户端作者与二次开发者查的公共 API。

> **状态：** 占位 —— 本目录在客户端接口冻结后，由 CI 里的 `moon doc` 生成。`Op` 与帧边界 codec 接口已可用，并由 `moon info` 锁定。

## 当前公共接口面（人工速览）

- `protocol` 包：线协议常量（`MAX_FRAME_LEN` 等 8 项）与分段的 `ErrCode` 注册表（`ErrCode::from_u16` / `ErrCode#to_u16`）。
- `protocol` 包：`Op` 通过 `Op::from_byte` / `Op#to_byte` 映射 15 个已分配操作字节；保留字节一律返回 `None`。
- `protocol` 包：`decode_frame` 返回 `Need`、借用视图的 `Frame` 或 `DecodeError`；未知 op 在五字节帧头可见时立即拒绝。
- `protocol` 包：`WirePayload` 覆盖全部 15 个 op 的请求、响应和推送 payload；`decode_wire_payload` / `encode_wire_payload` 执行字段序、边界、尾字节和 op 匹配检查。
- 其余各包随实现落地由 `moon doc` 补入。
