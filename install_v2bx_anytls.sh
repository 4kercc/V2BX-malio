#!/bin/bash

set -e

############################################
# 共用参数
#
# 多节点（推荐，一次装完整台机器）：
#   NODE_IDS="37,38,39"  DOMAINS="a.com,b.com,c.com"（数量必须一致）
#   两者都可用逗号/点号/空格分隔，节点数由 NODE_IDS 自动判定
#
# 位置参数（单节点，或配合多节点模式提供面板信息）：
#   1 API_HOST   面板地址（如 https://72v.net）
#   2 API_KEY    面板节点密钥（多个节点用同一个就写一个；也可用逗号按序对应）
#   3 NODE_ID    节点 ID
#   4 DOMAIN     证书域名；写 null / auto / panel = 安装时向面板取该节点的域名（免手填）；
#                写 self / selfsigned = 自签证书；留空 = 自签
#   5 WARP_MODE  on/off（默认 on）
#   6/7/8        云控中心地址 / Token / insecure（可选）
#
# 进阶（环境变量，都可省；v1.3.0 起一张证书覆盖多个域名、地址可自动推导）：
#   LISTEN=auto                  监听地址（auto=按该节点域名的 A 记录解析；也可 0.0.0.0 / :: / 具体 IP）
#   LISTEN6=auto                 IPv6 入口（auto=本机空闲公网 v6；留空=不启用）
#   SEND=auto                    出口地址（auto=跟随监听地址，同进同出；0=不绑定）
#   CERT_KEY_TYPE=ec-256         证书密钥类型（ec-256 / ec-384 / rsa2048 / rsa4096）
#   CERT_DNS_PROVIDER=cloudflare 用 dns-01 签发（域名不必指向本机；另配 CF_DNS_API_TOKEN 等）
#   SKIP_DNS_CHECK=1             跳过安装前的 DNS 预检（默认：域名必须已解析到本机，否则提示并退出）
############################################
API_HOST="${1:-}"
API_KEY="${2:-}"
NODE_ID="${3:-}"
DOMAIN="${4:-}"
# 第5个参数：是否启用内置 WARP 分流（on/off，默认 on）
WARP_MODE="${5:-on}"
# 第6/7个参数：云控中心地址与 Token（可选，接入后可在后台查看节点并批量下发配置）
# 第8个参数：云控为自签 HTTPS 时传 insecure（心跳免证书校验）
CLOUD_URL="${6:-}"
CLOUD_TOKEN="${7:-}"
CLOUD_INSECURE="${8:-}"

# 地址与证书的可选项（不填就用推荐值）
LISTEN_OPT="${LISTEN:-}"
LISTEN6_OPT="${LISTEN6:-}"
SEND_OPT="${SEND:-}"
CERT_KEY_TYPE="${CERT_KEY_TYPE:-ec-256}"
CERT_DNS_PROVIDER="${CERT_DNS_PROVIDER:-}"

WARP_ENABLED=true
case "$WARP_MODE" in
  off|OFF|false|False|0|no|NO) WARP_ENABLED=false ;;
esac

# 多节点列表（NODE_IDS / DOMAINS，逗号/点号/空格分隔）
NODE_IDS_IN="${NODE_IDS:-}"
DOMAINS_IN="${DOMAINS:-}"
MULTI_MODE=false
if [[ -n "$NODE_IDS_IN" || -n "$DOMAINS_IN" ]]; then
  MULTI_MODE=true
fi

split_list() { # $1=原始串 $2=分隔符正则（默认逗号/点号/空格）→ 逐行输出、去空白去空项
  local raw="$1" sep="${2:-,. }"
  printf '%s' "$raw" | tr "$sep" '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
}

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

