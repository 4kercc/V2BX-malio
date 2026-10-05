# Heki AnyTLS 优化清单 → V2bX 可移植性分析

日期：2026-10-05
样本：heki v1.2.7（Go 1.26.3，未 strip）+ 本地 `sing-box_mod v1.12.0-beta.17.2` 源码 + `anytls/sing-anytls` v0.0.9 / v0.0.13

---

## 一、Heki 到底对 AnyTLS 做了什么优化（函数级证据）

| # | 优化项 | Heki 侧证据（符号 / 日志串） | 实际作用 |
|---|---|---|---|
| 1 | **AnyTLS UDP（UoT + 旧版兼容）** | `anytls.udpAssoc`、`anytls.sharedUDPPacketAssoc`、`anytls.sessionTracker`、`features.anyTLSLegacyUDPConn.{ReadPacket,WritePacket,Upstream,InitializeReadWaiter}`；日志 `AnyTLS UDP user=%d -> packet-assoc (uot=%d, stream=%s)`、`AnyTLS UDP user=%d read UoT request failed: %v`、`AnyTLS UDP user=%d dial %s failed: %v` | 在 sing-anytls（纯 TCP 隧道）之上自建 UDP 关联：走标准 UoT 目标的按 UoT 解析，非 UoT 的旧客户端走 `anyTLSLegacyUDPConn` 兼容路径；带会话复用、IP 限制、限速 |
| 2 | **认证失败 fallback** | `anytls.anytlsFallbackHandler`、`features.AnyTLSOutDialer`；日志 `AnyTLS fallback enabled -> %s (source=%s)`、`AnyTLS auth failed from %s but fallback handled it`、`AnyTLS unknown user tag: %s`、`[AnyTLS] fallback dial %s failed` | 未知密码/非法握手时，把原始 TCP 流转发到本地 web 入站，落地机表现为普通 HTTPS，抗主动探测 |
| 3 | **padding_scheme 多格式解析（自研包）** | `heki/config/anytls_padding.go` + `ResolveAnyTLSPaddingScheme`、`resolveAnyTLSPaddingScheme{JSON,Lines,String,Value}`、`normalizeAnyTLSPaddingSchemeRaw`、`NormalizeAnyTLSPaddingSchemeValue`、`validateAnyTLSPaddingScheme{Bytes,Text}`、`sortAnyTLSPaddingSchemeKeys[go.shape.{string,interface{}}]`；日志 `AnyTLS using custom padding scheme`、`ignore invalid AnyTLS padding_scheme from panel: %q`、`marshal AnyTLS padding scheme: %w` | 兼容 JSON 数组 / 多行 / 单行 / 键值对象四种面板下发格式，键排序归一化并校验；非法值告警并回退，不让节点起不来 |
| 4 | **SNI 白名单** | `reject_unknown_sni: client SNI %q does not match %q` | 握手期校验客户端 SNI，面板下发 `tls_settings.reject_unknown_sni=1` 时启用 |
| 5 | **ECH（入站）** | 配置键 `anytls_ech_server_keys`；`Failed to unmarshal ECHKeySetList: Failed to unmarshal ECHConfigList` | 服务端启用 ECH，隐藏真实 SNI |
| 6 | **连接数限制 + 无效访问封禁** | `AnyTLS user=%d connection limit reached (%d)`；`anytls_invalid_access_{enable,count,duration,forbidden_times}` | 每用户并发连接上限；短时大量无效连接即禁封目标 |
| 7 | **会话空闲回收（出站侧）** | 库 API：`IdleSessionCheckInterval` / `IdleSessionTimeout` / `MinIdleSession` / `DisableReuse`（`session/client.go` 的 `idleSession` skiplist）；Heki 符号 `anytls.streamIdleWatchdog` | 复用空闲 session 降低握手开销；注意这是 **outbound（客户端/中继）** 特性，服务端不受影响 |
| 8 | **传输扩展** | `anytls_transport`、`anytls_ws_path/host`、`anytls_h2_path/host`、`anytls_grpc_service_name` | AnyTLS over ws/h2/grpc |

> 注意：**没有任何证据表明 Heki 优化了 AnyTLS 的核心多路复用协议本身**。它的价值集中在 UDP、fallback、配置解析健壮性、TLS 策略四块。

---

## 二、逐项可移植性（V2bX + sing-box_mod v1.12.0-beta.17.2）

