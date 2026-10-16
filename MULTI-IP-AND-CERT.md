# 多 IP 机器"配置一次"+ 多域名单证书：soga 模式可行性分析（阶段 1+2 已实现，v1.3.0）

> 背景：一台机器 5 个 IPv4 + 5 个 IPv6 时，现在要在 `config.json` 里写 5 份节点配置（每份还要带自己的 ListenIP / SendIP / ListenIP6 / 整套 CertConfig），比较繁琐。
> 参考对象：soga 的配置形态（`node_id=37,38` 一份配置多节点、`cert_mode=域名1,域名2` 一次签多域名、`cert_key_length=ec-256`、`dns_provider`、`proxy_protocol`、redis 全局 IP 限、动态限速等）。
> 本文结论：**证书合并（阶段 1）与地址自动推导（阶段 2）已实现（v1.3.0）**；soga 字面意义的"同进同出"按你们的出口策略改造后落地为"固定配对 + 自动推导"。

---

## 0. 已实现的用法（TL;DR）

一台机器上的 `config.json`：

```json
{
  "Log": { "Level": "info" },
  "Cert": {
    "CertMode": "http",
    "CertDomains": ["hytron1.wukong.us.kg", "hytron1-1.wukong.us.kg"],
    "KeyType": "ec-256",
    "Email": "v2bx@github.com"
  },
  "Nodes": [
    { "Core": "sing", "ApiHost": "https://72v.net", "ApiKey": "...", "NodeID": 37, "NodeType": "anytls",
      "ListenIP": "auto", "SendIP": "auto", "ListenIP6": "auto",
      "CertConfig": { "CertDomain": "hytron1.wukong.us.kg" } },
    { "Core": "sing", "ApiHost": "https://72v.net", "ApiKey": "...", "NodeID": 38, "NodeType": "anytls",
      "ListenIP": "auto", "SendIP": "auto", "ListenIP6": "auto",
      "CertConfig": { "CertDomain": "hytron1-1.wukong.us.kg" } }
  ]
}
```

- `Cert`（机器级，一次写好）：一张证书覆盖 `CertDomains` 里的所有域名（一次 ACME order 带全部 SAN），路径默认 `/etc/V2bX/cert/machine/fullchain.pem`；`"CertDomains": ["auto"]` 会自动取本机各节点声明的域名并去重。
- 节点级只留它**自己**的东西：`CertDomain`（自己的落地域名）。**要继承机器证书，节点就不要写 `CertMode`/`CertFile`/`KeyFile`**（写了就是显式覆盖，节点会自己签一张）。
- 签发与续期只由**第一个继承机器证书的节点**（owner）执行，其余节点等文件出现即用；失败时按既有逻辑降级自签（多 SAN）并告警，不会影响其它节点。
- `ListenIP: "auto"`：解析该节点自己的 `CertDomain` 的 A 记录作为监听地址与出口（同进同出）；`SendIP: "auto"` = 跟随监听地址（通配地址则不绑定并告警）；`ListenIP6: "auto"` = 在本机公网 v6 里取一个空闲地址，**按节点固定**（重载不漂移，AAAA 不会失效），已被其它节点显式占用的地址不会拿。

---

## 1. "同进同出"的两种含义

| 含义 | 行为 | 对你们适用吗 |
|---|---|---|
| **字面同进同出**（soga 卖点） | 出口源地址 = 用户连进来的那个本机地址（动态跟随，谁进谁出） | **v6 不适用**：你们要的是"v6 进、v4 出"（保持媒体解锁/GeoIP 归属一致），字面跟随会让 v6 用户从 v6 出去，两套语义打架 |
| **按节点固定配对**（V2bX 的做法，也是现在自动化的对象） | 每个节点的流量固定从该节点指定的 `SendIP` 出去，与入口地址族无关 | ✅ 你们要的；v1.3.0 起 `SendIP: "auto"` 自动等于该节点的监听地址，不用再手写 |

