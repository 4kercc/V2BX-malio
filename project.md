# V2BX-malio 项目改动记录与功能文档

本文档记录本项目所做的所有架构优化、功能重构、Bug 修复与发布历史，用于后续问题回溯与接力维护。

---

## 一、版本演进与发布记录

| 版本 | 发布类型 | 核心改动说明 |
|---|---|---|
| **v1.1.0** | Release / 证书链路 | 1. 面板驱动证书链路：域名推导取面板 `server` 主段（不用客户端伪装 SNI）、面板推送证书原子落盘、仅有域名时自动把 `CertMode=none` 提升为 `http`（`node/cert_panel.go`）；<br>2. **ACME 申请失败默认降级自签证书并告警，不再阻断节点启动**（`CertConfig.StrictACMEFailure=true` 可恢复旧行为）；续期任务每日对自签占位证书重新申请，恢复后自动换上正式证书并清除告警；<br>3. ECH 入站与面板 `server_name` 真正写入 sing-box（`core/sing/node.go` 的 `buildInboundTLS`）；<br>4. 云控可见性：agent 上报 `cert.fallback*`、新增证书探测路径，面板出事件 + Telegram/Webhook 告警 + `自签·ACME失败` 徽标。 |
| **v1.0.9** | Release / 精简构建 | 1. 裁剪为 AnyTLS-only 精简版，移除 Xray/Hysteria2 独立内核与 quic-go 依赖；<br>2. 修复 gVisor 依赖报错，恢复 `with_gvisor` 标签；<br>3. 二进制从 134MB 降至 111MB，发布包 44MB 降至 35MB。 |
| **v1.0.8** | Release / 体验优化 | 1. 增强运行日志可观测性，启动时输出协议/端口/用户数；<br>2. 注入真实版本号 ldflags，启动横幅不再显示 TempVersion；<br>3. 默认日志级别调整为 `info`，恢复每分钟流量与在线统计上报。 |
| **v1.0.7** | Release / 性能优化 | 1. 修复流量计数器长期运行导致的内存泄漏问题（`core/sing/user.go`）；<br>2. 将设备 IP 限制计算由 O(N) 全表扫描优化为 O(1) 增量计数（`limiter/limiter.go`）；<br>3. 同步合并上游 1.0.6 Bug 修复（节点独立设备限制、Xray 同名出入站选择）。 |

---

## 二、修改与新增的文件详情

### 1. 核心业务与控制层代码

* **`limiter/limiter.go` & `limiter/limiter_test.go`**
  - **优化前**：每个新 IP 接入时调用 `countOldUserIPs` 遍历整个 `OldUserOnline` 全局表，高并发/用户量大时导致严重 CPU 尖峰。
  - **优化后**：引入 `OldIPCount` 增量计数表（`uid -> count`）与 `countMu` 锁，查询降为 O(1)；在 `GetOnlineDevice` 中实现快照原子交换，避免重载窗口内设备限制被重置。
* **`core/sing/user.go`**
  - **修复**：在 `DelUsers` 中添加 `counter.Delete(uuid)` 逻辑，当面板删除或过期用户时，同步清除流量统计结构，防止死用户内存持续累积。
  - **精简**：精简仅保留 AnyTLS 相关操作，其他协议返回明确错误。
* **`core/sing/node.go`**
  - **精简**：移除 VMess / VLESS / Trojan / Hysteria 等非 AnyTLS 入站协议生成逻辑。保留 `DelNode` 跨重载保留计数器设计，保证流量上报连续性。
* **`node/controller.go`**
  - **增强**：在节点启动成功时，主动打印 tag、协议类型、监听地址和加载用户数关键日志。

### 2. 构建与依赖管理

* **`build.sh`**
  - 注入版本号 ldflags：`-s -w -X 'github.com/InazumaV/V2bX/cmd.version=${VERSION}'`；
  - 精简构建标签：`sing,with_gvisor,with_wireguard`（保障原生 WARP 所需的 WireGuard 和 gVisor 网络栈）。
* **`go.mod` & `go.sum`**
  - 彻底剔除了 `xtls/xray-core`、`apernet/hysteria`、`apernet/quic-go` 等重型依赖库。
* **`core/xray/` & `core/hy2/`**
  - 目录已物理删除。

