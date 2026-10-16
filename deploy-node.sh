#!/bin/bash
############################################
# V2bX AnyTLS 节点部署（soga 风格：一条命令 + $1/$2 注入变量）
#
#   bash <(curl -Ls https://raw.githubusercontent.com/4kercc/V2BX-malio/main/deploy-node.sh) <NodeID> <域名> [ApiHost] [ApiKey]
#
#   例：
#     bash deploy-node.sh 37 hytron1.wukong.us.kg        # 完整域名
#     bash deploy-node.sh 38 hytron1-1                   # 只写前缀 -> 拼 DOMAIN_SUFFIX（默认 stpikit.com）
#
#   行为：
#     · 机器上还没有 V2bX → 调标准安装脚本装好（含 WARP 分流/系统调优/服务），再写这个节点
#     · 已经在跑      → 只追加/更新这一个节点，域名自动并入机器级证书
#                       （一张证书覆盖全机所有域名，只由第一个节点签发与续期）
#     · 地址默认全自动：ListenIP=auto（按该节点域名的 A 记录）、SendIP=auto（同进同出）、
#       ListenIP6=auto（本机空闲公网 v6，按节点固定）
#
# 环境变量（都可省）：
#   API_HOST / API_KEY       面板地址与节点密钥（缺省则交互询问）
#   DOMAIN_SUFFIX            域名后缀，默认 stpikit.com（$2 已含点号时忽略）
#   LISTEN / LISTEN6 / SEND  覆盖地址（默认 auto；SEND 可写 0 表示不绑定）
#   CERT_KEY_TYPE            证书密钥类型，默认 ec-256
#   WARP_MODE                on/off（仅首次安装时生效，默认 on）
#   CLOUD_URL / CLOUD_TOKEN  顺带接入云控中心（仅首次安装时生效）
############################################

set -e

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; plain='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${red}必须使用 root 运行${plain}"; exit 1; }

NODEID="${1:-}"
DOMAIN_IN="${2:-}"
API_HOST="${3:-${API_HOST:-}}"
API_KEY="${4:-${API_KEY:-}}"
DOMAIN_SUFFIX="${DOMAIN_SUFFIX:-stpikit.com}"
LISTEN="${LISTEN:-auto}"
LISTEN6="${LISTEN6:-auto}"
SEND="${SEND:-auto}"
CERT_KEY_TYPE="${CERT_KEY_TYPE:-ec-256}"
WARP_MODE="${WARP_MODE:-on}"
CLOUD_URL="${CLOUD_URL:-}"
CLOUD_TOKEN="${CLOUD_TOKEN:-}"

CONFIG_JSON="/etc/V2bX/config.json"
BIN="/usr/local/V2bX/V2bX"
REPO_RAW="https://raw.githubusercontent.com/4kercc/V2BX-malio/main"

usage() {
  echo "用法: bash deploy-node.sh <NodeID> <域名> [ApiHost] [ApiKey]"
  echo "  例:  bash deploy-node.sh 37 hytron1.wukong.us.kg"
  echo "       bash deploy-node.sh 38 hytron1-1"
  exit 1
}

[[ -z "$NODEID" || -z "$DOMAIN_IN" ]] && usage
[[ "$NODEID" =~ ^[0-9]+$ ]] || { echo -e "${red}NodeID 必须是数字${plain}"; exit 1; }

# 域名：含点号视为完整域名，否则拼后缀
if [[ "$DOMAIN_IN" == *.* ]]; then
  DOMAIN="$DOMAIN_IN"
else
  DOMAIN="${DOMAIN_IN}.${DOMAIN_SUFFIX}"
fi
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo -e "${red}域名格式不对: $DOMAIN${plain}"; exit 1; }

