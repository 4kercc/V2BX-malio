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
 </div>
</div>

<div id="msg"></div>

<div class="card">
 <p class="card-title">节点列表 <span class="muted" id="cnt2" style="font-weight:400"></span></p>
 <div class="tbwrap">
  <table><thead><tr>
   <th style="width:32px"><input type="checkbox" id="selAll" onchange="toggleAll(this)" style="width:14px;height:14px;padding:0"></th>
   <th>状态</th><th>名称</th><th>IP</th><th>版本</th><th>内存</th><th>连接</th><th>WARP</th><th>面板 / 节点ID</th><th>最后心跳</th><th>待下发</th><th>最近动作</th>
  </tr></thead><tbody id="tb"></tbody></table>
 </div>
 <div class="only-mobile" id="mc"></div>
</div>
</div>

<div class="modal" id="modal">
 <div class="modal-box" id="modalBox"></div>
</div>

<script>
(function(){try{var qs=new URLSearchParams(location.search).get('token');if(qs)localStorage.setItem('cloudToken',qs);}catch(e){}})();
function applyTheme(t){document.documentElement.classList.toggle('dark',t==='dark');
 var b=document.getElementById('themeBtn');if(b)b.textContent=t==='dark'?'🌙':'☀️';}
function toggleTheme(){var t=document.documentElement.classList.contains('dark')?'light':'dark';
 localStorage.setItem('cloudTheme',t);applyTheme(t);}
applyTheme(localStorage.getItem('cloudTheme')||'dark');

const T=localStorage.getItem('cloudToken')||prompt('请输入管理 Token（服务端 cloud-data.json 里的 token 字段）');
localStorage.setItem('cloudToken',T);
let NODES=[];
async function api(p,body){const r=await fetch(p,{method:body?'POST':'GET',headers:{'X-Token':T,'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined});
 const j=await r.json().catch(()=>({}));
 if(r.status===401){alert('Token 错误');localStorage.removeItem('cloudToken');location.reload();return j;}
 if(r.status===403){document.getElementById('msg').textContent=j.error||'被拒绝';}
 return j;}
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
function render(){const keepSel=new Set([...document.querySelectorAll('.sel:checked')].map(x=>decodeURIComponent(x.value)));
 const online=NODES.filter(n=>n.online).length;
 document.getElementById('cnt').textContent='· '+online+'/'+NODES.length+' 在线';
 document.getElementById('cnt2').textContent='';
 document.getElementById('tb').innerHTML=NODES.map(n=>'<tr>'+
 '<td><input type="checkbox" class="sel" value="'+encodeURIComponent(n.key)+'" style="width:14px;height:14px;padding:0"></td>'+
 '<td>'+(n.online?badge('b-ok','在线'):badge('b-bad','离线'))+'</td>'+
 '<td style="font-weight:500">'+n.name+'</td><td>'+n.ip+'</td>'+
 '<td>'+(n.info.version?badge('b-mut',n.info.version):'-')+'</td>'+
 '<td>'+(n.info.rss_mb||0)+' MB</td><td>'+(n.info.conns||0)+'</td>'+
 '<td>'+(n.info.warp||'-')+'</td>'+
 '<td class="small"><div class="ellip">'+((n.info.cfg&&n.info.cfg.ApiHost)||'')+'</div>NodeID '+((n.info.cfg&&n.info.cfg.NodeID)||'-')+'</td>'+
 '<td class="small" style="white-space:nowrap">'+fmtTime(n.lastSeen)+'</td>'+
 '<td class="small">'+(n.desired?badge('b-warn','待应用')+'<div class="small ellip" style="max-width:150px">'+JSON.stringify(n.desired)+'</div>':'-')+'</td>'+
 '<td>'+fmtAct(n.action)+'</td></tr>').join('');
 document.getElementById('mc').innerHTML=NODES.map(n=>'<div class="ncard">'+
 '<div class="nrow"><div style="display:flex;align-items:center;gap:8px">'+
 '<input type="checkbox" class="sel" value="'+encodeURIComponent(n.key)+'" style="width:14px;height:14px;padding:0">'+
 (n.online?badge('b-ok','在线'):badge('b-bad','离线'))+'<b>'+n.name+'</b></div>'+fmtAct(n.action)+'</div>'+
 '<div class="ngrid"><span class="k">IP</span><span>'+n.ip+'</span>'+
 '<span class="k">版本</span><span>'+(n.info.version||'-')+'</span>'+
 '<span class="k">内存</span><span>'+(n.info.rss_mb||0)+' MB</span>'+
 '<span class="k">连接</span><span>'+(n.info.conns||0)+'</span>'+
 '<span class="k">WARP</span><span>'+(n.info.warp||'-')+'</span>'+
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
 render();
 const inflight=NODES.some(n=>n.action&&(n.action.status==='queued'||n.action.status==='delivered'));
 document.getElementById('lastRefresh').textContent='上次刷新 '+new Date().toLocaleTimeString()+(inflight&&AUTO?' · ⚡ 任务执行中 3s 快速轮询':'');}catch(e){}}
function scheduleRefresh(){if(pollTimer)clearTimeout(pollTimer);pollTimer=setTimeout(()=>{if(AUTO)refresh();scheduleRefresh();},pollMs());}
function toggleAuto(){AUTO=!AUTO;const b=document.getElementById('autoBtn');b.textContent='自动刷新: '+(AUTO?'开':'关');if(AUTO)refresh();}
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
 ], '完成后「待下发」列清空即代表已应用；列表自动刷新');}
