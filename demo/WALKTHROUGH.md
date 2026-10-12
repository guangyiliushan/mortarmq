# 浏览器 Demo 五分钟走查

按本清单走一遍 `demo/index.html`：先跑脚本化四步拿输出，再按手操表逐格对照画面。
无 broker 时全程走第 7 步降级路径（如实入包，不装死）。有 broker 时按 QUICKSTART 启动
集群，并确认两个配置键（默认都是关的）：

```json
{ "listen_ws": "0.0.0.0:7188", "ws_origins": ["http://localhost:4173"] }
```

空的 `ws_origins` 是拒绝所有来源。

## 一、脚本化证据

**A. 宿主桥与线协议面测**

```
moon test --target js -p js_main
→ Total tests: 5, passed: 5, failed: 0
```

覆盖：宿主 Promise 桥双向、状态机名映射、编解码往返、调用链解析。

**B. demo 构建配方**

```
moon build --target js ./client/js_main
→ Finished.
```

产物 `_build/js/debug/build/client/js_main/js_main.js`（ESM，五个导出）。
构建产物不入库；本地开发由页面自动回退到该路径。

**C. 宿主调用链冒烟**

```
node --input-type=module -e "import('./_build/js/debug/build/client/js_main/js_main.js').then(async m => { console.log(await m.demo_chain()); })"
→ chain ok: Disconnected->Connecting->Authenticating->Ready; declare frame 17 bytes
```

**D. 静态服务**

```
npx -y http-server <仓库根> -p 4173 -c-1
GET /demo/ → 200
GET /_build/js/debug/build/client/js_main/js_main.js → 200
```

## 二、浏览器手操走查

| # | 操作 | 预期画面 |
|---|---|---|
| 1 | 打开 `http://localhost:4173/demo/` | 标题与四徽章；绿条「宿主桥调用链：chain ok: …; declare frame 17 bytes」；七态芯片 Disconnected 高亮；DECLARE/PUB 按钮可用 |
| 2 | 点「连接」 | 芯片走 Connecting→Authenticating；状态徽章「已连接」 |
| 3 | 填 topic=orders、分区数=3，点「DECLARE」 | 流表 send 行「DECLARE orders x3」；回包行「OK」 |
| 4 | 填 topic_id=1、key=user-42、value=hello，点「PUB」 | 流表 send 行；回包行「OK」 |
| 5 | 消息回流（QUICKSTART 消费回路或第二客户端） | 流表 recv 行「MSG seq=… key=… value=…」；p50/p90 延迟条随样本更新 |
| 6 | 点「断开」 | 芯片回 Disconnected；徽章「未连接」 |
| 7 | 无 broker：点「连接」 | Connecting→**Backoff 高亮**（传输失败边，已实测）；徽章「未连接」；页脚降级说明在位 |

第 1、7 步为浏览器实测画面；第 2–6 步的 broker 联动态按 QUICKSTART 契约列预期。

## 三、形制与诚实边界

- 客户端模块是构建产物，**不入库**（`_build/`、复制出的 `client_js_main.js` 均不提交）；
  页面缺件时转只读并显示构建配方，不隐藏缺口。
- 页脚三固化：`listen_ws` / `ws_origins` 默认关与空源语义；WS 监听缺席时的降级路径
  （ws-tcp 桥）标注为路线图项；模块构建配方一行。
- 状态机与线协议编解码全部来自随附模块（单一事实源）；页面只做 DOM 与 WebSocket 胶水。
