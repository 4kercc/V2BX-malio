#!/bin/bash

set -e

############################################
# 共用参数
############################################
API_HOST="${1:-}"
API_KEY="${2:-}"
NODE_ID="${3:-}"
DOMAIN="${4:-}"

USE_SELF_SIGNED=false
# 如果处于命令行非交互模式（前3个参数齐全），但第4个参数未传或为 null/NULL，则默认使用自签证书
if [[ -n "$API_HOST" && -n "$API_KEY" && -n "$NODE_ID" ]]; then
  if [[ -z "$DOMAIN" || "$DOMAIN" == "null" || "$DOMAIN" == "NULL" ]]; then
    USE_SELF_SIGNED=true
    DOMAIN="node${NODE_ID}.selfsigned.local"
  fi
elif [[ "$DOMAIN" == "null" || "$DOMAIN" == "NULL" ]]; then
  USE_SELF_SIGNED=true
  DOMAIN="node${NODE_ID:-1}.selfsigned.local"
fi

############################################
# 端口80检查（仅在需要申请ACME证书时检查）
############################################
if [[ "$USE_SELF_SIGNED" != "true" ]]; then
  if lsof -i :80 -sTCP:LISTEN >/dev/null 2>&1; then
    echo "[ERROR] 端口 80 已被占用，无法申请 ACME 证书，安装退出。"
    exit 1
  fi
fi

declare -a NODE_IDS DOMAINS SEND_IPS LISTEN_IPS

if [[ -n "$API_HOST" && -n "$API_KEY" && -n "$NODE_ID" ]]; then
  AUTO_INSTALL=true
  NODE_COUNT=1
  NODE_IDS=("$NODE_ID")
  DOMAINS=("$DOMAIN")
  LISTEN_IPS=("0.0.0.0")
  SEND_IPS=("0.0.0.0")
  ACME_EMAIL="v2bx@github.com"
