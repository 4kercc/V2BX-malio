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
AGENT_VER="25"
# 媒体探测逻辑版本：改了探测方式（如绑定出口 IP、地址族策略）就 +1，
# 服务端 MEDIA_PV 同步提升后会让全队旧结果立即失效并自动重测（不用等 12 小时）
MEDIA_PV="1"

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

# 本机真实地址列表（媒体探测绑定前校验，避免绑到不存在的地址；无 ip 命令则跳过校验）
LOCAL_IPS=$(ip -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

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
# Google/YouTube 强制 IPv4 出站（整机改动）
#   背景: 部分机房 IPv6 直连出口被 Google 判定异常流量（搜索 302 跳 /sorry/）
#   做法: 在 sing-box 基础配置里插入专用直连出站 v4-google（DNS 策略 ipv4_only），
#         并把 Google/YouTube 域名路由到它；规则插在最前，优先于兜底与 WARP 规则
#   范围: sing_origin.json 为该机全部节点共用 → 整机生效；改完需重启 V2bX
############################################
G4_TAG="v4-google"
G4_KEYWORDS='["google","googlevideo","youtube","ytimg","ggpht","gstatic","googleapis","googleusercontent","withgoogle"]'
g4_state() { # 输出 on / off / na（na = 该机没有 sing_origin.json，无法应用）
  local f="/etc/V2bX/sing_origin.json"
  [[ -f "$f" ]] || { echo na; return; }
  grep -q "\"$G4_TAG\"" "$f" 2>/dev/null && echo on || echo off
}
eff_family() { # 没有同进同出绑定时，按 sing-box 解析策略推断出口地址族: v4 / v6 / auto
  local strat
  strat=$(jq -r '.dns.strategy // ""' /etc/V2bX/sing_origin.json 2>/dev/null)
  case "$strat" in
    ipv4_only|prefer_ipv4) echo v4 ;;
    ipv6_only|prefer_ipv6) echo v6 ;;
    *) echo auto ;;
  esac
}
apply_googlev4() { # $1=on|off（空或 null = 不下发）
  local want="$1" f cur ok=1
  [[ -z "$want" || "$want" == "null" || "$want" == "na" ]] && return 0
  [[ -f /etc/V2bX/sing_origin.json ]] || { log "GoogleV4=$want: 未找到 sing_origin.json(未安装 V2bX)，跳过"; return 0; }
  cur=$(g4_state)
  [[ "$want" == "$cur" ]] && return 0
  G4_FILES=(/etc/V2bX/sing_origin.json)
  [[ -f /etc/V2bX/sing_origin_direct.json ]] && G4_FILES+=(/etc/V2bX/sing_origin_direct.json)
  [[ -f /etc/V2bX/sing_origin_warp.json ]] && G4_FILES+=(/etc/V2bX/sing_origin_warp.json)
  for f in "${G4_FILES[@]}"; do
    [[ -f "$f" ]] || continue
    # 只在首次应用前备份：保留真正的原始值，供 dns.strategy 精确回退与失败回滚
    [[ -f "${f}.bak.cloud" ]] || cp -f "$f" "${f}.bak.cloud" 2>/dev/null
    if [[ "$want" == "on" ]]; then
      # 出站: 复制现有 direct 出站的 domain_resolver 并把策略改为 ipv4_only
      #（没有 domain_resolver 就退回第一个 DNS 服务器；再没有则用 domain_strategy 兜底）
      # 另外把 dns.strategy 置为 prefer_ipv4 —— 同进同出的 node_N_out 没有独立解析器，
      # 走的就是它，这才能让 Google/YouTube 真正落到 v4
      jq --arg tag "$G4_TAG" --argjson kw "$G4_KEYWORDS" '
        (.outbounds // []) as $o
        | ([ $o[] | select(.tag == "direct") | .domain_resolver | select(. != null) ] | first) as $dr
        | ([ (.dns.servers // [])[] | .tag | select(. != null and . != "") ] | first) as $srv
        | ( if $dr != null then ($dr + { strategy: "ipv4_only" })
            elif $srv != null then { server: $srv, strategy: "ipv4_only" }
            else null end ) as $newdr
        | .outbounds = ( ($o | map(select(.tag != $tag)))
            + [ ({ tag: $tag, type: "direct" }
                + ( if $newdr != null then { domain_resolver: $newdr } else { domain_strategy: "ipv4_only" } end )) ] )
        | .route.rules = ( [ { domain_keyword: $kw, outbound: $tag } ]
            + (( .route.rules // [] ) | map(select((.outbound // "") != $tag))) )
        | ( if .dns then .dns.strategy = "prefer_ipv4" else . end )
      ' "$f" > "$f.tmp" 2>/dev/null && jq empty "$f.tmp" 2>/dev/null \
        && mv -f "$f.tmp" "$f" || { rm -f "$f.tmp"; ok=0; }
    else
      # 去掉出站与规则，并把 dns.strategy 恢复为首次应用前的原值（原来没有该键则删掉）
      # 另外：原本没有 route / route.rules 的文件，去掉后不留空的 [] 结构（保证逐字节还原）
      local orig_strat has_route has_rules
      orig_strat=$(jq -r 'if .dns and (.dns.strategy != null) then (.dns.strategy|tostring) else "__NONE__" end' "${f}.bak.cloud" 2>/dev/null)
      [[ -z "$orig_strat" ]] && orig_strat="__NONE__"
      has_route=$(jq -r 'if .route != null then "true" else "false" end' "${f}.bak.cloud" 2>/dev/null)
      has_rules=$(jq -r 'if .route.rules != null then "true" else "false" end' "${f}.bak.cloud" 2>/dev/null)
      [[ "$has_route" == "true" ]] || has_route="false"
      [[ "$has_rules" == "true" ]] || has_rules="false"
      jq --arg tag "$G4_TAG" --arg os "$orig_strat" --argjson hr "$has_route" --argjson hs "$has_rules" '
        (if .outbounds then .outbounds |= map(select(.tag != $tag)) else . end)
        | (if .route.rules then .route.rules |= map(select((.outbound // "") != $tag)) else . end)
        | (if (.route.rules // null) == [] and ($hs|not) then del(.route.rules) else . end)
        | (if (.route // null) == {} and ($hr|not) then del(.route) else . end)
        | (if .dns then (if $os == "__NONE__" then del(.dns.strategy) else .dns.strategy = $os end) else . end)
      ' "$f" > "$f.tmp" 2>/dev/null && jq empty "$f.tmp" 2>/dev/null \
        && mv -f "$f.tmp" "$f" || { rm -f "$f.tmp"; ok=0; }
    fi
  done
  # 同进同出绑定为 v6 的节点: 每节点规则会抢先把流量绑到 v6 出口，本文件的 v4 路由无法覆盖
  if [[ "$want" == "on" ]]; then
    local v6n
    v6n=$(jq -r '[.Nodes[]? | select((.SendIP // "") | test(":"))] | length' "$CONFIG_JSON" 2>/dev/null)
    [[ -n "$v6n" && "$v6n" != "0" ]] && log "提示: 本机 $v6n 个节点 SendIP 为 IPv6（同进同出强制 v6 出口），GoogleV4 对这些节点不生效，需把 SendIP 改成 v4"
  fi
  if [[ "$ok" == "1" ]]; then
    G4_APPLIED=1; CHANGED=1
    log "applied GoogleV4 -> $want (files=${#G4_FILES[@]})"
  else
    log "GoogleV4=$want 应用失败(jq)，已回滚本次改动"
    for f in "${G4_FILES[@]}"; do [[ -f "${f}.bak.cloud" ]] && cp -f "${f}.bak.cloud" "$f"; done
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
#   出口归属: 多 IP 机器上 V2bX 给每个节点生成 node_N_out 并 bind SendIP（同进同出），
#             所以按 $2 指定的节点自身出口 IP 探测（--interface），每个节点各测各的 IP；
#             单机/无绑定则用本机默认路径（此时若开了 GoogleV4 则用 -4）
############################################
media_check() { # $1=该节点在云控上的名称 $2=(可选)该节点出口 IP（SendIP）
  local name="$1" bind="${2:-}" d trace ip loc yt="" gcode="" gredir="" nfcode="" gptcode="" gptloc="" ms
  local IF="" MF=""
  # 探测必须与"该节点用户实际出口"同源:
  #   有同进同出绑定 → 绑到该节点自己的 IP，地址族由该 IP 决定（v4 IP 即强制 v4 出口）
  #   无绑定         → 按 sing-box 的解析策略（dns.strategy）选地址族
  if [[ -n "$bind" ]]; then
    IF="--interface $bind"
    if [[ "$bind" == *:* ]]; then MF="-6"; else MF="-4"; fi
  else
    case "$(eff_family)" in
      v4) MF="-4" ;;
      v6) MF="-6" ;;
      *)  MF="" ;;
    esac
  fi
  ms=$(date +%s%3N 2>/dev/null || echo 0)
  d=$(mktemp -d 2>/dev/null) || return 0
  # 并发探测（每项限时，互不阻塞）；结果写入外层变量，便于失败后改参数重跑一次
  probe() {
    yt=""; gcode=""; gredir=""; nfcode=""; gptcode=""; gptloc=""; trace=""
    # YouTube: 带 SOCS=CAI 绕过 consent 页；页面内 "GL":"XX" 即出口区域，另捕获"异常流量/sorry"提示
    ( curl $IF $MF -s --compressed --max-time 10 -H "Cookie: SOCS=CAI" -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0" https://www.youtube.com/premium > "$d/yt" 2>/dev/null ) &
    ( curl $IF $MF -s -o /dev/null -w '%{http_code}' --max-time 6 https://www.google.com/generate_204 > "$d/g" 2>/dev/null ) &
    ( curl $IF $MF -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 6 "https://www.google.com/search?q=test" > "$d/gb" 2>/dev/null ) &
    # Netflix: 跟随重定向（301 是正常地域跳转），并检查页面是否出现 "Not Available"（该区无此片源）
    ( curl $IF $MF -sL --max-time 10 -o "$d/nfb" -w '%{http_code}' https://www.netflix.com/title/81215567 > "$d/nf" 2>/dev/null ) &
    ( curl $IF $MF -s -o /dev/null -w '%{http_code}' --max-time 8 https://chatgpt.com/ > "$d/gpt" 2>/dev/null ) &
    ( curl $IF -s --max-time 6 https://chatgpt.com/cdn-cgi/trace > "$d/gpttr" 2>/dev/null ) &
    trace=$(curl $IF $MF -s --max-time 6 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    wait
    ip=$(printf '%s' "$trace" | grep -m1 '^ip=' | cut -d= -f2)
    loc=$(printf '%s' "$trace" | grep -m1 '^loc=' | cut -d= -f2)
    yt=$(grep -o '"GL":"[A-Z][A-Z]"' "$d/yt" 2>/dev/null | head -1 | sed 's/.*"GL":"\([A-Z][A-Z]\)".*/\1/')
    gcode=$(cat "$d/g" 2>/dev/null | tr -d '\n')
    read -r gredir_code gredir_url < <(cat "$d/gb" 2>/dev/null)
    nfcode=$(cat "$d/nf" 2>/dev/null | tr -d '\n')
    gptcode=$(cat "$d/gpt" 2>/dev/null | tr -d '\n')
    gptloc=$(grep -m1 '^loc=' "$d/gpttr" 2>/dev/null | cut -d= -f2)
  }
  probe
  if [[ -n "$IF" && -z "$ip" ]]; then
    # 绑定地址探测不出来（地址失效/被回收等）→ 回退默认路径重跑一次，保证检测仍能出结果
    log "media($name): 绑定出口 $bind 探测失败，回退默认路径重试"
    IF=""; probe
  fi
  local ytbad=false nfbad=false
  grep -qiE 'unusual traffic|sorry/index|detected unusual' "$d/yt" 2>/dev/null && ytbad=true
  grep -qi 'not available' "$d/nfb" 2>/dev/null && nfbad=true
  rm -rf "$d"
  local gblocked=false
  printf '%s' "$gredir_url" | grep -q '/sorry/' && gblocked=true
  [[ -z "$ip" ]] && log "media($name): 未取到出口 IP（bind=${bind:-无}）"
  local payload
  payload=$(jq -n \
    --arg ip "${ip:-}" --arg loc "${loc:-}" --arg src "${bind:-}" --argjson pv "${MEDIA_PV:-1}" \
    --arg yt "${yt:-}" --arg ytb "$ytbad" --arg g "${gcode:-0}" --arg gb "$gblocked" --arg gn "${gredir_code:-0}" \
    --arg nf "${nfcode:-0}" --arg nfb "$nfbad" --arg gpt "${gptcode:-0}" --arg gptloc "${gptloc:-}" \
    --argjson ms "$(( $(date +%s%3N 2>/dev/null || echo 0) - ${ms:-0} ))" \
    '{ip:$ip, loc:$loc, src:$src, pv:$pv, ms:$ms,
      youtube:{region:$yt, ok:($yt != ""), blocked:($ytb == "true")},
      google:{ok:(($g == "204") or ($gn == "200" and $gb != "true")), blocked:($gb == "true"), code:$g, search:$gn},
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
WANT_G4_I=""
MEDIA_NAMES=()
G4_APPLIED=0
G4_FILES=()

for ((i=0; i<NODE_CNT; i++)); do
  if [[ "$NO_CFG" == "1" ]]; then
    NID=""; CUR_HOST=""; CUR_KEY=""; LIP=""; C_FILE=""; C_DOM=""; N_TYPE=""; SEND_IP=""
  else
    NID=$(jq -r ".Nodes[$i].NodeID // empty" "$CONFIG_JSON" 2>/dev/null)
    [[ -z "$NID" || "$NID" == "null" ]] && continue
    CUR_HOST=$(jq -r ".Nodes[$i].ApiHost // empty" "$CONFIG_JSON" 2>/dev/null)
    CUR_KEY=$(jq -r ".Nodes[$i].ApiKey // empty" "$CONFIG_JSON" 2>/dev/null)
    LIP=$(jq -r ".Nodes[$i].ListenIP // empty" "$CONFIG_JSON" 2>/dev/null)
    SEND_IP=$(jq -r ".Nodes[$i].SendIP // empty" "$CONFIG_JSON" 2>/dev/null)
    C_FILE=$(jq -r ".Nodes[$i].CertConfig.CertFile // empty" "$CONFIG_JSON" 2>/dev/null)
    C_DOM=$(jq -r ".Nodes[$i].CertConfig.CertDomain // empty" "$CONFIG_JSON" 2>/dev/null)
    N_TYPE=$(jq -r ".Nodes[$i].NodeType // empty" "$CONFIG_JSON" 2>/dev/null)
  fi
  if [[ "$NO_CFG" == "1" ]]; then NAME_I="$BASE_NAME"; else NAME_I=$(node_name "$NID"); fi
  CONNS_I=$(node_conns "$LIP")
  cert_probe "$C_FILE" "$C_DOM"

  # 该节点的真实出口 IP（媒体探测要绑到它，才等于用户实际走的 IP）:
  # 取 SendIP —— 这正是 V2bX 同进同出给 node_N_out 绑定的地址；没有 SendIP 就说明
  # V2bX 不绑定（用户走内核默认出口 = 本机默认路径，探测不绑即为一致）；必须是本机真实地址
  PEIP=""
  for cand in "${SEND_IP:-}"; do
    [[ -z "$cand" || "$cand" == "0.0.0.0" || "$cand" == "::" ]] && continue
    [[ "$cand" =~ ^[0-9a-fA-F:.]{3,45}$ ]] || continue
    if [[ -n "$LOCAL_IPS" ]] && ! printf '%s\n' "$LOCAL_IPS" | grep -qxF "$cand"; then continue; fi
    PEIP="$cand"
  done

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
    --arg nodeType "$N_TYPE" --arg googleV4 "$(g4_state)" \
    '{name:$name, hostname:$hostname, version:$version, rss_mb:$rss, conns:$conns, uptime_sec:$uptime,
      warp:$warp, svc:$svc, load:$load, ack:$ack, agentVer:$agentVer, certDays:$certDays,
      cert:{path:$cPath, domain:$cDomain, end:$cEnd, days:$cDays, selfSigned:$cSelf},
      appliedRename:$appliedRename, nodeCount:$nodeCount, nodeId:$nodeId,
      cfg:{ApiHost:$apiHost, ApiKey:$apiKey, NodeID:$nodeId, CertDomain:$certDomain, Name:$cName, NodeType:$nodeType, GoogleV4:$googleV4}}' 2>/dev/null)
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

  # Google/YouTube 强制 IPv4（全局，取本机任一节点下发的值）
  G=$(jq -r '.desired.GoogleV4 // empty' <<<"$RESP" 2>/dev/null)
  [[ -n "$G" && "$G" != "null" ]] && WANT_G4_I="$G"

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
  # ---- 媒体检测: 面板按需触发（结果回传后由服务端清除标记）
  # 推迟到配置应用之后执行，使探测的地址族与本轮新下发的 GoogleV4 策略一致；带上该节点出口 IP 做绑定
  [[ "$(jq -r '.media // empty' <<<"$RESP" 2>/dev/null)" == "1" ]] && MEDIA_NAMES+=("${NAME_I}|${PEIP}")
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
# Google/YouTube 强制 IPv4（整机，跟在 WARP 模板切换之后应用，避免被模板覆盖）
############################################
apply_googlev4 "$WANT_G4_I"

############################################
# 媒体检测回传（推迟到配置应用之后，使探测地址族与本轮新策略一致）
############################################
if [[ ${#MEDIA_NAMES[@]} -gt 0 ]]; then
  for NAME_M in "${MEDIA_NAMES[@]}"; do media_check "${NAME_M%%|*}" "${NAME_M#*|}"; done
fi

############################################
# JSON 校验：改坏了自动回滚，绝不带病重启
############################################
if [[ "$CHANGED" == "1" ]] && ! jq empty "$CONFIG_JSON" 2>/dev/null; then
  cp -f "$CONFIG_JSON.bak.cloud" "$CONFIG_JSON"
  CHANGED=0
  log "config.json 校验失败，已回滚到修改前备份"
fi
if [[ "$G4_APPLIED" == "1" ]] && ! jq empty /etc/V2bX/sing_origin.json 2>/dev/null; then
  for f in "${G4_FILES[@]}"; do [[ -f "${f}.bak.cloud" ]] && cp -f "${f}.bak.cloud" "$f"; done
  G4_APPLIED=0; CHANGED=0
  log "sing_origin.json 校验失败，已回滚 GoogleV4 改动"
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

# 配置变更重启（放在 agent 自更新之前：自更新会 exit，曾导致本轮配置改动悬空不生效）
if [[ "$CHANGED" == "1" ]]; then
  if systemctl restart V2bX 2>/dev/null; then
    sleep 2
    # GoogleV4 改了 sing-box 基础配置：起不来就回滚并再重启（绝不留下起不来的节点）
    if [[ "$G4_APPLIED" == "1" ]] && ! systemctl is-active V2bX >/dev/null 2>&1; then
      log "V2bX 重启后未运行，回滚 GoogleV4 改动并再次重启"
      for f in "${G4_FILES[@]}"; do [[ -f "${f}.bak.cloud" ]] && cp -f "${f}.bak.cloud" "$f"; done
      systemctl restart V2bX 2>/dev/null
      echo "googlev4-rollback $(date +%s)" > /tmp/.v2bx-cloud-ack
    else
      log "config changed, V2bX restarted (nodes=$NODE_CNT)"
    fi
  else
    log "config changed, 但 restart 命令失败（服务单元缺失？）"
  fi
else
  log "heartbeat ok (nodes=$NODE_CNT, no change)"
fi

############################################
# agent 自更新（放最后：不阻断本轮配置变更；只在下载版本更新时覆盖，防 CDN 缓存旧版导致降级/空转）
############################################
if [[ "$DO_AGENT_UPDATE" == "1" ]]; then
  log "agent: self-update to server version"
  curl $CURL_TLS -fsSL -o /usr/local/V2bX/cloud-agent.sh.new \
    "https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-agent.sh" 2>/dev/null
  NEWVER=$(grep -m1 -oP '^AGENT_VER="\K[0-9]+' /usr/local/V2bX/cloud-agent.sh.new 2>/dev/null)
  if [[ -s /usr/local/V2bX/cloud-agent.sh.new ]] \
     && bash -n /usr/local/V2bX/cloud-agent.sh.new 2>/dev/null \
     && [[ -n "$NEWVER" ]] && [[ "$NEWVER" -gt "$AGENT_VER" ]]; then
    mv -f /usr/local/V2bX/cloud-agent.sh.new /usr/local/V2bX/cloud-agent.sh
    chmod +x /usr/local/V2bX/cloud-agent.sh
    log "agent: self-update applied (v$AGENT_VER -> v$NEWVER)"
  else
    rm -f /usr/local/V2bX/cloud-agent.sh.new
    log "agent: self-update skipped（下载版本 v${NEWVER:-未知} 未高于当前 v$AGENT_VER，疑似 CDN 缓存旧版）"
  fi
  exit 0
fi
