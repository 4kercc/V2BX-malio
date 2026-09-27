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
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = parseInt(process.env.PORT || '8765', 10);
const DATA_FILE = path.join(__dirname, 'cloud-data.json');
const DEFAULT_ADMIN = 'changeme-token';
const DEFAULT_NODE = 'changeme-node-token';
const ALLOW_INSECURE = process.env.ALLOW_INSECURE_TOKEN === '1';

// ---------- Web 后台（单页，shadcn/ui 风格，响应式） ----------
const UI = `<!DOCTYPE html>
<html lang="zh-CN" class="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>V2bX 云控中心</title>
<style>
:root{
 --background:0 0% 100%;--foreground:240 10% 3.9%;
 --card:0 0% 100%;--card-fg:240 10% 3.9%;
 --border:240 5.9% 90%;--input:240 5.9% 90%;
 --muted:240 4.8% 95.9%;--muted-fg:240 5.2% 33.9%;
 --primary:240 5.9% 10%;--primary-fg:0 0% 98%;
 --accent:240 4.8% 95.9%;--accent-fg:240 5.2% 33.9%;
 --destructive:0 84.2% 60.2%;--destructive-fg:0 0% 98%;
 --ring:240 5.9% 10%;--radius:0.5rem;
 --ok:142 76% 36%;--warn:38 92% 50%;--info:217 91% 60%;--bad:0 72% 51%;
}
.dark{
 --background:240 10% 3.9%;--foreground:0 0% 98%;
 --card:240 10% 3.9%;--card-fg:0 0% 98%;
 --border:240 3.7% 15.9%;--input:240 3.7% 15.9%;
 --muted:240 3.7% 15.9%;--muted-fg:240 5% 64.9%;
 --primary:0 0% 98%;--primary-fg:240 5.9% 10%;
 --accent:240 3.7% 15.9%;--accent-fg:0 0% 98%;
 --destructive:0 72% 51%;--destructive-fg:0 0% 98%;
 --ring:240 4.9% 83.9%;
 --ok:142 76% 44%;--warn:38 92% 55%;--info:217 91% 65%;--bad:0 84% 65%;
}
*{box-sizing:border-box;border-color:hsl(var(--border))}
body{margin:0;background:hsl(var(--background));color:hsl(var(--foreground));
 font-family:ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;
 font-size:14px;line-height:1.5;-webkit-font-smoothing:antialiased}
.wrap{max-width:1200px;margin:0 auto;padding:16px}
@media(min-width:768px){.wrap{padding:24px}}
h1{font-size:18px;font-weight:600;margin:0;letter-spacing:-.01em}
.muted{color:hsl(var(--muted-fg));font-size:12px}
.card{border:1px solid hsl(var(--border));border-radius:var(--radius);background:hsl(var(--card));color:hsl(var(--card-fg));padding:16px;margin-bottom:16px}
.card-title{font-size:14px;font-weight:600;margin:0 0 12px}
.grid-form{display:grid;gap:8px;grid-template-columns:1fr}
@media(min-width:900px){.grid-form{grid-template-columns:repeat(5,1fr)}}
.row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-top:10px}
input,select{background:transparent;color:hsl(var(--foreground));border:1px solid hsl(var(--input));
 border-radius:calc(var(--radius) - 2px);padding:0 12px;height:36px;font-size:14px;width:100%;outline:none}
input:focus,select:focus{border-color:hsl(var(--ring));box-shadow:0 0 0 2px hsl(var(--ring)/.15)}
input::placeholder{color:hsl(var(--muted-fg))}
.btn{display:inline-flex;align-items:center;justify-content:center;height:36px;padding:0 14px;
 border-radius:calc(var(--radius) - 2px);font-size:13px;font-weight:500;cursor:pointer;
 border:1px solid transparent;transition:opacity .15s,background .15s;white-space:nowrap}
.btn-primary{background:hsl(var(--primary));color:hsl(var(--primary-fg))}
.btn-primary:hover{opacity:.88}
.btn-outline{background:transparent;border:1px solid hsl(var(--input));color:hsl(var(--foreground))}
.btn-outline:hover{background:hsl(var(--accent));color:hsl(var(--accent-fg))}
.btn-ghost{background:transparent;color:hsl(var(--muted-fg))}
.btn-ghost:hover{background:hsl(var(--accent));color:hsl(var(--accent-fg))}
.btn-destructive{background:hsl(var(--destructive));color:hsl(var(--destructive-fg))}
.btn-sm{height:32px;padding:0 10px;font-size:12px}
.head{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:16px;flex-wrap:wrap}
.head-r{display:flex;align-items:center;gap:8px}
.tbwrap{overflow-x:auto;border:1px solid hsl(var(--border));border-radius:var(--radius)}
table{width:100%;border-collapse:collapse;font-size:13px;min-width:960px}
th{background:hsl(var(--muted));color:hsl(var(--muted-fg));font-weight:500;text-align:left;padding:9px 12px;white-space:nowrap}
td{padding:10px 12px;border-top:1px solid hsl(var(--border));vertical-align:top}
tbody tr:hover{background:hsl(var(--accent)/.5)}
.badge{display:inline-flex;align-items:center;border-radius:9999px;padding:2px 9px;font-size:11px;font-weight:600;border:1px solid transparent;white-space:nowrap}
.b-ok{background:hsl(var(--ok)/.12);color:hsl(var(--ok));border-color:hsl(var(--ok)/.35)}
.b-info{background:hsl(var(--info)/.12);color:hsl(var(--info));border-color:hsl(var(--info)/.35)}
.b-warn{background:hsl(var(--warn)/.12);color:hsl(var(--warn));border-color:hsl(var(--warn)/.35)}
.b-bad{background:hsl(var(--bad)/.12);color:hsl(var(--bad));border-color:hsl(var(--bad)/.35)}
.b-mut{background:hsl(var(--muted));color:hsl(var(--muted-fg));border-color:hsl(var(--border))}
.small{font-size:11px;color:hsl(var(--muted-fg))}
.ellip{max-width:190px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mobile-cards{display:none}
.ncard{border:1px solid hsl(var(--border));border-radius:var(--radius);padding:12px;margin-bottom:10px;background:hsl(var(--card))}
.ncard .nrow{display:flex;align-items:center;justify-content:space-between;gap:8px}
.ncard .ngrid{display:grid;grid-template-columns:1fr 1fr;gap:4px 12px;margin-top:8px;font-size:12px}
.ncard .ngrid .k{color:hsl(var(--muted-fg))}
#msg{margin:0 0 12px;color:hsl(var(--warn));min-height:18px;font-size:13px}
.modal{display:none;position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:99;align-items:center;justify-content:center;padding:16px}
.modal.show{display:flex}
.modal-box{background:hsl(var(--card));border:1px solid hsl(var(--border));border-radius:var(--radius);padding:24px;max-width:520px;width:100%;box-shadow:0 16px 48px rgba(0,0,0,.4)}
.modal-box h3{margin:0 0 12px;font-size:15px;font-weight:600}
.modal-box ul{margin:8px 0 14px;padding-left:18px;font-size:13px;line-height:1.9;color:hsl(var(--muted-fg))}
.modal-box .foot{font-size:11px;color:hsl(var(--muted-fg))}
.only-mobile{display:none}
@media(max-width:767px){.only-mobile{display:block}.tbwrap{display:none}.grid-form{grid-template-columns:1fr 1fr}.row .btn{flex:1 1 auto}}
</style>
</head>
<body>
<div class="wrap">
<div class="head">
 <div><h1>V2bX 云控中心</h1><span class="muted" id="cnt"></span></div>
 <div class="head-r">
   <span class="muted" id="lastRefresh"></span>
   <button class="btn btn-ghost btn-sm" onclick="refresh()">↻ 刷新</button>
   <button class="btn btn-outline btn-sm" id="autoBtn" onclick="toggleAuto()">自动刷新: 开</button>
   <button class="btn btn-ghost btn-sm" id="themeBtn" onclick="toggleTheme()">🌙</button>
   <button class="btn btn-ghost btn-sm" onclick="logout()" title="退出登录">退出</button>
 </div>
</div>

<div class="card">
 <p class="card-title">批量下发 <span class="muted" style="font-weight:400">（仅填写修改的字段，留空不下发；NodeID 属差异化字段禁止批量）</span></p>
 <div class="grid-form">
  <input id="fApiHost" placeholder="ApiHost 例: https://new.panel.com">
  <input id="fApiKey" placeholder="ApiKey">
  <input id="fNodeId" placeholder="NodeID (数字)">
  <input id="fDomain" placeholder="CertDomain">
  <select id="fWarp"><option value="">WARP 不变</option><option value="on">WARP 开</option><option value="off">WARP 关</option></select>
 </div>
 <div class="row">
  <button class="btn btn-primary" onclick="sendDesired()">下发到选中节点</button>
  <button class="btn btn-primary" onclick="sendDesiredAll()">下发到全部节点</button>
  <button class="btn btn-outline" onclick="doAction('restart')">重启选中</button>
  <button class="btn btn-outline" onclick="doAction('update')">升级选中</button>
  <button class="btn btn-ghost" onclick="clearDesired()">清除选中节点的期望配置</button>
  <input id="fGroup" placeholder="分组标签" style="width:140px;height:32px">
  <button class="btn btn-outline btn-sm" onclick="setGroup()">设置选中分组</button>
 </div>
 <p class="muted" style="margin:8px 0 0">节点在下一个心跳周期（≤2 分钟）内自动应用并重启</p>
</div>

<div class="card">
 <p class="card-title">全局设置</p>
 <div class="grid-form" style="grid-template-columns:1fr">
  <div>
   <div class="muted" style="margin-bottom:4px">节点接入 Token <span>（cloud-join.sh / agent 心跳专用，与管理 Token 分离）</span></div>
   <input id="sNodeToken" readonly>
  </div>
  <div>
   <div class="muted" style="margin-bottom:4px">一键对接脚本 <span>（粘贴到节点服务器以 root 执行即完成接入，自签证书自动识别）</span></div>
   <div style="display:flex;gap:8px">
    <input id="joinCmd" readonly style="font-family:ui-monospace,Consolas,monospace;font-size:12px">
    <button class="btn btn-outline" style="flex:0 0 auto" onclick="copyJoin()">复制</button>
   </div>
  </div>
  <div>
   <div class="muted" style="margin-bottom:4px">升级版本锁定 <span>（留空 = 最新 Release）</span></div>
   <div style="display:flex;gap:8px">
    <input id="sUpdateVer" placeholder="如 v1.0.9" style="flex:1">
    <button class="btn btn-outline" style="flex:0 0 auto" onclick="saveSettings()">保存设置</button>
   </div>
  </div>
  <div>
   <div class="muted" style="margin-bottom:4px">Agent 目标版本 <span>（数字，与节点上报不一致时自动自更新；留空关闭）</span></div>
   <input id="sAgentVer" placeholder="如 6">
  </div>
  <div>
   <div class="muted" style="margin-bottom:4px">Telegram Bot Token <span>（告警推送，可留空）</span></div>
   <input id="sTgBot" placeholder="123456:ABC-DEF...">
  </div>
  <div>
   <div class="muted" style="margin-bottom:4px">Telegram Chat ID</div>
   <input id="sTgChat" placeholder="-100123456789">
  </div>
  <div>
   <div class="muted" style="margin-bottom:4px">Webhook URL <span>（备选告警通道）</span></div>
   <input id="sWebhook" placeholder="https://...">
  </div>
 </div>
 <div class="row"><button class="btn btn-outline btn-sm" onclick="saveSettings()">保存全部设置</button></div>
</div>

<div id="msg"></div>

<div class="card">
 <p class="card-title">节点列表 <span class="muted" id="cnt2" style="font-weight:400"></span></p>
 <div class="row" style="margin:0 0 10px">
  <select id="groupFilter" onchange="render()" style="width:auto;min-width:140px">
   <option value="">全部分组</option>
  </select>
  <select id="hostFilter" onchange="render()" style="width:auto;min-width:180px">
   <option value="">全部面板域名</option>
  </select>
  <button class="btn btn-ghost btn-sm" onclick="showAudit()">📜 审计 / 事件日志</button>
 </div>
 <div class="tbwrap">
  <table><thead><tr>
   <th style="width:32px"><input type="checkbox" id="selAll" onchange="toggleAll(this)" style="width:14px;height:14px;padding:0"></th>
   <th>状态</th><th>名称</th><th>分组</th><th>IP</th><th>版本</th><th>内存</th><th>连接</th><th>WARP</th><th>证书</th><th>面板 / 节点ID</th><th>最后心跳</th><th>待下发</th><th>最近动作</th>
  </tr></thead><tbody id="tb"></tbody></table>
 </div>
 <div class="only-mobile" id="mc"></div>
</div>
</div>

<div class="modal" id="modal">
 <div class="modal-box" id="modalBox"></div>
</div>

<script>
function applyTheme(t){document.documentElement.classList.toggle('dark',t==='dark');
 var b=document.getElementById('themeBtn');if(b)b.textContent=t==='dark'?'🌙':'☀️';}
function toggleTheme(){var t=document.documentElement.classList.contains('dark')?'light':'dark';
 localStorage.setItem('cloudTheme',t);applyTheme(t);}
applyTheme(localStorage.getItem('cloudTheme')||'dark');

let NODES=[];
// 会话由服务端 Cookie 维护，前端不再持有/传递任何 Token
async function api(p,body){const r=await fetch(p,{method:body?'POST':'GET',headers:{'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,credentials:'same-origin'});
 const j=await r.json().catch(()=>({}));
 if(r.status===401){location.href='/login';return j;} // 会话失效 → 回登录页
 if(r.status===403){document.getElementById('msg').textContent=j.error||'被拒绝';}
 return j;}
function logout(){fetch('/api/logout',{method:'POST',credentials:'same-origin'}).catch(function(){}).then(function(){location.href='/login';});}
function fmtTime(ts){const s=(Date.now()-ts)/1000;if(s<60)return Math.floor(s)+'秒前';if(s<3600)return Math.floor(s/60)+'分钟前';return Math.floor(s/3600)+'小时前';}
function badge(cls,txt){return '<span class="badge '+cls+'">'+txt+'</span>';}
function fmtAct(a){if(!a)return badge('b-mut','-');
 const t=fmtTime(a.queuedAt);
 if(a.status==='queued')return badge('b-warn','⏳ 排队中')+(a.queuedOffline?'<div class="small" style="color:hsl(var(--bad))">节点离线，上线后执行</div>':'<div class="small">'+a.type+' · '+t+'</div>');
 if(a.status==='stuck-offline')return badge('b-bad','⚠️ 节点离线')+'<div class="small">'+a.type+' 已下发未确认 · '+t+'</div>';
 if(a.status==='unconfirmed')return badge('b-bad','⚠️ 未确认')+'<div class="small">'+a.type+' 心跳异常 · '+t+'</div>';
 if(a.status==='done')return badge('b-ok','✅ 已完成')+(a.inferred?' <span class="small">(推断)</span>':'')+'<div class="small">'+a.type+(a.version?' '+a.version:'')+' · '+fmtTime(a.completedAt||a.queuedAt)+'</div>';
 if(a.status==='delivered')return badge('b-info','🔄 已下发')+'<div class="small">等节点心跳执行 · '+t+'</div>';
 return badge('b-mut','-');}
function fmtCert(d){if(d===null||d===undefined)return badge('b-mut','-');
 if(d<=7)return badge('b-bad','⚠ '+d+'天');
 if(d<=14)return badge('b-warn',d+'天');
 if(d<=21)return badge('b-info',d+'天');
 return badge('b-ok',d+'天');}
function visibleNodes(){const gf=document.getElementById('groupFilter').value;
 const hf=document.getElementById('hostFilter').value;
 return NODES.filter(n=>(!gf||n.group===gf)&&(!hf||((n.info.cfg&&n.info.cfg.ApiHost)||'')===hf));}
function render(){const keepSel=new Set([...document.querySelectorAll('.sel:checked')].map(x=>decodeURIComponent(x.value)));
 const list=visibleNodes();
 const online=NODES.filter(n=>n.online).length;
 document.getElementById('cnt').textContent='· '+online+'/'+NODES.length+' 在线';
 document.getElementById('cnt2').textContent='(显示 '+list.length+'/'+NODES.length+')';
 // 分组下拉选项
 const gf=document.getElementById('groupFilter');const cur=gf.value;
 const groups=[...new Set(NODES.map(n=>n.group).filter(Boolean))].sort();
 if(gf.dataset.sig!==groups.join('|')){gf.dataset.sig=groups.join('|');gf.innerHTML='<option value="">全部分组</option>'+groups.map(g=>'<option value="'+g+'">'+g+'</option>').join('');gf.value=groups.includes(cur)?cur:'';}
 // 面板域名下拉选项
 const hf=document.getElementById('hostFilter');const curH=hf.value;
 const hosts=[...new Set(NODES.map(n=>(n.info.cfg&&n.info.cfg.ApiHost)||'').filter(Boolean))].sort();
 if(hf.dataset.sig!==hosts.join('|')){hf.dataset.sig=hosts.join('|');hf.innerHTML='<option value="">全部面板域名</option>'+hosts.map(h=>'<option value="'+h+'">'+h+'</option>').join('');hf.value=hosts.includes(curH)?curH:'';}
 document.getElementById('tb').innerHTML=list.map(n=>'<tr>'+
 '<td><input type="checkbox" class="sel" value="'+encodeURIComponent(n.key)+'" style="width:14px;height:14px;padding:0"></td>'+
 '<td>'+(n.online?badge('b-ok','在线'):badge('b-bad','离线'))+((n.online&&n.info.svc&&n.info.svc!=='active')?' '+badge('b-warn',n.info.svc==='absent'?'未安装':'服务停止'):'')+'</td>'+
 '<td style="font-weight:500"><a href="#" class="nlink" data-key="'+encodeURIComponent(n.key)+'" data-name="'+encodeURIComponent(n.name)+'" style="color:hsl(var(--info));text-decoration:none" title="单击查看详情 / 双击重命名">'+n.name+'</a>'+(n.renaming?' '+badge('b-info','✏ → '+n.renaming):'')+(n.pendingRename?' '+badge('b-warn','→ '+n.pendingRename):'')+'</td>'+
 '<td>'+(n.group?badge('b-mut',n.group):'-')+'</td>'+
 '<td>'+n.ip+'</td>'+
 '<td>'+(n.info.version?badge('b-mut',n.info.version):'-')+'</td>'+
 '<td>'+(n.info.rss_mb||0)+' MB</td><td>'+(n.info.conns||0)+'</td>'+
 '<td>'+(n.info.warp||'-')+'</td>'+
 '<td>'+fmtCert(n.certDays)+'</td>'+
 '<td class="small"><div class="ellip">'+((n.info.cfg&&n.info.cfg.ApiHost)||'')+'</div>NodeID '+((n.info.cfg&&n.info.cfg.NodeID)||'-')+'</td>'+
 '<td class="small" style="white-space:nowrap">'+fmtTime(n.lastSeen)+'</td>'+
 '<td class="small">'+(n.desired?badge('b-warn','待应用'):'-')+'</td>'+
 '<td>'+fmtAct(n.action)+'</td></tr>').join('');
 document.getElementById('mc').innerHTML=list.map(n=>'<div class="ncard">'+
 '<div class="nrow"><div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;min-width:0">'+
 '<input type="checkbox" class="sel" value="'+encodeURIComponent(n.key)+'" style="width:14px;height:14px;padding:0">'+
 (n.online?badge('b-ok','在线'):badge('b-bad','离线'))+((n.online&&n.info.svc&&n.info.svc!=='active')?' '+badge('b-warn',n.info.svc==='absent'?'未安装':'服务停止'):'')+'<a href="#" class="nlink" data-key="'+encodeURIComponent(n.key)+'" data-name="'+encodeURIComponent(n.name)+'" style="color:inherit;text-decoration:none;font-weight:600;overflow-wrap:anywhere">'+n.name+'</a>'+(n.group?' '+badge('b-mut',n.group):'')+
 (n.renaming?' '+badge('b-info','✏ → '+n.renaming):'')+(n.pendingRename?' '+badge('b-warn','→ '+n.pendingRename):'')+
 '<button class="btn btn-ghost btn-sm renbtn" data-key="'+encodeURIComponent(n.key)+'" data-name="'+encodeURIComponent(n.name)+'" title="重命名">改名</button></div>'+fmtAct(n.action)+'</div>'+
 '<div class="ngrid"><span class="k">IP</span><span>'+n.ip+'</span>'+
 '<span class="k">版本</span><span>'+(n.info.version||'-')+'</span>'+
 '<span class="k">内存</span><span>'+(n.info.rss_mb||0)+' MB</span>'+
 '<span class="k">连接</span><span>'+(n.info.conns||0)+'</span>'+
 '<span class="k">WARP</span><span>'+(n.info.warp||'-')+'</span>'+
 '<span class="k">服务</span><span>'+(n.info.svc==='active'?'运行中':(n.info.svc==='absent'?'未安装':(n.info.svc==='inactive'?'已停止':'-')))+'</span>'+
 '<span class="k">证书</span><span>'+fmtCert(n.certDays)+'</span>'+
 '<span class="k">面板</span><span class="ellip">'+((n.info.cfg&&n.info.cfg.ApiHost)||'-')+'</span>'+
 '<span class="k">NodeID</span><span>'+((n.info.cfg&&n.info.cfg.NodeID)||'-')+'</span>'+
 '<span class="k">最后心跳</span><span>'+fmtTime(n.lastSeen)+'</span></div>'+
 (n.desired?'<div class="small" style="margin-top:6px">待下发: '+JSON.stringify(n.desired)+'</div>':'')+
 '</div>').join('');
 document.querySelectorAll('.sel').forEach(x=>{x.checked=keepSel.has(decodeURIComponent(x.value));});
 const all=[...document.querySelectorAll('.sel')];
 const sa=document.getElementById('selAll');if(sa)sa.checked=all.length>0&&all.every(x=>x.checked);}
let AUTO=true;let pollTimer=null;
function pollMs(){const inflight=NODES.some(n=>n.action&&(n.action.status==='queued'||n.action.status==='delivered'));return inflight?3000:5000;}
async function refresh(){try{const d=await api('/api/nodes');if(!d.nodes)return;NODES=d.nodes||[];
 document.getElementById('sNodeToken').value=d.nodeToken||'';
 document.getElementById('joinCmd').value='bash <(curl -fsSL https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-join.sh) "'+location.origin+'" "'+(d.nodeToken||'')+'"';
 if(document.getElementById('sUpdateVer')!==document.activeElement)document.getElementById('sUpdateVer').value=d.updateVersion||'';
 if(document.getElementById('sAgentVer')!==document.activeElement)document.getElementById('sAgentVer').value=d.agentVersion||'';
 if(document.getElementById('sTgBot')!==document.activeElement)document.getElementById('sTgBot').value=d.tgBotToken||'';
 if(document.getElementById('sTgChat')!==document.activeElement)document.getElementById('sTgChat').value=d.tgChatId||'';
 if(document.getElementById('sWebhook')!==document.activeElement)document.getElementById('sWebhook').value=d.webhookUrl||'';
 render();
 const inflight=NODES.some(n=>n.action&&(n.action.status==='queued'||n.action.status==='delivered'));
 document.getElementById('lastRefresh').textContent='上次刷新 '+new Date().toLocaleTimeString()+(inflight&&AUTO?' · ⚡ 任务执行中 3s 快速轮询':'');}catch(e){}}
function sparkline(series,color){if(!series||series.length<2)return '<div class="muted">数据收集中...</div>';
 const w=460,h=90,p=4;const vals=series.map(s=>s.v);const max=Math.max(...vals,1);const min=Math.min(...vals,0);
 const pts=series.map((s,i)=>(p+i*(w-2*p)/(series.length-1)).toFixed(1)+','+(h-p-((s.v-min)/(max-min||1))*(h-2*p)).toFixed(1)).join(' ');
 return '<svg viewBox="0 0 '+w+' '+h+'" style="width:100%;height:'+h+'px;background:hsl(var(--muted));border-radius:6px">'+
 '<polyline points="'+pts+'" fill="none" stroke="'+color+'" stroke-width="2"/></svg>';}
function renameNode(keyEnc,cur){const key=decodeURIComponent(keyEnc);
 uiPrompt('重命名节点（1-64 字符，禁用 | 和路径分隔符；将迁移全部历史数据，约 2 分钟生效）',cur,function(v){
  const nn=(v||'').trim();
  if(!nn||nn===cur)return;
  api('/api/rename',{key,newName:nn}).then(d=>{
   if(d.error){show('被拒绝: '+d.error);return;}
   show('✓ 重命名已下发: '+cur+' → '+d.newName+'（等节点心跳应用，≤2 分钟）');});});}
async function showNode(keyEnc){const key=decodeURIComponent(keyEnc);
 const d=await api('/api/node_detail?key='+encodeURIComponent(key));
 if(d.error){show('加载失败: '+d.error);return;}
 const m=d.metrics||{};const recent=(m.recent||[]).map(s=>({v:s.rss}));
 const conns=(m.recent||[]).map(s=>({v:s.c}));
 const evs=(d.events||[]).map(e=>'<li><span class="muted">'+new Date(e.t).toLocaleString()+'</span> — '+e.text+'</li>').join('');
 showModal('📊 '+d.name+(d.group?' ['+d.group+']':''), [
  'IP '+d.ip+' · 版本 '+(d.info.version||'-')+' · Agent v'+(d.agentVer||'-')+' · 证书 '+fmtCert(d.certDays)+' · 服务 '+(d.info.svc==='active'?'运行中':(d.info.svc==='absent'?'未安装':(d.info.svc==='inactive'?'已停止':'未知'))),
  '<b>内存趋势（近 3 小时）</b>'+sparkline(recent,'hsl(217 91% 60%)'),
  '<b>连接数趋势</b>'+sparkline(conns,'hsl(142 76% 44%)'),
  (evs?'<b>近期事件</b><ul style="margin:4px 0">'+evs+'</ul>':'<div class="muted">暂无事件</div>')
 ], '指标每 2 分钟采集一次：近 3 小时明细 + 7 天降采样');}
async function showAudit(){const d=await api('/api/audit');
 const aud=(d.audit||[]).map(a=>'<li><span class="muted">'+new Date(a.t).toLocaleString()+'</span> — <b>'+a.act+'</b> '+a.detail+'</li>').join('');
 const evs=(d.events||[]).map(e=>'<li><span class="muted">'+new Date(e.t).toLocaleString()+'</span> — '+e.text+'</li>').join('');
 showModal('📜 审计与事件', [
  '<b>管理操作审计</b>'+(aud?'<ul style="margin:4px 0">'+aud+'</ul>':'<div class="muted">暂无</div>'),
  '<b>节点事件</b>'+(evs?'<ul style="margin:4px 0">'+evs+'</ul>':'<div class="muted">暂无</div>')
 ], '审计记录管理端全部下发操作；事件记录上下线/证书告警');}
async function setGroup(){const t=targets();if(!t)return;const g=document.getElementById('fGroup').value.trim();
 const d=await api('/api/groups',{targets:t,group:g});show(d.error?('被拒绝: '+d.error):('✓ 已将 '+d.applied+' 台节点分组设为 ['+(d.group||'无')+']'));}
function scheduleRefresh(){if(pollTimer)clearTimeout(pollTimer);pollTimer=setTimeout(()=>{if(AUTO)refresh();scheduleRefresh();},pollMs());}
function toggleAuto(){AUTO=!AUTO;const b=document.getElementById('autoBtn');b.textContent='自动刷新: '+(AUTO?'开':'关');if(AUTO)refresh();}
function targets(){const s=[...document.querySelectorAll('.sel:checked')].map(x=>decodeURIComponent(x.value));if(!s.length){show('请先勾选节点');return null;}return s;}
function gather(){const f={};for(const [id,k] of [['fApiHost','ApiHost'],['fApiKey','ApiKey'],['fNodeId','NodeID'],['fDomain','CertDomain'],['fWarp','Warp']]){const v=document.getElementById(id).value.trim();if(v)f[k]=v;}
 if(f.NodeID&&!/^\\d+$/.test(f.NodeID)){show('NodeID 必须为数字');return null;}return f;}
async function sendDesired(){const t=targets();if(!t)return;const f=gather();if(!f)return;if(!Object.keys(f).length){show('请至少填写一个字段');return;}
 const d=await api('/api/desired',{targets:t,fields:f});
 if(d.error){show('被拒绝: '+d.error);return;}
 showModal('已写入期望配置到 '+d.applied+' 台节点', [
   '下发内容: '+JSON.stringify(d.fields),
   '执行时机: 每台节点下一次心跳（≤2 分钟）',
   '执行规则: 与节点当前配置一致则跳过；有差异才修改并自动重启'
 ], '完成后「待下发」列清空即代表已应用；列表自动刷新');}
async function sendDesiredAll(){const f=gather();if(!f)return;if(!Object.keys(f).length){show('请至少填写一个字段');return;}
 const d=await api('/api/desired',{targets:'all',fields:f});
 if(d.error){show('被拒绝: '+d.error);return;}
 showModal('已写入期望配置到全部 '+d.applied+' 台节点', [
   '下发内容: '+JSON.stringify(d.fields),
   '执行时机: 每台节点下一次心跳（≤2 分钟）',
   '执行规则: 与节点当前配置一致则跳过；有差异才修改并自动重启'
 ], '完成后「待下发」列清空即代表已应用');}
async function doAction(a){const t=targets();if(!t)return;
 const ver=document.getElementById('sUpdateVer').value.trim();
 if(!await uiConfirmP(a==='update'?('确认升级选中节点？'+(ver?('（锁定版本 '+ver+'）'):'（最新版）')):'确认重启选中节点？'))return;
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
   '状态流转: ⏳ 排队中 → 🔄 已下发(等心跳) → ✅ 已完成<br>页面自动刷新，有任务时 3 秒一次');}
async function clearDesired(){const t=targets();if(!t)return;await api('/api/desired/clear',{targets:t});show('已清除期望配置');}
async function saveSettings(){const v=document.getElementById('sUpdateVer').value.trim();
 const d=await api('/api/settings',{updateVersion:v,
  agentVersion:document.getElementById('sAgentVer').value.trim(),
  tgBotToken:document.getElementById('sTgBot').value.trim(),
  tgChatId:document.getElementById('sTgChat').value.trim(),
  webhookUrl:document.getElementById('sWebhook').value.trim()});
 show(d.error?('被拒绝: '+d.error):('✓ 设置已保存（'+(d.error?'':(v?'版本锁定 '+v:'最新版')+' / Agent '+(document.getElementById('sAgentVer').value.trim()||'关闭自更新')+' / 告警通道已更新）')));}
function copyJoin(){const v=document.getElementById('joinCmd').value;
 if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(v).then(()=>show('✓ 对接脚本已复制到剪贴板')).catch(()=>{fallbackCopy(v);show('✓ 对接脚本已复制到剪贴板');});}
 else{fallbackCopy(v);show('✓ 对接脚本已复制到剪贴板');}}
function fallbackCopy(v){const i=document.getElementById('joinCmd');i.focus();i.select();document.execCommand('copy');}
function showModal(title,lines,foot){
 document.getElementById('modalBox').innerHTML='<h3>'+title+'</h3><ul>'+lines.map(l=>'<li>'+l+'</li>').join('')+'</ul><div class="foot">'+foot+'</div><button class="btn btn-primary" id="modalOk" style="margin-top:12px">知道了</button>';
 document.getElementById('modalOk').onclick=function(){document.getElementById('modal').classList.remove('show');};
 document.getElementById('modal').classList.add('show');}
// 页面内输入/确认弹窗：不依赖 prompt/confirm（内嵌浏览器不支持会直接抛错，导致功能失效）
function uiPrompt(title,defVal,cb){
 const esc=String(defVal==null?'':defVal).split('&').join('&amp;').split('"').join('&quot;');
 document.getElementById('modalBox').innerHTML='<h3>'+title+'</h3><input id="uiIn" style="width:100%;margin:10px 0" value="'+esc+'"><div class="foot">回车确认 · Esc 或「取消」放弃</div><div style="margin-top:12px;display:flex;gap:8px"><button class="btn btn-primary" id="uiOk">确认</button><button class="btn btn-ghost" id="uiCancel">取消</button></div>';
 document.getElementById('modal').classList.add('show');
 const inp=document.getElementById('uiIn');inp.focus();inp.select();
 let done=false;
 function finish(v){if(done)return;done=true;document.getElementById('modal').classList.remove('show');cb(v);}
 document.getElementById('uiOk').onclick=function(){finish(inp.value);};
 document.getElementById('uiCancel').onclick=function(){finish(null);};
 inp.onkeydown=function(e){if(e.key==='Enter'){e.preventDefault();finish(inp.value);}else if(e.key==='Escape'){e.preventDefault();finish(null);}};}
function uiConfirm(title,cb){
 document.getElementById('modalBox').innerHTML='<h3>'+title+'</h3><div style="margin-top:12px;display:flex;gap:8px"><button class="btn btn-primary" id="uiOk">确认</button><button class="btn btn-ghost" id="uiCancel">取消</button></div>';
 document.getElementById('modal').classList.add('show');
 let done=false;
 function finish(v){if(done)return;done=true;document.getElementById('modal').classList.remove('show');cb(v);}
 document.getElementById('uiOk').onclick=function(){finish(true);};
 document.getElementById('uiCancel').onclick=function(){finish(false);};}
function uiConfirmP(title){return new Promise(function(r){uiConfirm(title,r);});}
function show(m){document.getElementById('msg').textContent=m;setTimeout(refresh,800);}
refresh();scheduleRefresh();
// 事件委托: 名称单击=详情抽屉 / 双击=重命名 / ✏按钮=重命名（桌面表格+移动卡片共用，零内联转义）
function wireNodeList(id){var el=document.getElementById(id);
 if(!el||el.dataset.wired)return;el.dataset.wired='1';
 var tmr=null; // 单击延迟 220ms：若期间发生双击则取消详情，避免弹窗叠加
 el.addEventListener('click',function(e){
  var a=e.target.closest('a.nlink');
  if(a){e.preventDefault();if(tmr)clearTimeout(tmr);
   var k=a.dataset.key;tmr=setTimeout(function(){tmr=null;showNode(k);},220);return;}
  var b=e.target.closest('button.renbtn');
  if(b){renameNode(b.dataset.key,decodeURIComponent(b.dataset.name));}});
 el.addEventListener('dblclick',function(e){
  var a=e.target.closest('a.nlink');
  if(a){e.preventDefault();if(tmr){clearTimeout(tmr);tmr=null;}
   renameNode(a.dataset.key,decodeURIComponent(a.dataset.name));}});}
wireNodeList('tb');wireNodeList('mc');
function toggleAll(cb){document.querySelectorAll('.sel').forEach(function(x){x.checked=cb.checked;});}
</script>
</body>
</html>`;

