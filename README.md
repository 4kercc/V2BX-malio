# V2bX SSPanel 对接版本

这是专门为 SSPanel-UIM 面板定制的 V2bX 版本，支持完整的 VLESS Reality 节点对接。

## 一键安装脚本
wget -N https://raw.githubusercontent.com/q42602736/V2BX-malio/main/install.sh && bash install.sh



## 直接安装anytls
wget -N https://raw.githubusercontent.com/4kercc/V2BX-malio/refs/heads/main/install-anytls.sh && bash install-anytls.sh

## 🚀 特性

- ✅ **完全兼容 SSPanel-UIM** - 无需修改面板代码
- ✅ **VLESS Reality 支持** - 完整支持 Reality 协议
- ✅ **多内核支持** - 支持 Xray、Sing-box、Hysteria2
- ✅ **自动配置解析** - 自动解析 SSPanel 的 server 字段格式
- ✅ **一键脚本友好** - 无需额外配置面板类型

## 📋 支持的节点类型

| 节点类型 | Sort值 | 内核支持 | 状态 |
|---------|--------|----------|------|
| VLESS | 15 | Xray, Sing | ✅ |
| VLESS Reality | 16 | Xray, Sing | ✅ |
| Trojan | 14 | Xray, Sing | ✅ |
| VMess | 11,12 | Xray, Sing | ✅ |
| Shadowsocks | 0,10 | Xray, Sing | ✅ |
| Hysteria2 | 17 | Hysteria2 | ✅ |
| AnyTLS | 18 | Sing | ✅ |

## 🔧 配置说明

### 基础配置 (单节点)

```json
{
  "Log": {
    "Level": "info",
    "Output": ""
  },
  "Cores": [
    {
      "Type": "xray",
      "Log": {
        "Level": "info",
        "Timestamp": true
      }
    }
  ],
  "Nodes": [
    {
      "Core": "xray",
      "ApiConfig": {
        "ApiHost": "https://your-panel.com",
        "ApiKey": "your-mukey-here",
        "NodeID": 1,
        "NodeType": "vless",
        "Timeout": 30
      },
      "Options": {
        "ListenIP": "0.0.0.0",
        "SendIP": "0.0.0.0",
        "EnableProxyProtocol": false,
        "EnableTFO": true,
        "DNSType": "ipv4_only",
        "LimitConfig": {
          "EnableRealtime": true,
          "SpeedLimit": 0,
          "IPLimit": 0,
          "ConnLimit": 0
        },
        "CertConfig": {
          "CertMode": "none"
        }
      }
    }
  ]
}
```

### 多内核配置

参考 `config_sspanel_multicore.json` 文件，支持同时运行多个内核和多个节点。

## 🛠️ 安装使用

### 1. 编译

```bash
cd V2bX
go build -o V2bX main.go
```

### 2. 配置

修改配置文件中的以下参数：
- `ApiHost`: 你的面板地址
- `ApiKey`: 面板的 muKey (在 .env 文件中)
- `NodeID`: 节点ID
- `NodeType`: 节点类型 (vless/trojan/vmess/shadowsocks)

### 3. 运行

```bash
./V2bX -config config_sspanel.json
```

## 📡 API 对接

V2bX 会自动调用以下 SSPanel API：

- `GET /mod_mu/nodes/{id}/info?key={mukey}` - 获取节点配置
- `GET /mod_mu/users?key={mukey}&node_id={id}` - 获取用户列表
- `POST /mod_mu/users/traffic?key={mukey}&node_id={id}` - 上报流量数据
- `POST /mod_mu/users/aliveip?key={mukey}&node_id={id}` - 上报在线用户

## 🔐 VLESS Reality 配置

在面板中创建 VLESS Reality 节点时，server 字段格式：

```
example.com;port=443&flow=xtls-rprx-vision&security=reality&dest=www.microsoft.com:443&serverName=www.microsoft.com&privateKey=xxx&shortId=xxx
```

V2bX 会自动解析这些参数并生成正确的配置。

## 🔒 AnyTLS 配置

在面板中创建 AnyTLS 节点时，server 字段格式：

```
example.com;port=443&server_name=example.com&padding_scheme=["0-255","1-5","10-20"]
```

参数说明：
- `port`: 监听端口（默认 443）
- `server_name`: SNI 服务器名称（可选，默认使用 host）
- `padding_scheme`: 填充方案，JSON 数组格式（可选，默认使用标准方案）

**注意**: AnyTLS 协议仅支持 Sing-box 内核，请在配置文件中使用 `"Core": "sing"`。

## 🐛 故障排除

### 1. 连接失败
- 检查 ApiHost 和 ApiKey 是否正确
- 确认面板的 muKey 设置正确
- 检查防火墙设置

### 2. 节点配置错误
- 确认节点的 sort 值正确
- 检查 server 字段格式是否符合要求
- 查看 V2bX 日志获取详细错误信息

### 3. 用户无法连接
- 检查节点状态是否正常
- 确认用户有权限使用该节点
- 检查证书配置是否正确

## 📝 日志

V2bX 会输出详细的日志信息，包括：
- 节点配置获取状态
- 用户列表同步状态
- 流量上报状态
- 错误信息和调试信息

建议在测试时将日志级别设置为 `debug` 以获取更多信息。

## 🤝 支持

如果遇到问题，请检查：
1. V2bX 日志输出
2. 面板后台日志
3. 网络连接状态
4. 配置文件格式

---

**注意**: 这个版本专门为 SSPanel-UIM 优化，不再支持 V2Board 面板。如需 V2Board 支持，请使用原版 V2bX。
