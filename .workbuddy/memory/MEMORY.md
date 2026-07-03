# V2bX 项目记忆

## 同进同出（Same IP In/Out）实现

**修改时间**: 2026-06-26

### 修改的文件

| 文件 | 修改内容 |
|------|----------|
| `conf/sing.go` | SingConfig 添加 `NodesConfig []NodeConfig` 字段（json:"-"，运行时注入） |
| `cmd/server.go` | NewCore 前将 NodeConfig 注入到 SingConfig.NodesConfig |
| `core/sing/sing.go` | New 函数中遍历 NodesConfig，自动生成 direct outbound（绑定 SendIP）+ 路由规则 |
| `node/controller.go` | buildNodeTag 简化为 `node_<NodeID>` 格式 |
| `core/sing/node.go` | 清理之前 AddNode 中的冗余 outbound 创建代码 |

### 工作原理

1. 读取 config.json 中每个节点的 `SendIP`
2. 在 sing-box 启动前（New 阶段）自动生成：
   - **Direct outbound**：绑定 `SendIP` 作为源 IP（dial.inet4_bind_address）
   - **路由规则**：inbound tag → 对应 outbound
3. tag 统一为 `node_<NodeID>` 格式（或 Options.Name）
4. outbound tag = tag + "_out"

### 配置示例

```json
{
  "Nodes": [{
    "ListenIP": "185.147.158.107",
    "SendIP": "185.147.158.107",
    "NodeID": 1049
  }]
}
```

不再需要手动配置 sing-box 原始配置文件中的路由规则。

## 编译

- Go 版本：1.24.2，安装在 `C:\Go`
- 编译机：Windows，目标平台：Linux amd64
- 使用 goproxy.cn 代理（默认 proxy.golang.org 不可达）
- 编译命令：
  ```
  $env:GOOS="linux"; $env:GOARCH="amd64"; $env:CGO_ENABLED="0"
  go build -tags "sing,xray,hysteria2,with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,with_clash_api" -o V2bX -ldflags="-s -w" main.go
  ```
- 产物：`V2bX`（约133MB，静态编译）