// ---------- 独立登录页（未认证时唯一可见的页面，不泄露任何配置/节点信息） ----------
const LOGIN = `<!DOCTYPE html>
<html lang="zh-CN" class="dark">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>登录 · V2bX 云控中心</title>
<style>
:root{--bg:222 47% 6%;--card:222 40% 10%;--border:217 33% 20%;--fg:210 40% 96%;--muted:215 20% 55%;--primary:217 91% 60%;--radius:10px}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px;
 background:hsl(var(--bg));color:hsl(var(--fg));
 font-family:system-ui,-apple-system,"Segoe UI","Microsoft YaHei",sans-serif}
.box{width:100%;max-width:360px;background:hsl(var(--card));border:1px solid hsl(var(--border));
 border-radius:var(--radius);padding:26px 22px;box-shadow:0 10px 40px rgba(0,0,0,.45)}
h1{margin:0 0 4px;font-size:17px;font-weight:600;text-align:center}
p.sub{margin:0 0 18px;font-size:12px;color:hsl(var(--muted));text-align:center}
label{display:block;font-size:12px;color:hsl(var(--muted));margin-bottom:6px}
input{width:100%;height:38px;padding:0 10px;border-radius:8px;background:transparent;color:inherit;
 border:1px solid hsl(var(--border));font-size:14px;outline:none}
input:focus{border-color:hsl(var(--primary))}
button{width:100%;height:38px;margin-top:14px;border:0;border-radius:8px;cursor:pointer;
 background:hsl(var(--primary));color:#fff;font-size:14px;font-weight:500}
button:disabled{opacity:.6;cursor:default}
#err{min-height:16px;margin-top:10px;font-size:12px;color:#f87171;text-align:center}
</style>
</head>
<body>
<form class="box" id="f" autocomplete="off">
 <h1>V2bX 云控中心</h1>
 <p class="sub">请输入管理 Token 登录</p>
 <label for="t">管理 Token</label>
 <input id="t" type="password" autocomplete="current-password" autofocus>
 <button id="b" type="submit">登 录</button>
 <div id="err"></div>
</form>
<script>
document.getElementById('f').addEventListener('submit',function(e){
 e.preventDefault();
 var b=document.getElementById('b'),err=document.getElementById('err'),v=document.getElementById('t').value;
 if(!v){err.textContent='请输入 Token';return;}
 b.disabled=true;err.textContent='';
 fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},credentials:'same-origin',body:JSON.stringify({token:v})})
  .then(function(r){return r.json().catch(function(){return{};}).then(function(j){return{ok:r.ok,status:r.status,j:j};});})
  .then(function(res){
    if(res.ok){location.href='/';return;}
    err.textContent=(res.j&&res.j.error)||('登录失败 ('+res.status+')');
    b.disabled=false;document.getElementById('t').select();
  })
  .catch(function(){err.textContent='网络错误，请重试';b.disabled=false;});
});
</script>
</body>
</html>`;