| 优化项 | sing-box 侧现状（已核实） | V2bX 落地成本 | 结论 |
|---|---|---|---|
| TLS `server_name` | `option.InboundTLSOptions.ServerName` 存在 | 纯 V2bX 层 | **已做**（第一阶段） |
| ECH 入站 | `InboundECHOptions{Enabled,Key,KeyPath}`，`common/tls/ech.go` 在 go1.24+ 自动生效（无额外标签） | 纯 V2bX 层 | **已做**（第一阶段） |
| padding_scheme 多格式 + 校验 | `badoption.Listable[string]` 只吃数组，`padding.UpdatePaddingScheme` 解析 | 纯 V2bX 层 | **值得做**，性价比高 |
| UDP（UoT） | `protocol/anytls/inbound.go:46` 已 `uot.NewRouter(router, logger)`；`common/uot/router.go` 的 `RouteConnection` 对 `uot.MagicAddress` 与 `uot.LegacyMagicAddress` **两条路径都做了 UoT 解包**并转入 `RoutePacketConnection` | 零成本 | **已可用，无需移植** |
| 旧版 UDP 兼容（`anyTLSLegacyUDPConn`） | **无需 fork**：`common/uot/router.go` 同时处理 `uot.MagicAddress`（标准 UoT）与 `uot.LegacyMagicAddress`（旧版 UoT），两条路径都转发到 `RoutePacketConnection` | 零成本 | **已可用**，heki 的 `anyTLSLegacyUDPConn` 在其内核里做的是等价的事 |
| fallback（抗探测） | 上游 `sing-anytls` 有 `fallbackHandler`，但 sing-box 的 inbound 未接线；`option.AnyTLSInboundOptions` 无 fallback 字段 | **需 fork sing-box_mod** | 高价值但成本高 |
| SNI 白名单 | `RejectUnknownSni` 字段存在于 `conf` 但 sing-box 无对应能力（`std_server.go` 的 `tlsConfig.ServerName` 在服务端无效） | **需 fork sing-box_mod**（在 `GetCertificate`/`GetConfigForClient` 钩子里校验） | 中价值，成本高 |
| 连接数限制 | V2bX 已有 limiter（`ConnLimit`、`DeviceLimit`、`IPLimit`）；但 sing-anytls 的 `UpdateUsers` 无 per-user 并发限制 | 小改（在 hook/limiter 层加 per-user 计数） | **值得做** |
| 会话空闲回收 | 库有 API（outbound 侧）；V2bX 用的是服务端 `anytls.Inbound`，不涉及 | 不适用 | 不需要 |
| ws/h2/grpc 传输 | `option.AnyTLSInboundOptions` 无 transport 字段 | **需 fork sing-box_mod** | 取决于是否有此类客户端 |

---

## 三、两个功能的真实实现机制

### 3.1 证书链路（heki：面板有域名即自动申请 + 手动证书 + 推送落盘）

heki 侧证据链：
- 面板配置项 `anytls_sni` / `anytls_cert_file` / `anytls_key_file`（heki.conf.example:127-132）。
- 编排日志：`AnyTLS detected domain: %s, port: %d` → `Using manual certificate (AnyTLS): %s` → `AnyTLS using custom padding scheme`。
- 面板推送证书：`writePanelPushedFile`（面板下发内容落盘）、`certificate_content` 字符串、`Using existing self-signed certificate: %s`、`no valid certificate name found in cert_domain=%q`、`no ACME-issuable DNS name found in cert_domain=%q`；ACME 由外挂 `acme.sh` 完成（`acme.sh install-cert failed, retrying with issuance`）。

机制：首选面板推送证书落盘 → 无推送则从 SNI/域名推导 `cert_domain`，校验是否 ACME 可签发（IP、无点主机名直接拒绝并告警）→ 交 acme.sh 申请/续期 → 证书路径回填给入站。

**实现要点提炼（与内核无关，可纯应用层复刻）**：域名推导优先级 = 落地域名（panel `server` 主段）> 本地显式 `CertDomain`；不可签发时明确告警而不是静默起明文；每节点证书路径按域名隔离；推送内容原子落盘。