async function sendDesiredAll(){const f=gather();if(!f||!Object.keys(f).length){alert('请至少填写一个字段');return;}
 const d=await api('/api/desired',{targets:'all',fields:f});
 if(d.error){show('被拒绝: '+d.error);return;}
 showModal('已写入期望配置到全部 '+d.applied+' 台节点', [
   '下发内容: '+JSON.stringify(d.fields),
   '执行时机: 每台节点下一次心跳（≤2 分钟）',
   '执行规则: 与节点当前配置一致则跳过；有差异才修改并自动重启'
 ], '完成后「待下发」列清空即代表已应用');}
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
   '状态流转: ⏳ 排队中 → 🔄 已下发(等心跳) → ✅ 已完成<br>页面自动刷新，有任务时 3 秒一次');}
async function clearDesired(){const t=targets();if(!t)return;await api('/api/desired/clear',{targets:t});show('已清除期望配置');}
async function saveSettings(){const v=document.getElementById('sUpdateVer').value.trim();
 const d=await api('/api/settings',{updateVersion:v});show(d.error?('被拒绝: '+d.error):('设置已保存: 升级版本锁定 = '+(v||'最新版')));}
function copyJoin(){const v=document.getElementById('joinCmd').value;
 if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(v).then(()=>show('✓ 对接脚本已复制到剪贴板')).catch(()=>{fallbackCopy(v);show('✓ 对接脚本已复制到剪贴板');});}
 else{fallbackCopy(v);show('✓ 对接脚本已复制到剪贴板');}}
function fallbackCopy(v){const i=document.getElementById('joinCmd');i.focus();i.select();document.execCommand('copy');}
function showModal(title,lines,foot){
 document.getElementById('modalBox').innerHTML='<h3>'+title+'</h3><ul>'+lines.map(l=>'<li>'+l+'</li>').join('')+'</ul><div class="foot">'+foot+'</div><button class="btn btn-primary" id="modalOk" style="margin-top:12px">知道了</button>';
 document.getElementById('modalOk').onclick=function(){document.getElementById('modal').classList.remove('show');};
 document.getElementById('modal').classList.add('show');}
function show(m){document.getElementById('msg').textContent=m;setTimeout(refresh,800);}
refresh();scheduleRefresh();
</script>
</body>
</html>`;


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