declare -a NODE_IDS_LIST DOMAINS_LIST KEYS_LIST
if [[ "$MULTI_MODE" == "true" ]]; then
  # 节点 ID：点号/逗号/空格都支持（37.38.39 / 37,38,39）
  while IFS= read -r id; do NODE_IDS_LIST+=("$id"); done < <(split_list "$NODE_IDS_IN" ',. ')
  # 域名：只按逗号/空格分（域名本身含点号）
  while IFS= read -r dom; do DOMAINS_LIST+=("$dom"); done < <(split_list "$DOMAINS_IN" ', ')
  if [[ ${#NODE_IDS_LIST[@]} -eq 0 || ${#DOMAINS_LIST[@]} -eq 0 ]]; then
    echo "[ERROR] 多节点模式需要 NODE_IDS 与 DOMAINS（例：NODE_IDS=37,38,39 DOMAINS=a.com,b.com,c.com）"
    exit 1
  fi
  # 域名只写一个 null/auto/panel = 所有节点都从面板取自己的域名
  if [[ ${#DOMAINS_LIST[@]} -eq 1 && ${#NODE_IDS_LIST[@]} -gt 1 ]] && is_panel_marker "${DOMAINS_LIST[0]}"; then
    _one="${DOMAINS_LIST[0]}"
    DOMAINS_LIST=()
    for ((_i=0; _i<${#NODE_IDS_LIST[@]}; _i++)); do DOMAINS_LIST+=("$_one"); done
  fi
  if [[ ${#NODE_IDS_LIST[@]} -ne ${#DOMAINS_LIST[@]} ]]; then
    echo "[ERROR] 节点数与域名数不一致：NODE_IDS=${#NODE_IDS_LIST[@]} 个（${NODE_IDS_LIST[*]}），DOMAINS=${#DOMAINS_LIST[@]} 个（${DOMAINS_LIST[*]}）"
    exit 1
  fi
fi

# 域名占位：null / auto / panel = 安装时向面板取该节点的域名（heki 风格）
#           self / selfsigned / none = 强制自签（一台机器只能统一一种，因为共用一张证书）
USE_SELF_SIGNED=false
panel_domains=0
self_domains=0
total_domains=0
if [[ "$MULTI_MODE" == "true" ]]; then
  for idx in "${!DOMAINS_LIST[@]}"; do
    total_domains=$((total_domains + 1))
    if is_panel_marker "${DOMAINS_LIST[$idx]}"; then
      panel_domains=$((panel_domains + 1))
      DOMAINS_LIST[$idx]="$PANEL_MARK"
    elif is_self_marker "${DOMAINS_LIST[$idx]}"; then
      self_domains=$((self_domains + 1))
      DOMAINS_LIST[$idx]="node${NODE_IDS_LIST[$idx]}.selfsigned.local"
    fi
  done
  if [[ $self_domains -gt 0 && $self_domains -lt $total_domains ]]; then
    echo "[ERROR] 自签(self) 与域名不能混用：本机所有节点共用一张证书"
    exit 1
  fi
  [[ $self_domains -gt 0 ]] && USE_SELF_SIGNED=true
elif [[ -n "$API_HOST" && -n "$API_KEY" && -n "$NODE_ID" ]]; then
  if is_panel_marker "$DOMAIN"; then
    panel_domains=1
    DOMAIN="$PANEL_MARK"
  elif is_self_marker "$DOMAIN" || [[ -z "$DOMAIN" ]]; then
    USE_SELF_SIGNED=true
    DOMAIN="node${NODE_ID}.selfsigned.local"
  fi
elif is_panel_marker "$DOMAIN"; then
  DOMAIN="$PANEL_MARK"     # 交互模式：等问到面板地址/密钥后再取
elif is_self_marker "$DOMAIN"; then
  USE_SELF_SIGNED=true
  DOMAIN="node${NODE_ID:-1}.selfsigned.local"
fi

############################################
# 面板取域名（域名写了 null/auto/panel 的节点）
#   · 多节点：取不到的节点从本次安装剔除；一个都不成功就直接退出（未做任何更改）
#   · 单节点：取不到就退出并给出原因
############################################
if [[ $panel_domains -gt 0 && "$MULTI_MODE" != "true" ]]; then
  if [[ -z "$API_HOST" || -z "$API_KEY" ]]; then
    echo "[ERROR] 域名写了 null/auto/panel（从面板取），但缺少面板地址/密钥（位置参数 1/2）"
    exit 1
  fi
  if panel_fetch_domain "$API_HOST" "$API_KEY" "$NODE_ID"; then
    echo "面板域名：NodeID ${NODE_ID} -> $PANEL_FETCH_DOMAIN"
    DOMAIN="$PANEL_FETCH_DOMAIN"
  else
    echo "[ERROR] 从面板取域名失败：$PANEL_FETCH_ERR"
    echo "        暂时没有域名可把域名位置写 self（自签证书）；已在面板配好域名的，确认密钥/NodeID 后重跑"
    exit 1
  fi
fi

if [[ $panel_domains -gt 0 && "$MULTI_MODE" == "true" ]]; then
  if [[ -z "$API_HOST" || -z "$API_KEY" ]]; then
    echo "[ERROR] 多节点 + 域名从面板取：需要位置参数 1/2（面板地址与密钥）"
    exit 1
  fi
  NODE_COUNT=${#NODE_IDS_LIST[@]}
  fill_keys
  echo ""
  echo "==== 从面板取域名（$panel_domains 个节点）===="
  declare -a _keep_idx=() _bad_idx=()
  for idx in "${!DOMAINS_LIST[@]}"; do
    if [[ "${DOMAINS_LIST[$idx]}" != "$PANEL_MARK" ]]; then _keep_idx+=("$idx"); continue; fi
    if panel_fetch_domain "$API_HOST" "${KEYS_LIST[$idx]}" "${NODE_IDS_LIST[$idx]}"; then
      DOMAINS_LIST[$idx]="$PANEL_FETCH_DOMAIN"
      _keep_idx+=("$idx")
      echo "  ✓ NodeID ${NODE_IDS_LIST[$idx]}: $dom"
    else
      _bad_idx+=("$idx")
      echo "  ✗ NodeID ${NODE_IDS_LIST[$idx]}: $PANEL_FETCH_ERR"
    fi
  done
  if [[ ${#_bad_idx[@]} -gt 0 ]]; then
    if [[ ${#_keep_idx[@]} -eq 0 ]]; then
      echo ""
      echo "── 面板没给出任何可签发域名，已退出（未做任何更改）──"
      echo "   1) 去面板把该节点的服务器地址填成域名（不是 IP），确认密钥/NodeID 正确后重跑"
      echo "   2) 暂时没有域名：DOMAINS 写 self 用自签证书安装"
      exit 1
    fi
    declare -a _ids _doms
    for idx in "${_keep_idx[@]}"; do _ids+=("${NODE_IDS_LIST[$idx]}"); _doms+=("${DOMAINS_LIST[$idx]}"); done
    if [[ "$API_KEY" == *","* ]]; then
      declare -a _keys
      for idx in "${_keep_idx[@]}"; do _keys+=("${KEYS_LIST[$idx]}"); done
      API_KEY=$(printf '%s,' "${_keys[@]}"); API_KEY="${API_KEY%,}"
    fi
    NODE_IDS_LIST=("${_ids[@]}")
    DOMAINS_LIST=("${_doms[@]}")
    echo "  已剔除 ${#_bad_idx[@]} 个取不到域名的节点，本次只装：NodeID ${NODE_IDS_LIST[*]}"
    echo "  （面板配好域名与密钥后重跑本命令即可把被剔除的节点加回来）"
  fi
fi

# 每个节点对应的面板密钥（一个 = 全部共用；逗号串 = 按节点顺序）——供上面的取域名与后面的配置复用
fill_keys() {
  KEYS_LIST=()
  if [[ "$API_KEY" == *","* ]]; then
    local k
    while IFS= read -r k; do KEYS_LIST+=("$k"); done < <(split_list "$API_KEY" ', ')
    if [[ ${#KEYS_LIST[@]} -ne $NODE_COUNT ]]; then
      echo "[ERROR] ApiKey 数量(${#KEYS_LIST[@]}) 与节点数($NODE_COUNT) 不一致"
      exit 1
    fi
  else
    for ((i=0; i<NODE_COUNT; i++)); do KEYS_LIST+=("$API_KEY"); done
  fi
}

############################################
# 端口80提示（不再阻断安装）
#   v1.1.0 起证书申请失败会自动降级自签并告警，节点照常启动；
#   80 被占用时只有"自动签发/续期"会失败，这里只做提醒。
############################################
if [[ "$USE_SELF_SIGNED" != "true" ]]; then
  if lsof -i :80 -sTCP:LISTEN >/dev/null 2>&1 || ss -ltn 2>/dev/null | grep -q ':80 '; then
    echo "[提示] 端口 80 已被占用：http-01 证书校验会失败，节点将以自签证书启动并每天重试（如需正式证书请腾出 80，或改用 CERT_DNS_PROVIDER 走 dns-01）。"
  fi
fi

declare -a NODE_IDS DOMAINS SEND_IPS LISTEN_IPS LISTEN6_IPS

# 域名是否已经指向本机（决定能不能用 ListenIP=auto）
domain_points_here() {
  local dom="$1" ip local_ips
  [[ -z "$dom" ]] && return 1
  [[ "$dom" == *.selfsigned.local ]] && return 1
  ip=$(getent ahostsv4 "$dom" 2>/dev/null | awk 'NR==1{print $1}')
  [[ -z "$ip" ]] && return 1
  local_ips=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}')
  grep -qxF "$ip" <<<"$local_ips"
}

# 本机所有公网 IPv4（一行一个）
local_ipv4_addrs() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | sort -u
}

# 本机所有公网 IPv6（一行一个，排除链路本地）
local_ipv6_addrs() {
  ip -6 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' | grep -vi '^fe80' | sort -u
}

############################################
# DNS 预检：证书域名必须解析到本机
#   · 没有 A 记录、但 AAAA 指向本机公网 v6 = 纯 v6 域名（强制 v6 入口）→ 放行并提示
#   · 不通过 -> 打印诊断并退出（不做任何更改）
#   · 跳过条件：SKIP_DNS_CHECK=1，或"显式 ListenIP + dns-01 签发"（域名本就不必指向本机）
############################################
dns_preflight() {
  local dom resolved ip hit local_ips local_v6s bad=0 others v6resolved v6hit
  local_ips=$(local_ipv4_addrs)
  local_v6s=$(local_ipv6_addrs)

  echo ""
  echo "==== DNS 预检（证书域名需要解析到本机）===="
  echo "  本机 IPv4: $(tr '\n' ' ' <<<"$local_ips")"
  [[ -n "$local_v6s" ]] && echo "  本机 IPv6: $(tr '\n' ' ' <<<"$local_v6s")"

  for dom in "$@"; do
    [[ -z "$dom" || "$dom" == *.selfsigned.local ]] && continue
    resolved=$(getent ahostsv4 "$dom" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
    hit=""
    for ip in $resolved; do
      grep -qxF "$ip" <<<"$local_ips" && { hit="$ip"; break; }
    done
    if [[ -z "${resolved// /}" ]]; then
      # 没有 A 记录：允许「纯 v6 域名」——AAAA 指向本机公网 v6（强制 v6 入口的节点）
      v6resolved=$(getent ahostsv6 "$dom" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')
      v6hit=""
      for ip in $v6resolved; do
        grep -qxF "$ip" <<<"$local_v6s" && { v6hit="$ip"; break; }
      done
      if [[ -n "$v6hit" ]]; then
        echo "  ✓ $dom: 纯 v6 域名（AAAA 命中本机 $v6hit）——注意：该节点 ListenIP 必须显式给（如 127.0.0.1），ListenIP6 用 auto 或 $v6hit"
      else
        echo "  ✗ $dom: 没有 A 记录，AAAA ${v6resolved:-也没有} 也不在本机（DNS 未配置或尚未生效）"
        bad=1
      fi
    elif [[ -n "$hit" ]]; then
      others=""
      for ip in $resolved; do [[ "$ip" != "$hit" ]] && others+="$ip "; done
      if [[ -n "$others" ]]; then
        echo "  ✓ $dom: $resolved（命中本机 $hit；⚠ 另有 $others 不指向本机，http-01 可能随机打到那边失败）"
      else
        echo "  ✓ $dom: $resolved（命中本机）"
      fi
    else
      echo "  ✗ $dom: 解析到 $resolved，不在本机"
      bad=1
    fi
  done

  if [[ $bad -eq 0 ]]; then
    echo "  预检通过"
    return 0
  fi

  if [[ "${SKIP_DNS_CHECK:-}" == "1" ]]; then
    echo ""
    echo "  [跳过] SKIP_DNS_CHECK=1：继续安装。未解析到本机的节点会在启动时被单独跳过并告警。"
    return 0
  fi

  echo ""
  echo "  ── DNS 预检未通过，已退出（未做任何更改）──"
  echo "  处理办法（任选其一）："
  echo "    1) 去 DNS 服务商把上面的域名 A 记录改成本机 IP，等生效后重跑本脚本"
  echo "       （域名在 Cloudflare 且开了代理小云朵时，源站 IP 会被隐藏：http-01 通常仍可用，"
  echo "        确认无误可加 SKIP_DNS_CHECK=1 跳过本检查）"
  echo "    2) 域名本来就不指向本机（跨机 / 走中转 / 只想先装起来）："
  echo "       用 dns-01 签发并显式指定监听地址，例如"
  echo "       CERT_DNS_PROVIDER=cloudflare CF_DNS_API_TOKEN=xxx LISTEN=0.0.0.0 bash <本脚本> ..."
  echo "    3) 现在就要装、DNS 稍后再配：加 SKIP_DNS_CHECK=1 重跑（那个节点会被跳过，配好 DNS 重启即可）"
  echo ""
  exit 1
}

# 本机是否有公网 IPv6
has_public_v6() {
  ip -6 -o addr show scope global 2>/dev/null | grep -qv 'inet6 fe80' && return 0
  return 1
}

# 每节点密钥：定义已上移到「面板取域名」之前（那里也要按节点取密钥）
declare -a KEYS_LIST

if [[ "$MULTI_MODE" == "true" ]]; then
  ############################################
  # 多节点模式（NODE_IDS="37,38,39" DOMAINS="a,b,c"）：完全非交互，一次装完整台机器
  ############################################
  AUTO_INSTALL=true
  NODE_COUNT=${#NODE_IDS_LIST[@]}
  NODE_IDS=("${NODE_IDS_LIST[@]}")
  DOMAINS=("${DOMAINS_LIST[@]}")
  LISTEN_IPS=(); LISTEN6_IPS=(); SEND_IPS=()
  for ((i=0; i<NODE_COUNT; i++)); do
    dom="${DOMAINS[$i]}"
    if [[ -n "$LISTEN_OPT" ]]; then
      LISTEN_IPS+=("$LISTEN_OPT")
    elif [[ "$USE_SELF_SIGNED" == "true" ]]; then
      LISTEN_IPS+=("0.0.0.0")
    elif domain_points_here "$dom"; then
      LISTEN_IPS+=("auto")
    else
      LISTEN_IPS+=("0.0.0.0")
      echo "[提示] $dom 未解析到本机 -> 节点 ${NODE_IDS[$i]} 先监听 0.0.0.0（DNS 就绪后可改成 auto）"
    fi
    if [[ -n "$LISTEN6_OPT" ]]; then
      LISTEN6_IPS+=("$LISTEN6_OPT")
    elif [[ "$USE_SELF_SIGNED" == "true" ]]; then
      LISTEN6_IPS+=("")
    elif has_public_v6; then
      LISTEN6_IPS+=("auto")
    else
      LISTEN6_IPS+=("")
    fi
    SEND_IPS+=("${SEND_OPT:-auto}")
  done
  ACME_EMAIL="${ACME_EMAIL:-v2bx@github.com}"
  if [[ -z "$API_HOST" || -z "$API_KEY" ]]; then
    echo "[ERROR] 多节点模式需要面板地址与密钥（位置参数 1/2，或 API_HOST / API_KEY 环境变量）"
    exit 1
  fi
  fill_keys
elif [[ -n "$API_HOST" && -n "$API_KEY" && -n "$NODE_ID" ]]; then
  AUTO_INSTALL=true
  NODE_COUNT=1
  NODE_IDS=("$NODE_ID")
  DOMAINS=("$DOMAIN")
  fill_keys
  # 命令行模式：默认 auto（按域名解析监听地址、出口跟随、v6 自动分配）
  if [[ -n "$LISTEN_OPT" ]]; then
    LISTEN_IPS=("$LISTEN_OPT")
  elif domain_points_here "$DOMAIN"; then
    LISTEN_IPS=("auto")
  else
    LISTEN_IPS=("0.0.0.0")
    echo "[提示] 域名 $DOMAIN 当前未解析到本机，ListenIP 用 0.0.0.0；DNS 就绪后可在 config.json 改成 auto"
  fi
  if [[ -n "$LISTEN6_OPT" ]]; then
    LISTEN6_IPS=("$LISTEN6_OPT")
  elif has_public_v6; then
    LISTEN6_IPS=("auto")
  else
    LISTEN6_IPS=("")
  fi
  SEND_IPS=("${SEND_OPT:-auto}")
  ACME_EMAIL="v2bx@github.com"
else
  AUTO_INSTALL=false
  if [[ -z "$API_HOST" ]]; then read -p "API_HOST (e.g. https://baidu.com): " API_HOST; fi
  if [[ -z "$API_KEY" ]];  then read -p "API_KEY: " API_KEY; fi

  read -p "ACME Email (默认 v2bx@github.com): " ACME_EMAIL
  ACME_EMAIL=${ACME_EMAIL:-v2bx@github.com}

  read -p "是否启用内置 WARP 分流解锁 (on/off, 默认 on): " warp_in
  case "${warp_in:-on}" in
    off|OFF|false|False|0|no|NO) WARP_ENABLED=false ;;
    *) WARP_ENABLED=true ;;
  esac

  ############################################
  # 自动读取本机公网IP（IPv4 + IPv6）
  ############################################
  echo ""
  echo "==== 检测本机公网IP ===="
  # IPv4：排除 127.x 回环
  mapfile -t PUB_IPS4 < <(ip -4 addr show | grep -oP 'inet \K[\d.]+' | grep -v '^127\.' | sort -u)
  # IPv6：排除 ::1 回环和 fe80:: 链路本地地址
  mapfile -t PUB_IPS6 < <(ip -6 addr show | grep -oP 'inet6 \K[0-9a-f:]+' | grep -v '^::1$' | grep -iv '^fe80' | sort -u)

  # 合并为统一列表
  PUB_IPS=("${PUB_IPS4[@]}" "${PUB_IPS6[@]}")

  if [[ ${#PUB_IPS[@]} -eq 0 ]]; then
    echo "  未检测到公网IP，将使用 0.0.0.0"
  else
    echo "  检测到 ${#PUB_IPS[@]} 个IP："
    for ((j=0; j<${#PUB_IPS[@]}; j++)); do
      if [[ "${PUB_IPS[$j]}" == *:* ]]; then
        echo "    [$((j+1))] ${PUB_IPS[$j]}  (IPv6)"
      else
        echo "    [$((j+1))] ${PUB_IPS[$j]}  (IPv4)"
      fi
    done
    echo "    [0] 0.0.0.0 (不绑定，使用默认路由)"
  fi

  ############################################
  # 多节点参数采集
  ############################################
  echo ""
  echo "==== 节点配置 ===="
  echo "提示：ListenIP 填 auto = 按该节点域名的 A 记录自动定监听地址（推荐，域名需已指向本机）"
  echo "      也可填 0.0.0.0（仅 IPv4 全部）或 :: （IPv6+IPv4 双栈全部）或具体 IP"
  echo "      SendIP auto = 出口跟随监听地址（同进同出）；ListenIP6 auto = 本机空闲公网 v6"
  read -p "节点数量: " NODE_COUNT

  for ((i=1; i<=NODE_COUNT; i++)); do
    echo ""
    echo "--- 节点 $i ---"
    read -p "  NodeID: " nid
    read -p "  域名 (certdomain；null=从面板取，self=自签): " dom
    if is_self_marker "$dom" || [[ -z "$dom" ]]; then
      dom="node${nid}.selfsigned.local"
      USE_SELF_SIGNED=true
      echo "  → 该节点用自签证书"
    elif is_panel_marker "$dom"; then
      if panel_fetch_domain "$API_HOST" "$API_KEY" "$nid"; then
        dom="$PANEL_FETCH_DOMAIN"
        echo "  → 面板域名: $dom"
      else
        echo "  [取不到] $PANEL_FETCH_ERR"
        read -p "  请手填域名（或 self 自签）: " dom
        if is_self_marker "$dom" || [[ -z "$dom" ]]; then
          dom="node${nid}.selfsigned.local"
          USE_SELF_SIGNED=true
          echo "  → 该节点用自签证书"
        fi
      fi
    fi

    # ListenIP：域名已指向本机则默认 auto，否则默认 0.0.0.0（auto 依赖 DNS）
    lip_default="0.0.0.0"
    if [[ -z "$LISTEN_OPT" ]] && domain_points_here "$dom"; then
      lip_default="auto"
      echo "  （检测到 $dom 已指向本机，ListenIP 默认 auto）"
    elif [[ -n "$LISTEN_OPT" ]]; then
      lip_default="$LISTEN_OPT"
    fi
    read -p "  ListenIP [$lip_default]: " lip
    lip=${lip:-$lip_default}

    # ListenIP6：本机有公网 v6 时默认 auto
    if [[ -n "$LISTEN6_OPT" ]]; then
      lip6_default="$LISTEN6_OPT"
    elif has_public_v6; then
      lip6_default="auto"
    else
      lip6_default=""
    fi
    read -p "  ListenIP6 [$lip6_default]（留空=不启用 IPv6 入口）: " lip6
    lip6=${lip6:-$lip6_default}

    # SendIP：默认 auto（跟随 ListenIP）；也支持序号快捷选具体 IP
    echo -n "  SendIP [${SEND_OPT:-auto}]"
    if [[ ${#PUB_IPS[@]} -gt 1 ]]; then
      echo -n " (回车=auto；输入序号 1-${#PUB_IPS[@]} 或直接写 IP；0=不绑定)"
    else
      echo -n " (回车=auto=跟随 ListenIP；0=不绑定)"
    fi
    echo -n ": "
    read sip

    # 解析 SendIP：支持序号、IP、空
    if [[ -z "$sip" ]]; then
      sip="${SEND_OPT:-auto}"
    elif [[ "$sip" == "0" ]]; then
      sip="0.0.0.0"
    elif [[ "$sip" =~ ^[0-9]+$ ]] && [[ $sip -ge 1 ]] && [[ $sip -le ${#PUB_IPS[@]} ]]; then
      sip="${PUB_IPS[$((sip-1))]}"
    fi
    # 否则原样使用（用户手打了IP / auto）

    NODE_IDS+=("$nid")
    DOMAINS+=("$dom")
    LISTEN_IPS+=("$lip")
    LISTEN6_IPS+=("$lip6")
    SEND_IPS+=("$sip")
  done
fi

############################################
# 证书方案（v1.3.0 起：一台机器一张证书，覆盖全部域名）
############################################
CERT_DOMAINS_JSON=$(printf '%s\n' "${DOMAINS[@]}" | awk 'NF && !seen[$0]++ {printf "%s\"%s\"", sep, $0; sep=", "}')
CERT_MODE="http"
if [[ "$USE_SELF_SIGNED" == "true" ]]; then
  CERT_MODE="self"
  [[ -z "$CERT_DNS_PROVIDER" ]] && CERT_DNS_PROVIDER=""
fi

############################################
# DNS 预检：安装前把域名问题拦下来（不做任何更改）
#   自签模式不需要；显式 ListenIP + dns-01 时域名本就不必指向本机
############################################
if [[ "$USE_SELF_SIGNED" == "true" ]]; then
  echo "自签证书模式：跳过 DNS 预检（不使用证书域名）。"
elif [[ -n "$LISTEN_OPT" && -n "$CERT_DNS_PROVIDER" ]]; then
  echo "已配置 dns-01（$CERT_DNS_PROVIDER）+ 显式 ListenIP=$LISTEN_OPT：域名无需指向本机，跳过 DNS 预检。"
else
  dns_preflight "${DOMAINS[@]}"
fi

############################################
# 确认
############################################
echo ""
echo "==== 配置确认 ===="
echo "API_HOST : $API_HOST"
echo "WARP分流 : $WARP_ENABLED"
echo "节点数   : $NODE_COUNT"
for ((i=0; i<NODE_COUNT; i++)); do
  echo "  节点$((i+1)): NodeID=${NODE_IDS[$i]}  域名=${DOMAINS[$i]}  ListenIP=${LISTEN_IPS[$i]}  ListenIP6=${LISTEN6_IPS[$i]:-无}  SendIP=${SEND_IPS[$i]}"
done
echo "证书     : $CERT_MODE，一张证书覆盖 [$CERT_DOMAINS_JSON]，密钥类型 $CERT_KEY_TYPE"
if [[ "$USE_SELF_SIGNED" != "true" && "$CERT_MODE" == "http" ]]; then
  needs_dns=false
  for dom in "${DOMAINS[@]}"; do domain_points_here "$dom" || needs_dns=true; done
  [[ "$needs_dns" == "true" ]] && echo "          注意：有域名当前未指向本机，http-01 校验会失败（将先以自签证书启动）"
fi
if [[ "$AUTO_INSTALL" != "true" ]]; then
  read -p "确认无误？回车继续 Ctrl+C 取消 ..."
fi

############################################
# deps
############################################
if command -v apt &>/dev/null; then
  apt update -y
  apt install -y curl jq cron socat openssl unzip
elif command -v yum &>/dev/null; then
  yum install -y curl jq cronie socat openssl unzip
fi

############################################
# install V2bX
############################################
bash <(curl -Ls https://raw.githubusercontent.com/4kercc/V2BX-malio/refs/heads/main/install.sh)

############################################
# 检测并自动卸载外部 WARP 透明代理组件
# （warp-google-unlock / 官方 warp-svc / redsocks）
# 避免其 iptables 劫持破坏内置 WARP 的回落机制
############################################
cleanup_external_warp() {
    local found=false

    if [[ -f /usr/local/bin/warp-google ]] \
       || systemctl list-unit-files 2>/dev/null | grep -q "warp-google" \
       || systemctl is-active --quiet warp-svc 2>/dev/null \
       || pgrep -x warp-svc >/dev/null 2>&1 \
       || pgrep -x redsocks >/dev/null 2>&1; then
        found=true
    fi
    if command -v iptables >/dev/null 2>&1; then
        if iptables -t nat -L WARP_GOOGLE >/dev/null 2>&1 \
           || iptables -t nat -L WARP_CHATGPT >/dev/null 2>&1 \
           || iptables -t nat -L WARP_NETFLIX >/dev/null 2>&1; then
            found=true
        fi
    fi

    if [[ "$found" != "true" ]]; then
        echo "未检测到外部 WARP 组件，跳过清理"
        return 0
    fi

    echo "检测到外部 WARP / redsocks 组件，开始自动卸载..."
    systemctl disable --now warp-google-update.timer 2>/dev/null || true
    systemctl stop warp-google-update.service 2>/dev/null || true
    systemctl disable warp-google-update.service 2>/dev/null || true
    systemctl stop warp-google.service 2>/dev/null || true
    systemctl disable warp-google.service 2>/dev/null || true
    rm -f /etc/systemd/system/warp-google.service \
          /etc/systemd/system/warp-google-update.service \
          /etc/systemd/system/warp-google-update.timer

    systemctl disable --now warp-svc 2>/dev/null || true
    systemctl disable redsocks 2>/dev/null || true
    pkill -9 warp-svc redsocks 2>/dev/null || true

    if command -v iptables >/dev/null 2>&1; then
        for chain in WARP_GOOGLE WARP_CHATGPT WARP_NETFLIX; do
            iptables -t nat -D OUTPUT -j "$chain" 2>/dev/null || true
            iptables -t nat -F "$chain" 2>/dev/null || true
            iptables -t nat -X "$chain" 2>/dev/null || true
        done
    fi

    if command -v apt &>/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get remove -y cloudflare-warp >/dev/null 2>&1 || true
    elif command -v dnf &>/dev/null; then
        dnf remove -y cloudflare-warp >/dev/null 2>&1 || true
    elif command -v yum &>/dev/null; then
        yum remove -y cloudflare-warp >/dev/null 2>&1 || true
    fi
    rm -f /usr/local/bin/warp-google

    systemctl daemon-reload
    echo "✓ 外部 WARP 组件卸载完成（将使用内置原生 WireGuard WARP）"
}

cleanup_external_warp

############################################
# 自动生成/注册 Cloudflare WARP WireGuard 凭证
# （WARP_ENABLED=false 时跳过注册，使用兜底凭证保证模板合法）
############################################
WARP_CONF_FILE="/etc/V2bX/warp_account.json"
# 兜底凭证：注册失败或 WARP 关闭时保证 warp 模板合法（可用 v2bx warp 切换）
WARP_PRIVATE_KEY="aAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEE="
WARP_IPV4="172.16.0.2/32"
WARP_IPV6="2606:4700:110:8a9a:b0d:20e:a5b4:6b9d/128"

if [[ "$WARP_ENABLED" == "true" ]]; then
if [[ -f "$WARP_CONF_FILE" ]]; then
  WARP_PRIVATE_KEY=$(jq -r '.private_key // empty' "$WARP_CONF_FILE" 2>/dev/null || true)
  WARP_IPV4=$(jq -r '.v4 // empty' "$WARP_CONF_FILE" 2>/dev/null || true)
  WARP_IPV6=$(jq -r '.v6 // empty' "$WARP_CONF_FILE" 2>/dev/null || true)
fi

if [[ -z "$WARP_PRIVATE_KEY" || -z "$WARP_IPV4" ]]; then
  echo "正在自动注册 Cloudflare WARP 免费账号..."
  mkdir -p /etc/V2bX
  # 优先使用 openssl 生成私钥，若无 wg 则 fallback
  if command -v wg &>/dev/null; then
    RAW_PRIV=$(wg genkey)
    RAW_PUB=$(echo "$RAW_PRIV" | wg pubkey)
  else
    RAW_PRIV=$(openssl rand -base64 32)
    # 通过 API 注册时传递公钥
    RAW_PUB=$(echo "$RAW_PRIV" | openssl pkey -pubout -outform DER 2>/dev/null | tail -c 32 | base64 2>/dev/null || echo "")
  fi

  if [[ -n "$RAW_PRIV" ]]; then
    WARP_REG_RES=$(curl -s -X POST "https://api.cloudflareclient.com/v0a2158/reg" \
      -H "Content-Type: application/json; charset=UTF-8" \
      -H "User-Agent: okhttp/3.12.1" \
      -d "{\"key\":\"${RAW_PUB}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"PC\",\"type\":\"Android\",\"locale\":\"zh_CN\"}" 2>/dev/null || true)

    WARP_IPV4=$(echo "$WARP_REG_RES" | jq -r '.result.config.interface.addresses.v4 // empty' 2>/dev/null || true)
    WARP_IPV6=$(echo "$WARP_REG_RES" | jq -r '.result.config.interface.addresses.v6 // empty' 2>/dev/null || true)

    if [[ -n "$WARP_IPV4" ]]; then
      WARP_PRIVATE_KEY="$RAW_PRIV"
      cat > "$WARP_CONF_FILE" <<EOF
{
  "private_key": "${WARP_PRIVATE_KEY}",
  "v4": "${WARP_IPV4}",
  "v6": "${WARP_IPV6}"
}
EOF
      echo "✓ Cloudflare WARP 账号注册成功 (IPv4: $WARP_IPV4)"
    fi
  fi
fi

# 如果注册未成功，沿用兜底凭证
if [[ -z "$WARP_PRIVATE_KEY" || -z "$WARP_IPV4" ]]; then
  echo "⚠️ WARP 自动注册受限，使用兜底凭证。"
fi
else
  echo "WARP 分流已关闭 (第5参数 off)，跳过 WARP 账号注册。"
fi

############################################
# dirs
############################################
CONFIG_DIR="/etc/V2bX"
SSL_DIR="/etc/ssl"
mkdir -p $CONFIG_DIR $SSL_DIR

############################################
# 证书：不再预生成自签、也不再外挂 acme.sh
#   v1.1.0 起 V2bX 自己申请证书、失败自动降级自签并每天重试；
#   v1.3.0 起一张机器级证书覆盖全部域名（只由第一个节点签发与续期）。
############################################

############################################
# 生成 Nodes JSON 数组
############################################
gen_nodes() {
  local first=true
  for ((i=0; i<NODE_COUNT; i++)); do
    $first || echo ","
    first=false
    local listen6_line=""
    if [[ -n "${LISTEN6_IPS[$i]:-}" ]]; then
      listen6_line="\"ListenIP6\": \"${LISTEN6_IPS[$i]}\","
    fi
    cat <<EOF
    {
      "Core": "sing",
      "ApiHost": "${API_HOST}",
      "ApiKey": "${KEYS_LIST[$i]:-$API_KEY}",
      "NodeID": ${NODE_IDS[$i]},
      "NodeType": "anytls",
      "Timeout": 30,
      "ListenIP": "${LISTEN_IPS[$i]}",
      ${listen6_line}
      "SendIP": "${SEND_IPS[$i]}",
      "DeviceOnlineMinTraffic": 200,
      "MinReportTraffic": 0,
      "TCPFastOpen": false,
      "SniffEnabled": true,
      "CertConfig": {
        "CertDomain": "${DOMAINS[$i]}"
      }
    }
EOF
  done
}

############################################
# config.json
#   "Cert" 是机器级证书：一张证书覆盖本机全部节点域名，
#   只由第一个节点签发与续期（改域名后重启会自动重新签发一次）。
############################################
CERT_PROVIDER_JSON=""
if [[ -n "$CERT_DNS_PROVIDER" ]]; then
  CERT_PROVIDER_JSON="    \"Provider\": \"${CERT_DNS_PROVIDER}\",
    \"DNSEnv\": { \"CF_DNS_API_TOKEN\": \"${CF_DNS_API_TOKEN:-}\" },
"
fi

cat > ${CONFIG_DIR}/config.json <<EOF
{
  "Log": {
    "Level": "info",
    "Output": ""
  },
  "Cert": {
    "CertMode": "${CERT_MODE}",
    "CertDomains": [${CERT_DOMAINS_JSON}],
    "KeyType": "${CERT_KEY_TYPE}",
${CERT_PROVIDER_JSON}    "Email": "${ACME_EMAIL:-v2bx@github.com}"
  },
  "Cores": [
    {
      "Type": "sing",
      "Log": {
        "Level": "error",
        "Timestamp": true
      },
      "NTP": {
        "Enable": false,
        "Server": "time.apple.com",
        "ServerPort": 0
      },
      "OriginalPath": "/etc/V2bX/sing_origin.json"
    }
  ],
  "Nodes": [
$(gen_nodes)
  ]
}
EOF

############################################
# sing_origin.json（双模板：warp / direct，可随时用 v2bx warp 切换）
############################################
dnsstrategy="prefer_ipv4"

cat <<EOF > ${CONFIG_DIR}/sing_origin_warp.json
{
  "dns": {
    "servers": [
      {
        "tag": "cf",
        "address": "1.1.1.1"
      }
    ],
    "strategy": "$dnsstrategy"
  },
  "outbounds": [
    {
      "tag": "direct",
      "type": "direct",
      "domain_resolver": {
        "server": "cf",
        "strategy": "$dnsstrategy"
      }
    },
    {
      "type": "wireguard",
      "tag": "warp-out",
      "server": "162.159.192.1",
      "server_port": 2408,
      "local_address": [
        "${WARP_IPV4}",
        "${WARP_IPV6}"
      ],
      "private_key": "${WARP_PRIVATE_KEY}",
      "peer_public_key": "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    },
    {
      "type": "urltest",
      "tag": "warp-auto",
      "outbounds": [
        "warp-out",
        "direct"
      ],
      "url": "https://www.google.com/generate_204",
      "interval": "1m",
      "tolerance": 5000,
      "idle_timeout": "30m"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "ip_is_private": true,
        "outbound": "block"
      },
      {
        "domain_suffix": [
          "google.com",
          "google.com.hk",
          "googleapis.com",
          "googlevideo.com",
          "gstatic.com",
          "youtube.com",
          "ytimg.com",
          "openai.com",
          "chatgpt.com",
          "oaistatic.com",
          "oaiusercontent.com",
          "claude.ai",
          "anthropic.com",
          "netflix.com",
          "netflix.net",
          "nflximg.net",
          "nflxvideo.net"
        ],
        "domain_keyword": [
          "openai",
          "chatgpt",
          "anthropic",
          "claude"
        ],
        "outbound": "warp-auto"
      },
      {
        "domain_regex": [
            "(api|ps|sv|offnavi|newvector|ulog.imap|newloc)(.map|).(baidu|n.shifen).com",
            "(.+.|^)(360|so).(cn|com)",
            "(Subject|HELO|SMTP)",
            "(torrent|.torrent|peer_id=|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=)",
            "(^.@)(guerrillamail|guerrillamailblock|sharklasers|grr|pokemail|spam4|bccto|chacuo|027168).(info|biz|com|de|net|org|me|la)",
            "(.?)(xunlei|sandai|Thunder|XLLiveUD)(.)",
            "(..||)(dafahao|mingjinglive|botanwang|minghui|dongtaiwang|falunaz|epochtimes|ntdtv|falundafa|falungong|wujieliulan|zhengjian).(org|com|net)",
            "(ed2k|.torrent|peer_id=|announce|info_hash|get_peers|find_node|BitTorrent|announce_peer|announce.php?passkey=|magnet:|xunlei|sandai|Thunder|XLLiveUD|bt_key)",
            "(.+.|^)(360).(cn|com|net)",
            "(.*.||)(guanjia.qq.com|qqpcmgr|QQPCMGR)",
            "(.*.||)(rising|kingsoft|duba|xindubawukong|jinshanduba).(com|net|org)",
            "(.*.||)(netvigator|torproject).(com|cn|net|org)",
            "(..||)(visa|mycard|gash|beanfun|bank).",
            "(.*.||)(gov|12377|12315|talk.news.pts.org|creaders|zhuichaguoji|efcc.org|cyberpolice|aboluowang|tuidang|epochtimes|zhengjian|110.qq|mingjingnews|inmediahk|xinsheng|breakgfw|chengmingmag|jinpianwang|qi-gong|mhradio|edoors|renminbao|soundofhope|xizang-zhiye|bannedbook|ntdtv|12321|secretchina|dajiyuan|boxun|chinadigitaltimes|dwnews|huaglad|oneplusnews|epochweekly|cn.rfi).(cn|com|org|net|club|net|fr|tw|hk|eu|info|me)",
            "(.*.||)(miaozhen|cnzz|talkingdata|umeng).(cn|com)",
            "(.*.||)(mycard).(com|tw)",
            "(.*.||)(gash).(com|tw)",
            "(.bank.)",
            "(.*.||)(pincong).(rocks)",
            "(.*.||)(taobao).(com)",
            "(.*.||)(laomoe|jiyou|ssss|lolicp|vv1234|0z|4321q|868123|ksweb|mm126).(com|cloud|fun|cn|gs|xyz|cc)",
            "(flows|miaoko).(pages).(dev)"
        ],
        "outbound": "block"
      },
      {
        "outbound": "direct",
        "network": [
          "udp","tcp"
        ]
      }
    ]
  },
  "experimental": {
    "cache_file": {
      "enabled": true
    }
  }
}
EOF

# 派生无 WARP 的直连模板（移除 warp 出站与分流规则），供 v2bx warp on/off 随时切换
jq 'del(.outbounds[]? | select(.tag == "warp-out" or .tag == "warp-auto"))
    | .route.rules |= map(select((.outbound // "") != "warp-auto"))' \
    ${CONFIG_DIR}/sing_origin_warp.json > ${CONFIG_DIR}/sing_origin_direct.json

if [[ "$WARP_ENABLED" == "true" ]]; then
  cp -f ${CONFIG_DIR}/sing_origin_warp.json ${CONFIG_DIR}/sing_origin.json
  echo "on" > ${CONFIG_DIR}/warp_mode
else
  cp -f ${CONFIG_DIR}/sing_origin_direct.json ${CONFIG_DIR}/sing_origin.json
  echo "off" > ${CONFIG_DIR}/warp_mode
fi
echo "WARP 分流模式: $(cat ${CONFIG_DIR}/warp_mode)（可用 v2bx warp on/off/status 随时切换）"

############################################
# 证书签发：交给 V2bX 自己（不再外挂 acme.sh）
#   - 首次启动时按上面 "Cert" 块申请一张覆盖全部域名的证书（http-01 或 dns-01）
#   - 失败自动降级为多域名自签证书并告警，节点照常起来；每天自动重试
#   - 续期由第一个节点负责，日志里能看到 acme 的申请/续期过程
############################################
if [[ "$USE_SELF_SIGNED" == "true" ]]; then
  echo "自签证书模式：V2bX 启动时会生成覆盖全部域名的自签证书（无需 ACME）。"
else
  echo "证书模式 $CERT_MODE：V2bX 启动时自动申请 $CERT_DOMAINS_JSON（一张证书覆盖全部域名）"
fi

############################################
# 内存与系统性能优化 (针对小内存VPS优化Go运行时与系统内核)
############################################
echo "==== 配置内存优化与性能调优 ===="

# 1. 调整 Linux 内核 swappiness 倾向，减少磁盘 Swap IO 阻塞
if ! grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
  echo "vm.swappiness=10" >> /etc/sysctl.conf
  sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
fi

# 2. 注入 Go 运行时内存限制与即时释放环境变量 (GOMEMLIMIT & GODEBUG)
mkdir -p /etc/systemd/system/V2bX.service.d
cat > /etc/systemd/system/V2bX.service.d/override.conf <<EOF
[Service]
Environment="GOMEMLIMIT=150MiB"
Environment="GODEBUG=madvdontneed=1"
EOF

# 3. 添加每 5 天凌晨 3 点自动定时重启任务（防止内存碎片堆积）
(crontab -l 2>/dev/null | grep -v "systemctl restart V2bX"; echo "0 3 */5 * * systemctl restart V2bX") | crontab - || true

systemctl daemon-reload

############################################
# restart
############################################
systemctl restart V2bX || true

v2bx log

############################################
# 云控 Agent（可选：传入第6/7参数自动接入云端）
#   统一委托 cloud-join.sh，保证「全新安装」和「存量机器 cloud-join」走同一条路径：
#     · 按本机 IP 复用云控上已有身份（避免同机产生重复节点记录）
#     · 自签 HTTPS 自动探测（不必手写 insecure）
#     · 长轮询守护（命令秒级送达）+ 幂等 cron 兜底
############################################
join_cloud() {
  if [[ -z "$CLOUD_URL" || -z "$CLOUD_TOKEN" ]]; then return 0; fi
  echo "==== 接入云控中心: $CLOUD_URL ===="
  local tmp
  tmp=$(mktemp /tmp/cloud-join.XXXXXX.sh)
  if ! curl -fsSL -o "$tmp" https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-join.sh; then
    echo "⚠ cloud-join.sh 下载失败，跳过云控接入（节点本身已装好，可稍后单独跑 cloud-join.sh）"
    rm -f "$tmp"; return 0
  fi
  bash "$tmp" "$CLOUD_URL" "$CLOUD_TOKEN" "" "$CLOUD_INSECURE" || \
    echo "⚠ 云控接入未完成，可稍后重跑: bash <(curl -fsSL https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-join.sh) \"$CLOUD_URL\" \"$CLOUD_TOKEN\""
  rm -f "$tmp"
}
join_cloud

echo "==== INSTALL DONE ===="
echo "节点数: $NODE_COUNT"
for ((i=0; i<NODE_COUNT; i++)); do
  echo "  NodeID=${NODE_IDS[$i]}  域名=${DOMAINS[$i]}  ListenIP=${LISTEN_IPS[$i]}  SendIP=${SEND_IPS[$i]}"
done
