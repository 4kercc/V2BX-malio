# V2bX 云控中心使用文档

批量管理 10~20 台 V2bX 节点：后台查看节点状态与网络情况，单个/批量下发配置（换面板地址、换密钥、改节点 ID、WARP 开关），一键重启/升级。

## 架构

```
控制中心（Node 单文件，零依赖）  ←  浏览器打开 Web 后台
        ▲  ①节点每2分钟 POST /api/heartbeat（上报+拉取）
        └  ②返回期望配置 desired / 动作 action
节点 cloud-agent.sh（随安装脚本自动装，无入站端口）
```

- **拉取式**：节点主动出站访问控制中心，节点侧无需开放任何端口，NAT/防火墙友好
- **幂等**：期望配置与本地一致则什么都不做；有差异才修改 + 重启（≤2 分钟收敛）

## 一、部署控制中心（一键脚本，任一台你现有的服务器）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-install.sh) [端口，默认8765]
```

脚本自动完成：安装 Node.js → 下载控制中心 → **生成双随机 Token** → 注册 systemd 常驻（`v2bx-cloud`，开机自启+崩溃自动拉起）→ 打印后台地址/两把 Token/**可直接复制的节点接入命令**。凭证同时落盘 `/opt/v2bx-cloud/credentials.txt`（600 权限）。幂等：重复执行只更新程序，Token 与节点数据保留。

手动部署（等价方式）：

```bash
mkdir -p /opt/v2bx-cloud && cd /opt/v2bx-cloud
curl -fsSL -o cloud-server.js https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-server.js
node cloud-server.js          # 首次运行自动生成 cloud-data.json
```

- 常驻运行：推荐上面的 systemd 方式，或 `pm2 start cloud-server.js --name v2bx-cloud`；
- **安全要求**：用 Nginx/Caddy 反代并启用 HTTPS 后再暴露公网（agent 与后台都走这个地址）；
- 改端口：安装脚本传参，或 `PORT=9000 node cloud-server.js`。

## 二、节点接入（安装时传第 6/7 参数）

```bash
bash install_v2bx_anytls.sh "https://面板" "密钥" "节点ID" "域名或null" on "https://云控中心地址" "云控Token"
```

存量节点补装（**零改动接入**：不碰 config.json、不重启 V2bX，业务无感知）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-join.sh) "https://云控中心地址" "云控Token"
# 可选第三参数自定义名称: ... "Token" "hk-iepl-01"
```

## 二点五、批量接入时如何判定"哪台是谁"

- **自动命名**：接入脚本自动读取节点现有配置里的 `NodeID`，命名为 `node{NodeID}-{主机名}`（如 `node12-wowtank`），后台名称列直接对上面板节点；
- **实时身份**：后台表格"面板/节点ID"列每个心跳周期都从该机真实 config.json 读取显示，改了配置表格同步变，不会张冠李戴；
- **防串号**：服务端节点身份 = `名称 + 出口IP`，同名不同机的节点也不会合并混淆；
- 20 台批量接入：在你的一键下发后台逐台粘贴上面单行命令即可，每台自动起名，无需人工登记。

## 三、后台操作

浏览器打开控制中心地址 → 输入 Token：

| 功能 | 操作 |
|---|---|
| 查看节点 | 表格：在线状态/版本/内存/连接数/WARP 模式/面板地址+节点ID/最后心跳 |
| **按分组批量操作** | 批量下发区选「目标分组」（含"未分组"）→ 下方所有操作（下发/重启/升级/清除期望配置/删除/证书到期/媒体检测）都作用于整组，无需逐台勾选；列表视图会自动过滤到该分组并在下方显示"共 N 台（在线 M 台）" |
| **换面板地址**（网站迁移） | 填 ApiHost → 勾选节点或"下发到全部" → ≤2 分钟全部生效 |
| 改密钥/节点ID/证书域名 | 同上，对应字段即可 |
| WARP 批量开关 | 下拉选开/关 → 下发 |
| **Google/YT 强制 IPv4** | 用于 IPv6 出口被 Google 拉黑（搜索跳 `/sorry/`）的节点：下拉选"强制 IPv4" → 下发；整机改 `sing_origin.json` 并重启 V2bX，选"恢复默认（不强制）"一键还原 |
| 一键重启/一键升级 | 对应按钮，动作在节点下次心跳时执行 |
| 撤销未应用的配置 | "清除期望配置" |

## 四、工作细节