### 3. 安装与运维自动化脚本

* **`install_v2bx_anytls.sh`**
  - **自签证书模式**：支持第 4 个参数传入 `"null"` 或留空，自动生成 10 年自签名证书，跳过 80 端口占用检查与 ACME 申请；
  - **WARP 解锁与自动回落**：集成免客户端的 Cloudflare 原生 WireGuard WARP 出站，生成 `warp-auto`（`urltest`）每分钟健康检查探测，故障时自动回落服务器原生 IP；
  - **WARP 开关控制**：支持第 5 个参数传入 `off` 禁用 WARP 出站；
  - **外部 WARP 自动清理**：内置 `cleanup_external_warp`，自动卸载旧 `warp-google-unlock`（含每日 timer 定时器）、`warp-svc`、`redsocks` 及 iptables 劫持链；
  - **系统级调优**：内置 `vm.swappiness=10`、`GOMEMLIMIT=150MiB` systemd drop-in 与每 5 天凌晨 3 点定时重启。
* **`V2bX.sh`**
  - 更新源全面重定向为本仓库 `4kercc/V2BX-malio`；
  - 增加交互式配置��改菜单；
  - 增加快捷命令：`v2bx set host|key|id|domain <val>`；
  - 增加 WARP 切换命令：`v2bx warp on|off|status`。
* **`update-v2bx.sh`**
  - 提供安全跨版本抢救与强制更新单行脚本，先验证语法后原子替换 `/usr/bin/V2bX`，保证存量服务器一键对齐最新逻辑。

### 4. 证书链路（面板驱动 + ACME 失败降级）

* **`conf/cert.go`**
  - 新增 `AutoFromPanel`（证书模式由面板推导，绝不覆盖运维显式配置）、`PanelPush`/`CertContent`/`KeyContent`/`PanelPushDir`（面板推送证书）、`ECHKey`/`ECHServerName`/`ACMEDataDirectory`、`StrictACMEFailure`（ACME 失败时保持旧行为：不启动节点）。
* **`node/cert_panel.go`**
  - 域名推导：只取面板 `server` 主段（`CommonNode.Host`），**不取 `server_name`**——AnyTLS 里它是客户端伪装 SNI（如 `updates.cdn-apple.com`），本机无权为其申请证书；IP / 单标签主机名直接判为不可签发。
  - 面板推送证书（内联或 `PanelPushDir/cert.pem|key.pem`）原子落盘并清除降级标记；仅有域名时自动把 `CertMode` 从 `none` 提升为 `http`（`AutoFromPanel`）。
* **`node/cert.go`**
  - **ACME 申请失败降级**：安装自签证书（CN/SAN=域名）保证节点起得来，写 `CERT-FALLBACK` 告警与 `<CertFile>.acme-fallback` 标记文件；`StrictACMEFailure=true` 时恢复"申请失败不启动"。
  - **自愈**：续期任务发现证书是自签（issuer==subject 且自验签）时走重新申请而非 `RenewCert`，成功后换正式证书并清除标记；剩余 <15 天时刷新自签占位。面板推送（`PanelPush`）的证书不做自动申请。
  - 写入健壮性：tmp+rename 原子替换、私钥 0600、PEM 标签修正为 `RSA PRIVATE KEY`（原来把 PKCS1 RSA 私钥标成了 `EC PRIVATE KEY`）。
* **`cloud-agent.sh` / `cloud-server.js`**
  - Agent 读取 `<CertFile>.acme-fallback` 并在心跳中上报 `cert.fallback/fallbackAt/fallbackError`，证书探测路径补 `/etc/V2bX/cert/<domain>/fullchain.pem`；
  - 面板对"ACME 失败降级"发事件 + Telegram/Webhook 告警，节点列表/卡片显示 `自签·ACME失败`（有意配置的自签只显示 `自签`，不告警）。

### 5. 云控中心（`cloud-server.js` + `cloud-agent*.sh`）

云控为独立于 V2bX 主程序的自研部分：控制中心（`203.88.114.11`，服务 `v2bx-cloud`，HTTPS `token.mx.mk:8765`）**无法主动连节点**，节点侧 agent 靠心跳 + `/api/wait` 长轮询拉取指令（管理端下发即唤醒，秒级送达）。

