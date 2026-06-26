#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)

############################################
# 0. AnyTLS 参数（新增）
############################################

API_HOST="$1"
API_KEY="$2"
NODE_ID="$3"
certdomain="$4"

if [[ -z "$API_HOST" ]]; then
  read -p "API_HOST: " API_HOST
fi

if [[ -z "$API_KEY" ]]; then
  read -p "API_KEY: " API_KEY
fi

if [[ -z "$NODE_ID" ]]; then
  read -p "NODE_ID: " NODE_ID
fi

if [[ -z "$certdomain" ]]; then
  read -p "certdomain: " certdomain
fi

echo ""
echo "=============================="
echo "AnyTLS 安装参数确认"
echo "API_HOST   = $API_HOST"
echo "API_KEY    = $API_KEY"
echo "NODE_ID    = $NODE_ID"
echo "certdomain = $certdomain"
echo "=============================="
echo ""

read -p "回车继续安装 V2bX..." _

############################################
# check root
############################################

[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

############################################
# check os
############################################

if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本${plain}\n" && exit 1
fi

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
else
    arch="64"
fi

############################################
# install base
############################################

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates jq -y
    elif [[ x"${release}" == x"debian" || x"${release}" == x"ubuntu" ]]; then
        apt-get update -y
        apt install wget curl unzip tar cron socat ca-certificates jq -y
    fi
}

############################################
# install V2bX
############################################

install_V2bX() {

    rm -rf /usr/local/V2bX/
    mkdir -p /usr/local/V2bX/
    cd /usr/local/V2bX/

    last_version=$(curl -Ls "https://api.github.com/repos/q42602736/V2BX-malio/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

    wget -q -O V2bX.zip https://github.com/q42602736/V2BX-malio/releases/download/${last_version}/V2bX-linux-${arch}.zip

    unzip -o V2bX.zip
    chmod +x V2bX

    mkdir -p /etc/V2bX/
    cp -f config.json /etc/V2bX/ 2>/dev/null
    cp -f dns.json /etc/V2bX/ 2>/dev/null
    cp -f route.json /etc/V2bX/ 2>/dev/null

    # systemd
    wget -q -O /etc/systemd/system/V2bX.service https://github.com/wyx2685/V2bX-script/raw/master/V2bX.service
    systemctl daemon-reload
    systemctl enable V2bX

}

############################################
# AnyTLS 自动配置（新增核心）
############################################

setup_anytls() {

CONFIG_DIR="/etc/V2bX"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SSL_DIR="/etc/ssl"

mkdir -p $SSL_DIR

NODE_JSON=$(curl -s -H "Authorization: ${API_KEY}" \
"${API_HOST}/api/v1/node/${NODE_ID}/config")

PORT=$(echo $NODE_JSON | jq -r '.port')
UUID=$(echo $NODE_JSON | jq -r '.uuid')

cat > $CONFIG_FILE <<EOF
{
  "inbounds": [{
    "port": ${PORT},
    "protocol": "anytls",
    "settings": {
      "clients": [{ "id": "${UUID}" }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "serverName": "${certdomain}",
        "certificates": [{
          "certificateFile": "${SSL_DIR}/${certdomain}.crt",
          "keyFile": "${SSL_DIR}/${certdomain}.key"
        }]
      }
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

############################################
# ACME 自动续期（关键）
############################################

ACME=~/.acme.sh/acme.sh

if ! command -v $ACME &>/dev/null; then
  curl https://get.acme.sh | sh
fi

$ACME --install-cronjob

$ACME --issue -d ${certdomain} --standalone --keylength ec-256 --force

$ACME --install-cert \
-d ${certdomain} \
--fullchain-file ${SSL_DIR}/${certdomain}.crt \
--key-file ${SSL_DIR}/${certdomain}.key \
--reloadcmd "systemctl restart V2bX"

}

############################################
# main
############################################

echo -e "${green}开始安装 V2bX + AnyTLS${plain}"

install_base
install_V2bX

############################################
# ⭐ 关键：安装完成后再做 AnyTLS
############################################

setup_anytls

systemctl restart V2bX

echo -e "${green}安装完成：AnyTLS + V2bX 已就绪${plain}"