// ---------- 会话（服务端 Cookie，HttpOnly；管理端 API 支持会话或 X-Token 两种凭证） ----------
const SESSIONS = new Map(); // sid -> { exp }
const SESSION_TTL = 12 * 3600 * 1000;
const SESSION_COOKIE = 'v2bx_sess';
function parseCookie(req, name) {
  const raw = req.headers.cookie || '';
  for (const part of raw.split(';')) {
    const i = part.indexOf('=');
    if (i > 0 && part.slice(0, i).trim() === name) return decodeURIComponent(part.slice(i + 1).trim());
  }
  return null;
}
function newSession() {
  const sid = crypto.randomBytes(32).toString('hex');
  SESSIONS.set(sid, { exp: Date.now() + SESSION_TTL });
  if (SESSIONS.size > 50) SESSIONS.delete(SESSIONS.keys().next().value); // 上限保护，淘汰最旧
  return sid;
}
function getSession(req) {
  const sid = parseCookie(req, SESSION_COOKIE);
  if (!sid) return null;
  const s = SESSIONS.get(sid);
  if (!s) return null;
  if (s.exp < Date.now()) { SESSIONS.delete(sid); return null; }
  s.exp = Date.now() + SESSION_TTL; // 滑动续期
  return sid;
}
function setSessionCookie(res, sid) {
  const secure = SCHEME === 'https' ? '; Secure' : '';
  res.setHeader('Set-Cookie', SESSION_COOKIE + '=' + sid + '; Path=/; HttpOnly; SameSite=Strict; Max-Age=' + Math.floor(SESSION_TTL / 1000) + secure);
}
function clearSessionCookie(res) {
  const secure = SCHEME === 'https' ? '; Secure' : '';
  res.setHeader('Set-Cookie', SESSION_COOKIE + '=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0' + secure);
}
// 管理端凭证：有效会话 Cookie，或脚本用的 X-Token 头
function isAuthed(req) {
  if (getSession(req)) return true;
  const t = req.headers['x-token'];
  return t ? safeEqual(t, data.token) : false;
}
// HTML 响应统一安全头：禁止被嵌套、禁嗅探、不泄露来源
function sendHtml(res, code, html) {
  res.writeHead(code, {
    'Content-Type': 'text/html; charset=utf-8',
    'Cache-Control': 'no-store',
    'X-Frame-Options': 'DENY',
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer'
  });
  res.end(html);
}

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
  // v3 迁移: P0/P1 新字段
  if (!d.agentVersion) d.agentVersion = '';
  if (!d.tgBotToken) d.tgBotToken = '';
  if (!d.tgChatId) d.tgChatId = '';
  if (!d.webhookUrl) d.webhookUrl = '';
  if (!d.audit) d.audit = [];
  if (!d.events) d.events = [];
  return d;
}
function saveData(d) {
  fs.writeFileSync(DATA_FILE, JSON.stringify(d, null, 2));
}
let data = loadData();
saveData(data);