（技术上 sing-box 的 direct 出站只支持静态 `bind_address`，动态跟随本来也做不了原生的；等价实现是"一个监听地址配一条绑该地址的出口规则"，即现在的做法。）

现状核对（仓库事实）：

- 出口绑定：`core/sing/sing.go` 的 `buildSendIPRoute()` 为每个节点生成 `node_<ID>_out`（`bind_address = SendIP`）并把入站规则前置 → 同进同出的效果已经在。
- 多地址：v1.2.0 起每个节点可多一个 `ListenIP6`（额外入站 `node_<ID>_v6`，流量/限速在 hook 层折回主 tag）。
- 证书：v1.3.0 起 `DomainsOf()` 支持多域名（`node/lego.go` 一次 order 多 SAN）、`KeyType` 可配；机器级 `Cert` 块在 `conf/conf.go`，合并逻辑在 `conf/cert.go: MergeCertConfig`、启动时解析在 `node/net_auto.go: PrepareOptions`。
- 限制能力：`SpeedLimit` / `DeviceLimit`(IPLimit) / `ConnLimit` / 动态限速 都有；BT 阻断在 `sing_origin.json` 已有。

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


---

## 3. 实现细节（v1.3.0，已完成）

### 3.1 机器级证书（阶段 1，已完成）

| 位置 | 改动 |
|---|---|
| `conf/conf.go` | 顶层新增 `"Cert": {...}`（机器级证书块） |
| `conf/cert.go` | `CertDomains []string`（多 SAN）、`KeyType`（ec-256 / ec-384 / rsa2048 / rsa4096，默认 rsa2048 保持老配置不变）、`DomainsOf()`、`HasAutoDomain()`、`MergeCertConfig()`（字段级继承，节点显式值优先） |
| `node/lego.go` | 一次 order 带上全部域名（多 SAN）；`certKeyType()` 映射密钥类型 |
| `node/cert.go` | 自签兜底按域名列表生成多 SAN 证书；`selfSignedDomains()` 跳过未解析的 `auto` |
| `node/net_auto.go` | 启动时 `PrepareOptions()`：解析机器证书域名（`auto` = 本机各节点声明的域名并去重）、填默认路径/邮箱、逐节点合并继承、指定唯一的 **owner**（第一个继承的节点负责签发+续期） |
| `node/cert.go` / `node/task.go` | 非 owner 节点不再自行签发与续期（避免多个节点抢同一份证书文件） |

**收益**：N 张证书 → 1 张；N 份私钥 → 1 份；续期只有一处、失败只有一个点；`insecure=1` 客户端零感知。
**前提**：http-01 要求**每个域名都能从外网访问到本机 80 端口**——同机多 IP（`.58` 的 `hytron1`→.58、`hytron1-1`→.67 都在本机）成立；**域名跨机器就必须用 dns-01**（`CertMode: "dns"` + `Provider` + `DNSEnv`，这些字段机器块里都支持）。
**注意**：换证书不会改变"客户端仍需 `insecure=1`"（伪装 SNI 与证书域名天然不一致）；多 SAN 的价值在运维侧（1 张 vs N 张、1 个续期失败点）。

### 3.2 地址自动推导（阶段 2，已完成）

| 写法 | 含义 |
|---|---|
| `ListenIP: "auto"` | 解析该节点**自己的** `CertDomain` 的 A 记录（多个 A 取最小并告警）；解析失败（含没有域名可用）重试 3 次后**只跳过这一个节点并明确告警**，同机其它节点照常运行（绝不静默监听错误地址，也绝不因为一个节点把整机拖下线） |
| `SendIP: "auto"` | = 解析后的监听地址（IPv4/IPv6 具体地址都算）；监听是通配（`0.0.0.0`/`::`）时不绑定并告警 |
| `ListenIP6: "auto"` | 在本机公网 v6 里取一个空闲地址，**按节点固定**（重载不漂移，AAAA 记录稳定）；其它节点显式配置的地址不会被拿走；本机没有空闲 v6 时只跳过 v6 入口（节点照常起） |