> **关键坑（实测踩到）**：SSPanel 的 `server_name` 参数是**客户端伪装 SNI**，不是证书域名。真实响应示例：
>
> ```
> GET /mod_mu/nodes/3/info
> {"sort":18,"server":"tw3.stpikit.com;port=443&server_name=updates.cdn-apple.com&insecure=1"}
> ```
>
> - `tw3.stpikit.com` = 落地域名 → **这才是证书身份**（`AnyTls.CommonNode.Host`）。
> - `updates.cdn-apple.com` = 客户端握手时伪装的 SNI，模仿 Apple 更新服务（`AnyTls.ServerName`）。本节点无权为它申请证书，ACME 必然失败。
> - `insecure=1` = 客户端侧跳过证书校验的**订阅提示**，服务端不需要也**不应**消费；若误当证书域名或误置 `tls.Insecure`，都会导致节点起不来或校验被削弱。
>
> 结论：证书域名只能取自 `server` 主段；`server_name` 只用于生成客户端订阅。

### 3.2 AnyTLS over UDP（heki：udpAssoc / sharedUDPPacketAssoc / sessionTracker / anyTLSLegacyUDPConn）

从符号与结构体字段还原的实现骨架：

```
anytls.Handler
 ├─ localUDPConns  map[string]*anytls.udpAssoc      // 按 源地址键 → 本地 UDP 关联
 ├─ sharedUDP     **anytls.sharedUDPPacketAssoc     // 到同一目标的共享 packet 通道
 ├─ cond          map[string]*anytls.udpAssoc       // 内部条件/索引
 └─ streamIdleWatchdog                              // 流空闲看护
```

`udpAssoc` 携带 `SpeedLimiter`（限速）、`network.PacketConn`、`time.Duration`（空闲超时）、`atomic.Int64`（计数）、`func(string, *udpAssoc)`（回收回调）——即每个 UDP 关联都有独立限速、空闲回收与计数器。

UoT 请求处理（日志实证）：`AnyTLS UDP user=%d read UoT request failed: %v`、`AnyTLS UDP user=%d -> packet-assoc (uot=%d, stream=%s)`、`AnyTLS UDP unknown user tag: %s`、`AnyTLS UDP user=%d dial %s failed: %v`。即：从流里读 UoT 目标地址，解析成功后按目标查/建共享关联，失败按行冲刷返回。

旧版兼容：`features.anyTLSLegacyUDPConn` 实现完整 `network.PacketConn` 接口（`ReadPacket`/`WritePacket`/`Upstream`/`InitializeReadWaiter`/`SetDeadline` 等），用于不按标准 UoT 封装、直接发原始 UDP 载荷的老客户端。

**sing-box 侧的等价能力（本次已核实）**：`common/uot/router.go` 的 `RouteConnection` 已经同时处理 `uot.MagicAddress` 与 `uot.LegacyMagicAddress` 两个分支，各自 `uot.ReadRequest` 或 `uot.NewConn(conn, uot.Request{})` 后转入 `RoutePacketConnection`。也就是说 **标准 UoT 与旧版 UoT 两条路径 sing-box 本体都已支持**，AnyTLS 入站又已接 `uot.NewRouter`，因此功能上无需移植。

**heki 比 sing-box 多出的部分**：per-assoc 限速（`SpeedLimiter` 挂在 UDP 关联上）、共享关联的空闲回收策略（`streamIdleWatchdog` + 回收回调）、以及可观测的 UDP 会话计数。这些属于策略增强，不是协议能力。

---

## 四、第一阶段已完成的接线（本次改动）

改动文件（V2bX 仓库）：

1. `conf/cert.go`：`CertConfig` 新增 `ECHKey`、`ECHServerName`、`ACMEDataDirectory`；`CertMode` 注释补全 `self`。
2. `core/sing/node.go`：新增 `buildInboundTLS()` 与 `buildECHKeyPEM()`，把三类此前"定义了但没消费"的能力接进 sing-box：
   - 面板 `server_name`（`api/panel/sspanel.go:981` 早就解析了）→ 真正写入 `InboundTLSOptions.ServerName`，缺失时回落本地 `CertDomain`。
   - ECH：接受 Base64 ECHConfigList 或现成 `ECH KEYS` PEM，规范化为 sing-box 要求的 PEM；`cert_mode=none` 时配 ECH 直接报错而不是静默忽略。
   - 证书：`CertFile/KeyFile` 继续沿用（`node/cert.go` 的 lego/self 签发流程不变）。
3. `core/sing/node_test.go`（新增）：8 个用例覆盖面板 SNI 优先、回落、TLS 关闭、明文节点、ECH base64 往返、ECH 与 TLS 冲突、PEM 透传、非法输入。

