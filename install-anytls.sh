#!/bin/bash

set -e

############################################
# AnyTLS + V2bX SAFE INSTALL (FINAL PACK)
############################################
if lsof -i :80 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "[ERROR] 端口 80 已被占用，安装退出。"
  exit 1
fi

API_HOST="$1"
API_KEY="$2"
NODE_ID="$3"
certdomain="$4"
ACME_EMAIL="$5"

if [[ -z "$API_HOST" ]]; then read -p "API_HOST: " API_HOST; fi
if [[ -z "$API_KEY" ]]; then read -p "API_KEY: " API_KEY; fi
if [[ -z "$NODE_ID" ]]; then read -p "NODE_ID: " NODE_ID; fi
if [[ -z "$certdomain" ]]; then read -p "certdomain: " certdomain; fi

if [[ -z "$ACME_EMAIL" ]]; then
  ACME_EMAIL="v2bx@github.com"
fi

echo "==== INSTALL START ===="
echo "DOMAIN: $certdomain"
echo "EMAIL : $ACME_EMAIL"

read -p
echo "确认后请回车继续"
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
# node config
############################################

NODE_JSON=$(curl -s -H "Authorization: ${API_KEY}" \
"${API_HOST}/api/v1/node/${NODE_ID}/config")

PORT=$(echo "$NODE_JSON" | jq -r '.port')
UUID=$(echo "$NODE_JSON" | jq -r '.uuid')

############################################
# fallback cert (SAFE MODE)
############################################

openssl req -x509 -nodes -newkey rsa:2048 \
-keyout ${SSL_DIR}/${certdomain}.key \
-out ${SSL_DIR}/${certdomain}.crt \
-subj "/CN=${certdomain}" \
-days 3650

############################################
# config.json (FIXED STRUCTURE)
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
    }],
    "Nodes": [{
            "Core": "sing",
            "ApiHost": "${API_HOST}",
            "ApiKey": "${API_KEY}",
            "NodeID": ${NODE_ID},
            "NodeType": "anytls",
            "Timeout": 30,
            "ListenIP": "::",
            "SendIP": "0.0.0.0",
            "DeviceOnlineMinTraffic": 200,
            "MinReportTraffic": 0,
            "TCPFastOpen": false,
            "SniffEnabled": true,
            "CertConfig": {
                "CertMode": "http",
                "RejectUnknownSni": false,
                "CertDomain": "${certdomain}",
                "CertFile": "${SSL_DIR}/${certdomain}.crt",
                "KeyFile": "${SSL_DIR}/${certdomain}.key",
                "Email": "${ACME_EMAIL}"
                "Provider": "cloudflare",
                "DNSEnv": {
                    "EnvName": "env1"
                }
            }
        }]
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
# ACME SAFE
############################################

ACME=~/.acme.sh/acme.sh

if ! command -v $ACME &>/dev/null; then
  curl https://get.acme.sh | sh
fi

set +e

$ACME --set-default-ca --server letsencrypt >/dev/null 2>&1
$ACME --register-account -m $ACME_EMAIL >/dev/null 2>&1
$ACME --install-cronjob >/dev/null 2>&1

$ACME --issue -d ${certdomain} --standalone --keylength ec-256 --force

if [[ $? -eq 0 ]]; then
  $ACME --install-cert \
    -d ${certdomain} \
    --fullchain-file ${SSL_DIR}/${certdomain}.crt \
    --key-file ${SSL_DIR}/${certdomain}.key \
    --reloadcmd "systemctl restart V2bX"
fi

set -e

systemctl restart V2bX || true

v2bx log

echo "INSTALL DONE"
