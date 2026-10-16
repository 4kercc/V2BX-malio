#!/bin/bash
############################################
# V2bX AnyTLS 节点部署（soga 风格：一条命令 + $1/$2 注入，支持多节点一次装完）
#
#   bash <(curl -Ls https://raw.githubusercontent.com/4kercc/V2BX-malio/main/deploy-node.sh) \
#        <NodeID列表> <域名列表> [ApiHost] [ApiKey] [云控地址] [云控Token] [insecure]
#
#   例（3 个节点一次装完）：
#     bash deploy-node.sh 37,38,39 \
#          hytron1.wukong.us.kg,hytron2.wukong.us.kg,hytron3.wukong.us.kg \
#          https://72v.net wukongs
#
#   例（节点 + 云控一条命令装完）：
#     bash deploy-node.sh 37,38,39 hytron1,hytron2,hytron3 https://72v.net wukongs \
#          https://token.mx.mk:8765 <云控Token>
#
#     · NodeID 支持逗号或点号分隔：37,38,39 / 37.38.39
#     · 节点数量由 $1 自动判定，域名按顺序一一对应（数量必须一致）
#     · 域名可只写前缀（hytron1）→ 自动拼 DOMAIN_SUFFIX（默认 stpikit.com）
#     · 域名写 null / auto / panel → 安装时直接问面板要该节点的域名（heki 风格，免手填）：
#         多节点可以整列只写一个 null，各节点各自去要自己的域名；
#         面板里没配域名（server 是 IP）或密钥/NodeID 不对 → 打印原因并从本次部署剔除，
#         只剩一个都不成功则直接退出（不做任何更改）。面板里该节点的域名必须已解析到本机。
#     · 域名写 self / selfsigned → 自签证书（不申请 ACME）
#     · ApiKey 给一个 = 全部共用（面板常见做法）；给逗号分隔的一串 = 按节点顺序对应
#     · 云控地址/Token 给了就顺带接入云控（已接入过的机器幂等复用身份，不产生重复记录）
#
#   行为：
#     · 机器上还没有 V2bX → 调标准安装脚本一次装完（含 WARP 分流/系统调优/systemd）
#     · 已经在跑      → 只追加/更新这些节点，域名自动并入机器级证书
#                       （一张证书覆盖全机所有域名，只由第一个节点签发与续期）
#                       已存在的节点只覆盖受管字段（面板地址/密钥/NodeID/类型/地址/证书域名），
#                       其余字段（面板下发的 DomainStrategy/EnableDNS/EnableProxyProtocol、
#                       Name、限速配置等）原样保留；新节点才写标准模板
#     · 地址默认全自动（仅新节点）：ListenIP=auto（按该节点域名的 A 记录）、
#       SendIP=auto（同进同出）、ListenIP6=auto（本机空闲公网 v6，按节点固定）；
#       存量节点上已经钉死的地址会原样保留（除非显式传 LISTEN/LISTEN6/SEND 覆盖）
#
# 环境变量（都可省）：
#   API_HOST / API_KEY       面板地址与密钥（缺省则交互询问）
#   DOMAIN_SUFFIX            域名后缀，默认 stpikit.com（$2 已含点号时忽略）
#   LISTEN / LISTEN6 / SEND  覆盖地址（默认 auto；SEND 可写 0 表示不绑定）
#   CERT_KEY_TYPE            证书密钥类型，默认 ec-256
#   WARP_MODE                on/off（仅首次安装时生效，默认 on）
#   CLOUD_URL / CLOUD_TOKEN  云控中心地址与 Token（也可用 $5/$6 传入）
#   CLOUD_INSECURE=1         云控为自签 HTTPS 时强制免证书校验（一般无需，自动探测）
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
# 显式传了地址就用传的；没传时，存量节点上已有的固化值会被保留（重跑不会把钉死的地址改掉）
LISTEN_GIVEN=false;  [[ -n "${LISTEN:-}"  ]] && LISTEN_GIVEN=true
LISTEN6_GIVEN=false; [[ -n "${LISTEN6:-}" ]] && LISTEN6_GIVEN=true
SEND_GIVEN=false;    [[ -n "${SEND:-}"    ]] && SEND_GIVEN=true
LISTEN="${LISTEN:-auto}"
LISTEN6="${LISTEN6:-auto}"
SEND="${SEND:-auto}"
CERT_KEY_TYPE="${CERT_KEY_TYPE:-ec-256}"
WARP_MODE="${WARP_MODE:-on}"
CLOUD_URL="${5:-${CLOUD_URL:-}}"
CLOUD_TOKEN="${6:-${CLOUD_TOKEN:-}}"
CLOUD_INSECURE="${7:-${CLOUD_INSECURE:-}}"