- **批量下发保护**：NodeID 是每台节点不同的差异化字段，**服务端直接禁止**批量/全部下发（只能单台设置），防止把 20 台全改成同一个节点；ApiHost/ApiKey/CertDomain/Warp/GoogleV4 可安全批量；
- **节点类型固定 anytls**：面板已不再提供类型切换（安装脚本默认与兜底都是 anytls）；列表里类型不一致的节点会标黄提示，如需纠正可用 API（`/api/desired` 传 NodeType）单台下发；
- **配置修改不破坏其他内容**：agent 用字段级 sed 只改目标字段，config.json 里的监听 IP、证书路径、内核配置等一概不动；
- **三重防呆**：修改前自动备份（`config.json.bak.cloud`）→ 修改后 `jq` 校验 JSON，失败自动回滚备份，**绝不带病重启** → 改 CertDomain 时若新域名无证书，自动生成 10 年自签兜底，节点不会重启即挂；
- 节点身份 = `NODE_NAME + 出口IP`，控制中心自动登记新节点；
- **媒体检测按"该节点真实出口 IP"探测**：多 IP 机器上 V2bX 会给每个节点生成 `node_N_out` 并绑定它的 `SendIP`（同进同出），面板即用 `curl --interface <该节点 SendIP>` 探测，**一台机器上的多个节点各测各的 IP**（悬停媒体图标可见"探测绑定节点出口 x.x.x.x"）；单节点/未配置 SendIP 的机器不绑定（用户走内核默认出口，探测不绑即为一致），地址族按节点 sing-box 的 `dns.strategy` 选择；
- **Google/YT 强制 IPv4（GoogleV4）**：agent 改 `/etc/V2bX/sing_origin.json`（同时改 WARP/直连两个模板，避免切 WARP 后补丁丢失）：插入直连出站 `v4-google`（`domain_resolver.strategy=ipv4_only`）+ 前置 Google/YouTube 域名路由，并把 `dns.strategy` 置为 `prefer_ipv4`；改前备份、`jq` 校验、重启后 2 秒活性检查，起不来自动回滚（`off` 按备份逐字节还原）。注意：多 IP 机器上 V2bX 自动生成的"每节点出站规则"**优先于**文件里的规则，这类节点的用户流量本来就按 `SendIP`(v4)+`prefer_ipv4` 走 IPv4；
- 心跳失败自动跳过本轮，不影响 V2bX 运行；agent 全程 `flock` 防并发；
- agent 日志进 journald：`journalctl -t v2bx-cloud`；升级日志：`/var/log/v2bx-cloud-update.log`；
- 手动测试 agent：`/usr/local/V2bX/cloud-agent.sh && journalctl -t v2bx-cloud -n 5`。

## 五、安全模型（v2）

1. **双 Token 分离**：
   - `token`（管理）——只用于后台登录与管理接口；
   - `nodeToken`（节点）——只用于 agent 心跳，后台"全局设置"栏查看；
   - **节点失陷不再等于全群失陷**：泄露某台节点的 nodeToken 只能伪造它的心跳，改不了任何配置。
2. **默认 Token 门禁**：`cloud-data.json` 里的 token/nodeToken 未修改（仍是 changeme-*）时，服务端**拒绝所有接口（403）**并在控制台打印醒目警告，强制改密后才可用；
3. **限速**：心跳每 IP 每分钟 10 次上限；认证失败每 IP 每分钟 10 次，超出返回 429——爆破不可行；
4. **常量时间比较**：Token 校验使用 `crypto.timingSafeEqual`，无时序侧信道；
5. **升级版本锁定**：后台"全局设置"可锁定升级版本（如 `v1.0.9`），"升级选中"动作将下发指定版本（留空 = 最新 Release），避免不可控的 main 分支滚动；
6. **HTTPS 仍为强制要求**：用 Nginx/Caddy 反代启用 TLS 后再暴露公网——心跳请求体含各节点 ApiKey，明文可被嗅探；
7. Token 泄露应急：编辑 `cloud-data.json` 换新 Token 重启进程，然后逐台更新节点 cloud.conf（或直接重跑 cloud-join.sh）。

### 初次部署必做

```bash
# 生成两把随机密钥并写入 cloud-data.json
NEW_ADMIN=$(openssl rand -hex 16); NEW_NODE=$(openssl rand -hex 16)
node -e "const fs=require('fs');const f='cloud-data.json';const d=JSON.parse(fs.readFileSync(f));d.token=process.argv[1];d.nodeToken=process.argv[2];fs.writeFileSync(f,JSON.stringify(d,null,2))" $NEW_ADMIN $NEW_NODE
pm2 restart cloud-server && echo "管理Token: $NEW_ADMIN / 节点Token: $NEW_NODE"
```

### 初次部署必做
