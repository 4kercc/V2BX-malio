#!/bin/bash
############################################
# V2BX-malio 云控 Agent（节点侧，拉取式，支持单机多节点）
#
# 身份规则:
#   单节点机器  → 沿用 cloud.conf 的 NODE_NAME（与旧版行为一致）
#   多节点机器  → config.json 的 .Nodes[] 每个条目 = 面板上一个节点
#                上报名称 = NAME_<NodeID>（重命名覆盖）或 node<NodeID>-<主机名>
#
# 下发修改如何定位:
#   一律按 NodeID 精确匹配 .Nodes[] 里的条目（jq 定向修改），
#   不会误改同机其它节点；重启/升级是整服务动作（影响该机全部节点）
############################################

CONF="/etc/V2bX/cloud.conf"
CONFIG_JSON="/etc/V2bX/config.json"
LOGTAG="v2bx-cloud"
AGENT_VER="19"

[[ -f "$CONF" ]] || exit 0
# shellcheck disable=SC1090
source "$CONF"
[[ -n "$CLOUD_URL" && -n "$CLOUD_TOKEN" ]] || exit 0
command -v curl >/dev/null || exit 0
command -v jq >/dev/null || exit 0

CURL_TLS=""
[[ "$CLOUD_INSECURE" == "1" ]] && CURL_TLS="-k"

log() { logger -t "$LOGTAG" "$1" 2>/dev/null || echo "$(date '+%F %T') $1" >> /var/log/v2bx-cloud.log; }

# 防止上一轮尚未跑完（如正在执行 update）
exec 9>/tmp/v2bx-cloud.lock
flock -n 9 || exit 0

############################################
# 进程级采集
############################################
HOSTNAME="$(hostname 2>/dev/null)"
[[ -z "$HOSTNAME" ]] && HOSTNAME="$(hostname -s 2>/dev/null)"

V2BX_BIN=""
for p in /usr/local/V2bX/V2bX /usr/local/bin/V2bX /usr/bin/V2bX; do
  [[ -x "$p" ]] && { V2BX_BIN="$p"; break; }
done
[[ -z "$V2BX_BIN" ]] && V2BX_BIN="$(command -v V2bX 2>/dev/null || true)"
VERSION=""
[[ -n "$V2BX_BIN" ]] && VERSION=$("$V2BX_BIN" version 2>/dev/null | grep -aoE 'V2bX [^ ]+' | head -1 | awk '{print $2}')

# 服务状态: 区分「agent 在线」与「V2bX 真的在跑」
if systemctl list-unit-files 2>/dev/null | grep -qE '^(V2bX|v2bx)\.service'; then
  SVC="$(systemctl is-active V2bX 2>/dev/null)"
  [[ -z "$SVC" ]] && SVC="$(systemctl is-active v2bx 2>/dev/null)"
  [[ -z "$SVC" ]] && SVC="inactive"
else
  SVC="absent"
fi
if [[ "$SVC" != "active" ]] && { pgrep -x V2bX >/dev/null 2>&1 || pgrep -x v2bx >/dev/null 2>&1; }; then
  SVC="active"
fi
RSS_MB=$(systemctl show V2bX -p MemoryCurrent --value 2>/dev/null | awk '{printf "%d", $1/1024/1024}')
if [[ -z "$RSS_MB" || "$RSS_MB" == "0" ]]; then
  RSS_PID=$(pgrep -x V2bX 2>/dev/null | head -1)
  [[ -z "$RSS_PID" ]] && RSS_PID=$(pgrep -x v2bx 2>/dev/null | head -1)
  [[ -n "$RSS_PID" ]] && RSS_MB=$(awk '/VmRSS/{printf "%d", $2/1024}' /proc/"$RSS_PID"/status 2>/dev/null)
fi
RSS_MB=${RSS_MB:-0}