验证：
- `go build -tags "sing,with_gvisor,with_wireguard"`（linux/amd64）**exit 0**，与改造前基线一致。
- `go test ./core/sing/` **8/8 PASS**；`limiter` 亦 PASS。
- `conf` / `node` 包的失败是既有环境依赖（文件监视超时、lego 用例真实访问 Let's Encrypt），与本次改动无关。

---

## 五、第二阶段已完成的证书链路（本次改动）

新增文件 `node/cert_panel.go`，把 heki 的证书编排方式落到 V2bX：

1. `certDomainFromNode()`：域名推导优先级 = AnyTLS `server_name` → 通用 `server_name` → 非 IP 主机名；`normalizeCertDomain()` 统一剥离端口、去尾点、小写化，并对 IPv4/IPv6 字面量直接判为不可签发。
2. `applyPanelTLSConfig()`：
   - 面板推送证书（`CertContent`/`KeyContent` 内联，或 `PanelPushDir/cert.pem|key.pem`）→ 原子落盘到节点证书路径（tmp + rename），置 `PanelPush=true`，跳过重复申请；
   - 只有域名时 → 自动把 `CertMode` 从 `none` 提升为 `http`（ACME），用 `AutoFromPanel` 标记，**绝不覆盖运维显式设置的模式与路径**；
   - 无任何可签发材料（纯 IP / 无域名无推送）→ 明确告警并保持节点可启动，不静默起明文。
3. 接线点：`node/controller.go` 的 `Start()` 与 `node/task.go` 的 `nodeInfoMonitor()`，都在 `requestCert()` 之前调用，失败只告警不阻断启动。
4. `conf/cert.go`：新增 `CertContent`、`KeyContent`、`PanelPushDir`、`AutoFromPanel`、`PanelPush`。
5. `node/cert_panel_test.go`（新增，8 个用例）：域名推导优先级、端口/I Pv6 拒绝、模板路径填充、自动提升 ACME 模式、不覆盖运维模式、明文节点不触发、无域名保持可用、推送证书原子落盘与幂等、不完整载荷拒绝。

验证：`go vet` 干净；新测试 8/8 PASS；`go build -tags "sing,with_gvisor,with_wireguard"`（linux/amd64）exit 0，产物 174,221,128 字节（与此前基线 174,203,420 基本一致）。

## 六、建议的后续路线（按性价比排序）

**P0（纯 V2bX 层，可立即做）**
1. padding_scheme 多格式解析 + 校验回退（移植 heki `heki/config/anytls_padding.go` 的思路）。
2. per-user 并发连接上限（落地在 limiter/hook）。
3. `RejectUnknownSni` 配置先做"启动期校验 + 告警"，避免用户以为已生效。

**P1（需要 fork sing-box_mod，收益最大）**
4. AnyTLS 入站 fallback：`option.AnyTLSInboundOptions` 加 `fallback_addr`/`fallback_port`，在 `protocol/anytls/inbound.go` 把 `sing-anytls` 的 `fallbackHandler` 接出去。这直接决定抗主动探测能力。
5. SNI 白名单：在 `common/tls/std_server.go` 用 `tls.Config.GetConfigForClient` 校验 `ClientHelloInfo.ServerName`。

**P2（视客户端分布）**
6. `anyTLSLegacyUDPConn` 旧版 UDP 兼容。
7. ws/h2/grpc 传输扩展。

**不需要移植**：免费版 88 用户限制、面板域名绑定/机器指纹/心跳守卫（Heki 的商业授权设计，与协议能力无关）；会话空闲回收（outbound 侧特性）。

## 七、第三阶段：ACME 申请失败不再阻断节点启动（本次改动）

### 7.1 决策

问题：`CertMode=http/dns` 在证书文件不存在时走 lego 签发，http-01 要求 **80 端口可达本机且域名解析到本机**，任一不满足即失败。原实现里这个失败是致命的：

- `node/controller.go` 的 `Start()`：`requestCert()` 失败 → `return error` → **节点完全起不来**；
- `node/task.go` 的 `nodeInfoMonitor()`：失败 → 跳过 `AddNode` → 热重载后节点同样起不来。

**结论：默认降级 + 告警，可用性优先。**

| 选项 | 结论 |
|---|---|
| 申请失败行为 | 默认安装自签证书（同名 CN/SAN）保证节点起来，`CERT-FALLBACK` 告警 |
| 恢复旧行为 | `CertConfig.StrictACMEFailure=true`（申请失败即启动失败） |
| 覆盖范围 | **全部 http/dns，而不只是 `AutoFromPanel`** |
| 严格模式下的重试 | 自签占位证书仍会被续期任务每日重试升级（严格模式只约束启动，不禁止申请） |

