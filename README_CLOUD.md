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

## 一、部署控制中心（任一台你现有的服务器）

```bash
mkdir -p /opt/v2bx-cloud && cd /opt/v2bx-cloud
curl -fsSL -o cloud-server.js https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-server.js
node cloud-server.js          # 首次运行自动生成 cloud-data.json
```

- 首次生成的 `cloud-data.json` 里有 `token` 字段（管理密钥），**务必改成自己的随机串**后重启进程；
- 常驻运行：`pm2 start cloud-server.js --name v2bx-cloud` 或 systemd；
- **安全要求**：用 Nginx/Caddy 反代并启用 HTTPS 后再暴露公网（agent 与后台都走这个地址）；
- 改端口：`PORT=9000 node cloud-server.js`。

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
| **换面板地址**（网站迁移） | 填 ApiHost → 勾选节点或"下发到全部" → ≤2 分钟全部生效 |
| 改密钥/节点ID/证书域名 | 同上，对应字段即可 |
| WARP 批量开关 | 下拉选开/关 → 下发 |
| 一键重启/一键升级 | 对应按钮，动作在节点下次心跳时执行 |
| 撤销未应用的配置 | "清除期望配置" |

## 四、工作细节

- **批量下发保护**：NodeID 是每台节点不同的差异化字段，**服务端直接禁止**批量/全部下发（只能单台设置），防止把 20 台全改成同一个节点；ApiHost/ApiKey/CertDomain/Warp 可安全批量；
- **配置修改不破坏其他内容**：agent 用字段级 sed 只改目标字段，config.json 里的监听 IP、证书路径、内核配置等一概不动；
- **三重防呆**：修改前自动备份（`config.json.bak.cloud`）→ 修改后 `jq` 校验 JSON，失败自动回滚备份，**绝不带病重启** → 改 CertDomain 时若新域名无证书，自动生成 10 年自签兜底，节点不会重启即挂；
- 节点身份 = `NODE_NAME + 出口IP`，控制中心自动登记新节点；
- 心跳失败自动跳过本轮，不影响 V2bX 运行；agent 全程 `flock` 防并发；
- agent 日志进 journald：`journalctl -t v2bx-cloud`；升级日志：`/var/log/v2bx-cloud-update.log`；
- 手动测试 agent：`/usr/local/V2bX/cloud-agent.sh && journalctl -t v2bx-cloud -n 5`。

## 五、安全边界（务必阅读）

1. Token 是唯一凭证：泄露 = 20 台节点配置可被任意改写。**必须 HTTPS**，Token 用 32 位以上随机串；
2. 不要把控制中心直接裸奔在公网 HTTP 上；可再加 Nginx Basic Auth 双保险；
3. agent 只接受有限字段（ApiHost/ApiKey/NodeID/CertDomain/Warp）与两个动作（restart/update），不执行任意命令；
4. update 动作会执行 update-v2bx.sh（从本仓库 main 拉取）——请确保仓库安全（GitHub 账号开 2FA）。
