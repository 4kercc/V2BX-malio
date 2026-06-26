#!/bin/bash

set -e

############################################
# AnyTLS + V2bX INSTALL (Multi-Node)
############################################
if lsof -i :80 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "[ERROR] 端口 80 已被占用，安装退出。"
  exit 1
fi

############################################
# 共用参数
############################################
API_HOST="${1:-}"
API_KEY="${2:-}"

if [[ -z "$API_HOST" ]]; then read -p "API_HOST (e.g. https://baidu.com): " API_HOST; fi
if [[ -z "$API_KEY" ]];  then read -p "API_KEY: " API_KEY; fi

read -p "ACME Email (默认 v2bx@github.com): " ACME_EMAIL
ACME_EMAIL=${ACME_EMAIL:-v2bx@github.com}

############################################
# 多节点参数采集
############################################
echo ""
echo "==== 节点配置 ===="
echo "多个节点只有 NodeID / 域名 / SendIP 不同，其余参数共享"
read -p "节点数量: " NODE_COUNT

declare -a NODE_IDS DOMAINS SEND_IPS LISTEN_IPS

for ((i=1; i<=NODE_COUNT; i++)); do
  echo ""
  echo "--- 节点 $i ---"
  read -p "  NodeID: " nid
  read -p "  域名 (certdomain): " dom

  # 单节点无需绑定IP，默认 0.0.0.0
  if [[ $NODE_COUNT -eq 1 ]]; then
    lip="0.0.0.0"
    sip="0.0.0.0"
  else
    read -p "  ListenIP (默认 0.0.0.0): " lip
    lip=${lip:-0.0.0.0}
    read -p "  SendIP (默认 0.0.0.0): " sip
    sip=${sip:-0.0.0.0}
  fi

  NODE_IDS+=("$nid")
  DOMAINS+=("$dom")
  LISTEN_IPS+=("$lip")
  SEND_IPS+=("$sip")
done

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
read -p "确认无误？回车继续 Ctrl+C 取消 ..."

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
        "CertMode": "http",
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