两个关键判断依据：

1. **范围必须覆盖显式 http**：云控安装脚本 `install_v2bx_anytls.sh:327` 写的就是显式 `"CertMode": "http"`（自签模式才写 `none`），只覆盖 `AutoFromPanel` 等于线上不生效。
2. **可用性优先**：节点起不来 = 100% 用户不可用；自签只影响"校验证书链"的客户端，而面板下发的订阅本身带 `insecure=1`（见 3.1 的真实响应），这类客户端照常可用。ACME 失败通常是环境问题（端口/解析），不该让节点陪葬。

### 7.2 实现

| 文件 | 改动 |
|---|---|
| `conf/cert.go` | 新增 `StrictACMEFailure`（默认 false = 降级） |
| `node/cert.go` | `handleACMEIssuanceFailure()`：失败 → 生成并原子安装自签（CN/SAN=CertDomain）→ `CERT-FALLBACK` 警告；`installSelfSignedCertificate()` / `generateSelfSslCertificatePEM()`；`writeCertificateFiles()`（tmp+rename、私钥 0600、PEM 标签修正为 `RSA PRIVATE KEY`）；`selfSignedCertificateFile()` / `isSelfSignedCertificatePEM()`（issuer==subject 且自验签）；`certificateDaysLeft()` |
| `node/cert.go` | `renewCertTask()`：http/dns 且证书是自签 → 走 **重新申请**（`CreateCert`）而不是 `RenewCert`（lego 的 Renew 会按证书 SAN 重新走签发，但显式申请语义更清晰）；成功 → 删除标记 + 日志"已替换"；失败 → 保留自签并更新标记，剩余 <15 天时刷新自签（不依赖 CA）。`PanelPush` 的材料不动 |
| `node/cert_panel.go` | 复用统一写入函数；面板推送证书落盘后清除降级标记（否则面板会一直误报 ACME 失败） |
| `node/cert_fallback_test.go` | 13 个用例：自签识别、原子落盘/权限/父目录、降级、严格模式、无域名不降级、requestCert 接线、升级成功/失败/临期刷新、健康证书与面板推送材料不被重签、标记文件写入与清除 |

**自愈语义**：自签 ≠ 永久降级。只要端口 80 / DNS 恢复，续期任务（每天一次，另有启动时一次）就会把正式证书换上并通知面板。每节点每天最多一次 ACME 尝试，符合 Let's Encrypt 的失败限制（5 次/账号/主机/小时）。

**告警链路（云控）**：`CERT-FALLBACK` 日志 → 标记文件 `<CertFile>.acme-fallback`（`{domain, at, error}`）→ `cloud-agent.sh` 心跳上报 `cert.fallback/fallbackAt/fallbackError` → `cloud-server.js` 事件 + Telegram/Webhook 通知（🔐 ACME 申请失败，已降级自签）+ 节点列表徽标 `自签·ACME失败`；恢复正式证书后自动发"已恢复"并复位。Agent 证书探测路径补了 `/etc/V2bX/cert/<domain>/fullchain.pem`（auto 模式的默认落盘位置）。

> 为什么用标记文件而不是直接对"自签"告警：运维**有意**配置自签（安装脚本的自签模式、openssl 预生成兜底）与"ACME 失败被迫降级"必须区分，前者告警就是噪声。

### 7.3 边界

- 无域名可签（纯 IP / CertDomain 为空）→ 不降级，按原样报错（不生成无名证书）；
- `CertMode=self/file` 行为不变；`self` 生成的自签仍是 **30 年**有效期（`AddDate(30,0,0)` 的既有语义，不做变更）；
- 面板推送的证书（`PanelPush`）归运维所有：续期任务不会对它发起自动申请；
- 显式 http/dns 且证书文件**已存在**时仍不重复申请（原有行为），升级只针对"内容是自签"的情况。

### 7.4 验证

- `go vet ./node/ ./conf/` 干净；
- `go test ./node/ -run '...(证书链路全部用例)'` **26/26 PASS**（含本次新增 16 个：降级/严格模式/升级/临期刷新/标记文件/接线）；
- `go test ./core/sing/` PASS；
- `go build -tags "sing,with_gvisor,with_wireguard"`（linux/amd64、linux/arm64）exit 0；
- `cloud-server.js` 通过 `node --check`，`cloud-agent.sh` 通过 `bash -n`。