else
  AUTO_INSTALL=false
  if [[ -z "$API_HOST" ]]; then read -p "API_HOST (e.g. https://baidu.com): " API_HOST; fi
  if [[ -z "$API_KEY" ]];  then read -p "API_KEY: " API_KEY; fi

  read -p "ACME Email (默认 v2bx@github.com): " ACME_EMAIL
  ACME_EMAIL=${ACME_EMAIL:-v2bx@github.com}

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
  echo "提示：ListenIP 建议填 0.0.0.0（IPv4监听全部）或 :: （IPv6+IPv4双栈监听全部）"
  echo "      SendIP 填哪个IP，流量就从哪个IP出"
  read -p "节点数量: " NODE_COUNT

  for ((i=1; i<=NODE_COUNT; i++)); do
    echo ""
    echo "--- 节点 $i ---"
    read -p "  NodeID: " nid
    read -p "  域名 (certdomain): " dom

    # ListenIP：默认 0.0.0.0
    read -p "  ListenIP [0.0.0.0]: " lip
    lip=${lip:-0.0.0.0}

    # SendIP：支持序号快捷输入
    echo -n "  SendIP"
    if [[ ${#PUB_IPS[@]} -gt 1 ]]; then
      echo -n " (输入IP或选序号 1-${#PUB_IPS[@]}, 0=0.0.0.0, 回车=自动)"
    else
      echo -n " (回车=0.0.0.0)"
    fi
    echo -n ": "
    read sip

    # 解析 SendIP：支持序号、IP、空
    if [[ -z "$sip" ]]; then
      sip="0.0.0.0"
    elif [[ "$sip" == "0" ]]; then
      sip="0.0.0.0"
    elif [[ "$sip" =~ ^[0-9]+$ ]] && [[ $sip -ge 1 ]] && [[ $sip -le ${#PUB_IPS[@]} ]]; then
      sip="${PUB_IPS[$((sip-1))]}"
    fi
    # 否则原样使用（用户手打了IP）

    NODE_IDS+=("$nid")
    DOMAINS+=("$dom")
    LISTEN_IPS+=("$lip")
    SEND_IPS+=("$sip")
  done
fi

############################################
# 确认
############################################
echo ""
echo "==== 配置确认 ===="
echo "API_HOST : $API_HOST"
echo "节点数   : $NODE_COUNT"
for ((i=0; i<NODE_COUNT; i++)); do
  echo "  节点$((i+1)): NodeID=${NODE_IDS[$i]}  域名=${DOMAINS[$i]}  ListenIP=${LISTEN_IPS[$i]}  SendIP=${SEND_IPS[$i]}"
done
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
# dirs
############################################
CONFIG_DIR="/etc/V2bX"
SSL_DIR="/etc/ssl"
mkdir -p $CONFIG_DIR $SSL_DIR

############################################
# fallback certs for all domains
############################################
for dom in "${DOMAINS[@]}"; do
  echo "生成自签证书: $dom"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout ${SSL_DIR}/${dom}.key \
    -out ${SSL_DIR}/${dom}.crt \
    -subj "/CN=${dom}" \
    -days 3650
done

############################################
# 生成 Nodes JSON 数组
############################################
gen_nodes() {
  local first=true
  for ((i=0; i<NODE_COUNT; i++)); do
    $first || echo ","
    first=false
    local cert_mode="http"
    if [[ "$USE_SELF_SIGNED" == "true" ]]; then
      cert_mode="none"
    fi
    cat <<EOF
    {
      "Core": "sing",
      "ApiHost": "${API_HOST}",
      "ApiKey": "${API_KEY}",
      "NodeID": ${NODE_IDS[$i]},
      "NodeType": "anytls",
      "Timeout": 30,
      "ListenIP": "${LISTEN_IPS[$i]}",
      "SendIP": "${SEND_IPS[$i]}",
      "DeviceOnlineMinTraffic": 200,
      "MinReportTraffic": 0,
      "TCPFastOpen": false,
      "SniffEnabled": true,
      "CertConfig": {
        "CertMode": "${cert_mode}",
        "RejectUnknownSni": false,
        "CertDomain": "${DOMAINS[$i]}",
        "CertFile": "${SSL_DIR}/${DOMAINS[$i]}.crt",
        "KeyFile": "${SSL_DIR}/${DOMAINS[$i]}.key",
        "Email": "${ACME_EMAIL}",
        "Provider": "cloudflare",
        "DNSEnv": {
          "EnvName": "env1"
        }
      }
    }
EOF
  done
}

############################################
# config.json
############################################
cat > ${CONFIG_DIR}/config.json <<EOF
{
  "Log": {
    "Level": "debug",
    "Output": ""
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
# sing_origin.json
############################################
dnsstrategy="prefer_ipv4"

cat <<EOF > /etc/V2bX/sing_origin.json
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

############################################
# ACME for all domains
############################################
if [[ "$USE_SELF_SIGNED" == "true" ]]; then
  echo "检测到使用自签证书模式 (域名为 null)，跳过 ACME 证书申请。"
else
  ACME=~/.acme.sh/acme.sh

  if ! command -v $ACME &>/dev/null; then
    curl https://get.acme.sh | sh
  fi

  set +e

  $ACME --set-default-ca --server letsencrypt >/dev/null 2>&1
  $ACME --register-account -m $ACME_EMAIL >/dev/null 2>&1
  $ACME --install-cronjob >/dev/null 2>&1

  for dom in "${DOMAINS[@]}"; do
    echo "申请 ACME 证书: $dom"
    $ACME --issue -d ${dom} --standalone --keylength ec-256 --force

    if [[ $? -eq 0 ]]; then
      $ACME --install-cert \
        -d ${dom} \
        --fullchain-file ${SSL_DIR}/${dom}.crt \
        --key-file ${SSL_DIR}/${dom}.key \
        --reloadcmd "systemctl restart V2bX"
    fi
  done

  set -e
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