if [[ -z "$API_HOST" ]]; then read -rp "ApiHost (面板地址，如 https://72v.net): " API_HOST; fi
if [[ -z "$API_KEY"  ]]; then read -rp "ApiKey  (该节点的面板密钥): " API_KEY; fi
[[ -z "$API_HOST" || -z "$API_KEY" ]] && { echo -e "${red}缺少 ApiHost / ApiKey${plain}"; exit 1; }

echo "==== 部署节点 ===="
echo "  NodeID   : $NODEID"
echo "  域名     : $DOMAIN"
echo "  面板     : $API_HOST"
echo "  监听/出口: $LISTEN / $LISTEN6 / $SEND（auto = 自动推导）"
echo ""

has_public_v6() { ip -6 -o addr show scope global 2>/dev/null | grep -q 'inet6 ' ; }
domain_points_here() {
  local dom="$1" ip local_ips
  ip=$(getent ahostsv4 "$dom" 2>/dev/null | awk 'NR==1{print $1}')
  [[ -z "$ip" ]] && return 1
  local_ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')
  grep -qxF "$ip" <<<"$local_ips"
}

############################################
# 首次安装：本机没有 V2bX 时就地调用标准安装脚本
############################################
if [[ ! -f "$CONFIG_JSON" || ! -x "$BIN" ]]; then
  echo "本机未安装 V2bX，先走标准安装（含 WARP 分流 / 系统调优 / systemd 服务）..."
  INST_ARGS=("$API_HOST" "$API_KEY" "$NODEID" "$DOMAIN" "$WARP_MODE")
  [[ -n "$CLOUD_URL"   ]] && INST_ARGS+=("$CLOUD_URL")
  [[ -n "$CLOUD_TOKEN" ]] && INST_ARGS+=("$CLOUD_TOKEN")
  LISTEN="$LISTEN" LISTEN6="$LISTEN6" SEND="$SEND" CERT_KEY_TYPE="$CERT_KEY_TYPE" \
    bash <(curl -Ls "${REPO_RAW}/install_v2bx_anytls.sh") "${INST_ARGS[@]}"
  echo -e "${green}✓ 安装完成，节点 $NODEID（$DOMAIN）已启动${plain}"
  exit 0
fi