// ---------- 通知（Telegram / Webhook，零依赖异步发送） ----------
function notify(text) {
  const stamp = new Date().toISOString().replace('T', ' ').slice(0, 19);
  const body = '[' + stamp + '] ' + text;
  try {
    if (data.tgBotToken && data.tgChatId) {
      const payload = JSON.stringify({ chat_id: data.tgChatId, text: body });
      const rq = https.request({
        hostname: 'api.telegram.org',
        path: '/bot' + data.tgBotToken + '/sendMessage',
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
        timeout: 8000
      }, () => {});
      rq.on('error', () => {});
      rq.on('timeout', () => rq.destroy());
      rq.end(payload);
    }
    if (data.webhookUrl && /^https?:\/\//.test(data.webhookUrl)) {
      const u = new URL(data.webhookUrl);
      const payload = JSON.stringify({ text: body });
      const rq = https.request({
        hostname: u.hostname, port: u.port || 443, path: u.pathname + u.search, method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
        timeout: 8000
      }, () => {});
      rq.on('error', () => {});
      rq.on('timeout', () => rq.destroy());
      rq.end(payload);
    }
  } catch (e) {}
}

// ---------- 审计日志 ----------
function audit(act, detail) {
  data.audit.unshift({ t: Date.now(), act, detail: String(detail).slice(0, 300) });
  if (data.audit.length > 200) data.audit.length = 200;
}

