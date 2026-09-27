#!/bin/bash
############################################
# V2BX-malio 云控接入脚本（存量节点专用）
# 只写 cloud.conf + agent + cron，绝不修改现有节点配置
# 用法:
#   bash cloud-join.sh "https://云控地址" "Token"              # 自动命名
#   bash cloud-join.sh "https://云控地址" "Token" "自定义名称"   # 指定名称
#   bash cloud-join.sh "https://云控地址" "Token" "" "insecure" # 云控为自签 HTTPS 时免证书校验
############################################

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; plain='\033[0m'
[[ $EUID -ne 0 ]] && echo -e "${red}必须使用 root 运行${plain}" && exit 1

CLOUD_URL="${1:-}"
CLOUD_TOKEN="${2:-}"
NODE_NAME="${3:-}"
INSECURE="${4:-}"

if [[ -z "$CLOUD_URL" || -z "$CLOUD_TOKEN" ]]; then
    echo -e "${red}用法: bash cloud-join.sh \"https://云控地址\" \"Token\" [自定义名称]${plain}"
    exit 1
fi
CLOUD_URL="${CLOUD_URL%/}"

# 依赖检查（缺 jq 则安装，agent 需要）
if ! command -v curl >/dev/null; then
    command -v apt >/dev/null && apt install -y curl >/dev/null 2>&1
    command -v yum >/dev/null && yum install -y curl >/dev/null 2>&1
fi
if ! command -v jq >/dev/null; then
    echo -n "安装 jq..."
    command -v apt >/dev/null && apt install -y jq >/dev/null 2>&1
    command -v yum >/dev/null && yum install -y jq >/dev/null 2>&1
    command -v jq >/dev/null && echo -e "${green}完成${plain}" || { echo -e "${red}失败${plain}"; exit 1; }
fi

############################################
# 读取现有节点信息（只读，展示给用户确认身份）
############################################
CONFIG_JSON="/etc/V2bX/config.json"
CUR_HOST=$(grep -oP '"ApiHost"\s*:\s*"\K[^"]+' "$CONFIG_JSON" 2>/dev/null | head -1)
CUR_ID=$(grep -oP '"NodeID"\s*:\s*\K[0-9]+' "$CONFIG_JSON" 2>/dev/null | head -1)
HS=$(hostname -s 2>/dev/null || hostname)

echo ""
echo "==== 现有节点信息（只读展示，接入过程不修改） ===="
echo "  ApiHost : ${CUR_HOST:-未找到(仍可接入)}"
echo "  NodeID  : ${CUR_ID:-未找到(仍可接入)}"

############################################
# 名称确定: 优先复用云控上已有身份（按 IP 匹配、在线优先），避免重新对接产生重复节点
#   1) 命令行显式传入名称 → 用传入的
#   2) 未传入 → 问云控 /api/whoami：本机 IP 上已有记录则复用（在线优先，其次最近心跳）
#   3) 云控上查不到 → 自动命名 node{NodeID}-{短主机名}
############################################
CURL_TLS=""
[[ "$INSECURE" == "insecure" || "$INSECURE" == "1" ]] && CURL_TLS="-k"
if [[ -z "$NODE_NAME" ]]; then
    WHOAMI=$(curl -s $CURL_TLS --max-time 10 -X POST "${CLOUD_URL}/api/whoami" \
        -H "X-Token: ${CLOUD_TOKEN}" -H "Content-Type: application/json" -d '{}' 2>/dev/null)
    REC_NAME=$(echo "$WHOAMI" | jq -r '.recommend // empty' 2>/dev/null)
    REC_CNT=$(echo "$WHOAMI" | jq -r '.nodes | length' 2>/dev/null)
    REC_ONLINE=$(echo "$WHOAMI" | jq -r '[.nodes[] | select(.online)] | length' 2>/dev/null)
    if [[ -n "$REC_NAME" && "$REC_NAME" != "null" ]]; then
        NODE_NAME="$REC_NAME"
        echo -e "${green}✓ 云控上已存在本机记录（同 IP 共 ${REC_CNT:-?} 条，在线 ${REC_ONLINE:-0} 条），复用身份: ${NODE_NAME}${plain}"
        if [[ "${REC_CNT:-0}" -gt 1 ]]; then
            echo -e "${yellow}  提示: 同 IP 存在多条记录，已选用在线且最近心跳的那条；如需清理可在面板中重命名或删除其余记录${plain}"
        fi
    fi