实现要点：`PrepareOptions()` 在**合并机器证书之前**解析 auto（否则会用机器级的域名并集把节点解析到别人的 IP —— 这是实现时实测到的一个坑）；`SendIP` 必须在核心构造前落地，因为 `buildSendIPRoute()` 的出口规则是那时生成的。

### 3.3 阶段 3（`Machines` 块）——不做

云控 agent/面板按 `Nodes[].NodeID` 精确定位下发，引入机器级块要么在展开后落回 `Nodes[]`（那和阶段 2 收益差不多），要么让 agent 也理解新模型（回归面大）。阶段 1+2 后每节点只剩 4~5 行，边际收益很小。

---

## 4. 与云控的关系（现成可用，无需铺开新版本）

- 面板/agent 仍然逐节点管理：`CertDomain`、`NodeType`、`ListenIP6`（auto/off/具体地址）、GoogleV4 等下发照旧工作。
- 机器级 `Cert` 块是**配置文件层**的，agent 不动它；agent 写的 `Nodes[].CertConfig.CertDomain` 只覆盖域名（节点的落地域名），不会破坏继承（继承是逐字段的，节点没写的 `CertMode`/`CertFile`/`KeyFile` 仍来自机器块）。
- 想让机器级证书也由云控下发？暂不需要：一个机器一个块，手工写一次即可（或者说：这正是"配置一次"的意义）。

---

## 5. 验收与回滚

验收清单（每台机器落地后）：

```bash
# 1) 只签发了一张证书、且覆盖所有域名
journalctl -u V2bX -n 50 | grep -E "acme:|Obtaining|Machine certificate"
openssl x509 -in /etc/V2bX/cert/machine/fullchain.pem -noout -subject -ext subjectAltName

# 2) 各节点监听地址符合预期（auto 解析结果看日志）
journalctl -u V2bX | grep -E "ListenIP=auto|ListenIP6=auto|SendIP=auto"
ss -ntlp | grep ':443'

# 3) 出口仍按节点绑定（同进同出）
journalctl -u V2bX | grep "Auto-configured outbound node_"
```

回滚：删掉顶层 `Cert` 块、把各节点的 `ListenIP/SendIP` 写回具体地址、恢复各自的 `CertConfig`，重启即可；老配置（没有 `Cert` 块、`ListenIP` 是具体地址）行为与本版本之前**完全一致**（有单测覆盖）。

---

## 6. 安装与部署：填哪些字段

### 6.1 一条命令装完整台机器（推荐，soga 风格 + 多节点）

```bash
bash <(curl -Ls https://raw.githubusercontent.com/4kercc/V2BX-malio/main/deploy-node.sh) \
     37,38,39 \
     hytron1.wukong.us.kg,hytron2.wukong.us.kg,hytron3.wukong.us.kg \
     https://72v.net wukongs
```

- **节点数由 `$1` 自动判定**：NodeID 支持逗号或点号（`37,38,39` / `37.38.39`），域名按顺序一一对应；数量不一致会直接报错并列出两串；
- 域名可只写前缀（`hytron1`）→ 自动拼 `DOMAIN_SUFFIX`（默认 `stpikit.com`）；
- `ApiKey` 给**一个** = 全部节点共用（面板常见做法）；给逗号分隔的一串 = 按节点顺序对应；
- 机器上没有 V2bX → 调标准安装脚本**一次装完整机**（WARP 分流 / 系统调优 / systemd / 新式配置）；已经装过 → 只追加/更新这些节点（保留手工加的自定义 `Name` 与 `LimitConfig`，证书字段统一改成继承机器证书）；
- 地址默认全自动：`ListenIP=auto`（按各节点自己域名的 A 记录；**未解析到本机的节点会被单独跳过并告警，不影响同机其它节点**）、`SendIP=auto`（同进同出）、`ListenIP6=auto`（本机空闲公网 v6，按节点固定分配）；
- 已安装时脚本先查二进制版本：低于 v1.3.0 会拦住并提示升级（老二进制不支持 `auto`）。