CONFIG_JSON="/etc/V2bX/config.json"
BIN="/usr/local/V2bX/V2bX"
REPO_RAW="https://raw.githubusercontent.com/4kercc/V2BX-malio/main"

usage() {
  echo "用法: bash deploy-node.sh <NodeID列表> <域名列表> [ApiHost] [ApiKey] [云控地址] [云控Token] [insecure]"
  echo "  例:  bash deploy-node.sh 37,38,39 a.wukong.us.kg,b.wukong.us.kg,c.wukong.us.kg https://72v.net <面板密钥>"
  echo "       bash deploy-node.sh 28 null https://w.gpfggtech.xyz <面板密钥>   # 域名从面板取（免手填，heki 风格）"
  echo "       bash deploy-node.sh 27,28 null https://w.gpfggtech.xyz <面板密钥> # 多节点：各取自己的域名"
  echo "       bash deploy-node.sh 37,38,39 a,b,c https://72v.net <面板密钥> https://token.mx.mk:8765 <云控Token>   # 节点+云控一起装"
  echo "       bash deploy-node.sh 37 self https://72v.net <面板密钥>            # 自签证书（无域名时）"
  echo "       bash deploy-node.sh 37 hytron1-1                  # 单节点，只写前缀（拼 DOMAIN_SUFFIX）"
  exit 1
}

[[ -z "$IDS_IN" || -z "$DOMAINS_IN" ]] && usage

# 列表切分：NodeID 支持 , . 空格；域名按 , 或空格（域名本身含点号）
split_list() { printf '%s' "$1" | tr "$2" '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'; }

############################################
# 面板取域名（heki 风格）：域名写 null / auto / panel 时，安装时直接问面板要该节点的域名
#   SSPanel : GET {ApiHost}/mod_mu/nodes/{NodeID}/info?key={ApiKey}  → data.server
#   V2board : GET {ApiHost}/api/v1/server/UniProxy/config?node_id={ID}&node_type=anytls&token={Key} → server
#   两种面板的 server 都形如 "jp.gpfggtech.xyz;port=443&server_name=..."，取分号前那段
############################################
PANEL_MARK="__PANEL__"
PANEL_FETCH_ERR=""

ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  echo "安装 jq（取面板域名需要）..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y jq >/dev/null 2>&1 || { apt-get update -y >/dev/null 2>&1; apt-get install -y jq >/dev/null 2>&1; }
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y jq >/dev/null 2>&1
  elif command -v yum >/dev/null 2>&1; then
    yum install -y jq >/dev/null 2>&1
  fi
  command -v jq >/dev/null 2>&1
}

is_panel_marker() { case "${1,,}" in null|auto|panel) return 0 ;; *) return 1 ;; esac; }
is_self_marker()  { case "${1,,}" in self|selfsigned|none) return 0 ;; *) return 1 ;; esac; }

# 结果通过全局变量回传（不能用 $( ) 调用：命令替换会开子 shell，失败原因传不出来）
PANEL_FETCH_DOMAIN=""
PANEL_FETCH_ERR=""