############################################
# 已安装：追加/更新这一个节点（幂等，按 NodeID 匹配）
############################################
############################################
# 已安装：先确认二进制支持新写法（auto 地址 / 机器级证书需要 v1.3.0+）
############################################
CUR_VER=$("$BIN" version 2>/dev/null | grep -aoE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
if [[ -n "$CUR_VER" ]] && [[ "$(printf '%s\nv1.3.0\n' "$CUR_VER" | sort -V | head -1)" != "v1.3.0" ]]; then
  echo -e "${red}当前 V2bX 是 $CUR_VER，不支持 ListenIP/SendIP/ListenIP6 = auto 与机器级证书。${plain}"
  echo -e "${yellow}请先升级：bash <(curl -fsSL https://raw.githubusercontent.com/4kercc/V2BX-malio/main/update-v2bx.sh)${plain}"
  echo -e "${yellow}（或 v2bx update v1.3.0），然后重新运行本脚本。${plain}"
  exit 1
fi
command -v jq >/dev/null || { echo "安装 jq..."; (apt install -y jq || yum install -y jq) >/dev/null 2>&1; }

LISTEN6_VALUE="$LISTEN6"
if [[ "$LISTEN6" == "auto" ]] && ! has_public_v6; then
  LISTEN6_VALUE=""
  echo -e "${yellow}[提示] 本机没有公网 IPv6，$NODEID 不启用 v6 入口${plain}"
fi

TS=$(date +%Y%m%d-%H%M%S)
cp -a "$CONFIG_JSON" "${CONFIG_JSON}.bak-$TS"
echo "已备份配置: ${CONFIG_JSON}.bak-$TS"

NODE_JSON=$(jq -nc \
  --arg host "$API_HOST" --arg key "$API_KEY" --argjson nid "$NODEID" \
  --arg dom "$DOMAIN" --arg listen "$LISTEN" --arg listen6 "$LISTEN6_VALUE" --arg send "$SEND" \
  '{Core:"sing", ApiHost:$host, ApiKey:$key, NodeID:$nid, NodeType:"anytls", Timeout:30,
    ListenIP:$listen, SendIP:$send, DeviceOnlineMinTraffic:200, MinReportTraffic:0,
    TCPFastOpen:false, SniffEnabled:true,
    CertConfig:{CertDomain:$dom}}
   + (if $listen6 != "" then {ListenIP6:$listen6} else {} end)')

NEW_CONFIG=$(jq \
  --argjson node "$NODE_JSON" \
  --arg dom "$DOMAIN" \
  --arg keytype "$CERT_KEY_TYPE" \
  --arg mode "$([[ "$DOMAIN" == *.selfsigned.local ]] && echo self || echo http)" \
  '
  # 1) 追加或更新该节点（按 NodeID 匹配）
  .Nodes = ((.Nodes // []) | map(select(.NodeID != $node.NodeID)) + [$node])
  # 2) 机器级证书：域名并集去重（一张证书覆盖全机）
  | .Cert = ((.Cert // {}) + {
      CertMode: ((.Cert.CertMode // $mode)),
      KeyType: ((.Cert.KeyType // $keytype)),
      CertDomains: (((.Cert.CertDomains // []) + [$dom]) | unique)
    })
  | if (.Cert.CertDomains | length) == 0 then del(.Cert.CertDomains) else . end
  | if (.Cert.Email // "") == "" then .Cert.Email = "v2bx@github.com" else . end
  ' "$CONFIG_JSON")

echo "$NEW_CONFIG" | jq -e . >/dev/null || { echo -e "${red}生成的新配置不是合法 JSON，已保留原配置不动${plain}"; exit 1; }
echo "$NEW_CONFIG" > "${CONFIG_JSON}.tmp" && mv "${CONFIG_JSON}.tmp" "$CONFIG_JSON"

echo ""
echo "==== 配置结果 ===="
jq -c '{Cert, Nodes: [.Nodes[] | {NodeID, ListenIP, ListenIP6, SendIP, CertDomain: .CertConfig.CertDomain}]}' "$CONFIG_JSON"

if ! domain_points_here "$DOMAIN"; then
  echo -e "${yellow}[注意] $DOMAIN 当前未解析到本机：ListenIP=auto 会解析失败导致节点起不来。${plain}"
  echo -e "${yellow}       请先把 A 记录指过来，或把该节点 ListenIP 改成 0.0.0.0。${plain}"
fi

echo ""
echo "重启 V2bX ..."
systemctl restart V2bX
sleep 5
if systemctl is-active --quiet V2bX; then
  echo -e "${green}✓ V2bX 运行中${plain}"
else
  echo -e "${red}✗ V2bX 未起来，最近日志：${plain}"
  journalctl -u V2bX -n 15 --no-pager | tail -15
  echo -e "${yellow}回滚：cp -a ${CONFIG_JSON}.bak-$TS ${CONFIG_JSON} && systemctl restart V2bX${plain}"
  exit 1
fi

echo ""
echo "==== 关键日志 ===="
journalctl -u V2bX --since "-30s" --no-pager | grep -aE "ListenIP=auto|ListenIP6=auto|SendIP=auto|Machine certificate|acme:|Node started|tcp server started" | tail -10 || true

echo ""
echo "下一步："
echo "  1) 给 $DOMAIN 配好 A 记录（指向本机）"
if [[ -n "$LISTEN6_VALUE" ]]; then
  ADDR6=$(journalctl -u V2bX --since "-1min" --no-pager | grep -a "ListenIP6=auto ->" | tail -1 | sed 's/.*-> //')
  [[ -n "$ADDR6" ]] && echo "  2) 给 $DOMAIN 配 AAAA 记录: $ADDR6"
fi
echo "  3) 面板里该节点的 server 填 $DOMAIN，端口 443"
