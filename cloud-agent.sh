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
AGENT_VER="10"

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
# 二进制路径兼容: 标准安装/自定义路径/PATH 中查找
V2BX_BIN=""
for p in /usr/local/V2bX/V2bX /usr/local/bin/V2bX /usr/bin/V2bX; do
  [[ -x "$p" ]] && { V2BX_BIN="$p"; break; }
done
[[ -z "$V2BX_BIN" ]] && V2BX_BIN="$(command -v V2bX 2>/dev/null || true)"
VERSION=""
[[ -n "$V2BX_BIN" ]] && VERSION=$("$V2BX_BIN" version 2>/dev/null | grep -aoE 'V2bX [^ ]+' | head -1 | awk '{print $2}')
# 服务状态: 区分「agent 在线」与「V2bX 真的在跑」（云控盲区防护）
if systemctl list-unit-files 2>/dev/null | grep -qE '^(V2bX|v2bx)\.service'; then
  SVC="$(systemctl is-active V2bX 2>/dev/null)"
  [[ -z "$SVC" ]] && SVC="$(systemctl is-active v2bx 2>/dev/null)"
  [[ -z "$SVC" ]] && SVC="inactive"
else
  SVC="absent"
fi
if [[ "$SVC" != "active" ]] && { pgrep -x V2bX >/dev/null 2>&1 || pgrep -x v2bx >/dev/null 2>&1; }; then
  SVC="active" # 非 systemd 安装时的进程兜底
fi
RSS_MB=$(systemctl show V2bX -p MemoryCurrent --value 2>/dev/null | awk '{printf "%d", $1/1024/1024}')
if [[ -z "$RSS_MB" || "$RSS_MB" == "0" ]]; then
  RSS_PID=$(pgrep -x V2bX 2>/dev/null | head -1)
  [[ -z "$RSS_PID" ]] && RSS_PID=$(pgrep -x v2bx 2>/dev/null | head -1)
  [[ -n "$RSS_PID" ]] && RSS_MB=$(awk '/VmRSS/{printf "%d", $2/1024}' /proc/"$RSS_PID"/status 2>/dev/null)
fi
RSS_MB=${RSS_MB:-0}
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

# 证书探测（多路径 + 按域名匹配兜底，兼容自签 / ACME / 自定义 CertFile）
CERT_DAYS=""; CERT_PATH=""; CERT_DOMAIN=""; CERT_END=""; CERT_SELF="false"
CERT_FILE=$(grep -oP '"CertFile"\s*:\s*"\K[^"]+' "$CONFIG_JSON" 2>/dev/null | head -1)
DOM_HINT=$(grep -oP '"CertDomain"\s*:\s*"\K[^"]+' "$CONFIG_JSON" 2>/dev/null | head -1)
[[ -z "$DOM_HINT" && -n "$CERT_FILE" ]] && DOM_HINT=$(basename "$CERT_FILE" | sed -E 's/\.(crt|pem|cer)$//')
CAND=()
[[ -n "$CERT_FILE" ]] && CAND+=("$CERT_FILE")
if [[ -n "$DOM_HINT" ]]; then
  CAND+=("/etc/ssl/${DOM_HINT}.crt" "/etc/ssl/certs/${DOM_HINT}.crt" \
         "/etc/V2bX/cert/${DOM_HINT}.crt" "/etc/V2bX/certs/${DOM_HINT}.crt" "/etc/V2bX/${DOM_HINT}.crt" \
         "/root/cert/${DOM_HINT}.crt" "/etc/letsencrypt/live/${DOM_HINT}/fullchain.pem" \
         "/root/.acme.sh/${DOM_HINT}_ecc/fullchain.cer" "/root/.acme.sh/${DOM_HINT}/fullchain.cer")
fi
for f in "${CAND[@]}"; do [[ -n "$f" && -f "$f" ]] && { CERT_PATH="$f"; break; }; done
# 兜底: 在常见目录里找 CN/SAN 命中本节点域名的证书（最多扫 40 个文件）
if [[ -z "$CERT_PATH" && -n "$DOM_HINT" ]] && command -v openssl >/dev/null; then
  while IFS= read -r f; do
    if openssl x509 -in "$f" -noout -subject -ext subjectAltName 2>/dev/null | grep -qF "$DOM_HINT"; then
      CERT_PATH="$f"; break
    fi
  done < <(find /etc/ssl /etc/V2bX /root/cert /root/.acme.sh -maxdepth 3 -type f \
             \( -name '*.crt' -o -name '*.pem' -o -name 'fullchain.cer' \) 2>/dev/null | head -40)