fi
if [[ -z "$NODE_NAME" ]]; then
    if [[ -n "$CUR_ID" ]]; then
        NODE_NAME="node${CUR_ID}-${HS}"
    else
        NODE_NAME="${HS}"
    fi
fi
echo "  云控名称: ${NODE_NAME}"
echo ""

############################################
# 写入云控配置（新增文件，不碰 config.json）
############################################
mkdir -p /etc/V2bX /usr/local/V2bX

# TLS 免校验决策: 显式第4参数 > 自动探测(严格连失败而 -k 连成功 = 自签) > 不启用
NEED_INSECURE=""
if [[ "$INSECURE" =~ ^(insecure|selfsign|-k|1)$ ]]; then
  NEED_INSECURE=1
  echo -e "${yellow}已按参数启用 TLS 免证书校验${plain}"
elif [[ "$CLOUD_URL" == https:* ]]; then
  if ! curl -sf --max-time 8 "$CLOUD_URL/" >/dev/null 2>&1; then
    if curl -skf --max-time 8 "$CLOUD_URL/" >/dev/null 2>&1; then
      NEED_INSECURE=1
      echo -e "${yellow}检测到自签证书，自动启用免校验（正规证书不受影响）${plain}"
    fi
  fi
fi
CLOUD_INSECURE_LINE=""
[[ "$NEED_INSECURE" == "1" ]] && CLOUD_INSECURE_LINE='CLOUD_INSECURE="1"'

cat > /etc/V2bX/cloud.conf <<EOF
CLOUD_URL="${CLOUD_URL}"
CLOUD_TOKEN="${CLOUD_TOKEN}"
NODE_NAME="${NODE_NAME}"
${CLOUD_INSECURE_LINE}
EOF

curl -fsSL -o /usr/local/V2bX/cloud-agent.sh \
    https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-agent.sh || {
    echo -e "${red}agent 下载失败，请检查网络${plain}"; exit 1; }
chmod +x /usr/local/V2bX/cloud-agent.sh

# 常驻守护（长轮询）: 命令下发秒级送达，替代「等下一次 cron」的 2 分钟延迟
curl -fsSL -o /usr/local/V2bX/cloud-agent-daemon.sh \
    https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-agent-daemon.sh || true
chmod +x /usr/local/V2bX/cloud-agent-daemon.sh 2>/dev/null

# 幂等注册 cron（兜底：守护进程异常/被停时仍能上报；agent 自带 flock 不会并发）
(crontab -l 2>/dev/null | grep -v "cloud-agent.sh"; echo "*/2 * * * * /usr/local/V2bX/cloud-agent.sh >/dev/null 2>&1") | crontab -

if [[ -f /usr/local/V2bX/cloud-agent-daemon.sh ]] && command -v systemctl >/dev/null; then
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
  echo -e "${green}✓ 长轮询守护已安装 (v2bx-cloud-agent)，命令下发秒级生效${plain}"
else
  echo -e "${yellow}提示: 未安装 systemd 守护，命令下发仍走 cron（最长 2 分钟）${plain}"
fi

############################################
# 立即执行一次 agent 完成首心跳，当场验证
############################################
echo -n "发送首心跳..."
if /usr/local/V2bX/cloud-agent.sh 2>/dev/null && journalctl -t v2bx-cloud -n 1 --no-pager 2>/dev/null | grep -q "heartbeat ok"; then
    echo -e "${green}成功${plain}"
else
    echo -e "${yellow}已执行(详情: journalctl -t v2bx-cloud -n 5)${plain}"
fi

echo ""
echo -e "${green}==== 接入完成 ====${plain}"
echo "  后台地址 : $CLOUD_URL"
echo "  节点名称 : $NODE_NAME  （后台刷新即可看到）"
echo "  身份判定 : 后台表格『名称』列 = node{NodeID}-{主机名}，『面板/节点ID』列实时显示该机当前对接的面板与节点号"
echo "  现有配置 : 未做任何修改（V2bX 未重启，业务无感知）"
