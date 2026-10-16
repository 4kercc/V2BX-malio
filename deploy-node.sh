#!/bin/bash
############################################
# V2bX AnyTLS 节点部署（soga 风格：一条命令 + $1/$2 注入，支持多节点一次装完）
#
#   bash <(curl -Ls https://raw.githubusercontent.com/4kercc/V2BX-malio/main/deploy-node.sh) \
#        <NodeID列表> <域名列表> [ApiHost] [ApiKey]
#
#   例（3 个节点一次装完）：
#     bash deploy-node.sh 37,38,39 \
#          hytron1.wukong.us.kg,hytron2.wukong.us.kg,hytron3.wukong.us.kg \
#          https://72v.net wukongs
#
#     · NodeID 支持逗号或点号分隔：37,38,39 / 37.38.39
#     · 节点数量由 $1 自动判定，域名按顺序一一对应（数量必须一致）
#     · 域名可只写前缀（hytron1）→ 自动拼 DOMAIN_SUFFIX（默认 stpikit.com）
#     · ApiKey 给一个 = 全部共用（面板常见做法）；给逗号分隔的一串 = 按节点顺序对应
#
#   行为：
#     · 机器上还没有 V2bX → 调标准安装脚本一次装完（含 WARP 分流/系统调优/systemd）
#     · 已经在跑      → 只追加/更新这些节点，域名自动并入机器级证书
#                       （一张证书覆盖全机所有域名，只由第一个节点签发与续期）
#     · 地址默认全自动：ListenIP=auto（按该节点域名的 A 记录）、SendIP=auto（同进同出）、
#       ListenIP6=auto（本机空闲公网 v6，按节点固定）
#
# 环境变量（都可省）：
#   API_HOST / API_KEY       面板地址与密钥（缺省则交互询问）
#   DOMAIN_SUFFIX            域名后缀，默认 stpikit.com（$2 已含点号时忽略）
#   LISTEN / LISTEN6 / SEND  覆盖地址（默认 auto；SEND 可写 0 表示不绑定）
#   CERT_KEY_TYPE            证书密钥类型，默认 ec-256
#   WARP_MODE                on/off（仅首次安装时生效，默认 on）
#   CLOUD_URL / CLOUD_TOKEN  顺带接入云控中心（仅首次安装时生效）
#   SKIP_DNS_CHECK            跳过安装前 DNS 预检（默认：域名必须解析到本机，否则提示并退出）
############################################

set -e

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; plain='\033[0m'

[[ $EUID -ne 0 ]] && { echo -e "${red}必须使用 root 运行${plain}"; exit 1; }

IDS_IN="${1:-}"
DOMAINS_IN="${2:-}"
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
  echo "用法: bash deploy-node.sh <NodeID列表> <域名列表> [ApiHost] [ApiKey]"
  echo "  例:  bash deploy-node.sh 37,38,39 a.wukong.us.kg,b.wukong.us.kg,c.wukong.us.kg https://72v.net <密钥>"
  echo "       bash deploy-node.sh 37 hytron1-1                  # 单节点，只写前缀（拼 DOMAIN_SUFFIX）"
  exit 1
}

[[ -z "$IDS_IN" || -z "$DOMAINS_IN" ]] && usage

# 列表切分：NodeID 支持 , . 空格；域名按 , 或空格（域名本身含点号）
split_list() { printf '%s' "$1" | tr "$2" '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'; }

declare -a IDS DOMAINS
while IFS= read -r id; do IDS+=("$id"); done < <(split_list "$IDS_IN" ',. ')
while IFS= read -r d; do DOMAINS+=("$d"); done < <(split_list "$DOMAINS_IN" ', ')

