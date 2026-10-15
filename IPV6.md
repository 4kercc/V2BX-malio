# V2bX 节点 IPv6 入口方案（通用，可复制到其他服务器）

> 本文是"让节点同时支持 IPv4 与 IPv6 客户端"的标准做法与决策依据，适用于本仓库的全部 AnyTLS 节点机器。
> 结论先行：**推荐 V2bX 原生双监听（`ListenIP6`）**，不要用端口转发。理由与对比见第 3 节。

---

## 1. 目标与现状

- 目标：同一个节点既要能被 IPv4 客户端连上，也要能被 IPv6 客户端连上；**出口仍走该节点原来的 IPv4（SendIP）**，落地归属、媒体解锁、GeoIP 判定都不变。
- 现状（典型）：机器有公网 IPv6，但 `ss -ntlp` 只有 `0.0.0.0:443` —— 一个 v6 监听都没有。

根因（源码级，不是猜测）：

1. V2bX 把配置里的 `ListenIP` 原样交给 sing-box（`core/sing/node.go`）；
2. sing-box 对 `0.0.0.0` 有特判：网络名被换成 **`tcp4`**（`sing/common/metadata/network.go`：`addr == IPv4Unspecified()` → `network + "4"`）；
3. Go 标准库（`net/ipsock_posix.go` 的 `favoriteAddrFamily`）：`tcp4` → `AF_INET`（纯 IPv4）；而 `tcp` + 通配 `::` → `AF_INET6` 且 `ipv6only=false` → **双栈**（同时收 v4-mapped）。

所以"只监听 v4"是 `ListenIP=0.0.0.0` 的必然结果。多节点机为了让每个节点有独立出口 IP，每个节点绑各自的 IPv4，因此不能简单地把所有节点都改成 `::`（同一端口上通配地址会互抢）。

---

## 2. 推荐方案：每节点多监听一个 IPv6 地址（`ListenIP6`）

v1.2.0 起支持。语义：

- `ListenIP6` = 该节点的**第二个监听地址**（裸地址，不带方括号与端口）；
- 同一节点、同一份用户/证书/填充方案；v6 客户端连的就是这个节点；
- 该节点 v6 连接的**限速、设备数、流量统计与 v4 完全共用**（内核 hook 层把 `node_<ID>_v6` 折回 `node_<ID>`，面板看到的仍是一个节点一份数据）；
- **出口仍由该节点的 `SendIP` 决定**（v6 进来、v4 出去）；
- 未配置 `ListenIP6` 的节点行为完全不变。

### 2.1 三种配置形态

| 机器形态 | 配置 | 结果 |
|---|---|---|
| 多节点机（每节点一个 v4，最常见） | `ListenIP: "45.x.x.x"` + `ListenIP6: "2401:db8:1::2"` | 每个节点两条监听：`45.x.x.x:443` 与 `[2401:db8:1::2]:443` |
| 单节点机（`ListenIP: "0.0.0.0"`） | `ListenIP6: "::"` | 自动**收敛为一个双栈监听** `[::]:443`（`::` 已覆盖 IPv4，不会两个套接字抢端口） |
| 单节点机（想绑定具体 v6） | `ListenIP6: "2401:db8:1::2"` | `0.0.0.0:443` + `[2401:db8:1::2]:443` 两条监听（互不冲突） |

通配收敛规则（`planListeners()`，有单测）：`0.0.0.0 + ::` → 只留 `::` 双栈；主监听已是 `::` 时额外地址被忽略；具体 v4 + 具体 v6 → 两条监听；具体 v4 + `::` **不收敛**（通配会占满整机、抢其他节点的地址），只作为第二监听尝试。

**安全网**：第二监听**绑定失败只降级**——节点继续在原有地址服务，日志打印 `IPv6 ingress on ... failed: <原因>`，绝不会因为 v6 地址写错把节点拖下线。

### 2.2 操作步骤（单机）

