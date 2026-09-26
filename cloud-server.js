#!/usr/bin/env node
/**
 * V2BX-malio 云控中心（零依赖，单文件）
 * 运行：node cloud-server.js   （数据存放在同目录 cloud-data.json）
 * 端口：环境变量 PORT，默认 8765
 *
 * 安全模型（v2）：
 *  - 双 Token：token=管理端专用，nodeToken=节点心跳专用（节点失陷不等于全群失陷）
 *  - 心跳与失败认证均有 IP 级限速
 *  - Token 常量时间比较
 *  - 默认 Token 启动门禁：未改 Token 前拒绝服务（ALLOW_INSECURE_TOKEN=1 可临时绕过）
 *  - 升级动作支持版本锁定（updateVersion，留空 = 最新 Release）
 *  - 仍需自行用 Nginx/Caddy 反代启用 HTTPS 后再暴露公网
 */
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = parseInt(process.env.PORT || '8765', 10);
const DATA_FILE = path.join(__dirname, 'cloud-data.json');
const DEFAULT_ADMIN = 'changeme-token';
const DEFAULT_NODE = 'changeme-node-token';
const ALLOW_INSECURE = process.env.ALLOW_INSECURE_TOKEN === '1';

// ---------- Web 后台（单页） ----------
const UI = `<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><title>V2bX 云控中心</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body{font-family:system-ui,Arial;background:#0f172a;color:#e5e7eb;margin:0;padding:20px}
h1{font-size:20px}.muted{color:#94a3b8;font-size:12px}
table{width:100%;border-collapse:collapse;background:#111827;border-radius:8px;overflow:hidden}
th,td{padding:8px 10px;border-bottom:1px solid #1f2937;text-align:left;font-size:13px}
th{background:#1e293b;color:#93c5fd}
.on{color:#34d399;font-weight:bold}.off{color:#f87171;font-weight:bold}
.bar{background:#111827;padding:12px;border-radius:8px;margin:12px 0}
input,select{background:#0b1220;color:#e5e7eb;border:1px solid #334155;border-radius:6px;padding:6px 8px;margin:2px 4px 2px 0;width:210px}
button{background:#2563eb;color:#fff;border:0;border-radius:6px;padding:7px 14px;margin:4px 4px 4px 0;cursor:pointer}
button.warn{background:#dc2626}button.ok{background:#059669}button.gray{background:#475569}
#msg{margin:8px 0;color:#fbbf24;min-height:18px;font-size:13px}
.small{font-size:11px;color:#94a3b8}
#nodeToken{width:280px}
.modal{display:none;position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:99;align-items:center;justify-content:center}
.modal.show{display:flex}
.modal-box{background:#111827;border:1px solid #334155;border-radius:12px;padding:24px 28px;max-width:520px;width:90%;box-shadow:0 10px 40px rgba(0,0,0,.5)}
.modal-box h3{margin:0 0 12px;font-size:16px;color:#93c5fd}
.modal-box ul{margin:8px 0 16px;padding-left:18px;font-size:13px;line-height:1.9;color:#cbd5e1}
.modal-box .foot{font-size:11px;color:#94a3b8}
.q{color:#fbbf24}.d{color:#60a5fa}.done{color:#34d399}
</style></head><body>
<h1>V2bX 云控中心 <span class="muted" id="cnt"></span></h1>
<div class="bar">
  <b>批量/单个下发</b>（仅填写修改的字段，留空不下发；NodeID 属差异化字段禁止批量）<br>
  <input id="fApiHost" placeholder="ApiHost 例: https://new.panel.com">
  <input id="fApiKey" placeholder="ApiKey">
  <input id="fNodeId" placeholder="NodeID(数字)" style="width:110px">
  <input id="fDomain" placeholder="CertDomain">
  <select id="fWarp"><option value="">WARP 不变</option><option value="on">WARP 开</option><option value="off">WARP 关</option></select><br>
  <button class="ok" onclick="sendDesired()">下发到选中节点</button>
  <button class="ok" onclick="sendDesiredAll()">下发到全部节点</button>
  <button onclick="doAction('restart')">重启选中</button>
  <button onclick="doAction('update')">升级选中</button>
  <button class="gray" onclick="clearDesired()">清除选中节点的期望配置</button>
  <button class="gray" onclick="refresh()">↻ 手动刷新</button>
  <button class="gray" id="autoBtn" onclick="toggleAuto()">自动刷新: 开</button>
  <span class="small" id="lastRefresh"></span>
  <span class="small">节点在下一个心跳周期(≤2分钟)内自动应用并重启</span>
</div>
<div class="bar">
  <b>全局设置</b><br>
  节点接入 Token: <input id="sNodeToken" readonly>
  <span class="small">（cloud-join.sh / agent 心跳专用，与管理 Token 分离）</span><br>
  升级版本锁定: <input id="sUpdateVer" placeholder="留空=最新 Release，如 v1.0.9" style="width:240px">
  <button class="gray" onclick="saveSettings()">保存设置</button>
</div>
<div id="msg"></div>
<div class="modal" id="modal" onclick="if(event.target===this)this.classList.remove('show')">
  <div class="modal-box" id="modalBox"></div>
</div>
<table><thead><tr>
<th><input type="checkbox" id="selAll" onchange="toggleAll(this)"></th><th>状态</th><th>名称</th><th>IP</th><th>版本</th><th>内存</th><th>连接</th><th>WARP</th><th>面板/节点ID</th><th>最后心跳</th><th>待下发</th><th>最近动作</th>
</tr></thead><tbody id="tb"></tbody></table>
<script>
const T=localStorage.getItem('cloudToken')||prompt('请输入管理 Token（服务端 cloud-data.json 里的 token 字段）');
localStorage.setItem('cloudToken',T);
let NODES=[];
async function api(p,body){const r=await fetch(p,{method:body?'POST':'GET',headers:{'X-Token':T,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
 const j=await r.json().catch(()=>({}));
 if(r.status===401){alert('Token 错误');localStorage.removeItem('cloudToken');location.reload();return j;}
 if(r.status===403){document.getElementById('msg').textContent=j.error||'被拒绝';}
 return j;}
function fmtTime(ts){const s=(Date.now()-ts)/1000;if(s<60)return Math.floor(s)+'秒前';if(s<3600)return Math.floor(s/60)+'分钟前';return Math.floor(s/3600)+'小时前';}
function fmtAct(a){if(!a)return '-';
 const t=fmtTime(a.queuedAt);
 if(a.status==='queued')return '<span class="q">⏳ 排队中</span>'+(a.queuedOffline?'<br><span class="small" style="color:#f87171">节点离线，上线后执行</span>':'<br><span class="small">'+a.type+' · '+t+'</span>');
 if(a.status==='stuck-offline')return '<span style="color:#f87171">⚠️ 节点离线</span><br><span class="small">'+a.type+' 已下发未确认 · '+t+'</span>';
 if(a.status==='unconfirmed')return '<span style="color:#f87171">⚠️ 未确认</span><br><span class="small">'+a.type+' 心跳异常 · '+t+'</span>';
 if(a.status==='done')return '<span class="done">✅ 已完成</span>'+(a.inferred?'<span class="small">(推断)</span>':'')+'<br><span class="small">'+a.type+(a.version?' '+a.version:'')+' · '+fmtTime(a.completedAt||a.queuedAt)+'</span>';
 if(a.status==='delivered')return '<span class="d">🔄 已下发</span><br><span class="small">等节点心跳执行 · '+t+'</span>';
 return '-';}
function render(){const keepSel=new Set([...document.querySelectorAll('.sel:checked')].map(x=>decodeURIComponent(x.value)));
 const tb=document.getElementById('tb');document.getElementById('cnt').textContent='('+NODES.filter(n=>n.online).length+'/'+NODES.length+' 在线)';
 tb.innerHTML=NODES.map(n=>'<tr>'+
 '<td><input type="checkbox" class="sel" value="'+encodeURIComponent(n.key)+'"></td>'+
 '<td class="'+(n.online?'on':'off')+'">'+(n.online?'在线':'离线')+'</td>'+
 '<td>'+n.name+'</td><td>'+n.ip+'</td><td>'+(n.info.version||'-')+'</td>'+
 '<td>'+(n.info.rss_mb||0)+'MB</td><td>'+(n.info.conns||0)+'</td>'+
 '<td>'+(n.info.warp||'-')+'</td>'+
 '<td class="small">'+((n.info.cfg&&n.info.cfg.ApiHost)||'')+'<br>NodeID '+((n.info.cfg&&n.info.cfg.NodeID)||'-')+'</td>'+
 '<td class="small">'+fmtTime(n.lastSeen)+'</td>'+
 '<td class="small">'+(n.desired?JSON.stringify(n.desired):'-')+'</td>'+
 '<td class="small">'+fmtAct(n.action)+'</td></tr>').join('');
 document.querySelectorAll('.sel').forEach(x=>{x.checked=keepSel.has(decodeURIComponent(x.value));});
 const all=[...document.querySelectorAll('.sel')];
 document.getElementById('selAll').checked=all.length>0&&all.every(x=>x.checked);}
async function refresh(){try{const d=await api('/api/nodes');if(!d.nodes)return;NODES=d.nodes||[];
 document.getElementById('sNodeToken').value=d.nodeToken||'';
 if(document.getElementById('sUpdateVer')!==document.activeElement)document.getElementById('sUpdateVer').value=d.updateVersion||'';
 render();}catch(e){}}
function targets(){const s=[...document.querySelectorAll('.sel:checked')].map(x=>decodeURIComponent(x.value));if(!s.length){alert('请先勾选节点');return null;}return s;}
function gather(){const f={};for(const [id,k] of [['fApiHost','ApiHost'],['fApiKey','ApiKey'],['fNodeId','NodeID'],['fDomain','CertDomain'],['fWarp','Warp']]){const v=document.getElementById(id).value.trim();if(v)f[k]=v;}
 if(f.NodeID&&!/^\\d+$/.test(f.NodeID)){alert('NodeID 必须为数字');return null;}return f;}
async function sendDesired(){const t=targets();if(!t)return;const f=gather();if(!f||!Object.keys(f).length){alert('请至少填写一个字段');return;}
 const d=await api('/api/desired',{targets:t,fields:f});
 if(d.error){show('被拒绝: '+d.error);return;}
 showModal('已写入期望配置到 '+d.applied+' 台节点', [
   '下发内容: '+JSON.stringify(d.fields),
   '执行时机: 每台节点下一次心跳（≤2 分钟）',
   '执行规则: 与节点当前配置一致则跳过；有差异才修改并自动重启'
 ], '完成后「待下发」列清空即代表已应用；列表每 5 秒自动刷新');}
async function sendDesiredAll(){const f=gather();if(!f||!Object.keys(f).length){alert('请至少填写一个字段');return;}
 const d=await api('/api/desired',{targets:'all',fields:f});
 if(d.error){show('被拒绝: '+d.error);return;}
 showModal('已写入期望配置到全部 '+d.applied+' 台节点', [
   '下发内容: '+JSON.stringify(d.fields),
   '执行时机: 每台节点下一次心跳（≤2 分钟）',
   '执行规则: 与节点当前配置一致则跳过；有差异才修改并自动重启'
 ], '完成后「待下发」列清空即代表已应用；列表每 5 秒自动刷新');}
async function doAction(a){const t=targets();if(!t)return;
 const ver=document.getElementById('sUpdateVer').value.trim();
 if(!confirm(a==='update'?('确认升级选中节点？'+(ver?('（锁定版本 '+ver+'）'):'（最新版）')):'确认重启选中节点？'))return;
 const d=await api('/api/action',{targets:t,action:a});
 if(d.error){show('被拒绝: '+d.error);return;}
 const lines=a==='update'?[
   '锁定版本: '+(d.version||'最新 Release'),
   '执行时机: 每台节点下一次心跳（≤2 分钟）',
   '执行方式: 自动运行升级脚本并重启服务（约 1~2 分钟）'
 ]:[
   '执行时机: 每台节点下一次心跳（≤2 分钟）',
   '执行方式: systemd 重启 V2bX 服务（约 10 秒完成）'
 ];
 showModal('已为 '+d.queued+' 台节点排队: '+(a==='update'?'升级':'重启'), lines,
   '状态流转: ⏳ 排队中 → 🔄 已下发(等心跳) → ✅ 已完成<br>列表每 5 秒自动刷新，可关闭本窗口');}
async function clearDesired(){const t=targets();if(!t)return;await api('/api/desired/clear',{targets:t});show('已清除期望配置');}
async function saveSettings(){const v=document.getElementById('sUpdateVer').value.trim();
 const d=await api('/api/settings',{updateVersion:v});show(d.error?('被拒绝: '+d.error):('设置已保存: 升级版本锁定 = '+(v||'最新版')));}
function showModal(title,lines,foot){
 document.getElementById('modalBox').innerHTML='<h3>'+title+'</h3><ul>'+lines.map(l=>'<li>'+l+'</li>').join('')+'</ul><div class="foot">'+foot+'</div><button class="ok" id="modalOk" style="margin-top:12px">知道了</button>';
 document.getElementById('modalOk').onclick=function(){document.getElementById('modal').classList.remove('show');};
 document.getElementById('modal').classList.add('show');}
function show(m){document.getElementById('msg').textContent=m;setTimeout(refresh,800);}
function toggleAll(cb){document.querySelectorAll('.sel').forEach(x=>x.checked=cb.checked);}
let AUTO=true;
function toggleAuto(){AUTO=!AUTO;const b=document.getElementById('autoBtn');b.textContent='自动刷新: '+(AUTO?'开':'关');b.style.background=AUTO?'#475569':'#dc2626';}
async function refresh(){try{const d=await api('/api/nodes');if(!d.nodes)return;NODES=d.nodes||[];
 document.getElementById('sNodeToken').value=d.nodeToken||'';
 if(document.getElementById('sUpdateVer')!==document.activeElement)document.getElementById('sUpdateVer').value=d.updateVersion||'';
 render();
 document.getElementById('lastRefresh').textContent='上次刷新 '+new Date().toLocaleTimeString();}catch(e){}}
refresh();setInterval(()=>{if(AUTO)refresh();},5000);
</script></body></html>`;