# $1=ApiHost $2=ApiKey $3=NodeID；成功：PANEL_FETCH_DOMAIN=域名 且 return 0
panel_fetch_domain() {
  local host key nid resp raw dom attempt
  host="${1%/}"; key="$2"; nid="$3"
  PANEL_FETCH_DOMAIN=""; PANEL_FETCH_ERR=""
  ensure_jq || { PANEL_FETCH_ERR="本机没有 jq 且自动安装失败"; return 1; }
  for attempt in 1 2; do
    resp=$(curl -s --max-time 20 "${host}/mod_mu/nodes/${nid}/info?key=${key}" 2>/dev/null)
    raw=$(printf '%s' "$resp" | jq -r 'if ((.ret // 0) == 1) then ((.data.server // "") | tostring) else "" end' 2>/dev/null)
    [[ -z "$raw" ]] && {
      resp=$(curl -s --max-time 20 "${host}/api/v1/server/UniProxy/config?node_id=${nid}&node_type=anytls&token=${key}" 2>/dev/null)
      raw=$(printf '%s' "$resp" | jq -r '(.server // "") | tostring' 2>/dev/null)
    }
    [[ -n "$raw" ]] && break
  done
  if [[ -z "$raw" ]]; then
    PANEL_FETCH_ERR="面板没返回 server（SSPanel ret≠1、UniProxy 也不可用）：检查密钥 / NodeID / 节点是否启用 / 面板是否可达"
    return 1
  fi
  dom="${raw%%;*}"
  dom="$(printf '%s' "$dom" | tr -d '[:space:]')"
  dom="${dom#[}"; dom="${dom%]}"
  [[ "$dom" == *:* ]] && dom="${dom%%:*}"
  if [[ "$dom" == *:* || "$dom" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ \
        || ! "$dom" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ || "$dom" != *.* ]]; then
    PANEL_FETCH_ERR="面板返回的不是可签发域名：$raw（证书只能签域名，请先在面板把该节点的域名配好）"
    return 1
  fi
  PANEL_FETCH_DOMAIN="$(printf '%s\n' "$dom" | tr 'A-Z' 'a-z')"
  return 0
}

declare -a IDS DOMAINS
while IFS= read -r id; do IDS+=("$id"); done < <(split_list "$IDS_IN" ',. ')
while IFS= read -r d; do DOMAINS+=("$d"); done < <(split_list "$DOMAINS_IN" ', ')

