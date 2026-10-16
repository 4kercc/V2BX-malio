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
#   4 DOMAIN     证书域名（写 null = 用自签证书）
#   5 WARP_MODE  on/off（默认 on）
#   6/7/8        云控中心地址 / Token / insecure（可选）
#
# 进阶（环境变量，都可省；v1.3.0 起一张证书覆盖多个域名、地址可自动推导）：
#   LISTEN=auto                  监听地址（auto=按该节点域名的 A 记录解析；也可 0.0.0.0 / :: / 具体 IP）
#   LISTEN6=auto                 IPv6 入口（auto=本机空闲公网 v6；留空=不启用）
#   SEND=auto                    出口地址（auto=跟随监听地址，同进同出；0=不绑定）
#   CERT_KEY_TYPE=ec-256         证书密钥类型（ec-256 / ec-384 / rsa2048 / rsa4096）
#   CERT_DNS_PROVIDER=cloudflare 用 dns-01 签发（域名不必指向本机；另配 CF_DNS_API_TOKEN 等）
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
  if [[ ${#NODE_IDS_LIST[@]} -ne ${#DOMAINS_LIST[@]} ]]; then
    echo "[ERROR] 节点数与域名数不一致：NODE_IDS=${#NODE_IDS_LIST[@]} 个（${NODE_IDS_LIST[*]}），DOMAINS=${#DOMAINS_LIST[@]} 个（${DOMAINS_LIST[*]}）"
    exit 1
  fi
fi

# 自签判定：域名写 null/NULL 视为自签（一台机器只能统一一种，因为共用一张证书）
USE_SELF_SIGNED=false
null_domains=0
total_domains=0
if [[ "$MULTI_MODE" == "true" ]]; then
  for idx in "${!DOMAINS_LIST[@]}"; do
    total_domains=$((total_domains + 1))
    if [[ "${DOMAINS_LIST[$idx]}" == "null" || "${DOMAINS_LIST[$idx]}" == "NULL" ]]; then
      null_domains=$((null_domains + 1))
      DOMAINS_LIST[$idx]="node${NODE_IDS_LIST[$idx]}.selfsigned.local"
    fi
  done
  if [[ $null_domains -gt 0 && $null_domains -lt $total_domains ]]; then
    echo "[ERROR] 自签(null) 与正式域名不能混用：本机所有节点共用一张证书"
    exit 1
  fi
  [[ $null_domains -gt 0 ]] && USE_SELF_SIGNED=true
elif [[ -n "$API_HOST" && -n "$API_KEY" && -n "$NODE_ID" ]]; then
  if [[ -z "$DOMAIN" || "$DOMAIN" == "null" || "$DOMAIN" == "NULL" ]]; then
    USE_SELF_SIGNED=true
    DOMAIN="node${NODE_ID}.selfsigned.local"
  fi
elif [[ "$DOMAIN" == "null" || "$DOMAIN" == "NULL" ]]; then
  USE_SELF_SIGNED=true
  DOMAIN="node${NODE_ID:-1}.selfsigned.local"
fi

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

# 本机是否有公网 IPv6
has_public_v6() {
  ip -6 -o addr show scope global 2>/dev/null | grep -qv 'inet6 fe80' && return 0
  return 1
}

# 每节点密钥：给一个 = 全部共用（面板常见做法）；给逗号分隔的一串 = 按节点顺序对应
declare -a KEYS_LIST
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
    read -p "  域名 (certdomain): " dom

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
# 云控 Agent（可选：传入第6/7参数自动接入云端）
############################################
if [[ -n "$CLOUD_URL" && -n "$CLOUD_TOKEN" ]]; then
  echo "==== 接入云控中心: $CLOUD_URL ===="
  CLOUD_INSECURE_LINE=""
  [[ "$CLOUD_INSECURE" =~ ^(insecure|selfsign|-k|1)$ ]] && CLOUD_INSECURE_LINE='CLOUD_INSECURE="1"'
  cat > /etc/V2bX/cloud.conf <<EOF
CLOUD_URL="${CLOUD_URL}"
CLOUD_TOKEN="${CLOUD_TOKEN}"
NODE_NAME="${NODE_NAME:-node${NODE_IDS[0]}-$(hostname -s 2>/dev/null || hostname)}"
${CLOUD_INSECURE_LINE}
EOF
  curl -fsSL -o /usr/local/V2bX/cloud-agent.sh \
    https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-agent.sh && \
    chmod +x /usr/local/V2bX/cloud-agent.sh
  (crontab -l 2>/dev/null | grep -v "cloud-agent.sh"; echo "*/2 * * * * /usr/local/V2bX/cloud-agent.sh >/dev/null 2>&1") | crontab - || true
  echo "✓ 云控 Agent 已安装（每 2 分钟心跳上报+配置拉取）"
fi

############################################
# restart
############################################
systemctl restart V2bX || true

v2bx log

echo "==== INSTALL DONE ===="
echo "节点数: $NODE_COUNT"
for ((i=0; i<NODE_COUNT; i++)); do
  echo "  NodeID=${NODE_IDS[$i]}  域名=${DOMAINS[$i]}  ListenIP=${LISTEN_IPS[$i]}  SendIP=${SEND_IPS[$i]}"
done