// ---------- 数据存储（含 v1 → v2 迁移） ----------
function loadData() {
  let d;
  try {
    d = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
  } catch (e) {
    d = { token: DEFAULT_ADMIN, nodeToken: DEFAULT_NODE, updateVersion: '', nodes: {} };
  }
  if (!d.nodeToken) d.nodeToken = d.token; // 旧版数据迁移
  if (d.updateVersion === undefined) d.updateVersion = '';
  if (!d.nodes) d.nodes = {};
  return d;
}
function saveData(d) {
  fs.writeFileSync(DATA_FILE, JSON.stringify(d, null, 2));
}
let data = loadData();
saveData(data);

// ---------- 安全工具 ----------
function safeEqual(a, b) {
  // 常量时间比较：先哈希定长再比，避免长度/时序侧信道
  const ha = crypto.createHash('sha256').update(String(a)).digest();
  const hb = crypto.createHash('sha256').update(String(b)).digest();
  return crypto.timingSafeEqual(ha, hb);
}
function isDefaultToken() {
  return data.token === DEFAULT_ADMIN || data.nodeToken === DEFAULT_NODE;
}
function defaultTokenBlocked() {
  return isDefaultToken() && !ALLOW_INSECURE;
}

// IP 级限速：滑动窗口计数（零依赖内存实现）
const rateBuckets = new Map(); // key -> {count, resetAt}
function rateLimit(key, max, windowMs) {
  const now = Date.now();
  let b = rateBuckets.get(key);
  if (!b || now > b.resetAt) {
    b = { count: 0, resetAt: now + windowMs };
    rateBuckets.set(key, b);
  }
  b.count++;
  if (rateBuckets.size > 10000) { // 防表膨胀
    for (const [k, v] of rateBuckets) if (now > v.resetAt) rateBuckets.delete(k);
  }
  return b.count <= max;
}

