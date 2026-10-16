# 多 IP 机器"配置一次"+ 多域名单证书：soga 模式可行性分析

> 背景：一台机器 5 个 IPv4 + 5 个 IPv6 时，现在要在 `config.json` 里写 5 份节点配置（每份还要带自己的 ListenIP / SendIP / ListenIP6 / 整套 CertConfig），比较繁琐。
> 参考对象：soga 的配置形态（`node_id=37,38` 一份配置多节点、`cert_mode=域名1,域名2` 一次签多域名、`cert_key_length=ec-256`、`dns_provider`、`proxy_protocol`、redis 全局 IP 限、动态限速等）。
> 本文结论：**证书合并（阶段 1）与地址自动推导（阶段 2）都能做且划算；soga 字面意义的"同进同出"要按你们的出口策略改造，不能照搬**。

---

## 1. 先厘清"同进同出"的两种含义

| 含义 | 行为 | 对你们适用吗 |
|---|---|---|
| **字面同进同出**（soga 卖点） | 出口源地址 = 用户连进来的那个本机地址（动态跟随，谁进谁出） | **v6 不适用**：你们要的是"v6 进、v4 出"（保持媒体解锁/GeoIP 归属一致），字面跟随会让 v6 用户从 v6 出去，两套语义打架 |
| **按节点固定配对**（V2bX 现在的做法） | 每个节点的流量固定从该节点指定的 `SendIP` 出去，与入口地址族无关 | ✅ 这才是你们要的；缺的只是"不用手填" |

所以要做的是：**保留"按节点固定出口"，把"配对关系"和"证书"自动化**，而不是引入动态跟随。
（技术上 sing-box 的 direct 出站只支持静态 `bind_address`，动态跟随本来也做不了原生的；我们的等价实现是"一个监听地址配一条绑该地址的出口规则"，也就是现在的做法。）

现状核对（仓库事实）：

- 出口绑定：`core/sing/sing.go` 的 `buildSendIPRoute()` 会为每个节点生成 `node_<ID>_out`（`bind_address = SendIP`）并把入站规则前置 → 同进同出的效果已经在，只是 SendIP 要手写。
- 多地址：v1.2.0 起每个节点可多一个 `ListenIP6`（额外入站 `node_<ID>_v6`，流量/限速在 hook 层折回主 tag）→ "一个节点多监听地址"的骨架已经搭好，泛化成 N 个地址是加法而非重构。
- 证书：`node/lego.go` 的 `CreateCert` 目前是 `Domains: []string{l.config.CertDomain}` —— **单域名**；`CertConfig` 只在节点级（`conf/node.go`），没有机器级证书块；密钥类型硬编码 `RSA2048`。
- 限制能力：`SpeedLimit` / `DeviceLimit`(IPLimit) / `ConnLimit` / 动态限速 都有（`conf/limit.go`、`limiter/`）；BT 阻断在 `sing_origin.json` 的 domain_regex 里已有。

---

## 2. 逐项对照 soga 配置

| soga 配置项 | 作用 | 本仓库现状 | 结论 |
|---|---|---|---|
| `node_id=37,38` | 一份配置服务多个面板节点 | `Nodes[]` 每节点一条 | 可借鉴，但优先用"自动推导"替代（见阶段 2/3） |
| `cert_mode=a.com,b.com` | **一张证书多域名**（一次签发） | 单域名/节点（`node/lego.go:94`） | **要改，收益最大** |
| `cert_key_length=ec-256` | 密钥类型可选 | 硬编码 RSA2048（`node/lego.go:43`） | 顺手加 |
| `dns_provider=` | dns-01 签发（域名不必指向本机） | 已有 `Provider` + `DNSEnv` | ✅ 已有；多域名跨机签发就靠它 |
| `cert_file`/`key_file` | 手动证书 | 已有 | ✅ |
| `proxy_protocol=*` | 中转保留真实 IP | sing-box 1.6 起已移除该入站能力（内核源码确认） | 不做；你们的中转是纯 L4 转发，不需要 |
| `redis_enable`（全局用户 IP 数） | 跨机共享 IP 计数 | limiter 是**节点内内存态**（按 tag） | 不做（要引 Redis，成本高）；同机多节点在你们架构下本就按节点算 |
| `dy_limit_*` 动态限速 | 触发式降速 | 已有 `EnableDynamicSpeedLimit` | ✅ |
| `user_conn_limit` / `user_speed_limit` / `node_speed_limit` | 各类限制 | `ConnLimit` / `SpeedLimit` / `DeviceLimit` 都有（面板 `node_speedlimit`、`NodeConnector` 已映射） | ✅ |
| `user_tcp_limit` | xray 概念 | 无（内核是 sing-box） | 不需要 |
| `forbidden_bit_torrent` | BT 阻断 | `sing_origin.json` 已有 torrent/ed2k/magnet 等规则 | ✅ |
| `check_interval` / `submit_interval` | 拉取/上报周期 | 面板下发的 `PullInterval` / `PushInterval` | ✅ |
| `log_level` | 日志级别 | ✅ | ✅ |

---

## 3. 改造方案（三阶段，按性价比排序）

### 阶段 1：机器级证书块 + 多域名单证书（低风险，先做这个）

新增顶层 `Cert` 块（机器级，`Nodes[].CertConfig` 保留为**覆盖项**，向后兼容）：