// ---------- 事件 ----------
function addEvent(nodeName, type, text) {
  const ev = { t: Date.now(), node: nodeName, type, text: String(text).slice(0, 200) };
  data.events.unshift(ev);
  if (data.events.length > 200) data.events.length = 200;
  return ev;
}

// ---------- 指标历史（近 3h 明细 + 7 天 30min 降采样） ----------
function pushMetrics(rec, rss, conns) {
  const now = Date.now();
  rec.metrics = rec.metrics || { recent: [], daily: [] };
  const m = rec.metrics;
  m.recent.push({ t: now, rss: rss || 0, c: conns || 0 });
  while (m.recent.length && m.recent[0].t < now - 3 * 3600 * 1000) m.recent.shift();
  if (m.recent.length > 120) m.recent.shift();
  const last = m.daily.length ? m.daily[m.daily.length - 1] : null;
  if (!last || now - last.t >= 30 * 60 * 1000) {
    m.daily.push({ t: now, rss: rss || 0, c: conns || 0 });
    while (m.daily.length && m.daily[0].t < now - 7 * 86400 * 1000) m.daily.shift();
  }
}

// ---------- 每日自动备份 cloud-data.json（保留 7 份） ----------
const BACKUP_DIR = path.join(__dirname, 'backups');
let lastBackupDay = '';
function backupDaily() {
  const day = new Date().toISOString().slice(0, 10);
  if (day === lastBackupDay) return;
  lastBackupDay = day;
  try {
    fs.mkdirSync(BACKUP_DIR, { recursive: true });
    fs.copyFileSync(DATA_FILE, path.join(BACKUP_DIR, 'cloud-data-' + day + '.json'));
    const files = fs.readdirSync(BACKUP_DIR).filter(f => f.startsWith('cloud-data-')).sort();
    while (files.length > 7) fs.unlinkSync(path.join(BACKUP_DIR, files.shift()));
  } catch (e) {}
}
backupDaily();
setInterval(backupDaily, 3600 * 1000);