fi
if [[ -n "$CERT_PATH" ]] && command -v openssl >/dev/null; then
  CERT_END=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2)
  if [[ -n "$CERT_END" ]]; then
    CERT_DAYS=$(( ( $(date -d "$CERT_END" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
    CERT_CN=$(openssl x509 -in "$CERT_PATH" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p' | head -1 | tr -d '"')
    CERT_ISS=$(openssl x509 -in "$CERT_PATH" -noout -issuer 2>/dev/null | sed -n 's/.*CN *= *//p' | head -1)
    CERT_DOMAIN="${CERT_CN:-$DOM_HINT}"
    [[ -n "$CERT_CN" && "$CERT_CN" == "$CERT_ISS" ]] && CERT_SELF="true"
  fi
fi

# 当前配置
get_str() { grep -oP "\"$1\"\s*:\s*\"\K[^\"]+" "$CONFIG_JSON" 2>/dev/null | head -1; }
get_int() { grep -oP "\"$1\"\s*:\s*\K[0-9]+" "$CONFIG_JSON" 2>/dev/null | head -1; }
CUR_HOST=$(get_str ApiHost)
CUR_KEY=$(get_str ApiKey)
CUR_ID=$(get_int NodeID)
CUR_DOMAIN=$(get_str CertDomain)
CUR_NAME=$(get_str Name)

############################################
# 节点重命名: 服务端下发 desiredName → 迁移本地 key（保持身份键稳定）
############################################
APPLY_RENAME_MARKER="/tmp/.v2bx-cloud-rename-applied"
PENDING_RENAME_FILE="/etc/V2bX/.cloud_pending_rename"

############################################
# 上报心跳并拉取期望配置
############################################
# 上一次动作的执行确认（一次性上报给云端，用于后台显示"已完成"）
ACK=""
if [[ -f /tmp/.v2bx-cloud-ack ]]; then
  ACK=$(head -1 /tmp/.v2bx-cloud-ack 2>/dev/null)
  rm -f /tmp/.v2bx-cloud-ack
fi
# 上一次重命名的应用确认（一次性上报: rename:旧名，服务端据此迁移数据）
APPLIED_RENAME=""
if [[ -f "$APPLY_RENAME_MARKER" ]]; then
  APPLIED_RENAME=$(head -1 "$APPLY_RENAME_MARKER" 2>/dev/null)
  rm -f "$APPLY_RENAME_MARKER"
fi

# 心跳报文用 jq 构建：任何字段含引号/分号/换行都能正确转义（手写 JSON 曾因证书 CN 带引号导致整包非法）
PAYLOAD=$(jq -n \
  --arg name "${NAME}" --arg hostname "${HOSTNAME}" --arg version "${VERSION}" \
  --argjson rss "${RSS_MB:-0}" --argjson conns "${CONNS:-0}" --argjson uptime "${SERVICE_UPTIME:-0}" \
  --arg warp "${WARP}" --arg svc "${SVC}" --arg load "${LOAD}" --arg ack "${ACK}" \
  --arg agentVer "${AGENT_VER}" --argjson certDays "${CERT_DAYS:-null}" \
  --arg cPath "${CERT_PATH}" --arg cDomain "${CERT_DOMAIN}" --arg cEnd "${CERT_END}" \
  --argjson cDays "${CERT_DAYS:-null}" --argjson cSelf "${CERT_SELF:-false}" \
  --arg appliedRename "${APPLIED_RENAME}" \
  --arg apiHost "${CUR_HOST}" --arg apiKey "${CUR_KEY}" --argjson nodeId "${CUR_ID:-0}" \
  --arg certDomain "${CUR_DOMAIN}" --arg cName "${CUR_NAME}" \
  '{name:$name, hostname:$hostname, version:$version, rss_mb:$rss, conns:$conns, uptime_sec:$uptime,
    warp:$warp, svc:$svc, load:$load, ack:$ack, agentVer:$agentVer, certDays:$certDays,
    cert:{path:$cPath, domain:$cDomain, end:$cEnd, days:$cDays, selfSigned:$cSelf},
    appliedRename:$appliedRename,
    cfg:{ApiHost:$apiHost, ApiKey:$apiKey, NodeID:$nodeId, CertDomain:$certDomain, Name:$cName}}' 2>/dev/null)
[[ -n "$PAYLOAD" ]] || { log "payload 构建失败(jq)"; exit 0; }

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
# 节点重命名: 服务端 pendingRename 下发 desiredName → 迁移身份键
# 流程: 改 cloud.conf NODE_NAME(云控身份键) + config.json Name(面板显示名)
#      → 写确认标记 → 下次心跳用新名上报，服务端凭 appliedRename 迁移数据
############################################
WANT_NAME=$(echo "$RESP" | jq -r ".desiredName // empty" 2>/dev/null)
if [[ -n "$WANT_NAME" && "$WANT_NAME" != "null" && "$WANT_NAME" != "$NODE_NAME" ]]; then
  if [[ "$WANT_NAME" =~ [|] || ${#WANT_NAME} -gt 64 ]]; then
    log "rename: 非法名称(含 | 或超长)，跳过: $WANT_NAME"
  else
    OLD_CLOUD_NAME="$NODE_NAME"
    sed -i "s/^NODE_NAME=\".*/NODE_NAME=\"${WANT_NAME}\"/" /etc/V2bX/cloud.conf 2>/dev/null || true
    NODE_NAME="$WANT_NAME"
    if grep -q '"Name"' "$CONFIG_JSON" 2>/dev/null; then
      sed -i -E "s/(\"Name\"\s*:\s*\")[^\"]*(\")/\1${WANT_NAME}\2/" "$CONFIG_JSON"
    fi
    echo "rename:${OLD_CLOUD_NAME}" > "$APPLY_RENAME_MARKER"
    log "rename: ${OLD_CLOUD_NAME} -> ${WANT_NAME} (已应用，等下次心跳确认迁移)"
    if [[ "$CHANGED" == "1" ]]; then
      systemctl restart V2bX && log "rename 轮次附带配置变更，已重启 V2bX"
    fi
    exit 0
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
    "https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-agent.sh" 2>/dev/null
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
