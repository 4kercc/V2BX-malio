#!/usr/bin/env bash
############################################
# V2bX 云控 agent 一键更新（在已接入云控的节点上执行）
#
# 作用: 把 agent 与长轮询守护更新到最新版，无需重新对接、不影响业务
#   新增能力: 证书详情上报(域名/到期/路径/自签) · V2bX 服务状态上报 · 命令秒级下发
# 用法: bash <(curl -fsSL https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-agent-update.sh)
# 幂等: 可重复执行；不会改动 V2bX 配置，不会重启业务
############################################
set -u
REPO_RAW="https://raw.githubusercontent.com/4kercc/V2BX-malio/main"
CONF="/etc/V2bX/cloud.conf"
DIR="/usr/local/V2bX"
CB="?cb=$(date +%s)"   # 破坏 CDN 缓存，避免拉到旧版
red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; cyan=$'\033[36m'; plain=$'\033[0m'

[[ $EUID -eq 0 ]] || { echo -e "${red}请用 root 执行${plain}"; exit 1; }
[[ -f "$CONF" ]] || { echo -e "${red}未找到 $CONF —— 该节点尚未接入云控，请先执行面板里的「一键对接脚本」${plain}"; exit 1; }
command -v curl >/dev/null || { echo -e "${red}缺少 curl，无法继续${plain}"; exit 1; }
mkdir -p "$DIR"

echo -e "${cyan}== 1/4 更新 agent ==${plain}"
curl -fsSL -o "$DIR/cloud-agent.sh.new" "$REPO_RAW/cloud-agent.sh$CB" || {
  echo -e "${red}agent 下载失败，请检查节点网络（未做任何改动）${plain}"; rm -f "$DIR/cloud-agent.sh.new"; exit 1; }
bash -n "$DIR/cloud-agent.sh.new" 2>/dev/null || {
  echo -e "${red}下载的 agent 校验失败，已放弃（未做任何改动）${plain}"; rm -f "$DIR/cloud-agent.sh.new"; exit 1; }
mv -f "$DIR/cloud-agent.sh.new" "$DIR/cloud-agent.sh"
chmod +x "$DIR/cloud-agent.sh"
echo -e "  ${green}✓${plain} agent 版本: $(grep -oP 'AGENT_VER="\K[0-9]+' "$DIR/cloud-agent.sh" | head -1)"

echo -e "${cyan}== 2/4 更新长轮询守护 ==${plain}"
DAEMON_OK=0
if curl -fsSL -o "$DIR/cloud-agent-daemon.sh.new" "$REPO_RAW/cloud-agent-daemon.sh$CB"; then
  if bash -n "$DIR/cloud-agent-daemon.sh.new" 2>/dev/null; then
    mv -f "$DIR/cloud-agent-daemon.sh.new" "$DIR/cloud-agent-daemon.sh"; chmod +x "$DIR/cloud-agent-daemon.sh"; DAEMON_OK=1
  else
    rm -f "$DIR/cloud-agent-daemon.sh.new"
  fi
fi
if [[ $DAEMON_OK -eq 1 ]] && command -v systemctl >/dev/null; then
  cat > /etc/systemd/system/v2bx-cloud-agent.service <<'EOF'
[Unit]
Description=V2bX Cloud Agent (long-poll, instant command delivery)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/V2bX/cloud-agent-daemon.sh
Restart=always
RestartSec=5
Nice=10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable --now v2bx-cloud-agent >/dev/null 2>&1 || systemctl restart v2bx-cloud-agent >/dev/null 2>&1
  sleep 2
  echo -e "  ${green}✓${plain} 守护状态: $(systemctl is-active v2bx-cloud-agent 2>/dev/null || echo 未知)  （命令下发秒级生效）"
else
  echo -e "  ${yellow}!${plain} 守护未安装（无 systemd 或下载失败），命令下发仍走 cron"
fi

echo -e "${cyan}== 3/4 校准 cron 兜底 ==${plain}"
(crontab -l 2>/dev/null | grep -v "cloud-agent.sh"; echo "*/2 * * * * $DIR/cloud-agent.sh >/dev/null 2>&1") | crontab -
echo -e "  ${green}✓${plain} 已就绪（守护与 cron 互不冲突）"

echo -e "${cyan}== 4/4 立即跑一轮验证 ==${plain}"
if bash "$DIR/cloud-agent.sh"; then
  echo -e "  ${green}✓${plain} 心跳正常"
else
  echo -e "  ${yellow}!${plain} 本轮异常，排查: journalctl -t v2bx-cloud -n 20 --no-pager"
fi

echo ""
echo -e "${green}==== 更新完成 ====${plain}"
echo "  后台可看到: 证书列/「🔐 证书到期」有本机证书详情；服务状态会标记未安装或已停止"
echo "  命令下发: 重启/升级/下发配置 现在 1~4 秒生效（原为最长 2 分钟）"