```json
"Cert": {
  "Mode": "http",                              // http / dns / self / file
  "Domains": ["auto"],                          // auto = 收集本机全部节点的面板域名（去重）
  "KeyType": "ec-256",                          // 新增：ec-256 / rsa2048（默认 rsa2048）
  "CertFile": "/etc/V2bX/cert/machine.pem",     // 一条证书给全机节点共用
  "KeyFile":  "/etc/V2bX/cert/machine.key",
  "Provider": "cloudflare", "DNSEnv": { "CF_DNS_API_TOKEN": "..." }
}
```

改动点：

- `node/lego.go`：`Domains: cert.Domains`（多 SAN 一次 order）+ `KeyType` 可配；
- `node/cert.go`：自签兜底支持多 SAN（`generateSelfSslCertificatePEM` 传域名切片）；ACME 失败降级/每日重试升级逻辑不变；
- `conf`：新增机器级 `Cert`，节点未显式配置时继承；`{domain}` 模板保留；
- `node/cert_panel.go`：`Domains: auto` 时聚合各节点的面板域名（`server` 主段，IP 与非法域名跳过）。

**收益**：5 张证书 → 1 张；5 份私钥 → 1 份；续期只有一处、失败只有一个点；`insecure=1` 客户端零感知。
**前提（必须写进操作手册）**：http-01 要求**每个域名都能从外网访问到本机 80 端口**——同一台机器的多个 IP/域名成立（如 `.58` 的 `hytron1` → .58、`hytron1-1` → .67 都在本机）；如果域名指向不同机器，就必须用 **dns-01**。
**注意**：单纯换证书不会改变"客户端仍需 `insecure=1`"（因为伪装 SNI 与证书域名不一致，之前分析过）；多 SAN 的价值在运维侧 + 将来若改 SNI 可直接启用校验。

### 阶段 2：地址自动推导 + 每节点多监听地址（消灭逐节点 IP 配置）

```json
{ "NodeID": 37, "NodeType": "anytls",
  "ListenIP": "auto",      // 面板 server 主段推导：IP 字面量直接用，域名解析 A 记录
  "ListenIP6": "auto",     // 本机公网 v6 自动分配（agent 已有此逻辑，内核侧做同样的）
  "SendIP": "auto" }       // 默认 = 该节点 ListenIP（同进同出）
```

或显式列表（一个节点吃多个地址，全部聚合到同一节点 tag）：

```json
{ "NodeID": 37, "ListenIPs": ["45.196.221.58", "45.196.221.67"],
  "ListenIP6s": ["2401:b60:3d:2::2", "2401:b60:3d:1b::2"], "SendIP": "auto" }
```

改动点（骨架已在）：

- `secondaryInboundTag()` 从固定 `_v6` 泛化成 `extraInboundTag(tag, addr)`；
- `nodeInboundTags()`（用户同步）、`hook.resolveInboundTag()`（流量/限速归并）、`buildSendIPRoute()`（规则数量 = 地址数量）相应扩展；
- `SendIP: auto` → 取该节点第一个 v4 监听地址（v6 监听不参与，保持"v6 进 v4 出"）。

**收益**：每台机器从"每节点 3 个 IP 字段"降到 0；配合阶段 1，一台 5 节点机器只需写 5 行 `NodeID` + 一个证书块。

### 阶段 3（可选，不建议现在做）：机器级 `Machines` 块

`"Machines": [{ "NodeIDs": [37,38,...], "ListenIPs": "auto", "Cert": {...} }]`，启动时展开成 `Nodes[]`。
**为什么不急**：云控 agent/面板是按 `Nodes[].NodeID` 精确定位下发的（这是"改配置不误伤同机其他节点"的根基）；引入机器级块要么在展开后落回 `Nodes[]`（那和阶段 2 的收益差别只剩几行），要么让 agent 也理解新模型（成本高、回归面大）。阶段 1+2 后每节点只剩 4~5 行，边际收益已经很小。

---

## 4. 需要操作者决定的一点

**5 个 IP 怎么组织**，直接决定阶段 2 的实现形态与面板/用户侧口径：

- **A. 保持 5 个面板节点**，每个节点 `auto` 拿一个 IP（用户侧不变；出口归属/媒体检测/限流口径全部不变；改动最小，推荐先做）。
- **B. 1 个面板节点吃 5 个 IP**（节点域名挂 5 条 A 记录，客户端随机进、从"进来的那个 IP"出去 = soga 完全体）：面板节点数变少、用户侧更简单，但"媒体解锁/GeoIP/出口 IP"从"一节点一出口"变成"一节点多出口"，面板展示口径（媒体检测是按 SendIP 逐 IP 探测的）和 GoogleV4 那套要跟着调整。
- **C. 混合**：v4 保持 A，v6 用 B（v6 监听聚合、出口仍 v4）。

---

## 5. 建议的落地顺序

1. 阶段 1（多域名单证书 + KeyType + `SendIP: auto`）——不改数据面、风险低、收益立竿见彩；在老规矩下验证（单测 + 沙箱 + 实机 + Release）。
2. 阶段 2 的 `ListenIP/ListenIP6: auto`（推荐 A 形态）——把逐节点 IP 字段清零。
3. 观察一段时间后，如果你要"一节点吃多 IP"（B/C），再在阶段 2 的多地址能力上加展示口径调整。