MONO_TS=$(systemctl show V2bX -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
UP_S=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
SERVICE_UPTIME=0
if [[ -n "$MONO_TS" && "$MONO_TS" != "0" && -n "$UP_S" ]]; then
  SERVICE_UPTIME=$(( UP_S - MONO_TS / 1000000 ))
fi
[[ "$SERVICE_UPTIME" -lt 0 ]] && SERVICE_UPTIME=0
LOAD=$(awk '{print $1, $2, $3}' /proc/loadavg 2>/dev/null)

# WARP 模式（全局模板）
if [[ -f /etc/V2bX/sing_origin_warp.json ]]; then
  if grep -q '"warp-auto"' /etc/V2bX/sing_origin.json 2>/dev/null; then WARP="on"; else WARP="off"; fi
else
  WARP="none"
fi

# 一次性动作确认（上一次动作执行完写入，本轮上报后删除）
ACK=""
if [[ -f /tmp/.v2bx-cloud-ack ]]; then
  ACK=$(head -1 /tmp/.v2bx-cloud-ack 2>/dev/null)
  rm -f /tmp/.v2bx-cloud-ack
fi

############################################
# 实例枚举与工具函数
############################################
NODE_CNT=$(jq -r '.Nodes | length' "$CONFIG_JSON" 2>/dev/null)
NO_CFG=0
if [[ -z "$NODE_CNT" || "$NODE_CNT" == "null" || ! "$NODE_CNT" =~ ^[0-9]+$ || "$NODE_CNT" -lt 1 ]]; then
  # 未安装 V2bX / 配置缺失: 仍上报一条心跳（服务状态会是 absent），避免节点在面板上消失
  NO_CFG=1
  NODE_CNT=1
  log "未找到 config.json 或 Nodes 条目，按「服务未就绪」上报"
fi

# 基础名: 忽略历史污染值 unknown
BASE_NAME="${NODE_NAME:-}"
[[ "$BASE_NAME" == "unknown" || "$BASE_NAME" == "null" ]] && BASE_NAME=""
[[ -z "$BASE_NAME" ]] && BASE_NAME="$HOSTNAME"

node_name() { # $1=NodeID → 输出该节点在云控上的名称
  local ov
  ov=$(grep -oP "^NAME_$1=\"\K[^\"]+" "$CONF" 2>/dev/null | head -1)
  if [[ -n "$ov" ]]; then echo "$ov"
  elif [[ "$NODE_CNT" -gt 1 ]]; then echo "node$1-$HOSTNAME"
  else echo "$BASE_NAME"; fi
}

node_conns() { # $1=ListenIP → 该节点监听端口上的入站连接数（按节点区分，且排除本机外连）
  local ip="$1" ports
  [[ -z "$ip" ]] && { echo 0; return; }
  # 该 IP 上正在监听的端口（ss 的列数在不同版本/过滤器下会变，故自适应取本地地址列）
  ports=$(ss -ltnH 2>/dev/null | awk -v ip="$ip" '{lip=(NF>=5?$4:$3)} index(lip, ip ":")==1 {split(lip,a,":"); print a[2]}' \
          | sort -u | paste -sd'|')
  [[ -z "$ports" ]] && { echo 0; return; }
  ss -Htn state established 2>/dev/null | awk -v ip="$ip" -v p="$ports" '
    { lip = (NF >= 5 ? $4 : $3)
      if (index(lip, ip ":") == 1) { split(lip, a, ":"); if (a[2] ~ ("^(" p ")$")) n++ } }
    END { print n+0 }'
}

cert_probe() { # $1=CertFile $2=CertDomain → 设置 CERT_PATH/CERT_DOMAIN/CERT_END/CERT_DAYS/CERT_SELF
  CERT_PATH=""; CERT_DOMAIN=""; CERT_END=""; CERT_DAYS=""; CERT_SELF="false"
  local f="$1" dom="$2" cand=() d cn iss
  [[ -n "$f" ]] && cand+=("$f")
  if [[ -n "$dom" ]]; then
    for d in "/etc/ssl/${dom}.crt" "/etc/ssl/certs/${dom}.crt" "/etc/V2bX/cert/${dom}.crt" \
             "/etc/V2bX/certs/${dom}.crt" "/etc/V2bX/${dom}.crt" "/root/cert/${dom}.crt" \
             "/etc/letsencrypt/live/${dom}/fullchain.pem" \
             "/root/.acme.sh/${dom}_ecc/fullchain.cer" "/root/.acme.sh/${dom}/fullchain.cer"; do
      cand+=("$d")
    done
  fi
  for f in "${cand[@]}"; do [[ -n "$f" && -f "$f" ]] && { CERT_PATH="$f"; break; }; done
  if [[ -z "$CERT_PATH" && -n "$dom" ]] && command -v openssl >/dev/null; then
    while IFS= read -r f; do
      if openssl x509 -in "$f" -noout -subject -ext subjectAltName 2>/dev/null | grep -qF "$dom"; then
        CERT_PATH="$f"; break
      fi
    done < <(find /etc/ssl /etc/V2bX /root/cert /root/.acme.sh -maxdepth 3 -type f \
               \( -name '*.crt' -o -name '*.pem' -o -name 'fullchain.cer' \) 2>/dev/null | head -40)
  fi
  if [[ -n "$CERT_PATH" ]] && command -v openssl >/dev/null; then
    CERT_END=$(openssl x509 -enddate -noout -in "$CERT_PATH" 2>/dev/null | cut -d= -f2)
    if [[ -n "$CERT_END" ]]; then
      CERT_DAYS=$(( ( $(date -d "$CERT_END" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
      cn=$(openssl x509 -in "$CERT_PATH" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p' | head -1 | tr -d '"')
      iss=$(openssl x509 -in "$CERT_PATH" -noout -issuer 2>/dev/null | sed -n 's/.*CN *= *//p' | head -1 | tr -d '"')
      CERT_DOMAIN="${cn:-$dom}"
      [[ -n "$cn" && "$cn" == "$iss" ]] && CERT_SELF="true"
    fi
  fi
}

apply_node() { # $1=NodeID $2=jq路径 $3=期望值 $4=当前值 —— 只改该 NodeID 的条目
  local nid="$1" path="$2" want="$3" cur="$4"
  [[ -z "$want" || "$want" == "null" || "$want" == "$cur" ]] && return 0
  if jq --argjson nid "$nid" --arg v "$want" "(.Nodes[] | select(.NodeID==\$nid) | $path) = \$v" \
        "$CONFIG_JSON" > "$CONFIG_JSON.tmp" 2>/dev/null; then
    mv -f "$CONFIG_JSON.tmp" "$CONFIG_JSON"
    log "node $nid: $path -> $want"
    CHANGED=1
  else
    rm -f "$CONFIG_JSON.tmp"
    log "node $nid: $path 修改失败（jq 报错）"
  fi
}

############################################
# 实时日志: 服务端订阅期间回传 V2bX 最新日志（近似 tail -f）
############################################
push_logs() { # $1=该节点在云控上的名称
  local name="$1" lines=""
  if command -v journalctl >/dev/null 2>&1; then
    lines=$(journalctl -u V2bX -n 60 --no-pager -o short-iso 2>/dev/null)
    [[ -z "$lines" ]] && lines=$(journalctl -u v2bx -n 60 --no-pager -o short-iso 2>/dev/null)
  fi
  if [[ -z "$lines" ]]; then
    local f
    for f in /var/log/V2bX.log /var/log/v2bx.log /etc/V2bX/V2bX.log; do
      [[ -f "$f" ]] && { lines=$(tail -n 60 "$f" 2>/dev/null); break; }
    done
  fi
  [[ -z "$lines" ]] && lines="(未取到日志：journalctl -u V2bX 与常见日志文件均为空)"
  local payload
  payload=$(printf '%s' "$lines" | jq -R -s --arg name "$name" '{name:$name, lines:(split("\n") | map(select(length>0)))}' 2>/dev/null)
  [[ -n "$payload" ]] && curl $CURL_TLS -sf --max-time 10 -X POST "$CLOUD_URL/api/log_push" \
    -H "X-Token: $CLOUD_TOKEN" -H "Content-Type: application/json" -d "$payload" >/dev/null 2>&1
}

############################################
# 媒体解锁检测: YouTube / ChatGPT / Netflix / Google 拉黑判定（面板按需触发）
#   判据: Google 搜索被 302 到 /sorry/ = IP 被判定异常流量（俗称被谷歌拉黑）
############################################
media_check() { # $1=该节点在云控上的名称
  local name="$1" d trace ip loc yt="" gcode="" gredir="" nfcode="" gptcode="" gptloc="" ms
  ms=$(date +%s%3N 2>/dev/null || echo 0)
  d=$(mktemp -d 2>/dev/null) || return 0
  # 并发探测（每项限时，互不阻塞）
  # YouTube: 带 SOCS=CAI 绕过 consent 页；页面内 "GL":"XX" 即出口区域，另捕获"异常流量/sorry"提示
  ( curl -s --compressed --max-time 10 -H "Cookie: SOCS=CAI" -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0" https://www.youtube.com/premium > "$d/yt" 2>/dev/null ) &
  ( curl -s -o /dev/null -w '%{http_code}' --max-time 6 https://www.google.com/generate_204 > "$d/g" 2>/dev/null ) &
  ( curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 6 "https://www.google.com/search?q=test" > "$d/gb" 2>/dev/null ) &
  # Netflix: 跟随重定向（301 是正常地域跳转），并检查页面是否出现 "Not Available"（该区无此片源）
  ( curl -sL --max-time 10 -o "$d/nfb" -w '%{http_code}' https://www.netflix.com/title/81215567 > "$d/nf" 2>/dev/null ) &
  ( curl -s -o /dev/null -w '%{http_code}' --max-time 8 https://chatgpt.com/ > "$d/gpt" 2>/dev/null ) &
  ( curl -s --max-time 6 https://chatgpt.com/cdn-cgi/trace > "$d/gpttr" 2>/dev/null ) &
  trace=$(curl -s --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  wait
  ip=$(printf '%s' "$trace" | grep -m1 '^ip=' | cut -d= -f2)
  loc=$(printf '%s' "$trace" | grep -m1 '^loc=' | cut -d= -f2)
  yt=$(grep -o '"GL":"[A-Z][A-Z]"' "$d/yt" 2>/dev/null | head -1 | sed 's/.*"GL":"\([A-Z][A-Z]\)".*/\1/')
  local ytbad=false
  grep -qiE 'unusual traffic|sorry/index|detected unusual' "$d/yt" 2>/dev/null && ytbad=true
  gcode=$(cat "$d/g" 2>/dev/null | tr -d '\n')
  read -r gredir_code gredir_url < <(cat "$d/gb" 2>/dev/null)
  nfcode=$(cat "$d/nf" 2>/dev/null | tr -d '\n')
  local nfbad=false
  grep -qi 'not available' "$d/nfb" 2>/dev/null && nfbad=true
  gptcode=$(cat "$d/gpt" 2>/dev/null | tr -d '\n')
  gptloc=$(grep -m1 '^loc=' "$d/gpttr" 2>/dev/null | cut -d= -f2)
  rm -rf "$d"
  local gblocked=false
  printf '%s' "$gredir_url" | grep -q '/sorry/' && gblocked=true
  local payload
  payload=$(jq -n \
    --arg ip "${ip:-}" --arg loc "${loc:-}" \
    --arg yt "${yt:-}" --arg ytb "$ytbad" --arg g "${gcode:-0}" --arg gb "$gblocked" --arg gn "${gredir_code:-0}" \
    --arg nf "${nfcode:-0}" --arg nfb "$nfbad" --arg gpt "${gptcode:-0}" --arg gptloc "${gptloc:-}" \
    --argjson ms "$(( $(date +%s%3N 2>/dev/null || echo 0) - ${ms:-0} ))" \
    '{ip:$ip, loc:$loc, ms:$ms,
      youtube:{region:$yt, ok:($yt != ""), blocked:($ytb == "true")},
      google:{ok:($g == "204"), blocked:($gb == "true"), code:$gn},
      netflix:{ok:($nf == "200" and $nfb != "true"), code:$nf},
      chatgpt:{ok:($gpt == "200"), code:$gpt, loc:$gptloc}}' 2>/dev/null)
  [[ -n "$payload" ]] && curl $CURL_TLS -sf --max-time 10 -X POST "$CLOUD_URL/api/media_push" \
    -H "X-Token: $CLOUD_TOKEN" -H "Content-Type: application/json" \
    -d "$(printf '%s' "$payload" | jq -c --arg name "$name" '. + {name:$name}')" >/dev/null 2>&1
}

############################################
# 逐节点: 心跳 + 按 NodeID 应用期望配置
############################################
cp -f "$CONFIG_JSON" "$CONFIG_JSON.bak.cloud" 2>/dev/null || true
CHANGED=0; HB_OK=0
DO_RESTART=0; DO_UPDATE=0; DO_UPDATE_VER=""; DO_AGENT_UPDATE=0
WANT_WARP_I=""

for ((i=0; i<NODE_CNT; i++)); do
  if [[ "$NO_CFG" == "1" ]]; then
    NID=""; CUR_HOST=""; CUR_KEY=""; LIP=""; C_FILE=""; C_DOM=""; N_TYPE=""
  else
    NID=$(jq -r ".Nodes[$i].NodeID // empty" "$CONFIG_JSON" 2>/dev/null)
    [[ -z "$NID" || "$NID" == "null" ]] && continue
    CUR_HOST=$(jq -r ".Nodes[$i].ApiHost // empty" "$CONFIG_JSON" 2>/dev/null)
    CUR_KEY=$(jq -r ".Nodes[$i].ApiKey // empty" "$CONFIG_JSON" 2>/dev/null)
    LIP=$(jq -r ".Nodes[$i].ListenIP // empty" "$CONFIG_JSON" 2>/dev/null)
    C_FILE=$(jq -r ".Nodes[$i].CertConfig.CertFile // empty" "$CONFIG_JSON" 2>/dev/null)
    C_DOM=$(jq -r ".Nodes[$i].CertConfig.CertDomain // empty" "$CONFIG_JSON" 2>/dev/null)
    N_TYPE=$(jq -r ".Nodes[$i].NodeType // empty" "$CONFIG_JSON" 2>/dev/null)
  fi
  if [[ "$NO_CFG" == "1" ]]; then NAME_I="$BASE_NAME"; else NAME_I=$(node_name "$NID"); fi
  CONNS_I=$(node_conns "$LIP")
  cert_probe "$C_FILE" "$C_DOM"

  # 该节点上一次重命名的确认（一次性上报，服务端据此迁移该节点记录）
  MARK="/tmp/.v2bx-cloud-rename-applied-${NID:-nocfg}"
  APPLIED_RENAME=""
  [[ -f "$MARK" ]] && APPLIED_RENAME=$(head -1 "$MARK" 2>/dev/null)

  PAYLOAD=$(jq -n \
    --arg name "$NAME_I" --arg hostname "$HOSTNAME" --arg version "$VERSION" \
    --argjson rss "${RSS_MB:-0}" --argjson conns "${CONNS_I:-0}" --argjson uptime "${SERVICE_UPTIME:-0}" \
    --arg warp "$WARP" --arg svc "$SVC" --arg load "$LOAD" --arg ack "$ACK" \
    --arg agentVer "$AGENT_VER" --argjson certDays "${CERT_DAYS:-null}" \
    --arg cPath "$CERT_PATH" --arg cDomain "$CERT_DOMAIN" --arg cEnd "$CERT_END" \
    --argjson cDays "${CERT_DAYS:-null}" --argjson cSelf "${CERT_SELF:-false}" \
    --arg appliedRename "$APPLIED_RENAME" --argjson nodeCount "$NODE_CNT" --argjson nodeId "${NID:-0}" \
    --arg apiHost "$CUR_HOST" --arg apiKey "$CUR_KEY" --arg certDomain "$C_DOM" --arg cName "$NAME_I" \
    --arg nodeType "$N_TYPE" \
    '{name:$name, hostname:$hostname, version:$version, rss_mb:$rss, conns:$conns, uptime_sec:$uptime,
      warp:$warp, svc:$svc, load:$load, ack:$ack, agentVer:$agentVer, certDays:$certDays,
      cert:{path:$cPath, domain:$cDomain, end:$cEnd, days:$cDays, selfSigned:$cSelf},
      appliedRename:$appliedRename, nodeCount:$nodeCount, nodeId:$nodeId,
      cfg:{ApiHost:$apiHost, ApiKey:$apiKey, NodeID:$nodeId, CertDomain:$certDomain, Name:$cName, NodeType:$nodeType}}' 2>/dev/null)
  if [[ -z "$PAYLOAD" ]]; then log "node $NID: payload 构建失败"; continue; fi

  RESP=$(curl $CURL_TLS -sf --max-time 15 -X POST "$CLOUD_URL/api/heartbeat" \
    -H "X-Token: $CLOUD_TOKEN" -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>/dev/null)
  if [[ -z "$RESP" ]]; then log "node $NID: heartbeat failed"; continue; fi
  HB_OK=1
  rm -f "$MARK"   # 重命名确认已上报

  # ---- 期望配置（只作用于本 NodeID；服务未就绪模式跳过） ----
  if [[ -n "$NID" ]]; then
  apply_node "$NID" ".ApiHost" "$(jq -r '.desired.ApiHost // empty' <<<"$RESP" 2>/dev/null)" "$CUR_HOST"
  apply_node "$NID" ".ApiKey"  "$(jq -r '.desired.ApiKey // empty'  <<<"$RESP" 2>/dev/null)" "$CUR_KEY"

  WANT_DOM=$(jq -r '.desired.CertDomain // empty' <<<"$RESP" 2>/dev/null)
  # 安全: 只接受标准域名，避免值进入 openssl/路径/sed 流程时被注入
  if [[ -n "$WANT_DOM" && ! "$WANT_DOM" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    log "node $NID: CertDomain 含非法字符，已忽略: $WANT_DOM"
    WANT_DOM=""
  fi
  if [[ -n "$WANT_DOM" && "$WANT_DOM" != "$C_DOM" ]]; then
    if [[ ! -f "/etc/ssl/${WANT_DOM}.crt" || ! -f "/etc/ssl/${WANT_DOM}.key" ]]; then
      mkdir -p /etc/ssl
      if openssl req -x509 -nodes -newkey rsa:2048 \
           -keyout "/etc/ssl/${WANT_DOM}.key" -out "/etc/ssl/${WANT_DOM}.crt" \
           -subj "/CN=${WANT_DOM}" -days 3650 2>/dev/null; then
        log "node $NID: CertDomain=${WANT_DOM} 无证书，已生成自签兜底"
        jq --argjson nid "$NID" --arg v "/etc/ssl/${WANT_DOM}.crt" \
          '(.Nodes[]|select(.NodeID==$nid)|.CertConfig.CertFile)=$v' "$CONFIG_JSON" > "$CONFIG_JSON.tmp" 2>/dev/null \
          && mv -f "$CONFIG_JSON.tmp" "$CONFIG_JSON"
        jq --argjson nid "$NID" --arg v "/etc/ssl/${WANT_DOM}.key" \
          '(.Nodes[]|select(.NodeID==$nid)|.CertConfig.KeyFile)=$v' "$CONFIG_JSON" > "$CONFIG_JSON.tmp" 2>/dev/null \
          && mv -f "$CONFIG_JSON.tmp" "$CONFIG_JSON"
      fi
    fi
    apply_node "$NID" ".CertConfig.CertDomain" "$WANT_DOM" "$C_DOM"
  fi

  WANT_ID=$(jq -r '.desired.NodeID // empty' <<<"$RESP" 2>/dev/null)
  if [[ -n "$WANT_ID" && "$WANT_ID" =~ ^[0-9]+$ && "$WANT_ID" != "$NID" ]]; then
    if jq --argjson nid "$NID" --argjson v "$WANT_ID" '(.Nodes[]|select(.NodeID==$nid)|.NodeID)=$v' \
         "$CONFIG_JSON" > "$CONFIG_JSON.tmp" 2>/dev/null; then
      mv -f "$CONFIG_JSON.tmp" "$CONFIG_JSON"
      log "node $NID: NodeID -> $WANT_ID（身份将随之变化）"
      CHANGED=1
    fi
  fi

  # 节点类型（白名单，防止写坏核心选择）
  WANT_TYPE=$(jq -r '.desired.NodeType // empty' <<<"$RESP" 2>/dev/null)
  if [[ -n "$WANT_TYPE" && "$WANT_TYPE" != "$N_TYPE" ]]; then
    case "$WANT_TYPE" in
      anytls|vless|vmess|trojan|shadowsocks|hysteria|hysteria2|tuic)
        apply_node "$NID" ".NodeType" "$WANT_TYPE" "$N_TYPE" ;;
      *) log "node $NID: NodeType 非法，已忽略: $WANT_TYPE" ;;
    esac
  fi

  # WARP（全局，取本机任一节点下发的值）
  W=$(jq -r '.desired.Warp // empty' <<<"$RESP" 2>/dev/null)
  [[ -n "$W" && "$W" != "null" ]] && WANT_WARP_I="$W"

  # ---- 重命名（按 NodeID 记入 cloud.conf，下次心跳生效） ----
  WANT_NAME=$(jq -r '.desiredName // empty' <<<"$RESP" 2>/dev/null)
  if [[ -n "$WANT_NAME" && "$WANT_NAME" != "$NAME_I" ]]; then
    # 安全: 该名称会写入 cloud.conf（sed/echo），先挡掉 shell 元字符与换行
    case "$WANT_NAME" in
      *'"'*|*"'"*|*'`'*|*'$'*|*';'*|*'&'*|*'('*|*')'*|*'<'*|*'>'*|*'\'*|*'|'*|*$'\n'*|*$'\r'*)
        log "node $NID: 名称含 shell 元字符，已拒绝: $WANT_NAME"
        WANT_NAME="" ;;
    esac
  fi
  if [[ -n "$WANT_NAME" && "$WANT_NAME" != "$NAME_I" ]]; then
    # 注意: ${#VAR} 在 C locale 下按字节计数，中文名会被误判超长；这里只做粗暴上限保护
    # （真正的 1-64 字符校验由服务端按字符数执行）
    if [[ ${#WANT_NAME} -gt 255 ]]; then
      log "node $NID: 名称超长，跳过"
    else
      if grep -q "^NAME_${NID}=" "$CONF" 2>/dev/null; then
        sed -i "s|^NAME_${NID}=.*|NAME_${NID}=\"${WANT_NAME}\"|" "$CONF"
      else
        echo "NAME_${NID}=\"${WANT_NAME}\"" >> "$CONF"
      fi
      echo "rename:${NAME_I}" > "$MARK"
      log "node $NID: rename ${NAME_I} -> ${WANT_NAME}（下次心跳确认迁移）"
    fi
  fi

  fi # 期望配置与重命名（需 NodeID）

  # ---- 动作与自更新（循环结束后统一执行一次） ----
  ACT=$(jq -r '.action // "none"' <<<"$RESP" 2>/dev/null)
  [[ "$ACT" == "restart" ]] && DO_RESTART=1
  if [[ "$ACT" == "update" ]]; then
    DO_UPDATE=1
    DO_UPDATE_VER=$(jq -r '.version // empty' <<<"$RESP" 2>/dev/null)
    # 安全: 版本号会作为参数传给 v2bx update，只接受 vX.Y.Z 形式
    if [[ -n "$DO_UPDATE_VER" && ! "$DO_UPDATE_VER" =~ ^v[0-9][A-Za-z0-9._-]*$ ]]; then
      log "node $NID: 版本号非法，回退为最新版: $DO_UPDATE_VER"
      DO_UPDATE_VER=""
    fi
  fi
  [[ "$(jq -r '.agentUpdate // "0"' <<<"$RESP" 2>/dev/null)" == "1" ]] && DO_AGENT_UPDATE=1

  # ---- 实时日志: 服务端订阅期间回传 journalctl 最新输出 ----
  [[ "$(jq -r '.log // empty' <<<"$RESP" 2>/dev/null)" == "1" ]] && push_logs "$NAME_I"
  # ---- 媒体检测: 面板按需触发（结果回传后由服务端清除标记） ----
  [[ "$(jq -r '.media // empty' <<<"$RESP" 2>/dev/null)" == "1" ]] && media_check "$NAME_I"
done

if [[ "$HB_OK" != "1" ]]; then log "全部节点心跳失败（共 $NODE_CNT 个），跳过后续处理"; exit 0; fi

############################################
# WARP 开关（全局）
############################################
if [[ -n "$WANT_WARP_I" && "$WANT_WARP_I" != "$WARP" ]]; then
  if [[ ! -f /etc/V2bX/sing_origin_warp.json ]]; then
    log "WARP 模板不存在(旧安装)，跳过 Warp=$WANT_WARP_I"
  elif [[ "$WANT_WARP_I" == "on" ]]; then
    cp -f /etc/V2bX/sing_origin_warp.json /etc/V2bX/sing_origin.json; CHANGED=1; log "applied Warp -> on"
  elif [[ "$WANT_WARP_I" == "off" ]]; then
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
# JSON 校验：改坏了自动回滚，绝不带病重启
############################################
if [[ "$CHANGED" == "1" ]] && ! jq empty "$CONFIG_JSON" 2>/dev/null; then
  cp -f "$CONFIG_JSON.bak.cloud" "$CONFIG_JSON"
  CHANGED=0
  log "config.json 校验失败，已回滚到修改前备份"
fi

############################################
# 一次性动作（多节点机器上为整服务动作，影响该机全部 $NODE_CNT 个节点）
############################################
if [[ "$DO_UPDATE" == "1" ]]; then
  if [[ -n "$DO_UPDATE_VER" && "$DO_UPDATE_VER" != "null" ]]; then
    log "action: self-update (pinned $DO_UPDATE_VER, nodes=$NODE_CNT)"
    nohup v2bx update "$DO_UPDATE_VER" >> /var/log/v2bx-cloud-update.log 2>&1 &
  else
    log "action: self-update (latest, nodes=$NODE_CNT)"
    nohup bash <(curl -fsSL https://raw.githubusercontent.com/4kercc/V2BX-malio/main/update-v2bx.sh) >> /var/log/v2bx-cloud-update.log 2>&1 &
  fi
  echo "update $(date +%s)" > /tmp/.v2bx-cloud-ack
  exit 0
fi
if [[ "$DO_RESTART" == "1" ]]; then
  systemctl restart V2bX && { log "action: restarted (nodes=$NODE_CNT)"; echo "restart $(date +%s)" > /tmp/.v2bx-cloud-ack; }
  exit 0
fi
if [[ "$DO_AGENT_UPDATE" == "1" ]]; then
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
  systemctl restart V2bX && log "config changed, V2bX restarted (nodes=$NODE_CNT)"
else
  log "heartbeat ok (nodes=$NODE_CNT, no change)"
fi
