#!/bin/bash
############################################
# V2BX-malio 云控中心一键安装脚本（服务端）
# 自动: 安装 Node.js -> 下载控制中心 -> 生成双随机 Token -> systemd 常驻
# 用法:
#   bash <(curl -fsSL https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-install.sh) [端口]
# 默认端口 8765，可传参: bash cloud-install.sh 9000
############################################

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; cyan='\033[0;36m'; plain='\033[0m'
[[ $EUID -ne 0 ]] && echo -e "${red}必须使用 root 运行${plain}" && exit 1

CLOUD_PORT="${1:-8765}"
INSTALL_DIR="/opt/v2bx-cloud"
REPO_RAW="https://raw.githubusercontent.com/4kercc/V2BX-malio/main"

echo -e "${cyan}==== V2bX 云控中心安装 (端口 $CLOUD_PORT) ====${plain}"

############################################
# 1. 依赖: Node.js >= 16
############################################
need_node=true
if command -v node >/dev/null; then
  VMAJOR=$(node -v | sed 's/v//' | cut -d. -f1)
  if [[ "$VMAJOR" -ge 16 ]]; then
    need_node=false
    echo -e "${green}✓ Node.js $(node -v) 已安装${plain}"
  fi
fi
if [[ "$need_node" == "true" ]]; then
  echo "安装 Node.js 20.x ..."
  if command -v apt >/dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    apt install -y nodejs >/dev/null 2>&1
  elif command -v dnf >/dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    dnf install -y nodejs >/dev/null 2>&1
  elif command -v yum >/dev/null; then
    curl -fsSL https://rpm.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    yum install -y nodejs >/dev/null 2>&1
  fi
  command -v node >/dev/null || { echo -e "${red}Node.js 安装失败，请手动安装后重试${plain}"; exit 1; }
  echo -e "${green}✓ Node.js $(node -v) 安装完成${plain}"
fi

############################################
# 2. 下载控制中心
############################################
mkdir -p "$INSTALL_DIR"
curl -fsSL -o "$INSTALL_DIR/cloud-server.js" "$REPO_RAW/cloud-server.js" || {
  echo -e "${red}cloud-server.js 下载失败${plain}"; exit 1; }
echo -e "${green}✓ 控制中心已更新到最新版${plain}"

############################################
# 3. 初始化数据文件（幂等: 已有则保留 Token 与节点数据）
############################################
if [[ ! -f "$INSTALL_DIR/cloud-data.json" ]]; then
  ADMIN_TOKEN=$(openssl rand -hex 16)
  NODE_TOKEN=$(openssl rand -hex 16)
  cat > "$INSTALL_DIR/cloud-data.json" <<EOF
{
  "token": "${ADMIN_TOKEN}",
  "nodeToken": "${NODE_TOKEN}",
  "updateVersion": "",
  "nodes": {}
}
EOF
  echo -e "${green}✓ 已自动生成双随机 Token${plain}"
else
  ADMIN_TOKEN=$(grep -oP '"token"\s*:\s*"\K[^"]+' "$INSTALL_DIR/cloud-data.json" | head -1)
  NODE_TOKEN=$(grep -oP '"nodeToken"\s*:\s*"\K[^"]+' "$INSTALL_DIR/cloud-data.json" | head -1)
  echo -e "${yellow}已有数据文件，保留原 Token 与节点记录${plain}"
fi

############################################
# 4. systemd 常驻服务
############################################
cat > /etc/systemd/system/v2bx-cloud.service <<EOF
[Unit]
Description=V2bX Cloud Control Center
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/node ${INSTALL_DIR}/cloud-server.js
Environment=PORT=${CLOUD_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now v2bx-cloud >/dev/null 2>&1 || systemctl restart v2bx-cloud
sleep 1
if ! systemctl is-active --quiet v2bx-cloud; then
  echo -e "${red}服务启动失败: journalctl -u v2bx-cloud -n 20${plain}"; exit 1
fi
echo -e "${green}✓ 服务已启动并设为开机自启 (v2bx-cloud)${plain}"

############################################
# 5. 凭证落盘 (仅 root 可读) + 汇总输出
############################################
PUBLIC_IP=$(curl -s4 --max-time 5 ip.sb 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
cat > "$INSTALL_DIR/credentials.txt" <<EOF
管理Token: ${ADMIN_TOKEN}
节点Token: ${NODE_TOKEN}
后台地址:  http://${PUBLIC_IP}:${CLOUD_PORT}
EOF
chmod 600 "$INSTALL_DIR/credentials.txt"

echo ""
echo -e "${cyan}============ 安装完成 ============${plain}"
echo -e "  后台地址 : ${green}http://${PUBLIC_IP}:${CLOUD_PORT}${plain}"
echo -e "  管理 Token: ${green}${ADMIN_TOKEN}${plain}  （登录后台用，妥善保管）"
echo -e "  节点 Token: ${green}${NODE_TOKEN}${plain}  （分发给节点）"
echo -e "  凭证备份 : ${INSTALL_DIR}/credentials.txt (600)"
echo ""
echo -e "${yellow}== 节点接入命令（复制到各节点服务器执行）==${plain}"
echo "bash <(curl -fsSL ${REPO_RAW}/cloud-join.sh) \"http://${PUBLIC_IP}:${CLOUD_PORT}\" \"${NODE_TOKEN}\""
echo ""
echo -e "${yellow}== 安全提醒 ==${plain}"
echo -e "  1. 当前为 HTTP 明文，正式使用请配置 Nginx/Caddy HTTPS 反代后，"
echo -e "     用 https 地址重新让节点接入（心跳含节点 ApiKey，必须加密传输）"
echo -e "  2. 云防火墙/安全组如需放行 ${CLOUD_PORT} 端口，建议仅对节点 IP 段开放"
echo -e "  3. 管理命令: systemctl {status|restart} v2bx-cloud"