// ---------- 离线检测巡检（60s，状态翻转时事件+通知） ----------
setInterval(() => {
  const now = Date.now();
  let changed = false;
  for (const [, n] of Object.entries(data.nodes)) {
    const online = now - n.lastSeen < 5 * 60 * 1000;
    if (!online && !n.offlineNotified && n.created && now - n.created > 5 * 60 * 1000) {
      n.offlineNotified = true;
      const ev = addEvent(n.name, 'offline', '节点离线（超过 5 分钟无心跳）');
      notify('🔴 [' + n.name + '] ' + ev.text);
      changed = true;
    }
  }
  if (changed) saveData(data);
  // 会话过期清理（避免内存里堆积失效会话）
  const t = Date.now();
  for (const [sid, s] of SESSIONS) if (s.exp < t) SESSIONS.delete(sid);
}, 60 * 1000);

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

  // ---------- 登录页 / 后台页面（服务端会话鉴权：未登录时只返回登录页，不输出任何面板内容） ----------
  if (url === '/login') {
    if (isAuthed(req)) { res.writeHead(302, { Location: '/' }); res.end(); return; }
    return sendHtml(res, 200, LOGIN);
  }
  if (url === '/favicon.ico') { res.writeHead(204); res.end(); return; }
  if (url === '/' || url === '/ui') {
    // 便捷入口: /?token=xxx 校验通过 → 写入会话 Cookie 并跳转到干净 URL（Token 不留在地址栏与历史记录里）
    const qToken = new URLSearchParams(req.url.split('?')[1] || '').get('token');
    if (qToken) {
      if (!defaultTokenBlocked() && safeEqual(qToken, data.token)) {
        setSessionCookie(res, newSession());
        res.writeHead(302, { Location: '/' }); res.end(); return;
      }
      res.writeHead(302, { Location: '/login' }); res.end(); return;
    }
    if (!isAuthed(req)) { res.writeHead(302, { Location: '/login' }); res.end(); return; }
    return sendHtml(res, 200, UI);
  }
  // 登录 / 登出（登录失败按 IP 限速，错误信息不区分「Token 不存在」与「Token 错误」）
  if (url === '/api/login' && req.method === 'POST') {
    if (!rateLimit('login:' + ip, 10, 60000)) return json(res, 429, { error: '尝试过于频繁，请稍后再试' });
    const body = await readBody(req);
    const t = String(body.token || '');
    if (!t || !safeEqual(t, data.token)) return json(res, 401, { error: 'Token 错误' });
    if (defaultTokenBlocked()) return json(res, 403, { error: '默认管理 Token 禁止登录：请在服务端修改 cloud-data.json 的 token 后重启' });
    setSessionCookie(res, newSession());
    return json(res, 200, { ok: true });
  }
  if (url === '/api/logout' && req.method === 'POST') {
    const sid = getSession(req);
    if (sid) SESSIONS.delete(sid);
    clearSessionCookie(res);
    return json(res, 200, { ok: true });
  }

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
    let rec = data.nodes[key];
    if (!rec) {
      // 重命名迁移: 心跳带了新名但无记录 → 查找 pendingRename 匹配的旧记录（同 IP + 新名匹配）
      // 迁移保留全部历史: 指标/事件/动作/期望配置/分组/证书天数/创建时间
      for (const [ok, old] of Object.entries(data.nodes)) {
        if (old.pendingRename && old.pendingRename.newName === name && old.ip === ip) {
          rec = old;
          delete data.nodes[ok];
          break;
        }
      }
    }
    if (!rec) rec = { created: Date.now(), desired: null, pendingAction: null };
    const prevSeen = rec.lastSeen || 0; // 真正的上一次心跳时间（必须在更新 lastSeen 之前捕获）
    rec.name = name;
    rec.ip = ip;
    rec.lastSeen = Date.now();
    rec.info = {
      hostname: body.hostname || '', version: body.version || '',
      rss_mb: body.rss_mb || 0, conns: body.conns || 0,
      uptime_sec: body.uptime_sec || 0, warp: body.warp || 'unknown',
      svc: body.svc || '', cfg: body.cfg || {}, load: body.load || ''
    };
    // 服务健康告警: agent 在线但 V2bX 未运行/未安装（agent v8 起上报 svc）
    const svc = rec.info.svc;
    if (svc && svc !== 'active') {
      if (rec.svcWarn !== svc) {
        rec.svcWarn = svc;
        const txt = svc === 'absent' ? 'V2bX 未安装（仅 agent 在线）' : 'V2bX 服务未运行（agent 在线）';
        const ev = addEvent(rec.name, 'service', txt);
        notify('🔴 [' + rec.name + '] ' + ev.text);
      }
    } else if (svc === 'active' && rec.svcWarn) {
      rec.svcWarn = null;
      const ev = addEvent(rec.name, 'service', 'V2bX 服务已恢复运行');
      notify('🟢 [' + rec.name + '] ' + ev.text);
    }
    // 恢复在线事件（此前被巡检标记为离线）
    if (rec.offlineNotified) {
      rec.offlineNotified = false;
      const ev = addEvent(rec.name, 'online', '节点恢复在线');
      notify('🟢 [' + rec.name + '] ' + ev.text);
    }
    // 指标历史入库
    pushMetrics(rec, rec.info.rss_mb, rec.info.conns);
    // agent 版本 + 证书剩余天数
    rec.agentVer = String(body.agentVer || '');
    if (body.certDays !== undefined && body.certDays !== null && body.certDays !== '') {
      const cd = Number(body.certDays);
      if (Number.isFinite(cd)) {
        rec.certDays = cd;
        const level = cd <= 7 ? 3 : cd <= 14 ? 2 : cd <= 21 ? 1 : 0;
        const prevLevel = rec.certWarnLevel || 0;
        if (level > prevLevel && level > 0) {
          const dom = (rec.info.cfg && rec.info.cfg.CertDomain) || '';
          const ev = addEvent(rec.name, 'cert', '证书 ' + dom + ' 剩余 ' + cd + ' 天');
          notify('⚠️ [' + rec.name + '] ' + ev.text);
          rec.certWarnLevel = level;
        } else if (level === 0 && prevLevel > 0) {
          rec.certWarnLevel = 0; // 已续期，静默重置
        }
      }
    }
    const pending = rec.pendingAction;
    const reply = { desired: rec.desired || null, action: pending || 'none' };
    if (pending === 'update') reply.version = data.updateVersion || '';
    // 重命名下发: pendingRename 携带新名，agent 应用后以 appliedRename 确认
    if (rec.pendingRename && rec.pendingRename.newName) reply.desiredName = rec.pendingRename.newName;
    // agent 自更新: 服务端设定版本与节点上报版本不一致时下发
    rec.agentVer = String(body.agentVer || '');
    if (data.agentVersion && rec.agentVer !== String(data.agentVersion)) reply.agentUpdate = '1';
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
    // 重命名确认: agent 上报 appliedRename（rename:旧名）→ 迁移生效，清除 pendingRename
    if (body.appliedRename && String(body.appliedRename).startsWith('rename:') && rec.pendingRename) {
      const oldName = String(body.appliedRename).slice(7);
      audit('rename-applied', '节点重命名生效: ' + oldName + ' → ' + name);
      addEvent(rec.name, 'rename', '节点重命名: ' + oldName + ' → ' + name);
      rec.pendingRename = null;
    }
    data.nodes[key] = rec;
    saveData(data);
    return json(res, 200, reply);
  }

  // ---------- 管理接口（会话 Cookie 或脚本用 X-Token；失败限速 + 默认 Token 门禁） ----------
  if (!isAuthed(req)) {
    if (!rateLimit('fail:' + ip, 10, 60000)) return json(res, 429, { error: 'rate limited' });
    return json(res, 401, { error: 'unauthorized' });
  }
  if (defaultTokenBlocked()) {
    return json(res, 403, { error: '默认管理 Token 禁止使用：请编辑 cloud-data.json 将 token 与 nodeToken 改为随机强串后重启本进程（开发调试可用 ALLOW_INSECURE_TOKEN=1 临时绕过）' });
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
      group: n.group || '', certDays: (n.certDays === undefined ? null : n.certDays),
      agentVer: n.agentVer || '',
      renaming: n.pendingRename ? n.pendingRename.newName : null,
      desired: n.desired || null, action: effAction(n)
    })).sort((a, b) => (a.online === b.online) ? a.name.localeCompare(b.name) : (a.online ? -1 : 1));
    return json(res, 200, {
      token: data.token, nodeToken: data.nodeToken, updateVersion: data.updateVersion,
      agentVersion: data.agentVersion, groups: [...new Set(Object.values(data.nodes).map(n => n.group).filter(Boolean))],
      nodes: list
    });
  }

  if (url === '/api/node_detail' && req.method === 'GET') {
    const key = decodeURIComponent((req.url.split('?')[1] || '').match(/key=([^&]+)/) ? req.url.split('?')[1].match(/key=([^&]+)/)[1] : '');
    const n = data.nodes[key];
    if (!n) return json(res, 404, { error: 'not found' });
    return json(res, 200, {
      name: n.name, ip: n.ip, group: n.group || '', certDays: (n.certDays === undefined ? null : n.certDays),
      agentVer: n.agentVer || '', info: n.info,
      metrics: n.metrics || { recent: [], daily: [] },
      events: (n.events || []).slice(0, 30),
      action: n.action || null
    });
  }

  if (url === '/api/audit' && req.method === 'GET') {
    return json(res, 200, { audit: (data.audit || []).slice(0, 100), events: (data.events || []).slice(0, 100) });
  }

  if (url === '/api/groups' && req.method === 'POST') {
    const body = await readBody(req);
    const g = String(body.group || '').trim().slice(0, 24);
    let count = 0;
    for (const [key, n] of Object.entries(data.nodes)) {
      if (body.targets === 'all' || (body.targets || []).includes(key)) { n.group = g; count++; }
    }
    audit('group', '设置分组 [' + (g || '无') + '] 到 ' + count + ' 台节点');
    saveData(data);
    return json(res, 200, { ok: true, applied: count, group: g });
  }

  if (url === '/api/rename' && req.method === 'POST') {
    const body = await readBody(req);
    const key = String(body.key || '');
    const newName = String(body.newName || '').trim();
    const n = data.nodes[key];
    if (!n) return json(res, 404, { error: '节点不存在' });
    if (!newName || newName.length > 64) return json(res, 400, { error: '名称长度需为 1-64 字符' });
    if (/[|]/.test(newName)) return json(res, 400, { error: '名称不能包含 | 字符' });
    if (/[\/\\]/.test(newName)) return json(res, 400, { error: '名称不能包含路径分隔符' });
    if (newName === n.name) return json(res, 400, { error: '名称未变化' });
    const newKey = newName + '|' + n.ip;
    if (data.nodes[newKey]) return json(res, 400, { error: '该名称已被同 IP 节点使用' });
    // 身份键迁移: 心跳键是 name|ip，直接改名会分裂记录 —— 走 pendingRename 流程
    // agent 收到 desiredName 应用后，下次心跳以新名上报，服务端凭 appliedRename 迁移全部历史
    n.pendingRename = { oldKey: key, newName, requestedAt: Date.now() };
    audit('rename', '节点重命名: ' + n.name + ' → ' + newName + '（等 agent 应用）');
    saveData(data);
    return json(res, 200, { ok: true, newName });
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
    audit('desired', '下发配置 ' + JSON.stringify(fields) + ' 到 ' + count + ' 台节点');
    saveData(data);
    return json(res, 200, { ok: true, applied: count, fields });
  }

  if (url === '/api/desired/clear' && req.method === 'POST') {
    const body = await readBody(req);
    let count = 0;
    for (const [key, n] of Object.entries(data.nodes)) {
      if (body.targets === 'all' || (body.targets || []).includes(key)) { n.desired = null; count++; }
    }
    audit('desired-clear', '清除 ' + count + ' 台节点的期望配置');
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
    audit('action', '排队动作 [' + act + (act === 'update' && data.updateVersion ? ' ' + data.updateVersion : '') + '] 到 ' + count + ' 台节点');
    saveData(data);
    return json(res, 200, { ok: true, queued: count, action: act, version: act === 'update' ? (data.updateVersion || '') : undefined });
  }

  if (url === '/api/settings' && req.method === 'POST') {
    const body = await readBody(req);
    const changes = [];
    if (body.updateVersion !== undefined) {
      const v = String(body.updateVersion).trim();
      if (v && !/^v[0-9][\w.\-]*$/.test(v)) return json(res, 400, { error: '版本号格式非法（示例: v1.0.9）' });
      data.updateVersion = v; changes.push('升级版本锁定=' + (v || '无'));
    }
    if (body.newNodeToken && String(body.newNodeToken).length >= 16) {
      data.nodeToken = String(body.newNodeToken); changes.push('nodeToken 已更换');
    }
    if (body.tgBotToken !== undefined) { data.tgBotToken = String(body.tgBotToken).trim(); changes.push('TG Bot Token 已更新'); }
    if (body.tgChatId !== undefined) { data.tgChatId = String(body.tgChatId).trim(); changes.push('TG ChatID 已更新'); }
    if (body.webhookUrl !== undefined) { data.webhookUrl = String(body.webhookUrl).trim(); changes.push('Webhook 已更新'); }
    if (body.agentVersion !== undefined) {
      const av = String(body.agentVersion).trim();
      if (av && !/^[0-9]+$/.test(av)) return json(res, 400, { error: 'agentVersion 必须为数字版本号' });
      data.agentVersion = av; changes.push('Agent 目标版本=' + (av || '关闭自更新'));
    }
    audit('settings', changes.join('; ') || '无变更');
    saveData(data);
    return json(res, 200, { ok: true, nodeToken: data.nodeToken, updateVersion: data.updateVersion, agentVersion: data.agentVersion });
  }

  if (url === '/api/token' && req.method === 'POST') {
    const body = await readBody(req);
    if (body.newToken && String(body.newToken).length >= 16) { data.token = String(body.newToken); saveData(data); return json(res, 200, { ok: true }); }
    return json(res, 400, { error: 'token too short (>=16)' });
  }

  json(res, 404, { error: 'not found' });
};