```bash
# 0) 看本机有哪些公网 v6（多节点机上每个节点要各占一个）
ip -o -6 addr show scope global | awk '{split($4,a,"/"); print a[1]}'

# 1) 备份配置
cp -a /etc/V2bX/config.json /etc/V2bX/config.json.bak-$(date +%F-%H%M)

# 2) 给节点加 ListenIP6（多节点机按 NodeID 指定各自地址）
jq '(.Nodes[] | select(.NodeID==37) | .ListenIP6) = "2401:db8:1::2"' \
   /etc/V2bX/config.json > /tmp/c.json && jq -e . /tmp/c.json >/dev/null && mv /tmp/c.json /etc/V2bX/config.json

# 3) 重启并确认监听（单节点机加 "::" 时应只看到一条 [::]:443）
systemctl restart V2bX && sleep 3 && ss -ntlp | grep ':443'

# 4) 本机验证（AnyTLS 端口上完成 TLS 握手即说明监听生效）
openssl s_client -connect '[2401:db8:1::2]:443' -servername updates.cdn-apple.com </dev/null 2>/dev/null | openssl x509 -noout -subject
```

### 2.3 客户端要解析到 v6：DNS 补 AAAA

节点监听好了，客户端还得**解析得到 v6 地址**才会走 v6：

```
hytron1.wukong.us.kg     AAAA  2401:b60:3d:2::2
hytron1-1.wukong.us.kg   AAAA  2401:b60:3d:1b::2
hk3.stpikit.com          AAAA  2401:b60:3d:1f::2     # 单节点双栈机：五个 v6 任选一个
```

- 不建议：先删 A 记录只留 AAAA（v4-only 用户会直接断）。
- 双栈（A + AAAA 同时存在）是正确形态：客户端按自己的网络能力选择，v4-only 用户不受影响。
- 没有 v6 的机器**不需要也不应该**加 AAAA。

---

## 3. 为什么不推荐"端口转发"（含各方案对比）

"v6 入口转发到 v4 节点"最常见的想法是加一层转发（socat / nginx stream / HAProxy / iptables 等）。**在 AnyTLS 上这些做法都有硬伤**：

| 方案 | 能不能用 | 致命问题 |
|---|---|---|
| **V2bX 原生 `ListenIP6`（推荐）** | ✅ | 无：同一节点、同一份状态、来源 IP 真实、面板统计一致 |
| socat / nginx stream / HAProxy 转发 `[v6]:443 → 127.0.0.1:443` | ⚠️ 技术上通，不推荐 | **客户端源 IP 全变成 127.0.0.1**：设备数/IP 限制、在线 IP 上报、异常 IP 判定全部失效（所有 v6 用户被当成同一个设备，第二台设备就会被踢）；用户流量还多一次内核↔用户态拷贝 |
| iptables/nftables DNAT v6→v4 | ❌ | **跨地址族无法 DNAT**：需要 NAT64/SIIT 级别的转换（有状态、需额外组件），不是一条规则能做的 |
| 单独起一个"v6 入口节点"（面板里再加一个节点，绑 v6 + SendIP 指 v4） | ⚠️ 可用但会分叉 | 用户/流量/限制变成两个节点两套：面板多一条记录、设备数各算各的、流量报表被拆成两份，运维上更容易出错 |
| 机器根本没有公网 v6 | — | 不用折腾：v6-only 客户端所在网络通常自带 DNS64/NAT64，能直接连你的 v4 节点；真要直连再考虑隧道代理（HE 6in4 等），但会引入额外延迟与依赖 |

> 一句话：**转发层能"通"，但会毁掉"按客户端 IP 计数"的一切功能**——而设备数限制正是这类服务收费与防滥用的核心。原生双监听没有这个问题。

---

## 4. 全队铺开（云控一键）

手动逐台改配置不适合几十台机器。云控已支持把 IPv6 入口作为**下发字段**：

1. 面板「批量下发 / 单台下发 → IPv6 入口」填 `auto`（推荐）或具体 v6 地址：
   - `auto`：agent 在本机公网 v6 里自动给每个节点分一个（分配结果就近缓存在 `/etc/V2bX/.v6-assign.json`，重启/重复下发不会漂移；已被其他节点显式占用的地址会跳过；v6 地址数量不足时按顺序分配并告警）；
   - `off`：关闭该节点的 IPv6 入口（可批量，例如整机没有 v6 时）；
   - 具体地址：只允许单台下发（地址是机器相关的，批量填同一个值会冲突），且 agent 会校验地址确实在本机接口上，否则拒绝写入。
