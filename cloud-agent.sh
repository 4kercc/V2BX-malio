#!/bin/bash
############################################
# V2BX-malio 云控 Agent（节点侧，拉取式）
# 由 install_v2bx_anytls.sh 安装到 /usr/local/V2bX/cloud-agent.sh
# 配置：/etc/V2bX/cloud.conf
# cron 每 2 分钟执行一次：上报心跳 -> 拉取期望配置 -> 有差异才修改并重启
############################################

CONF="/etc/V2bX/cloud.conf"
CONFIG_JSON="/etc/V2bX/config.json"
LOGTAG="v2bx-cloud"
AGENT_VER="6"

[[ -f "$CONF" ]] || exit 0
source "$CONF"
[[ -n "$CLOUD_URL" && -n "$CLOUD_TOKEN" ]] || exit 0
command -v curl >/dev/null || exit 0
command -v jq >/dev/null || exit 0

# 自签 HTTPS 场景: CLOUD_INSECURE=1 时跳过证书校验
CURL_TLS=""
[[ "$CLOUD_INSECURE" == "1" ]] && CURL_TLS="-k"

log() { logger -t "$LOGTAG" "$1" 2>/dev/null || echo "$(date '+%F %T') $1" >> /var/log/v2bx-cloud.log; }

# 防止上一轮尚未跑完（如正在执行 update）
exec 9>/tmp/v2bx-cloud.lock
flock -n 9 || exit 0