COUNT=${#IDS[@]}
if [[ $COUNT -eq 0 || ${#DOMAINS[@]} -eq 0 ]]; then usage; fi
if [[ ${#DOMAINS[@]} -ne $COUNT ]]; then
  echo -e "${red}节点数与域名数不一致：NodeID ${#IDS[@]} 个，域名 ${#DOMAINS[@]} 个${plain}"
  echo "  NodeID : ${IDS[*]}"
  echo "  域名   : ${DOMAINS[*]}"
  exit 1
fi

# 校验并补全域名（写 null = 自签）
declare -a FULL_DOMAINS
SELF_SIGNED=false
for i in "${!IDS[@]}"; do
  [[ "${IDS[$i]}" =~ ^[0-9]+$ ]] || { echo -e "${red}NodeID 不是数字: ${IDS[$i]}${plain}"; exit 1; }
  d="${DOMAINS[$i]}"
  if [[ "$d" == "null" || "$d" == "NULL" ]]; then
    SELF_SIGNED=true
    d="node${IDS[$i]}.selfsigned.local"
  elif [[ "$d" != *.* ]]; then
    d="${d}.${DOMAIN_SUFFIX}"
  fi
  [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo -e "${red}域名格式不对: $d${plain}"; exit 1; }
  FULL_DOMAINS+=("$d")
done

if [[ -z "$API_HOST" ]]; then read -rp "ApiHost (面板地址，如 https://72v.net): " API_HOST; fi
if [[ -z "$API_KEY"  ]]; then read -rp "ApiKey  (面板密钥；多个节点可用逗号按序给): " API_KEY; fi
[[ -z "$API_HOST" || -z "$API_KEY" ]] && { echo -e "${red}缺少 ApiHost / ApiKey${plain}"; exit 1; }

echo "==== 部署节点（自动判定节点数：$COUNT） ===="
for i in "${!IDS[@]}"; do
  echo "  [$((i+1))/$COUNT] NodeID=${IDS[$i]}  域名=${FULL_DOMAINS[$i]}"
done
echo "  面板     : $API_HOST"
echo "  监听/出口: $LISTEN / $LISTEN6 / $SEND（auto = 自动推导）"
echo ""

has_public_v6() { ip -6 -o addr show scope global 2>/dev/null | grep -q 'inet6 ' ; }
domain_points_here() {
  local dom="$1" ip local_ips
  [[ -z "$dom" ]] && return 1
  ip=$(getent ahostsv4 "$dom" 2>/dev/null | awk 'NR==1{print $1}')
  [[ -z "$ip" ]] && return 1
  local_ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')
  grep -qxF "$ip" <<<"$local_ips"
}
local_ipv4_addrs() { ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | sort -u; }

############################################
# DNS 预检：证书域名必须解析到本机，否则打印诊断并退出（不做任何更改）
#   跳过：SKIP_DNS_CHECK=1，或"显式 LISTEN + dns-01 签发"
############################################
dns_preflight() {
  local dom resolved ip hit local_ips bad=0 others
  local_ips=$(local_ipv4_addrs)
  echo ""
  echo "==== DNS 预检（证书域名需要解析到本机）===="
  echo "  本机 IPv4: $(tr '\n' ' ' <<<"$local_ips")"
  for dom in "$@"; do
    [[ -z "$dom" || "$dom" == *.selfsigned.local ]] && continue
    resolved=$(getent ahostsv4 "$dom" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    hit=""
    for ip in $resolved; do grep -qxF "$ip" <<<"$local_ips" && { hit="$ip"; break; }; done
    if [[ -z "${resolved// /}" ]]; then
      echo "  ✗ $dom: 没有 A 记录（DNS 未配置或尚未生效）"; bad=1
    elif [[ -n "$hit" ]]; then
      others=""
      for ip in $resolved; do [[ "$ip" != "$hit" ]] && others+="$ip "; done
      if [[ -n "$others" ]]; then
        echo "  ✓ $dom: $resolved（命中本机 $hit；⚠ 另有 $others 不指向本机，http-01 可能随机打到那边失败）"
      else
        echo "  ✓ $dom: $resolved（命中本机）"
      fi
    else
      echo "  ✗ $dom: 解析到 $resolved，不在本机"; bad=1
    fi
  done
  [[ $bad -eq 0 ]] && { echo "  预检通过"; return 0; }
  if [[ "${SKIP_DNS_CHECK:-}" == "1" ]]; then
    echo ""; echo "  [跳过] SKIP_DNS_CHECK=1：继续。未解析到本机的节点会在启动时被单独跳过并告警。"
    return 0
  fi
  echo ""
  echo "  ── DNS 预检未通过，已退出（未做任何更改）──"
  echo "  处理办法（任选其一）："
  echo "    1) 去 DNS 服务商把上面的域名 A 记录改成本机 IP，等生效后重跑本脚本"
  echo "       （Cloudflare 开了代理小云朵时会隐藏源站 IP：http-01 通常仍可用，确认无误可加 SKIP_DNS_CHECK=1）"
  echo "    2) 域名本来就不指向本机（跨机 / 中转）：CERT_DNS_PROVIDER=cloudflare CF_DNS_API_TOKEN=xxx LISTEN=0.0.0.0 重跑"
  echo "    3) 现在就要装、DNS 稍后再配：加 SKIP_DNS_CHECK=1 重跑（该节点会被跳过，配好 DNS 重启即可）"
  echo ""
  exit 1
}

############################################
# DNS 预检（本脚本先做一遍；委托安装脚本时会跳过它那边的重复检查）
############################################
if [[ "$SELF_SIGNED" == "true" ]]; then
  echo "自签证书模式：跳过 DNS 预检（不使用证书域名）。"
elif [[ -n "$CERT_DNS_PROVIDER" && "$LISTEN" != "auto" ]]; then
  echo "已配置 dns-01（$CERT_DNS_PROVIDER）+ 显式 ListenIP=$LISTEN：域名无需指向本机，跳过 DNS 预检。"
else
  dns_preflight "${FULL_DOMAINS[@]}"
fi

############################################
# 首次安装：本机没有 V2bX 时，交给标准安装脚本一次装完整机
############################################
if [[ ! -f "$CONFIG_JSON" || ! -x "$BIN" ]]; then
  echo "本机未安装 V2bX，先走标准安装（含 WARP 分流 / 系统调优 / systemd 服务）..."
  NODE_IDS=$(printf '%s,' "${IDS[@]}"); NODE_IDS="${NODE_IDS%,}"
  DOMAINS_ENV=$(printf '%s,' "${FULL_DOMAINS[@]}"); DOMAINS_ENV="${DOMAINS_ENV%,}"
  # 位置参数：1 ApiHost、2 ApiKey、3/4 留空（多节点模式走 NODE_IDS/DOMAINS 环境变量）、5 WARP、6/7 云控
  INST_ARGS=("$API_HOST" "$API_KEY" "" "" "$WARP_MODE")
  [[ -n "$CLOUD_URL"   ]] && INST_ARGS+=("$CLOUD_URL")
  [[ -n "$CLOUD_TOKEN" ]] && INST_ARGS+=("$CLOUD_TOKEN")
  NODE_IDS="$NODE_IDS" DOMAINS="$DOMAINS_ENV" LISTEN="$LISTEN" LISTEN6="$LISTEN6" SEND="$SEND" \
    CERT_KEY_TYPE="$CERT_KEY_TYPE" SKIP_DNS_CHECK=1 \
    bash <(curl -Ls "${REPO_RAW}/install_v2bx_anytls.sh") "${INST_ARGS[@]}"
  echo -e "${green}✓ 安装完成，$COUNT 个节点已启动${plain}"
  exit 0
fi

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

############################################
# 逐节点追加/更新（按 NodeID 幂等），域名并集进机器级证书
############################################
LISTEN6_VALUE="$LISTEN6"
if [[ "$LISTEN6" == "auto" ]] && ! has_public_v6; then
  LISTEN6_VALUE=""
  echo -e "${yellow}[提示] 本机没有公网 IPv6，本次不启用 v6 入口${plain}"
fi

TS=$(date +%Y%m%d-%H%M%S)
cp -a "$CONFIG_JSON" "${CONFIG_JSON}.bak-$TS"
echo "已备份配置: ${CONFIG_JSON}.bak-$TS"

KEYS=()
if [[ "$API_KEY" == *","* ]]; then
  while IFS= read -r k; do KEYS+=("$k"); done < <(split_list "$API_KEY" ', ')
  if [[ ${#KEYS[@]} -ne $COUNT ]]; then
    echo -e "${red}ApiKey 数量(${#KEYS[@]}) 与节点数($COUNT) 不一致${plain}"; exit 1
  fi
else
  for ((i=0; i<COUNT; i++)); do KEYS+=("$API_KEY"); done
fi

UPDATED="$CONFIG_JSON"
for i in "${!IDS[@]}"; do
  NODE_JSON=$(jq -nc \
    --arg host "$API_HOST" --arg key "${KEYS[$i]}" --argjson nid "${IDS[$i]}" \
    --arg dom "${FULL_DOMAINS[$i]}" --arg listen "$LISTEN" --arg listen6 "$LISTEN6_VALUE" --arg send "$SEND" \
    '{Core:"sing", ApiHost:$host, ApiKey:$key, NodeID:$nid, NodeType:"anytls", Timeout:30,
      ListenIP:$listen, SendIP:$send, DeviceOnlineMinTraffic:200, MinReportTraffic:0,
      TCPFastOpen:false, SniffEnabled:true,
      CertConfig:{CertDomain:$dom}}
     + (if $listen6 != "" then {ListenIP6:$listen6} else {} end)')

  jq --argjson node "$NODE_JSON" --arg dom "${FULL_DOMAINS[$i]}" --arg keytype "$CERT_KEY_TYPE" \
     --arg mode "$([[ "$SELF_SIGNED" == "true" ]] && echo self || echo http)" '
    # 该节点按标准模板重写；只保留运维自己加的东西（自定义 Name / 限速配置），
    # 证书相关字段一律丢弃（改为继承机器级证书）
    . as $cfg
    | ($cfg.Nodes // [] | map(select(.NodeID == $node.NodeID)) | .[0] // {}) as $old
    | $node + (if ($old.Name // "") != "" then {Name: $old.Name} else {} end)
              + (if ($old.LimitConfig // null) != null then {LimitConfig: $old.LimitConfig} else {} end)
    | . as $new
    | $cfg
    | .Nodes = (($cfg.Nodes // [] | map(select(.NodeID != $node.NodeID))) + [$new])
    | .Cert = ((.Cert // {}) + {
        CertMode: ((.Cert.CertMode // $mode)),
        KeyType: ((.Cert.KeyType // $keytype)),
        CertDomains: (((.Cert.CertDomains // []) + [$dom]) | unique)
      })
    | if (.Cert.Email // "") == "" then .Cert.Email = "v2bx@github.com" else . end
    ' "$UPDATED" > "${UPDATED}.tmp" && mv "${UPDATED}.tmp" "$UPDATED"
done

jq -e . "$UPDATED" >/dev/null || { echo -e "${red}生成的新配置不是合法 JSON，已保留原配置不动${plain}"; exit 1; }

echo ""
echo "==== 配置结果 ===="
jq -c '{Cert, Nodes: [.Nodes[] | {NodeID, ListenIP, ListenIP6, SendIP, CertDomain: .CertConfig.CertDomain}]}' "$UPDATED"

NEED_DNS=false
for d in "${FULL_DOMAINS[@]}"; do domain_points_here "$d" || NEED_DNS=true; done
if [[ "$NEED_DNS" == "true" ]]; then
  echo -e "${yellow}[注意] 有域名当前未解析到本机：这些节点若用 ListenIP=auto 会解析失败起不来。${plain}"
  echo -e "${yellow}       请先把 A 记录指过来，或把该节点的 ListenIP 改成 0.0.0.0。${plain}"
fi

echo ""
echo "重启 V2bX ..."
systemctl restart V2bX
sleep 5
if systemctl is-active --quiet V2bX; then
  echo -e "${green}✓ V2bX 运行中（$COUNT 个节点）${plain}"
else
  echo -e "${red}✗ V2bX 未起来，最近日志：${plain}"
  journalctl -u V2bX -n 15 --no-pager | tail -15
  echo -e "${yellow}回滚：cp -a ${CONFIG_JSON}.bak-$TS ${CONFIG_JSON} && systemctl restart V2bX${plain}"
  exit 1
fi

echo ""
echo "==== 关键日志 ===="
journalctl -u V2bX --since "-40s" --no-pager | grep -aE "ListenIP=auto|ListenIP6=auto|SendIP=auto|Machine certificate|acme:|Node started|tcp server started" | tail -12 || true

echo ""
echo "下一步："
echo "  1) 给这些域名配好 A 记录（指向本机）: ${FULL_DOMAINS[*]}"
if [[ -n "$LISTEN6_VALUE" ]]; then
  echo "  2) 如需 v6 入口，给域名加 AAAA（下面是本次分配到的 v6 地址）："
  journalctl -u V2bX --since "-2min" --no-pager | grep -a "ListenIP6=auto ->" | tail -"$COUNT" | sed 's/^.*Node /     /' || true
fi
echo "  3) 面板里这些节点的 server 填对应域名，端口 443（节点类型 anytls）"
