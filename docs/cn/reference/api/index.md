# API 参考

给客户端作者与二次开发者查的公共 API。

> **状态：** 占位 —— 本目录在 codec 与客户端接口冻结后，由 CI 里的 `moon doc` 生成。

## 当前公共接口面（人工速览）

- `protocol` 包：线协议常量（`MAX_FRAME_LEN` 等 8 项）与分段的 `ErrCode` 注册表（`ErrCode::from_u16` / `ErrCode#to_u16`）。
- 其余各包随实现落地由 `moon doc` 补入。