COUNT=${#IDS[@]}
# 域名只写一个 null / auto / panel = 所有节点都从面板取自己的域名
if [[ ${#DOMAINS[@]} -eq 1 && $COUNT -gt 1 ]] && is_panel_marker "${DOMAINS[0]}"; then
  one="${DOMAINS[0]}"
  DOMAINS=()
  for ((i=0; i<COUNT; i++)); do DOMAINS+=("$one"); done
fi
if [[ $COUNT -eq 0 || ${#DOMAINS[@]} -eq 0 ]]; then usage; fi
if [[ ${#DOMAINS[@]} -ne $COUNT ]]; then
  echo -e "${red}节点数与域名数不一致：NodeID ${#IDS[@]} 个，域名 ${#DOMAINS[@]} 个${plain}"
  echo "  NodeID : ${IDS[*]}"
  echo "  域名   : ${DOMAINS[*]}"
  exit 1
fi

# 校验并补全域名：null/auto/panel = 从面板取；self/selfsigned = 自签
declare -a FULL_DOMAINS
SELF_SIGNED=false
PANEL_DOMAINS=0
SELF_DOMAINS=0
for i in "${!IDS[@]}"; do
  [[ "${IDS[$i]}" =~ ^[0-9]+$ ]] || { echo -e "${red}NodeID 不是数字: ${IDS[$i]}${plain}"; exit 1; }
  d="${DOMAINS[$i]}"
  if is_panel_marker "$d"; then
    d="$PANEL_MARK"
    PANEL_DOMAINS=$((PANEL_DOMAINS + 1))
  elif is_self_marker "$d"; then
    SELF_DOMAINS=$((SELF_DOMAINS + 1))
    d="node${IDS[$i]}.selfsigned.local"
  elif [[ "$d" != *.* ]]; then
    d="${d}.${DOMAIN_SUFFIX}"
  fi
  if [[ "$d" != "$PANEL_MARK" ]]; then
    [[ "$d" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { echo -e "${red}域名格式不对: $d${plain}"; exit 1; }
  fi
  FULL_DOMAINS+=("$d")
done
if [[ $SELF_DOMAINS -gt 0 && $SELF_DOMAINS -lt $COUNT ]]; then
  echo -e "${red}自签(self) 与域名不能混用：本机所有节点共用一张证书${plain}"; exit 1
fi
[[ $SELF_DOMAINS -gt 0 ]] && SELF_SIGNED=true

if [[ -z "$API_HOST" ]]; then read -rp "ApiHost (面板地址，如 https://72v.net): " API_HOST; fi
if [[ -z "$API_KEY"  ]]; then read -rp "ApiKey  (面板密钥；多个节点可用逗号按序给): " API_KEY; fi
[[ -z "$API_HOST" || -z "$API_KEY" ]] && { echo -e "${red}缺少 ApiHost / ApiKey${plain}"; exit 1; }

############################################
# 从面板取域名并回填（域名写了 null/auto/panel 的节点）
#   · 取不到的节点：打印原因后从本次部署里剔除（不写进配置，不动系统）
#   · 全部取不到：直接退出，不做任何更改
############################################
if [[ $PANEL_DOMAINS -gt 0 ]]; then
  echo ""
  echo "==== 从面板取域名（$PANEL_DOMAINS 个节点）===="
  declare -a FETCHED_OK=() FETCHED_BAD=()
  for i in "${!IDS[@]}"; do
    [[ "${FULL_DOMAINS[$i]}" == "$PANEL_MARK" ]] || continue
    if panel_fetch_domain "$API_HOST" "$API_KEY" "${IDS[$i]}"; then
      FULL_DOMAINS[$i]="$PANEL_FETCH_DOMAIN"
      FETCHED_OK+=("$i")
      echo -e "  ${green}✓${plain} NodeID ${IDS[$i]}: $PANEL_FETCH_DOMAIN"
    else
      FETCHED_BAD+=("$i")
      echo -e "  ${red}✗${plain} NodeID ${IDS[$i]}: $PANEL_FETCH_ERR"
    fi
  done
  if [[ ${#FETCHED_OK[@]} -eq 0 ]]; then
    echo ""
    echo -e "${red}── 面板没给出任何可签发域名，已退出（未做任何更改）──${plain}"
    echo "  处理办法："
    echo "    1) 去面板把该节点的服务器地址填成域名（不是 IP），确认密钥/NodeID 正确后重跑"
    echo "    2) 暂时没有域名：域名位置写 self 用自签证书安装"
    echo ""
    exit 1
  fi
  if [[ ${#FETCHED_BAD[@]} -gt 0 ]]; then
    # 剔除取不到域名的节点（连同它那一位的 ApiKey）
    declare -a KEEP_IDS KEEP_DOMS
    for i in "${!IDS[@]}"; do
      skip=false
      for b in "${FETCHED_BAD[@]}"; do [[ "$b" == "$i" ]] && skip=true; done
      [[ "$skip" == "true" ]] && continue
      KEEP_IDS+=("${IDS[$i]}"); KEEP_DOMS+=("${FULL_DOMAINS[$i]}")
    done
    if [[ "$API_KEY" == *","* ]]; then
      declare -a ALL_KEYS KEEP_KEYS
      while IFS= read -r k; do ALL_KEYS+=("$k"); done < <(split_list "$API_KEY" ', ')
      for i in "${!IDS[@]}"; do
        skip=false
        for b in "${FETCHED_BAD[@]}"; do [[ "$b" == "$i" ]] && skip=true; done
        [[ "$skip" == "true" ]] && continue
        KEEP_KEYS+=("${ALL_KEYS[$i]}")
      done
      API_KEY=$(printf '%s,' "${KEEP_KEYS[@]}"); API_KEY="${API_KEY%,}"
    fi
    IDS=("${KEEP_IDS[@]}"); FULL_DOMAINS=("${KEEP_DOMS[@]}"); COUNT=${#IDS[@]}
    echo -e "${yellow}  已剔除 ${#FETCHED_BAD[@]} 个取不到域名的节点，本次只部署：NodeID ${IDS[*]}${plain}"
    echo -e "${yellow}  （面板配好域名与密钥后，重跑本命令即可把被剔除的节点加回来）${plain}"
  fi
fi

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
  # 位置参数：1 ApiHost、2 ApiKey、3/4 留空（多节点模式走 NODE_IDS/DOMAINS 环境变量）、5 WARP、6/7/8 云控
  INST_ARGS=("$API_HOST" "$API_KEY" "" "" "$WARP_MODE")
  if [[ -n "$CLOUD_URL" && -n "$CLOUD_TOKEN" ]]; then
    INST_ARGS+=("$CLOUD_URL" "$CLOUD_TOKEN" "$CLOUD_INSECURE")
  fi
  NODE_IDS="$NODE_IDS" DOMAINS="$DOMAINS_ENV" LISTEN="$LISTEN" LISTEN6="$LISTEN6" SEND="$SEND" \
    CERT_KEY_TYPE="$CERT_KEY_TYPE" SKIP_DNS_CHECK=1 \
    bash <(curl -Ls "${REPO_RAW}/install_v2bx_anytls.sh") "${INST_ARGS[@]}"
  echo -e "${green}✓ 安装完成，$COUNT 个节点已启动${plain}"
  if [[ -n "$CLOUD_URL" && -n "$CLOUD_TOKEN" ]]; then
    echo -e "${green}✓ 云控也已接入：$CLOUD_URL（后台刷新即可看到本机）${plain}"
    echo -e "${yellow}  若上面云控那步报错，可单独重跑：bash <(curl -fsSL ${REPO_RAW}/cloud-join.sh) \"$CLOUD_URL\" \"$CLOUD_TOKEN\"${plain}"
  else
    echo -e "${yellow}提示：需要接云控可加参数：... <面板密钥> https://云控地址 <云控Token>${plain}"
  fi
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
KEPT=()
for i in "${!IDS[@]}"; do
  # 该节点已有配置里的地址（重跑保留判断：没显式传就沿用原值，新节点才用 auto）
  # 注意：逐个取值，不能用 IFS 切分——空字段会被 IFS 空白折叠，导致字段错位
  CUR_LISTEN=$(jq -r --argjson nid "${IDS[$i]}" '(.Nodes // [] | map(select(.NodeID == $nid)) | .[0] // {}) | .ListenIP // ""' "$UPDATED")
  CUR_LISTEN6=$(jq -r --argjson nid "${IDS[$i]}" '(.Nodes // [] | map(select(.NodeID == $nid)) | .[0] // {}) | .ListenIP6 // ""' "$UPDATED")
  CUR_SEND=$(jq -r --argjson nid "${IDS[$i]}" '(.Nodes // [] | map(select(.NodeID == $nid)) | .[0] // {}) | .SendIP // ""' "$UPDATED")
  LISTEN_EFF="$LISTEN"
  if [[ "$LISTEN_GIVEN" == "false" && -n "$CUR_LISTEN" ]]; then
    LISTEN_EFF="$CUR_LISTEN"
    [[ "$LISTEN_EFF" == "$LISTEN" ]] || KEPT+=("NodeID ${IDS[$i]}: ListenIP 保留 $LISTEN_EFF")
  fi
  LISTEN6_EFF="$LISTEN6_VALUE"
  if [[ "$LISTEN6_GIVEN" == "false" && -n "$CUR_LISTEN6" ]]; then
    LISTEN6_EFF="$CUR_LISTEN6"
    [[ "$LISTEN6_EFF" == "$LISTEN6_VALUE" ]] || KEPT+=("NodeID ${IDS[$i]}: ListenIP6 保留 $LISTEN6_EFF")
  fi
  SEND_EFF="$SEND"
  if [[ "$SEND_GIVEN" == "false" && -n "$CUR_SEND" ]]; then
    SEND_EFF="$CUR_SEND"
    [[ "$SEND_EFF" == "$SEND" ]] || KEPT+=("NodeID ${IDS[$i]}: SendIP 保留 $SEND_EFF")
  fi

  NODE_JSON=$(jq -nc \
    --arg host "$API_HOST" --arg key "${KEYS[$i]}" --argjson nid "${IDS[$i]}" \
    --arg dom "${FULL_DOMAINS[$i]}" --arg listen "$LISTEN_EFF" --arg listen6 "$LISTEN6_EFF" --arg send "$SEND_EFF" \
    '{Core:"sing", ApiHost:$host, ApiKey:$key, NodeID:$nid, NodeType:"anytls", Timeout:30,
      ListenIP:$listen, SendIP:$send, DeviceOnlineMinTraffic:200, MinReportTraffic:0,
      TCPFastOpen:false, SniffEnabled:true,
      CertConfig:{CertDomain:$dom}}
     + (if $listen6 != "" then {ListenIP6:$listen6} else {} end)')

  jq --argjson node "$NODE_JSON" --arg dom "${FULL_DOMAINS[$i]}" --arg keytype "$CERT_KEY_TYPE" \
     --arg listen6 "$LISTEN6_EFF" \
     --arg mode "$([[ "$SELF_SIGNED" == "true" ]] && echo self || echo http)" '
    # 新节点：写标准模板；已存在的节点：原样保留全部原有字段，只强制以下「受管字段」——
    #   ApiHost / ApiKey / NodeID / NodeType / ListenIP / SendIP / ListenIP6 / CertConfig
    #   （面板下发的 DomainStrategy、EnableDNS、EnableProxyProtocol，运维加的 Name、限速配置、
    #     SniffEnabled 等一律不动、也不凭空补模板默认值）
    . as $cfg
    | ($cfg.Nodes // [] | map(select(.NodeID == $node.NodeID)) | .[0] // {}) as $old
    | (if ($old | length) > 0
       then ($old | .ApiHost = $node.ApiHost | .ApiKey = $node.ApiKey
                  | .NodeID = $node.NodeID | .NodeType = $node.NodeType)
       else $node end)
    | .ListenIP = $node.ListenIP
    | .SendIP = $node.SendIP
    | .CertConfig = $node.CertConfig
    | (if $listen6 != "" then .ListenIP6 = $listen6 else del(.ListenIP6) end)
    | . as $new
    | $cfg
    | .Nodes = (($cfg.Nodes // []) as $all
        | if ($all | map(.NodeID) | index($new.NodeID)) != null
          then ($all | map(if .NodeID == $new.NodeID then $new else . end))   # 原地替换，保持节点顺序
          else ($all + [$new])                                               # 新节点追加到末尾
          end)
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
if [[ ${#KEPT[@]} -gt 0 ]]; then
  echo "==== 沿用原有地址（想改就显式传 LISTEN= / LISTEN6= / SEND= 重跑） ===="
  printf '  %s\n' "${KEPT[@]}"
fi
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

############################################
# 顺带接入云控（$5/$6 或 CLOUD_URL/CLOUD_TOKEN；已接入过的机器幂等复用身份）
#   委托 cloud-join.sh：只写 cloud.conf + agent + 守护，绝不碰节点配置
############################################
CLOUD_JOINED=false
if [[ -n "$CLOUD_URL" && -n "$CLOUD_TOKEN" ]]; then
  echo ""
  echo "==== 接入云控中心: $CLOUD_URL ===="
  if [[ -f /etc/V2bX/cloud.conf ]]; then
    CUR_CLOUD=$(grep -oP '^CLOUD_URL="\K[^"]+' /etc/V2bX/cloud.conf 2>/dev/null | head -1)
    [[ -n "$CUR_CLOUD" && "$CUR_CLOUD" != "$CLOUD_URL" ]] && \
      echo -e "${yellow}  注意：本机原来接的是 $CUR_CLOUD，本次改成 $CLOUD_URL${plain}"
  fi
  CLOUD_JOIN_TMP=$(mktemp /tmp/cloud-join.XXXXXX.sh)
  if curl -fsSL -o "$CLOUD_JOIN_TMP" "${REPO_RAW}/cloud-join.sh"; then
    if bash "$CLOUD_JOIN_TMP" "$CLOUD_URL" "$CLOUD_TOKEN" "" "$CLOUD_INSECURE"; then
      CLOUD_JOINED=true
    else
      echo -e "${yellow}⚠ 云控接入未完成（节点已更新完成，可稍后单独重跑 cloud-join.sh）${plain}"
    fi
  else
    echo -e "${yellow}⚠ cloud-join.sh 下载失败，云控接入跳过（节点已更新完成）${plain}"
  fi
  rm -f "$CLOUD_JOIN_TMP"
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
if [[ -n "$CLOUD_URL" && -n "$CLOUD_TOKEN" ]]; then
  if [[ "$CLOUD_JOINED" == "true" ]]; then
    echo "  4) 云控后台 $CLOUD_URL 刷新即可看到本机（表格里带云控名称与面板/节点ID）"
  else
    echo "  4) 云控未接入成功，稍后重跑: bash <(curl -fsSL ${REPO_RAW}/cloud-join.sh) \"$CLOUD_URL\" \"$CLOUD_TOKEN\""
  fi
fi
