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
<table><thead><tr>
<th></th><th>状态</th><th>名称</th><th>IP</th><th>版本</th><th>内存</th><th>连接</th><th>WARP</th><th>面板/节点ID</th><th>最后心跳</th><th>待下发</th>
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
function render(){const tb=document.getElementById('tb');document.getElementById('cnt').textContent='('+NODES.filter(n=>n.online).length+'/'+NODES.length+' 在线)';
 tb.innerHTML=NODES.map(n=>'<tr>'+
 '<td><input type="checkbox" class="sel" value="'+encodeURIComponent(n.key)+'"></td>'+
 '<td class="'+(n.online?'on':'off')+'">'+(n.online?'在线':'离线')+'</td>'+
 '<td>'+n.name+'</td><td>'+n.ip+'</td><td>'+(n.info.version||'-')+'</td>'+
 '<td>'+(n.info.rss_mb||0)+'MB</td><td>'+(n.info.conns||0)+'</td>'+
 '<td>'+(n.info.warp||'-')+'</td>'+
 '<td class="small">'+((n.info.cfg&&n.info.cfg.ApiHost)||'')+'<br>NodeID '+((n.info.cfg&&n.info.cfg.NodeID)||'-')+'</td>'+
 '<td class="small">'+fmtTime(n.lastSeen)+'</td>'+
 '<td class="small">'+(n.desired?JSON.stringify(n.desired):'-')+'</td></tr>').join('');}
async function refresh(){try{const d=await api('/api/nodes');if(!d.nodes)return;NODES=d.nodes||[];
 document.getElementById('sNodeToken').value=d.nodeToken||'';
 if(document.getElementById('sUpdateVer')!==document.activeElement)document.getElementById('sUpdateVer').value=d.updateVersion||'';
 render();}catch(e){}}
function targets(){const s=[...document.querySelectorAll('.sel:checked')].map(x=>decodeURIComponent(x.value));if(!s.length){alert('请先勾选节点');return null;}return s;}
function gather(){const f={};for(const [id,k] of [['fApiHost','ApiHost'],['fApiKey','ApiKey'],['fNodeId','NodeID'],['fDomain','CertDomain'],['fWarp','Warp']]){const v=document.getElementById(id).value.trim();if(v)f[k]=v;}
 if(f.NodeID&&!/^\\d+$/.test(f.NodeID)){alert('NodeID 必须为数字');return null;}return f;}
async function sendDesired(){const t=targets();if(!t)return;const f=gather();if(!f||!Object.keys(f).length){alert('请至少填写一个字段');return;}
 const d=await api('/api/desired',{targets:t,fields:f});show(d.error?('被拒绝: '+d.error):('已下发到 '+d.applied+' 个节点: '+JSON.stringify(d.fields)));}
async function sendDesiredAll(){const f=gather();if(!f||!Object.keys(f).length){alert('请至少填写一个字段');return;}
 const d=await api('/api/desired',{targets:'all',fields:f});show(d.error?('被拒绝: '+d.error):('已下发到全部 '+d.applied+' 个节点'));}
async function doAction(a){const t=targets();if(!t)return;if(!confirm(a==='update'?'确认升级选中节点？':'确认重启选中节点？'))return;
 const d=await api('/api/action',{targets:t,action:a});show(d.error?('被拒绝: '+d.error):('动作已排队: '+d.action+(d.version?' (锁定版本 '+d.version+')':' (最新版)')));}
async function clearDesired(){const t=targets();if(!t)return;await api('/api/desired/clear',{targets:t});show('已清除期望配置');}
async function saveSettings(){const v=document.getElementById('sUpdateVer').value.trim();
 const d=await api('/api/settings',{updateVersion:v});show(d.error?('被拒绝: '+d.error):('设置已保存: 升级版本锁定 = '+(v||'最新版')));}
function show(m){document.getElementById('msg').textContent=m;setTimeout(refresh,800);}
refresh();setInterval(refresh,5000);
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
    if (pending) rec.pendingAction = null; // 动作一次性下发
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
    const list = Object.entries(data.nodes).map(([key, n]) => ({
      key, name: n.name, ip: n.ip, lastSeen: n.lastSeen,
      online: now - n.lastSeen < 5 * 60 * 1000, info: n.info,
      desired: n.desired || null
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
      if (body.targets === 'all' || (body.targets || []).includes(key)) { n.pendingAction = act; count++; }
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
