# V2BX-malio 项目改动记录与功能文档

本文档记录本项目所做的所有架构优化、功能重构、Bug 修复与发布历史，用于后续问题回溯与接力维护。

---

## 一、版本演进与发布记录

| 版本 | 发布类型 | 核心改动说明 |
|---|---|---|
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