############################################
# 采集本机信息
############################################
NAME="${NODE_NAME:-$(hostname)}"
HOSTNAME="$(hostname 2>/dev/null)"
VERSION=$(/usr/local/V2bX/V2bX version 2>/dev/null | grep -aoE 'V2bX [^ ]+' | head -1 | awk '{print $2}')
RSS_MB=$(systemctl show V2bX -p MemoryCurrent --value 2>/dev/null | awk '{printf "%d", $1/1024/1024}')
CONNS=$(ss -tan state established 2>/dev/null | wc -l)
# 服务运行时长（同为单调时钟: 开机秒数 - 服务启动单调时间）
MONO_TS=$(systemctl show V2bX -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
UP_S=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
SERVICE_UPTIME=0
if [[ -n "$MONO_TS" && "$MONO_TS" != "0" && -n "$UP_S" ]]; then
  SERVICE_UPTIME=$(( UP_S - MONO_TS / 1000000 ))
fi
[[ "$SERVICE_UPTIME" -lt 0 ]] && SERVICE_UPTIME=0
LOAD=$(cat /proc/loadavg 2>/dev/null | awk '{print $1, $2, $3}')

# WARP 模式
if [[ -f /etc/V2bX/sing_origin_warp.json ]]; then
  if grep -q '"warp-auto"' /etc/V2bX/sing_origin.json 2>/dev/null; then WARP="on"; else WARP="off"; fi
else
  WARP="none"
fi

# 证书剩余天数（取配置里的 CertFile）
CERT_DAYS=""
CERT_FILE=$(grep -oP '"CertFile"\s*:\s*"\K[^"]+' "$CONFIG_JSON" 2>/dev/null | head -1)
if [[ -n "$CERT_FILE" && -f "$CERT_FILE" ]] && command -v openssl >/dev/null; then
  CERT_END=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2)
  if [[ -n "$CERT_END" ]]; then
    CERT_DAYS=$(( ( $(date -d "$CERT_END" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
  fi
fi

# 当前配置
get_str() { grep -oP "\"$1\"\s*:\s*\"\K[^\"]+" "$CONFIG_JSON" 2>/dev/null | head -1; }
get_int() { grep -oP "\"$1\"\s*:\s*\K[0-9]+" "$CONFIG_JSON" 2>/dev/null | head -1; }
CUR_HOST=$(get_str ApiHost)
CUR_KEY=$(get_str ApiKey)
CUR_ID=$(get_int NodeID)
CUR_DOMAIN=$(get_str CertDomain)

############################################
# 上报心跳并拉取期望配置
############################################
# 上一次动作的执行确认（一次性上报给云端，用于后台显示"已完成"）
ACK=""
if [[ -f /tmp/.v2bx-cloud-ack ]]; then
  ACK=$(head -1 /tmp/.v2bx-cloud-ack 2>/dev/null)
  rm -f /tmp/.v2bx-cloud-ack
fi

PAYLOAD=$(cat <<EOF
{
  "name": "${NAME}",
  "hostname": "${HOSTNAME}",
  "version": "${VERSION}",
  "rss_mb": ${RSS_MB:-0},
  "conns": ${CONNS:-0},
  "uptime_sec": ${SERVICE_UPTIME:-0},
  "warp": "${WARP}",
  "load": "${LOAD}",
  "ack": "${ACK}",
  "agentVer": "${AGENT_VER}",
  "certDays": ${CERT_DAYS:-null},
  "cfg": {"ApiHost":"${CUR_HOST}","ApiKey":"${CUR_KEY}","NodeID":${CUR_ID:-0},"CertDomain":"${CUR_DOMAIN}"}
}
EOF
)

RESP=$(curl $CURL_TLS -sf --max-time 15 -X POST "$CLOUD_URL/api/heartbeat" \
  -H "X-Token: $CLOUD_TOKEN" -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>/dev/null)

[[ -n "$RESP" ]] || { log "heartbeat failed (no response)"; exit 0; }

############################################
# 应用期望配置（有差异才改，改了才重启）
############################################
apply_str() { # $1=json字段  $2=json键名  $3=当前值
  local want=$(echo "$RESP" | jq -r ".desired.$1 // empty" 2>/dev/null)
  [[ -z "$want" || "$want" == "null" ]] && return 0
  [[ "$want" == "$3" ]] && return 0
  sed -i -E "s/(\"$2\"\s*:\s*\")[^\"]+(\")/\1${want//\//\\/}\2/g" "$CONFIG_JSON"
  log "applied $2 -> $want"
  CHANGED=1
}
apply_int() {
  local want=$(echo "$RESP" | jq -r ".desired.$1 // empty" 2>/dev/null)
  [[ -z "$want" || "$want" == "null" ]] && return 0
  [[ "$want" =~ ^[0-9]+$ ]] || { log "NodeID 非数字，跳过: $want"; return 0; }
  [[ "$want" == "$3" ]] && return 0
  sed -i -E "s/(\"$2\"\s*:\s*)[0-9]+/\1${want}/g" "$CONFIG_JSON"
  log "applied $2 -> $want"
  CHANGED=1
}

# 修改前备份当前配置（用于校验失败回滚，保证"不影响现有配置"）
cp -f "$CONFIG_JSON" "$CONFIG_JSON.bak.cloud" 2>/dev/null || true

CHANGED=0
apply_str "ApiHost" "ApiHost" "$CUR_HOST"
apply_str "ApiKey" "ApiKey" "$CUR_KEY"
apply_int "NodeID" "NodeID" "$CUR_ID"

# CertDomain 特殊处理：新证书不存在时先生成自签兜底，避免改完域名重启即挂
WANT_DOMAIN=$(echo "$RESP" | jq -r ".desired.CertDomain // empty" 2>/dev/null)
if [[ -n "$WANT_DOMAIN" && "$WANT_DOMAIN" != "null" && "$WANT_DOMAIN" != "$CUR_DOMAIN" ]]; then
  if [[ ! -f "/etc/ssl/${WANT_DOMAIN}.crt" || ! -f "/etc/ssl/${WANT_DOMAIN}.key" ]]; then
    mkdir -p /etc/ssl
    openssl req -x509 -nodes -newkey rsa:2048 \
      -keyout "/etc/ssl/${WANT_DOMAIN}.key" \
      -out "/etc/ssl/${WANT_DOMAIN}.crt" \
      -subj "/CN=${WANT_DOMAIN}" -days 3650 2>/dev/null \
      && log "CertDomain=${WANT_DOMAIN} 无证书，已自动生成自签兜底"
  fi
  sed -i -E "s/(\"CertDomain\"\s*:\s*\")[^\"]+(\")/\1${WANT_DOMAIN}\2/g" "$CONFIG_JSON"
  log "applied CertDomain -> $WANT_DOMAIN"
  CHANGED=1
fi

# WARP 开关
WANT_WARP=$(echo "$RESP" | jq -r ".desired.Warp // empty" 2>/dev/null)
if [[ -n "$WANT_WARP" && "$WANT_WARP" != "$WARP" && "$WANT_WARP" != "null" ]]; then
  if [[ ! -f /etc/V2bX/sing_origin_warp.json ]]; then
    log "WARP 模板不存在(旧安装)，跳过 Warp=$WANT_WARP"
  elif [[ "$WANT_WARP" == "on" ]]; then
    cp -f /etc/V2bX/sing_origin_warp.json /etc/V2bX/sing_origin.json; CHANGED=1; log "applied Warp -> on"
  elif [[ "$WANT_WARP" == "off" ]]; then
    if [[ -f /etc/V2bX/sing_origin_direct.json ]]; then
      cp -f /etc/V2bX/sing_origin_direct.json /etc/V2bX/sing_origin.json; CHANGED=1; log "applied Warp -> off"
    else
      jq 'del(.outbounds[]? | select(.tag == "warp-out" or .tag == "warp-auto"))
          | .route.rules |= map(select((.outbound // "") != "warp-auto"))' \
          /etc/V2bX/sing_origin.json > /etc/V2bX/sing_origin.json.tmp && \
          mv /etc/V2bX/sing_origin.json.tmp /etc/V2bX/sing_origin.json && CHANGED=1 && log "applied Warp -> off(jq)"
    fi
  fi
fi

############################################
# JSON 校验：任何修改导致配置损坏时自动回滚，绝不带病重启
############################################
if [[ "$CHANGED" == "1" ]]; then
  if ! jq empty "$CONFIG_JSON" 2>/dev/null; then
    cp -f "$CONFIG_JSON.bak.cloud" "$CONFIG_JSON"
    CHANGED=0
    log "config.json 校验失败，已回滚到修改前备份"
  fi
fi

############################################
# 处理一次性动作
############################################
ACTION=$(echo "$RESP" | jq -r ".action // \"none\"" 2>/dev/null)
if [[ "$ACTION" == "restart" ]]; then
  systemctl restart V2bX && { log "action: restarted"; echo "restart $(date +%s)" > /tmp/.v2bx-cloud-ack; }
  exit 0
fi
if [[ "$ACTION" == "update" ]]; then
  # 版本锁定: 服务端可指定 Release 版本，留空 = 最新
  VER=$(echo "$RESP" | jq -r ".version // empty" 2>/dev/null)
  if [[ -n "$VER" && "$VER" != "null" ]]; then
    log "action: self-update (pinned $VER)"
    nohup v2bx update "$VER" >> /var/log/v2bx-cloud-update.log 2>&1 &
  else
    log "action: self-update (latest)"
    nohup bash <(curl -fsSL https://raw.githubusercontent.com/4kercc/V2BX-malio/main/update-v2bx.sh) >> /var/log/v2bx-cloud-update.log 2>&1 &
  fi
  echo "update $(date +%s)" > /tmp/.v2bx-cloud-ack
  exit 0
fi
# agent 自更新: 服务端下发版本号与本机不一致时，拉取新版并校验替换
AGENT_UPDATE=$(echo "$RESP" | jq -r ".agentUpdate // \"0\"" 2>/dev/null)
if [[ "$AGENT_UPDATE" == "1" ]]; then
  log "agent: self-update to server version"
  curl $CURL_TLS -fsSL -o /usr/local/V2bX/cloud-agent.sh.new \
    "https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-agent.sh?cb=$(date +%s%N)" 2>/dev/null
  if [[ -s /usr/local/V2bX/cloud-agent.sh.new ]] \
     && bash -n /usr/local/V2bX/cloud-agent.sh.new 2>/dev/null \
     && grep -q 'AGENT_VER' /usr/local/V2bX/cloud-agent.sh.new; then
    mv -f /usr/local/V2bX/cloud-agent.sh.new /usr/local/V2bX/cloud-agent.sh
    chmod +x /usr/local/V2bX/cloud-agent.sh
    log "agent: self-update applied"
  else
    rm -f /usr/local/V2bX/cloud-agent.sh.new
    log "agent: self-update download invalid, skipped"
  fi
  exit 0
fi

if [[ "$CHANGED" == "1" ]]; then
  systemctl restart V2bX && log "config changed, V2bX restarted"
else
  log "heartbeat ok (no change)"
fi