// ---------- HTTP 工具 ----------
function send(res, code, body, type) {
  res.writeHead(code, { 'Content-Type': type || 'application/json; charset=utf-8' });
  res.end(body);
}
function json(res, code, obj) { send(res, code, JSON.stringify(obj)); }
function readBody(req) {
  return new Promise((resolve) => {
    let b = '';
    req.on('data', (c) => { b += c; if (b.length > 1e6) req.destroy(); });
    req.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch (e) { resolve({}); } });
  });
}
function pickCfg(cfg) {
  const out = {};
  for (const k of ['ApiHost', 'ApiKey', 'NodeID', 'CertDomain', 'Warp']) {
    if (cfg && cfg[k] !== undefined && cfg[k] !== null && cfg[k] !== '') out[k] = cfg[k];
  }
  return out;
}
const PER_NODE_FIELDS = ['NodeID']; // 差异化字段：禁止多目标批量下发

// ---------- API ----------
const handler = async (req, res) => {
  const url = req.url.split('?')[0];
  const ip = (req.headers['x-forwarded-for'] || req.socket.remoteAddress || '').split(',')[0].trim();

  // Web 后台
  if (url === '/' || url === '/ui') { send(res, 200, UI, 'text/html; charset=utf-8'); return; }

  // ---------- 节点心跳（节点专用 nodeToken + 限速） ----------
  if (url === '/api/heartbeat' && req.method === 'POST') {
    if (!rateLimit('hb:' + ip, 10, 60000)) return json(res, 429, { error: 'rate limited' });
    if (!safeEqual(req.headers['x-token'], data.nodeToken)) {
      rateLimit('fail:' + ip, 10, 60000);
      return json(res, 401, { error: 'bad token' });
    }
    if (defaultTokenBlocked()) return json(res, 403, { error: '默认 nodeToken 禁止使用，请在服务端 cloud-data.json 修改 nodeToken 后重启' });
    const body = await readBody(req);
    const name = String(body.name || 'unknown').slice(0, 64);
    const key = name + '|' + ip;
    const rec = data.nodes[key] || { created: Date.now(), desired: null, pendingAction: null };
    const prevSeen = rec.lastSeen || 0; // 真正的上一次心跳时间（必须在更新 lastSeen 之前捕获）
    rec.name = name;
    rec.ip = ip;
    rec.lastSeen = Date.now();
    rec.info = {
      hostname: body.hostname || '', version: body.version || '',
      rss_mb: body.rss_mb || 0, conns: body.conns || 0,
      uptime_sec: body.uptime_sec || 0, warp: body.warp || 'unknown',
      cfg: body.cfg || {}, load: body.load || ''
    };
    const pending = rec.pendingAction;
    const reply = { desired: rec.desired || null, action: pending || 'none' };
    if (pending === 'update') reply.version = data.updateVersion || '';
    if (pending) {
      rec.pendingAction = null; // 动作一次性下发
      if (rec.action && rec.action.status === 'queued') {
        rec.action.status = 'delivered';
        rec.action.deliveredAt = Date.now();
        rec.action.deliveredLastSeen = prevSeen; // 推断基准：交付时节点的心跳时间
      }
    }
    // 节点上报的动作执行确认（新 agent 执行完写 ack，下一次心跳带回）
    if (body.ack && rec.action && rec.action.status === 'delivered'
        && String(body.ack).startsWith(rec.action.type)) {
      rec.action.status = 'done';
      rec.action.completedAt = Date.now();
    }
    // 老版本 agent 无 ack 机制：交付基准点之后的心跳即视为执行完成，避免动作永远卡在"已下发"
    // restart: 交付后的下一轮心跳推断完成；update: 版本与锁定一致，或两轮心跳后推断完成
    const inferBase = rec.action && (rec.action.deliveredLastSeen || rec.action.deliveredAt) || 0;
    if (rec.action && rec.action.status === 'delivered'
        && prevSeen > inferBase && !body.ack) {
      let infer = false;
      if (rec.action.type === 'restart') infer = true;
      else if (rec.action.version && body.version === rec.action.version) infer = true;
      else if (prevSeen > inferBase + 150000) infer = true;
      if (infer) {
        rec.action.status = 'done';
        rec.action.inferred = true; // 无 ack，由服务端推断
        rec.action.completedAt = Date.now();
      }
    }
    data.nodes[key] = rec;
    saveData(data);
    return json(res, 200, reply);
  }

  // ---------- 管理接口（管理 Token + 失败限速 + 默认 Token 门禁） ----------
  if (url !== '/api/token') {
    if (!safeEqual(req.headers['x-token'], data.token)) {
      if (!rateLimit('fail:' + ip, 10, 60000)) return json(res, 429, { error: 'rate limited' });
      return json(res, 401, { error: 'unauthorized' });
    }
    if (defaultTokenBlocked()) {
      return json(res, 403, { error: '默认管理 Token 禁止使用：请编辑 cloud-data.json 将 token 与 nodeToken 改为随机强串后重启本进程（开发调试可用 ALLOW_INSECURE_TOKEN=1 临时绕过）' });
    }
  }

  if (url === '/api/nodes' && req.method === 'GET') {
    const now = Date.now();
    // 计算动作的有效展示状态（覆盖离线/超时等真实场景）
    const effAction = (n) => {
      const a = n.action;
      if (!a) return null;
      const online = now - n.lastSeen < 5 * 60 * 1000;
      const out = Object.assign({}, a);
      if (a.status === 'delivered') {
        if (n.lastSeen > a.deliveredAt + 60000) {
          out.status = 'done'; // 交付后节点又心跳过一次：老 agent 由推断逻辑落库，这里兜底展示
        } else if (!online && now - a.deliveredAt > 5 * 60 * 1000) {
          out.status = 'stuck-offline'; // 节点掉线，动作未确认
        } else if (now - a.deliveredAt > 30 * 60 * 1000) {
          out.status = 'unconfirmed'; // 长时间无后续心跳，无法确认
        }
      }
      if (a.status === 'queued' && !online) out.queuedOffline = true;
      return out;
    };
    const list = Object.entries(data.nodes).map(([key, n]) => ({
      key, name: n.name, ip: n.ip, lastSeen: n.lastSeen,
      online: now - n.lastSeen < 5 * 60 * 1000, info: n.info,
      desired: n.desired || null, action: effAction(n)
    })).sort((a, b) => (a.online === b.online) ? a.name.localeCompare(b.name) : (a.online ? -1 : 1));
    return json(res, 200, { token: data.token, nodeToken: data.nodeToken, updateVersion: data.updateVersion, nodes: list });
  }

  if (url === '/api/desired' && req.method === 'POST') {
    const body = await readBody(req);
    const fields = pickCfg(body.fields);
    if (!Object.keys(fields).length) return json(res, 400, { error: 'no fields' });
    const isBatch = body.targets === 'all' || (Array.isArray(body.targets) && body.targets.length > 1);
    if (isBatch) {
      const bad = Object.keys(fields).filter((k) => PER_NODE_FIELDS.includes(k));
      if (bad.length) {
        return json(res, 400, { error: `字段 ${bad.join(',')} 是每台节点不同的差异化配置，禁止批量下发，请单独勾选节点逐台设置` });
      }
    }
    let count = 0;
    for (const [key, n] of Object.entries(data.nodes)) {
      if (body.targets === 'all' || (body.targets || []).includes(key)) {
        n.desired = Object.assign({}, n.desired || {}, fields);
        count++;
      }
    }
    saveData(data);
    return json(res, 200, { ok: true, applied: count, fields });
  }

  if (url === '/api/desired/clear' && req.method === 'POST') {
    const body = await readBody(req);
    let count = 0;
    for (const [key, n] of Object.entries(data.nodes)) {
      if (body.targets === 'all' || (body.targets || []).includes(key)) { n.desired = null; count++; }
    }
    saveData(data);
    return json(res, 200, { ok: true, cleared: count });
  }

  if (url === '/api/action' && req.method === 'POST') {
    const body = await readBody(req);
    const act = body.action === 'update' ? 'update' : 'restart';
    let count = 0;
    for (const [key, n] of Object.entries(data.nodes)) {
      if (body.targets === 'all' || (body.targets || []).includes(key)) {
        n.pendingAction = act;
        n.action = {
          type: act,
          version: act === 'update' ? (data.updateVersion || '') : '',
          queuedAt: Date.now(),
          status: 'queued'
        };
        count++;
      }
    }
    saveData(data);
    return json(res, 200, { ok: true, queued: count, action: act, version: act === 'update' ? (data.updateVersion || '') : undefined });
  }

  if (url === '/api/settings' && req.method === 'POST') {
    const body = await readBody(req);
    if (body.updateVersion !== undefined) {
      const v = String(body.updateVersion).trim();
      if (v && !/^v[0-9][\w.\-]*$/.test(v)) return json(res, 400, { error: '版本号格式非法（示例: v1.0.9）' });
      data.updateVersion = v;
    }
    if (body.newNodeToken && String(body.newNodeToken).length >= 16) {
      data.nodeToken = String(body.newNodeToken);
    }
    saveData(data);
    return json(res, 200, { ok: true, nodeToken: data.nodeToken, updateVersion: data.updateVersion });
  }

  if (url === '/api/token' && req.method === 'POST') {
    const body = await readBody(req);
    if (body.newToken && String(body.newToken).length >= 16) { data.token = String(body.newToken); saveData(data); return json(res, 200, { ok: true }); }
    return json(res, 400, { error: 'token too short (>=16)' });
  }

  json(res, 404, { error: 'not found' });
};

