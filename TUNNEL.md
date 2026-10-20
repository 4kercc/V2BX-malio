# V2bX 原生加密隧道（V2bX Native Encrypted Tunnel）

版本：v1.4.2 · 兼容端：nyanpass `impl/lib/v2bx_tunnel.js`

在不增加独立出口服务器的前提下，让 nyanpass 入口直接与落地 V2bX 建立一条
**带密码认证的加密隧道**，在 AnyTLS 之前再加一层 AEAD 加密，并把真实客户端 IP
（PROXY protocol v2）透传给 AnyTLS 入站，设备数限制、审计和流量统计保持按真实 IP 计算。

## 1. 分层结构

```
客户端 ──AnyTLS(TLS)──▶ nyanpass 入口
                          │
                          │  外层：ws / tls / wss（可选 TLS）
                          │  认证：HKDF-SHA256(密码, 随机盐) → AES-128-GCM 分帧
                          │  防扫：握手帧 "VT01" + 时间戳 + 随机填充（错密即断）
                          ▼
                       V2bX 落地
                          │  解密 → 可选 PROXY v2（真实客户端 IP）
                          ▼
                     AnyTLS 入站（内层 TLS 握手）
                          ▼
                        出站
```

- 外层 TLS 与内层 AnyTLS 的 TLS **完全独立**：内层 ClientHello 对外层只是普通二进制载荷，
  SNI、证书、握手状态机互不冲突（洋葱封装）。
- 推荐 `ws`：比 `tls` 少一次跨国 TLS 握手 RTT，同时 AEAD 已把内层 AnyTLS 的
  ClientHello（含明文 SNI 与指纹）完整加密隐藏。
- 密码错误、时间戳超出 ±5 分钟、帧被篡改都会在 GCM 校验阶段直接断开，不产生任何回显。

## 2. V2bX 配置

在节点 `Options` 中增加 `TunnelConfig`（也可用兼容字段 `TunnelEnable` / `TunnelType` /
`TunnelPassword` / `TunnelWSPath` 平铺写入）：

```json
"TunnelConfig": {
  "Enable": true,
  "Type": "ws-tunnel",
  "Password": "CHANGE_ME_TO_A_LONG_RANDOM_SECRET",
  "WSPath": "/ws",
  "ListenPort": 0,
  "AllowDirect": true,
  "ProxyProtocol": true
}
```

| 字段 | 说明 |
| --- | --- |
| `Enable` | 是否启用；`true` 且 `Password` 非空才真正生效 |
| `Type` | `ws-tunnel`（默认）/ `tls-tunnel` / `ws-tls-tunnel`，也接受 `ws` / `tls` / `wss` |
| `Password` | 预共享密钥，建议 32 字节以上随机串；两端必须一致 |
| `WSPath` | WebSocket 升级路径，默认 `/ws`（常见路径，避免 `/tunnel` 这种特征）；不匹配的 HTTP 探针返回 `404 page not found` |
| `ListenPort` | `0`（或等于节点端口）= 与 AnyTLS **共用**节点端口；其它值 = 隧道独立端口 |
| `AllowDirect` | `true`（默认）：同端口仍接受普通 AnyTLS 客户端直连——**仅 `ws` 模式生效**；`tls` / `wss` 模式外层 TLS 会被隧道接管，该端口为隧道专用（见 §2.1 指纹说明） |
| `ProxyProtocol` | `true`（默认）：接受隧道内 PROXY v2 头并还原真实客户端 IP |

### 同端口模式（`ListenPort: 0`）

sing-box 的 AnyTLS 入站改绑 `127.0.0.1:0`（仅内部使用），对外端口由隧道监听器接管：

- `GET <WSPath>` + `Upgrade: websocket` → WebSocket 隧道（`ws` / `wss`）
- `ws` 模式（无外层 TLS）：TLS ClientHello = 普通 AnyTLS 客户端，原样交给内层 TLS 握手；
  其它流量同理（`AllowDirect=true` 时）
- `tls` / `wss` 模式：外层 TLS 由隧道接管，**该端口为隧道专用**。握手后：
  - `wss`：首个 HTTP 请求路径必须等于 `WSPath`，否则回 `404 page not found`
  - `tls`：首包若是 HTTP 请求（浏览器/扫描器）→ 回 `404 page not found`；否则进入 AEAD 握手
  - 普通 AnyTLS 客户端在 tls/wss 模式下**不能**共用该端口（`AllowDirect` 仅在 `ws` 生效，
    启动日志会给出提示）

### 2.1 指纹与伪装（v1.4.1）