// ---------- 启动自检: 内联脚本必须能被浏览器解析 ----------
// 模板字面量里的 \n 等转义会被 Node 提前消化，可能在页面字符串里留下裸换行，
// 导致整段内联 JS 变成 SyntaxError（表现为"函数全部未定义"）。此处逐个解析，坏了一律拒绝启动。
(function selfCheckInlineScripts() {
  for (const [name, html] of [['UI', UI], ['LOGIN', LOGIN]]) {
    const m = html.match(/<script>([\s\S]*?)<\/script>/);
    if (!m) { console.error('!! ' + name + ' 自检失败: 未找到内联 <script> 块'); process.exit(1); }
    try {
      new Function(m[1]);
    } catch (e) {
      console.error('!! ' + name + ' 内联脚本语法错误，拒绝启动: ' + e.message);
      process.exit(1);
    }
  }
})();

// ---------- TLS 可选: 设置 TLS_CERT/TLS_KEY 环境变量后以 HTTPS 监听（自签证书场景） ----------
const TLS_CERT = process.env.TLS_CERT || '';
const TLS_KEY = process.env.TLS_KEY || '';
const net = require('net');
const tls = require('tls');
let server;
let SCHEME = 'http';
if (TLS_CERT && TLS_KEY && fs.existsSync(TLS_CERT) && fs.existsSync(TLS_KEY)) {
  const https = require('https');
  const cert = fs.readFileSync(TLS_CERT);
  const key = fs.readFileSync(TLS_KEY);
  const tlsServer = https.createServer({ cert, key }, handler);
  const secureCtx = tls.createSecureContext({ cert, key });
  // 同端口双协议: 首字节 0x16 = TLS 握手 → 交回 https 服务器；否则视为明文 HTTP → 301 跳到 https
  // 这样用户误用 http:// 访问时不会再"连不上"，而是自动跳转到加密地址
  server = net.createServer((socket) => {
    socket.on('error', () => socket.destroy());
    socket.once('data', (chunk) => {
      socket.pause();
      if (chunk[0] === 0x16) {
        socket.unshift(chunk);
        tlsServer.emit('connection', socket);
        process.nextTick(() => socket.resume());
        return;
      }
      const head = chunk.toString('latin1');
      const reqLine = head.split('\r\n')[0] || '';
      const m = reqLine.match(/^[A-Z]+\s+(\S+)/);
      const hostHdr = (head.match(/^host:\s*([^\r\n]+)/im) || [])[1];
      const host = (hostHdr || '').trim() || (socket.localAddress || '') + ':' + PORT;
      const path = m ? m[1] : '/';
      socket.end('HTTP/1.1 301 Moved Permanently\r\nLocation: https://' + host + path
        + '\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
    });
  });
  server.secureContext = secureCtx; // 保留引用（便于后续需要时复用）
  SCHEME = 'https';
} else {
  if (TLS_CERT || TLS_KEY) console.log('⚠️ TLS_CERT/TLS_KEY 指向的证书文件缺失，回退为 HTTP 明文监听');
  server = http.createServer(handler);
}

server.listen(PORT, () => {
  console.log('V2bX 云控中心已启动: ' + SCHEME + '://0.0.0.0:' + PORT + (SCHEME === 'https' ? '  (TLS 已启用)' : ''));
  if (SCHEME === 'https') console.log('提示: 用 http:// 访问同一端口会自动 301 跳转到 https://（请务必使用 https 登录）');
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