// ---------- TLS 可选: 设置 TLS_CERT/TLS_KEY 环境变量后以 HTTPS 监听（自签证书场景） ----------
const TLS_CERT = process.env.TLS_CERT || '';
const TLS_KEY = process.env.TLS_KEY || '';
let server;
let SCHEME = 'http';
if (TLS_CERT && TLS_KEY && fs.existsSync(TLS_CERT) && fs.existsSync(TLS_KEY)) {
  const https = require('https');
  server = https.createServer({ cert: fs.readFileSync(TLS_CERT), key: fs.readFileSync(TLS_KEY) }, handler);
  SCHEME = 'https';
} else {
  if (TLS_CERT || TLS_KEY) console.log('⚠️ TLS_CERT/TLS_KEY 指向的证书文件缺失，回退为 HTTP 明文监听');
  server = http.createServer(handler);
}

server.listen(PORT, () => {
  console.log('V2bX 云控中心已启动: ' + SCHEME + '://0.0.0.0:' + PORT + (SCHEME === 'https' ? '  (TLS 已启用)' : ''));
  if (isDefaultToken()) {
    console.log('!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!');
    console.log('!! 检测到默认 Token：管理接口与心跳已拒绝服务(403)。   !!');
    console.log('!! 请编辑 ' + DATA_FILE);
    console.log('!! 将 token / nodeToken 改为随机强串（openssl rand -hex 16）');
    console.log('!! 后重启本进程。开发调试可设 ALLOW_INSECURE_TOKEN=1 绕过。');
    console.log('!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!');
  } else {
    console.log('管理 Token 与节点 Token 已分离，安全模式: 正常');
  }
  console.log('升级版本锁定: ' + (data.updateVersion || '最新 Release'));
  console.log('安全要求: 用 Nginx/Caddy 反代并启用 HTTPS 后再暴露公网');
});