| 位置 | 旧行为（可被识别） | 现在的行为 |
| --- | --- | --- |
| 外层 TLS ALPN | 客户端 ClientHello 里带自定义 `v2bx-tunnel` | **客户端只发标准 ALPN**（`h2`/`http/1.1`）；服务端协商结果落在 `http/1.1`。服务端仅为 v1.4.1 之前的老客户端保留旧 token 作为兜底——它不出现在任何一方的 ClientHello 里，等入口全部升级后可删除 |
| 隧道/直连区分 | 靠 ALPN 标记 | `ws` 模式靠首字节（HTTP vs TLS）；`tls/wss` 模式端口专用，靠 WS 路径 / AEAD 握手（`VT01`）自身 |
| WS 路径 | `/tunnel` | 默认 `/ws`（可配成任意常见路径，如 `/api/ws`、`/socket`） |
| 握手头 | 无 UA、只有最小几个头 | 客户端发送浏览器风格 `User-Agent` / `Accept` / `Accept-Language` / `Cache-Control` / `Pragma` / `Origin` / `Sec-WebSocket-Extensions` |
| HTTPS 探测 | TLS 后直接断开 | `tls` 模式回标准 `404 page not found`，`wss` 模式非匹配路径同样 404，表现为普通站点 |

> **升级注意（v1.4.0 → v1.4.1）**：两端需一起升级。旧客户端带 `v2bx-tunnel` ALPN 连新服务端会
> 因 ALPN 无交集握手失败；默认路径也从 `/tunnel` 改成 `/ws`（配置里显式写了路径的以配置为准）。
> `tls`/`wss` 模式下不再支持同端口直连，需要直连请用 `ws` 模式或另开端口。

`AllowDirect=false` 时请确认客户端不会再直连该端口（例如只把该端口作为中转专用入口）。

### 独立端口模式（`ListenPort` 非 0）

AnyTLS 继续监听节点原端口；隧道监听器额外监听 `ListenIP:ListenPort`，解密后把连接注入同一
AnyTLS 入站（同一个 tag、同一批用户、同一套限速/设备数/流量统计）。

## 3. nyanpass 配置

面板「转发规则」中将协议选择为 `ws` / `tls` / `wss`，填写：

- **V2bX 隧道密码**：与 V2bX `TunnelConfig.Password` 一致
- **隧道 WS 路径**：默认 `/ws`
- **出口节点**：选择 `#0 不使用隧道，直接转发`（入口直接拨入落地 V2bX，无需独立出口机）

保存后 Agent 日志会出现：

```
监听 rule#N :20001 -> 直连 1.2.3.4:443 [V2bX-Tunnel:ws] (ws)
```

MCP 方式：

```
add_forward listen_port=20001 target="1.2.3.4:443" protocol="ws" \
  tunnel_password="..." tunnel_ws_path="/ws" entries="all"
```

`update_forward` 传 `tunnel_password: ""` 可关闭隧道并恢复普通直连。

## 4. 验证

仓库内 `core/sing/tunnel_e2e_test.go` 覆盖：

- `ws` / `tls` / `wss` 三种模式的加解密回环
- PROXY v2 真实客户端 IP 还原（`203.0.113.7:45678`）
- 错误密码必须被拒绝且不触达 AnyTLS 入站
- 外层 TLS 只协商标准 ALPN `http/1.1`（不再有 `v2bx-tunnel` 标记）
- `ws` 模式下普通 AnyTLS 客户端透明直通；`tls` 模式的 HTTPS 探测回标准 404
- 经 nyanpass `Forwarder` 真实转发引擎的端到端回环

运行：

```bash
go test ./core/sing/ -run TestV2bXTunnel -v
```

nyanpass 侧：

```bash
node impl/test/tunnel.js
```

## 5. 安全说明

- 隧道密码只用于 HKDF，不参与明文传输；每连接随机 16 字节盐，双向密钥独立。
- AES-128-GCM 提供机密性 + 完整性；帧长作为 AAD，序列号参与 nonce，重放/乱序会校验失败。
- 握手帧含 Unix 秒时间戳，服务端拒绝偏差超过 300 秒的连接，降低重放窗口。
- `404 page not found` 回退使该端口对普通 HTTP/HTTPS 扫描表现为无特征站点；`tls` 模式同样如此。
- 外层 ALPN 只用标准值 `http/1.1`，WS 路径与握手头均按浏览器习惯设置（见 §2.1）。
- 外层 TLS 使用节点证书；取不到证书时自动回退自签（外层只保护已认证的隧道，客户端默认不校验证书）。
- 建议密码通过配置文件权限（`600`）保护，不要写入公开仓库或 `project.md`。

## 6. 回滚

配置层面：把 `TunnelConfig.Enable` 改为 `false`（或删除 `TunnelConfig` 块）后重启 V2bX；
同端口模式会恢复为 AnyTLS 直接监听节点端口。nyanpass 侧把规则的 `tunnel_password` 清空即可。