只加/改一个节点也用同一条命令：`bash deploy-node.sh 38 hytron1-1`。

也可以跳过包装脚本，直接用安装脚本的多节点模式（环境变量注入）：

```bash
NODE_IDS="37,38,39" DOMAINS="a.wukong.us.kg,b.wukong.us.kg,c.wukong.us.kg" \
  bash <(curl -Ls .../install_v2bx_anytls.sh) https://72v.net wukongs
```

可选环境变量：`LISTEN` / `LISTEN6` / `SEND`（默认全是 `auto`）、`CERT_KEY_TYPE`（默认 `ec-256`）、`WARP_MODE`（默认 on，仅首次安装）、`CLOUD_URL` / `CLOUD_TOKEN`（顺带接入云控，仅首次安装）。

### 6.2 标准安装脚本（install_v2bx_anytls.sh）的字段

| 位置 | 字段 | 怎么填 |
|---|---|---|
| 参数 1 | API_HOST | 面板地址，如 `https://72v.net` |
| 参数 2 | API_KEY | 该节点的面板密钥（每个节点不同） |
| 参数 3 | NODE_ID | 面板里的节点 ID |
| 参数 4 | DOMAIN | 证书域名（`hytron1.wukong.us.kg`）；写 `null` = 自签 |
| 参数 5 | WARP_MODE | `on`/`off`，默认 on |
| 参数 6/7/8 | 云控 URL / Token / insecure | 可选，接入云控中心 |
| 交互询问 | 节点数量 / NodeID / 域名 / ListenIP / ListenIP6 / SendIP | 见下表 |

| 交互字段 | 推荐填法 | 说明 |
|---|---|---|
| ListenIP | **直接回车**（域名已指向本机时默认 `auto`） | `auto` = 按该节点域名的 A 记录自动定地址；也可 `0.0.0.0` / `::` / 具体 IP |
| ListenIP6 | **直接回车**（本机有公网 v6 时默认 `auto`） | `auto` = 本机空闲公网 v6 按节点固定分配；留空 = 不启用 v6 入口 |
| SendIP | **直接回车**（默认 `auto`） | `auto` = 跟随监听地址 = 同进同出；也可输序号选具体 IP，`0` = 不绑定 |
| 域名 | 该节点的落地域名 | 多节点的域名会自动合成**一张机器级证书** |

### 6.3 安装后生成的 config.json 长什么样

```json
{
  "Cert": { "CertMode": "http", "CertDomains": ["hytron1.wukong.us.kg", "hytron1-1.wukong.us.kg"],
            "KeyType": "ec-256", "Email": "v2bx@github.com" },
  "Nodes": [
    { "NodeID": 37, "ListenIP": "auto", "ListenIP6": "auto", "SendIP": "auto",
      "CertConfig": { "CertDomain": "hytron1.wukong.us.kg" } }
  ]
}
```

要点：**节点里不要再写 `CertMode`/`CertFile`/`KeyFile`**（写了就是显式覆盖机器证书）；`ListenIP=auto` 的前置条件是域名 A 记录已指向本机（否则 V2bX 启动时会明确报错，不会静默监听到错误地址）。

### 6.4 云控 Agent 的配合

- agent 仍按 NodeID 逐节点下发 `CertDomain`/`NodeType`/`ListenIP6`/`GoogleV4` 等；
- 检测到机器级证书（config.json 有 `Cert` 块且证书文件存在）时，agent **不会再给节点写 `CertFile`/`KeyFile`**（否则单域名自签会顶掉机器证书），只更新 `CertDomain`，日志会打印「本机使用机器级证书…」；
- 证书探测路径新增 `/etc/V2bX/cert/machine/fullchain.pem`，面板能正常显示机器证书的剩余天数与自签标记。