**（1）Google/YouTube 强制 IPv4 下发（GoogleV4 字段）**

* **背景**：部分机房 IPv6 直连出口被 Google 判定异常（搜索 302 跳 `/sorry/`），YouTube 打不开。
* **做法**：agent 改节点 `/etc/V2bX/sing_origin.json`（同时改 `sing_origin_direct.json` / `sing_origin_warp.json`，避免切 WARP 后补丁丢失）——插入直连出站 `v4-google`（`domain_resolver.strategy=ipv4_only`，server 复制现有 `direct` 出站的解析器）+ 前置 `domain_keyword`（google/youtube 系）路由，并把 `dns.strategy` 置为 `prefer_ipv4`。
* **安全网**：只在首次应用前备份、`jq` 校验、`systemctl restart V2bX` 后 2 秒查活性，起不来自动回滚再重启；`off` 按备份逐字节还原（含 `dns.strategy` 原值、原本没有的 `route`/`rules` 结构），已用 7 种文件结构变异做往返测试验证一致。
* **注意**：多 IP 机器上 V2bX 自动生成的"每节点出站规则"（`node_N_out` + `bind_address=SendIP`）是 **prepend**，优先于文件里的规则——这类节点的用户流量本就按 `SendIP`(v4)+`prefer_ipv4` 走 IPv4，文件规则是兜底；`SendIP` 为 IPv6 的节点会强制 v6 出口，文件规则覆盖不了（agent 会写日志告警）。
* **面板对照**：批量下发区「Google/YT 出口」下拉（强制 IPv4 / 恢复默认），可批量（整机字段）；开启后媒体标签显示绿色 `v4·强制`，悬停可看到绑定信息与"已强制"说明。

**（2）媒体解锁检测：按节点真实出口 IP 探测**

* **判据**：YouTube 带 `Cookie: SOCS=CAI` 取页面 `"GL":"XX"`；Google 用 `generate_204` + 搜索是否 302 跳 `/sorry/`（拉黑）；Netflix `-L` 跟随跳转并检查 `Not Available`；ChatGPT 看 HTTP 码 + `cdn-cgi/trace` 的 loc。
* **出口归属（关键）**：多 IP 机器上 V2bX 给每个节点生成 `node_N_out` 并绑 `SendIP`（同进同出），因此探测用 `curl --interface <该节点 SendIP>`，**一台机器上的多个节点各测各的 IP**；无 `SendIP` 的机器不绑定（用户走内核默认出口，不绑即为一致），地址族按 `dns.strategy` 选择。绑定前校验该地址在本机存在，绑定取不到结果自动回退默认路径重试一次。
* **结果新鲜度**：payload 带 `pv`（探测逻辑版本 `MEDIA_PV`），服务端 `MEDIA_PV` 同步提升后旧结果立即失效并自动补测（10 分钟退避）——避免"探测逻辑升级了、面板还挂着旧数据装正常"。另有 12 小时 TTL 自动补测。
* **面板呈现**：列表两行两列品牌图标 + `✓/✗(原因)`，末尾 v4/v6 出口协议标签；媒体检测弹窗显示出口 IP/归属地/「绑定」徽标；悬停显示完整出口 IP、绑定源与规则说明。结果入库 `src`/`pv` 字段（曾漏存 `src` 导致绑定信息显示不出来）。
* **实测结论**：数据中心 IP 的 ChatGPT 403 属正常；"Google 拉黑"最初 6 台全部是**本机默认路径（IPv6）**的假警报，按节点出口探测后各自 v4 均为正常；机队 5 台多节点机器全部实现"各节点各出各的 IP"。

**（3）Agent 版本与自更新机制**