2. agent 写入 `Nodes[].ListenIP6` 后走既有的"配置变更 → 重启 → 健康检查失败自动回滚"链路。
3. 节点心跳会把生效的 `cfg.ListenIP6` 回报面板：列表/卡片里有「IPv6」一行显示实际地址 → **照着它加 AAAA 记录**。

前置条件：云控 server 重新部署（`cloud-server.js` 已含 `ListenIP6` 字段与校验）+ 面板「全局设置 → Agent 目标版本」填 **26**（新 agent 脚本自带 `AGENT_VER="26"`；自更新只在"下载版本 > 当前版本"时生效，所以必须 +1 才能铺开）。

---

## 5. 验证清单（每台机器落地后照做）

```bash
# 监听：多节点机应出现 2×节点数 条（v4+v6），单节点双栈机一条 [::]:443
ss -ntlp | grep ':443'

# 本机自测（AnyTLS 端口能完成 TLS 握手、拿到该节点证书即正确）
openssl s_client -connect '[<该节点v6>]:443' -servername updates.cdn-apple.com </dev/null 2>/dev/null | openssl x509 -noout -subject

# 外部 v6 自测（用一台有公网 v6 的机器）
openssl s_client -connect '[<该节点v6>]:443' -servername updates.cdn-apple.com </dev/null 2>/dev/null | openssl x509 -noout -subject
```

验收标准：

- v4 端点证书不变、连接正常（回归）；
- v6 端点返回**该节点自己的证书**（多节点机上别把 A 节点的地址填到 B 节点）；
- 面板中该节点的流量/连接数在 v6 客户端连接后**仍然增长**（证明归因正常）；
- 日志无 `get limiter for node_<ID>_v6 error`（若出现说明归并失效，属 bug，应报回本项目）。

---

## 6. 回滚与排错

回滚（任一步）：

```bash
# 去掉 v6 入口
jq '(.Nodes[].ListenIP6) = null' /etc/V2bX/config.json > /tmp/c.json && mv /tmp/c.json /etc/V2bX/config.json
systemctl restart V2bX
# 或整份配置回滚
cp -a /etc/V2bX/config.json.bak-<你备份的时间戳> /etc/V2bX/config.json && systemctl restart V2bX
```

常见问题：

| 现象 | 原因与处理 |
|---|---|
| 日志 `IPv6 ingress on X failed: ... address already in use` | 该地址/端口已被占用，或你在多节点机给某节点写了 `::`（通配会占满整机）；改用该节点自己的具体 v6 地址 |
| 日志 `... cannot assign requested address` | 这个 v6 不在本机接口上（写错地址/写成了别的机器的）；用 `ip -o -6 addr` 核对 |
| 监听起来了但客户端连不上 | ① 域名没有 AAAA（用 `dig AAAA 域名` 确认）；② 机房防火墙/安全组未放行 v6 入站；③ 客户端本身没有 v6 出口 |
| 写成了 `[...]` 或 `addr:port` | 会绑定失败或绑到错误地址（`2401:db8::1:443` 本身是**合法** IPv6 地址，不会报语法错）；务必写裸地址 |
| v6 流量没进面板 | 检查是否真的连到了该节点（证书 CN）；确认 V2bX ≥ v1.2.1 |

---

## 7. 设计约束（改造本项目时需知）

- 额外入站的 tag 固定为 `node_<ID>_v6`（`secondaryInboundTag()`）。因此**节点 `Name` 不要以 `_v6` 结尾**再启用该功能（tag 会撞车，`AddNode` 会明确报错，不会静默算错流量）。
- 用户增删会同步到两个入站（`nodeInboundTags()`）；只在 `PanelPush`（面板推送）等并行路径上保持一致时注意同样处理。
- 出口绑定规则由 `buildSendIPRoute()` 一次生成，**同时覆盖两个 tag**；新增第三个监听地址时要一并扩展（当前设计是"一个主监听 + 一个 v6 监听"）。
