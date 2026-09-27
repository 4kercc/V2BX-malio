#!/usr/bin/env bash
############################################
# V2bX 云控 agent 常驻守护（长轮询模式）
#
# 作用: 把命令下发延迟从「等下一次 cron（最长 2 分钟）」降到秒级
# 循环: 跑一轮完整采集/心跳 → 长轮询挂起等任务 → 有任务立即再跑一轮
# 兼容: cron 仍保留作为兜底（cloud-agent.sh 自带 flock，不会并发执行）
# 安装: 由 cloud-join.sh 部署为 systemd 服务 v2bx-cloud-agent
############################################
CONF="/etc/V2bX/cloud.conf"
AGENT="/usr/local/V2bX/cloud-agent.sh"
[[ -f "$CONF" ]] || exit 0
# shellcheck disable=SC1090
source "$CONF"
[[ -n "$CLOUD_URL" && -n "$CLOUD_TOKEN" ]] || exit 0
command -v curl >/dev/null || exit 0

CURL_TLS=""
[[ "$CLOUD_INSECURE" == "1" ]] && CURL_TLS="-k"
NAME="${NODE_NAME:-$(hostname)}"
log() { logger -t v2bx-cloud "$1" 2>/dev/null || true; }

log "daemon: 已启动（长轮询模式，命令秒级下发）"
STREAK=0
while :; do
  # 完整一轮: 采集指标 + 应用期望配置/动作/重命名
  [[ -f "$AGENT" ]] && bash "$AGENT"

  # 长轮询: 服务端挂起连接直到有任务或超时（~50s）
  RESP=$(curl -s $CURL_TLS --max-time 58 -X POST "$CLOUD_URL/api/wait" \
    -H "X-Token: $CLOUD_TOKEN" -H "Content-Type: application/json" \
    -d "{\"name\":\"${NAME}\"}" 2>/dev/null)

  case "$RESP" in
    *'"wake":1'*)
      # 有任务: 立刻再跑一轮；连续唤醒时退避，避免异常情况下空转
      STREAK=$((STREAK + 1))
      if [[ $STREAK -gt 5 ]]; then sleep 10; STREAK=0; else sleep 1; fi
      ;;
    *'"idle":1'*) STREAK=0 ;;
    *) STREAK=0; sleep 5 ;;   # 服务不可达/被限速: 退避后重试
  esac
done