* 面板说的 v2x 是**云控 agent 版本**（`cloud-agent.sh` 的 `AGENT_VER`），与节点上 V2bX 程序版本（列表「版本」列）无关；V2bX 升级走「升级选中」。
* 铺开流程：改完代码 `git push` → 面板「⚙ 全局设置 → Agent 目标版本」+1；节点心跳上报 `agentVer`，服务端发现低于目标就回 `agentUpdate:1`，agent 自 GitHub 拉取并原地替换（`bash -n` + 必须含 AGENT_VER + **下载版本必须更高**才覆盖），全网 1~2 分钟收敛，**无需逐台 SSH**。
* **两个硬教训**：① 自更新分支必须在 agent 最末尾——它 `exit 0`，曾抢在"配置变更重启"之前，导致改动写进文件却不重启、悬空不生效；② raw.githubusercontent.com 对分支有 300 秒 CDN 缓存，刚推的新版可能被旧版顶回，必须做版本比对防降级/防空转。
* 版本记录：**v21** 新增 GoogleV4；**v22/v23** 修自更新顺序与防降级；**v24** 媒体探测绑 `SendIP` + 上报 `src` + GoogleV4 补 `dns.strategy`；**v25** 新增 `MEDIA_PV` 探测版本号。
* 依赖说明：机器不可达/agent 没在跑的节点（如长期离线节点）无法自更新，需上机重跑 `cloud-agent-update.sh`（不带参数=已装则更新 agent+守护+cron），起来后会自动追到目标版本。

**（4）面板交互增强**

* **按分组批量操作**：批量下发区「目标分组」下拉（含"未分组"）；选中后 `targets()` 直接返回整组，下发/重启/升级/清除期望配置/删除/证书到期/媒体检测**全部作用于整组**（勾选被忽略），列表视图自动过滤到该分组并提示"共 N 台（在线 M 台）"。证书/媒体检测由原来的"未勾选=全部"改为分组优先，避免误伤全队。
* **行双击勾选**：鼠标在任意行内双击即勾选/取消该行（按钮/链接/输入框除外），选中行高亮（`tr.selrow`/`.ncard.selrow`），桌面表格与手机卡片勾选态同步；双击节点名仍是重命名（原行为不变）。
* **「面板 / 节点ID」列自动换行**：去掉省略号截断，长域名徽标整块折行、超长 token 可断行；该列 `th` 设 `min-width:200px`（否则 table-layout:auto 会把列压到 88px，导致所有单元格折成 5 行）。
* **节点类型固定 anytls**：面板不再提供类型切换（安装脚本默认与兜底均为 anytls）；服务端 `NODE_TYPES` 校验与 `NodeType` 单台下发能力保留（脚本可用 API 纠正历史遗留），列表对非 anytls 节点标黄提示。
* **登录页**：表单保留「账号(username) + 管理 Token(password)」两字段以兼容密码管理器（Bitwarden 等）的内联填充图标，但页面上不再显示解释文案；实际校验的始终是管理 Token，会话 Cookie 只在内存（服务重启即失效，用 `?token=` 重新登录）。

---

## 三、常用运维与升级命令汇总

1. **一键强制更新/对齐最新版**：
   ```bash
   bash <(curl -fsSL https://raw.githubusercontent.com/4kercc/V2BX-malio/main/update-v2bx.sh)
   ```
2. **AnyTLS 自签证书一键安装**：
   ```bash
   bash install_v2bx_anytls.sh "https://dy.jsq.mk" "jsqs" "28" "null"
   ```
3. **快捷修改配置参数**：
   ```bash
   v2bx set host https://dy.jsq.mk
   v2bx set key jsqs
   v2bx set id 30
   v2bx set domain jp.gpfggtech.xyz
   ```
4. **WARP 分流管理**：
   ```bash
   v2bx warp status   # 查看当前状态
   v2bx warp off      # 禁用 WARP 分流（全走原生 IP，省 40MB 内存）
   v2bx warp on       # 启用 WARP 分流（含自动回落）
   ```
5. **云控 agent（节点侧）排查与升级**：
   ```bash
   grep -m1 AGENT_VER= /usr/local/V2bX/cloud-agent.sh      # 当前 agent 版本
   journalctl -t v2bx-cloud -n 30                          # agent 日志（含 applied GoogleV4 / self-update / media 等）
   bash cloud-agent-update.sh                              # 不带参数：已装则更新 agent+守护+cron（不重装）
   ```
6. **云控全网铺开 agent 新版本**：代码 `git push` 后，面板「⚙ 全局设置 → Agent 目标版本」填新版本号即可；节点心跳发现落后会自拉更新（1~2 分钟），查落后节点看节点详情里的 `Agent vX`。
7. **云控媒体检测即席复测**：面板勾选节点（或选「目标分组」）→「🌐 媒体检测」；探测按各节点自己的出口 IP 进行，悬停图标可见出口 IP / 绑定源。
