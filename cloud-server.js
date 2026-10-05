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
.wrap{max-width:none;margin:0;padding:16px}
@media(min-width:768px){.wrap{padding:20px 24px}}
@media(min-width:1600px){.wrap{padding:20px 32px}}
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
.head-r{display:flex;align-items:center;gap:8px;flex-wrap:wrap;justify-content:flex-end}
.tbwrap{overflow-x:auto;border:1px solid hsl(var(--border));border-radius:var(--radius)}
th.sortable{cursor:pointer;user-select:none}
th.sortable:hover{color:hsl(var(--foreground))}
th.sortable .si{font-size:9px;opacity:.8;margin-left:2px}
table{width:100%;border-collapse:collapse;font-size:13px;min-width:1040px}
th{background:hsl(var(--muted));color:hsl(var(--muted-fg));font-weight:500;text-align:left;padding:9px 10px;white-space:nowrap}
td{padding:10px;border-top:1px solid hsl(var(--border));vertical-align:top}
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
.modal-box{background:hsl(var(--card));border:1px solid hsl(var(--border));border-radius:var(--radius);padding:24px;max-width:520px;width:100%;box-shadow:0 16px 48px rgba(0,0,0,.4);max-height:88vh;overflow-y:auto}
.modal-box .sect{margin-bottom:12px}
.modal-box .sect input{width:100%}
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
   <button class="btn btn-outline btn-sm" onclick="showSettings()">⚙ 全局设置</button>
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
  <select id="fG4" title="Google/YouTube 强制 IPv4 出站：改节点 sing_origin.json 的 sing-box 路由（整机生效，会重启 V2bX）。用于 IPv6 出口被 Google 拉黑（搜索跳 /sorry/）的节点；开启后面板媒体检测也同步改用 IPv4 探测">
   <option value="">Google/YT 出口 不变</option>
   <option value="on">Google/YT 强制 IPv4</option>
   <option value="off">恢复默认（不强制）</option>
  </select>
  <select id="fType" title="节点类型（与面板里该节点的类型必须一致；仅支持单台下发）">
   <option value="">节点类型 不变</option>
   <option value="anytls">anytls</option>
   <option value="vless">vless</option>
   <option value="vmess">vmess</option>
   <option value="trojan">trojan</option>
   <option value="shadowsocks">shadowsocks</option>
   <option value="hysteria">hysteria</option>
   <option value="hysteria2">hysteria2</option>
   <option value="tuic">tuic</option>
  </select>
 </div>
 <div class="row">
  <button class="btn btn-primary" onclick="sendDesired()">下发到选中节点</button>
  <button class="btn btn-primary" onclick="sendDesiredAll()">下发到全部节点</button>
  <button class="btn btn-outline" onclick="doAction('restart')">重启选中</button>
  <button class="btn btn-outline" onclick="doAction('update')">升级选中</button>
  <button class="btn btn-ghost" onclick="clearDesired()">清除选中节点的期望配置</button>
  <input id="fGroup" placeholder="分组标签" style="width:140px;height:32px">
  <button class="btn btn-outline btn-sm" onclick="setGroup()">设置选中分组</button>
  <button class="btn btn-outline btn-sm" onclick="deleteNodes()" title="删除选中节点的云控记录（不影响节点上的服务）">🗑 删除选中</button>
  <button class="btn btn-outline btn-sm" onclick="showCert()">🔐 证书到期</button>
  <button class="btn btn-outline btn-sm" onclick="showDups()" title="检查同名不同机 / 同面板同 NodeID 的重复节点">🔍 重复检查</button>
  <button class="btn btn-outline btn-sm" onclick="showMedia()" title="检测 YouTube / ChatGPT / Netflix / Google 拉黑（未勾选则检测全部）">🌐 媒体检测</button>
 </div>
 <p class="muted" style="margin:8px 0 0">节点在下一个心跳周期（≤2 分钟）内自动应用并重启 · Google/YT 强制 IPv4 与 WARP 均为整机改动（同机多节点共用 sing_origin.json，改后整机重启一次 V2bX）</p>
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
  <select id="sortSel" onchange="setSortFromSelect()" style="width:auto;min-width:170px" title="排序方式（表头也可直接点击）">
   <option value="">默认排序（在线优先）</option>
   <option value="ip">按 IP 地址（同 IP 内按 NodeID）</option>
   <option value="nodeid">按面板 NodeID</option>
   <option value="name">按名称</option>
   <option value="panel">按面板域名</option>
   <option value="conns">按连接数</option>
   <option value="rss">按内存</option>
   <option value="cert">按证书剩余</option>
   <option value="seen">按最后心跳</option>
   <option value="group">按分组</option>
   <option value="media">按流媒体解锁数</option>
   <option value="ver">按版本</option>
   <option value="warp">按 WARP</option>
   <option value="desired">按待下发</option>
   <option value="action">按最近动作</option>
   <option value="online">按在线状态</option>
  </select>
  <button class="btn btn-ghost btn-sm" id="sortDirBtn" onclick="toggleSortDir()" title="切换升序/降序">↑ 升序</button>
  <button class="btn btn-ghost btn-sm" onclick="showAudit()">📜 审计 / 事件日志</button>
 </div>
 <div class="tbwrap">
  <table><thead id="tbhead"><tr>
   <th style="width:32px"><input type="checkbox" id="selAll" onchange="toggleAll(this)" style="width:14px;height:14px;padding:0"></th>
   <th class="sortable" data-col="online" onclick="toggleSort('online')">状态<span class="si"></span></th><th class="sortable" data-col="name" onclick="toggleSort('name')">名称<span class="si"></span></th><th class="sortable" data-col="group" onclick="toggleSort('group')">分组<span class="si"></span></th><th class="sortable" data-col="media" onclick="toggleSort('media')" title="流媒体解锁：▶YouTube · G Google · AI ChatGPT · N Netflix（✓可用 ✗不可用 ?受限）">流媒体<span class="si"></span></th><th class="sortable" data-col="ip" onclick="toggleSort('ip')">IP<span class="si"></span></th><th class="sortable" data-col="ver" onclick="toggleSort('ver')">版本<span class="si"></span></th><th class="sortable" data-col="rss" onclick="toggleSort('rss')">内存<span class="si"></span></th><th class="sortable" data-col="conns" onclick="toggleSort('conns')">连接<span class="si"></span></th><th class="sortable" data-col="warp" onclick="toggleSort('warp')">WARP<span class="si"></span></th><th class="sortable" data-col="cert" onclick="toggleSort('cert')">证书<span class="si"></span></th><th class="sortable" data-col="panel" onclick="toggleSort('panel')" title="点击排序: 面板域名 → 节点ID">面板 / 节点ID<span class="si"></span></th><th class="sortable" data-col="seen" onclick="toggleSort('seen')">最后心跳<span class="si"></span></th><th class="sortable" data-col="desired" onclick="toggleSort('desired')">待下发<span class="si"></span></th><th class="sortable" data-col="action" onclick="toggleSort('action')">最近动作<span class="si"></span></th>
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
let SETTINGS={}; // 全局设置缓存（表单在弹窗里，关闭时 DOM 不存在）
// 会话由服务端 Cookie 维护，前端不再持有/传递任何 Token
async function api(p,body){const r=await fetch(p,{method:body?'POST':'GET',headers:{'Content-Type':'application/json'},body:body?JSON.stringify(body):undefined,credentials:'same-origin'});
 const j=await r.json().catch(()=>({}));
 if(r.status===401){location.href='/login';return j;} // 会话失效 → 回登录页
 if(r.status===403){document.getElementById('msg').textContent=j.error||'被拒绝';}
 return j;}
function logout(){fetch('/api/logout',{method:'POST',credentials:'same-origin'}).catch(function(){}).then(function(){location.href='/login';});}
function fmtTime(ts){const s=(Date.now()-ts)/1000;if(s<60)return Math.floor(s)+'秒前';if(s<3600)return Math.floor(s/60)+'分钟前';return Math.floor(s/3600)+'小时前';}
function badge(cls,txt){return '<span class="badge '+cls+'">'+txt+'</span>';}
// HTML 转义: 节点上报的字段(名称/版本/证书域名等)不可信，进 HTML 前一律转义，杜绝存储型 XSS
function esc(s){return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function fmtAct(a){if(!a)return badge('b-mut','-');
 const t=fmtTime(a.queuedAt);
 const ty=esc(a.type);
 if(a.status==='queued')return badge('b-warn','⏳ 排队中')+(a.queuedOffline?'<div class="small" style="color:hsl(var(--bad))">节点离线，上线后执行</div>':'<div class="small">'+ty+' · '+t+'</div>');
 if(a.status==='stuck-offline')return badge('b-bad','⚠️ 节点离线')+'<div class="small">'+ty+' 已下发未确认 · '+t+'</div>';
 if(a.status==='unconfirmed')return badge('b-bad','⚠️ 未确认')+'<div class="small">'+ty+' 心跳异常 · '+t+'</div>';
 if(a.status==='done')return badge('b-ok','✅ 已完成')+(a.inferred?' <span class="small">(推断)</span>':'')+'<div class="small">'+ty+(a.version?' '+esc(a.version):'')+' · '+fmtTime(a.completedAt||a.queuedAt)+'</div>';
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
// 面板域名 → 固定颜色（按域名哈希），让不同来源一眼可分
function panelTag(n){const h=(n.info&&n.info.cfg&&n.info.cfg.ApiHost)||'';
 if(!h)return '<span class="muted">未接入</span>';
 const s=h.replace(/^https?:[/][/]/,'').replace(/[/]+$/,'');
 let hue=0;for(let i=0;i<s.length;i++)hue=(hue*31+s.charCodeAt(i))%360;
 return '<span class="badge" style="background:hsl('+hue+' 55% 42%);color:#fff">'+escAttr(s)+'</span> ';}
// 重复节点检测:
//   1) 同名 + 同面板 → 疑似真重复（同一面板节点被两台机器服务）
//   2) 同名 + 不同面板 → 仅重名（各自服务各自面板，无需处理，只提示）
//   3) 同面板 + 同 NodeID 落在多台机器 → 疑似真重复
// 说明: ApiHost 为 127.0.0.1/localhost 时是"各机器自己的本地面板"，不算重复
function dupMaps(){
 const byName={},byPanel={};
 NODES.forEach(function(n){
  (byName[n.name]=byName[n.name]||[]).push(n);
  const c=n.info.cfg||{},host=c.ApiHost||'',nid=c.NodeID||'';
  if(host&&nid&&!/^https?:[/][/](127[.]0[.]0[.]1|localhost)(:|[/]|$)/.test(host)){
   const k=host+'#'+nid;(byPanel[k]=byPanel[k]||[]).push(n);
  }
 });
 const multi=function(o){return Object.entries(o).filter(function(e){return new Set(e[1].map(function(n){return n.ip;})).size>1;});};
 const nameAll=multi(byName);
 const real=nameAll.filter(function(e){
  const hosts=new Set(e[1].map(function(n){return (n.info.cfg&&n.info.cfg.ApiHost)||'';}));
  return hosts.size===1;
 });
 const same=nameAll.filter(function(e){return real.indexOf(e)<0;});
 return {realDups:real,nameOnly:same,panelDups:multi(byPanel)};
}
function dupInfo(n,maps){
 const hitReal=maps.realDups.filter(function(e){return e[0]===n.name;});
 const c=n.info.cfg||{};
 const hitPanel=maps.panelDups.filter(function(e){return e[0]===((c.ApiHost||'')+'#'+(c.NodeID||''));});
 const hitSame=maps.nameOnly.filter(function(e){return e[0]===n.name;});
 const ips=[],src=[].concat(hitReal,hitPanel,hitSame);
 src.forEach(function(e){e[1].forEach(function(x){if(x.ip!==n.ip&&ips.indexOf(x.ip)<0)ips.push(x.ip);});});
 if(!ips.length)return null;
 return {kind:(hitReal.length||hitPanel.length)?'dup':'same',ips:ips};
}
// 节点类型标记: 本项目为 AnyTLS 专用构建，非 anytls 类型标黄提示（可能是装错或面板类型不匹配）
function typeTag(n){const t=(n.info.cfg&&n.info.cfg.NodeType)||'';if(!t)return '';
 return /^anytls$/i.test(t)
  ? '<span class="badge b-mut" style="font-size:10px">anytls</span>'
  : '<span class="badge b-warn" style="font-size:10px" title="非 anytls 类型：若面板里该节点类型不是它，会导致节点无法正常服务">'+esc(t)+'</span>';}
// Google 拉黑标记（媒体检测结果）: 列表里直接可见
// ---------- 流媒体解锁: 列表内联图标（2×2 固定宽度网格，右列对齐；失败标原因 ✗(403)/✗(拉黑)） ----------
var OPENAI_PATH='M22.282 9.821a6 6 0 0 0-.516-4.91a6.05 6.05 0 0 0-6.51-2.9A6.065 6.065 0 0 0 4.981 4.18a6 6 0 0 0-3.998 2.9a6.05 6.05 0 0 0 .743 7.097a5.98 5.98 0 0 0 .51 4.911a6.05 6.05 0 0 0 6.515 2.9A6 6 0 0 0 13.26 24a6.06 6.06 0 0 0 5.772-4.206a6 6 0 0 0 3.997-2.9a6.06 6.06 0 0 0-.747-7.073M13.26 22.43a4.48 4.48 0 0 1-2.876-1.04l.141-.081l4.779-2.758a.8.8 0 0 0 .392-.681v-6.737l2.02 1.168a.07.07 0 0 1 .038.052v5.583a4.504 4.504 0 0 1-4.494 4.494M3.6 18.304a4.47 4.47 0 0 1-.535-3.014l.142.085l4.783 2.759a.77.77 0 0 0 .78 0l5.843-3.369v2.332a.08.08 0 0 1-.033.062L9.74 19.95a4.5 4.5 0 0 1-6.14-1.646M2.34 7.896a4.5 4.5 0 0 1 2.366-1.973V11.6a.77.77 0 0 0 .388.677l5.815 3.354l-2.02 1.168a.08.08 0 0 1-.071 0l-4.83-2.786A4.504 4.504 0 0 1 2.34 7.872zm16.597 3.855l-5.833-3.387L15.119 7.2a.08.08 0 0 1 .071 0l4.83 2.791a4.494 4.494 0 0 1-.676 8.105v-5.678a.79.79 0 0 0-.407-.667m2.01-3.023l-.141-.085l-4.774-2.782a.78.78 0 0 0-.785 0L9.409 9.23V6.897a.07.07 0 0 1 .028-.061l4.83-2.787a4.5 4.5 0 0 1 6.68 4.66zm-12.64 4.135l-2.02-1.164a.08.08 0 0 1-.038-.057V6.075a4.5 4.5 0 0 1 7.375-3.453l-.142.08L8.704 5.46a.8.8 0 0 0-.393.681zm1.097-2.365l2.602-1.5l2.607 1.5v2.999l-2.597 1.5l-2.607-1.5Z';
var GLYPH_YT='<svg width="10" height="10" viewBox="0 0 24 24" aria-hidden="true"><path d="M8 5v14l11-7z" fill="#fff"/></svg>';
var GLYPH_GPT='<svg width="11" height="11" viewBox="0 0 24 24" aria-hidden="true"><path d="'+OPENAI_PATH+'" fill="#fff"/></svg>';
function mChip(bg,glyph,state,label,tip){
 const color=state==='ok'?'#4ade80':(state==='warn'?'#fbbf24':'#f87171');
 const mark=state==='ok'?'✓':'✗';
 return '<span title="'+esc(tip)+'" style="display:inline-flex;align-items:center;gap:3px;white-space:nowrap">'
  +'<span style="display:inline-flex;align-items:center;justify-content:center;width:15px;height:15px;border-radius:4px;background:'+bg+';color:#fff;font-size:9px;font-weight:700">'+glyph+'</span>'
  +'<b style="color:'+color+';font-size:11px">'+mark+(label?('('+esc(label)+')'):'')+'</b></span>';
}
function mediaScore(n){
 const m=n.media;if(!m||!m.at)return -1;
 let s=0;
 if(m.youtube&&m.youtube.ok&&!m.youtube.blocked)s++;
 if(m.google&&m.google.ok&&!m.google.blocked)s++;
 if(m.chatgpt&&m.chatgpt.ok)s++;
 if(m.netflix&&m.netflix.ok)s++;
 return s;
}
function mediaChips(n){
 const m=n.media;
 if(!m||!m.at)return '<span class="muted" style="font-size:11px">待检测</span>';
 const ip=String(m.ip||'');
 const is6=ip.indexOf(':')>=0;
 const g4on=String((n.info&&n.info.cfg&&n.info.cfg.GoogleV4)||'')==='on';
 const src=String(m.src||'');
 const famTip=ip?('出口 '+(is6?'IPv6':'IPv4')+'：'+ip+(m.loc?(' · '+m.loc):'')+(src?(' · 探测绑定节点出口 '+src):'')+(g4on?' · 已强制 Google/YT 走 IPv4（sing-box 路由）':'')):'出口 IP 未知';
 const yt=(m.youtube&&m.youtube.blocked)
  ?mChip('#FF0000',GLYPH_YT,'bad','拉黑','YouTube 提示异常流量：出口 IP 疑似被拉黑 · '+famTip)
  :(m.youtube&&m.youtube.ok)
   ?mChip('#FF0000',GLYPH_YT,'ok',(m.youtube.region||''),'YouTube 可用 · 解锁区域 '+(m.youtube.region||'未知')+' · '+famTip)
   :mChip('#FF0000',GLYPH_YT,'bad','','YouTube 不可用 · '+famTip);
 const g=(m.google&&m.google.blocked)
  ?mChip('#4285F4','G','bad','拉黑','Google 搜索被跳转 /sorry/：出口 IP 被判定异常流量 · '+famTip)
  :(m.google&&m.google.ok)
   ?mChip('#4285F4','G','ok','','Google 正常（generate_204='+((m.google&&m.google.code)||'-')+' · 搜索='+((m.google&&m.google.search)||'-')+'）· '+famTip)
   :mChip('#4285F4','G','bad',String((m.google&&m.google.code)||''),'Google 不通 · generate_204='+((m.google&&m.google.code)||'-')+' · 搜索='+((m.google&&m.google.search)||'-')+' · '+famTip);
 const ai=(m.chatgpt&&m.chatgpt.ok)
  ?mChip('#10A37F',GLYPH_GPT,'ok','','ChatGPT 可用 · '+famTip)
  :mChip('#10A37F',GLYPH_GPT,'warn',String((m.chatgpt&&m.chatgpt.code)||''),'ChatGPT 受限 · HTTP '+((m.chatgpt&&m.chatgpt.code)||'-')+((m.chatgpt&&m.chatgpt.loc)?(' · loc='+m.chatgpt.loc):'')+' · '+famTip);
 const nf=(m.netflix&&m.netflix.ok)
  ?mChip('#E50914','N','ok','','Netflix 可看 · '+famTip)
  :mChip('#E50914','N','warn',String((m.netflix&&m.netflix.code)||''),'Netflix 受限 · HTTP '+((m.netflix&&m.netflix.code)||'-')+' · '+famTip);
 // 固定两列宽度的网格: 两行两列跨节点对齐；出口协议(v4/v6)单独一行小字，避免与(拉黑)等长标签挤压
 const fam=ip?('<span title="'+esc(famTip)+'" style="grid-column:1 / -1;font-size:9px;line-height:12px;color:'+(g4on?'#4ade80':(is6?'#93c5fd':'#a1a1aa'))+';border:1px solid '+(g4on?'#4ade80':(is6?'#3b82f6':'#3f3f46'))+';border-radius:3px;padding:0 3px;white-space:nowrap;justify-self:start;margin-top:1px">'+(is6?'v6':'v4')+(g4on?'·强制':'')+'</span>'):'';
 return '<span style="display:inline-grid;grid-template-columns:60px 64px;gap:2px 4px;justify-items:start;align-items:center">'
  +yt+g+ai+nf+fam+'</span>';
}
function mediaTag(n){const m=n.media;
 if(!m||!m.at)return '';
 if(m.google&&m.google.blocked)return ' <span class="badge b-bad" style="font-size:10px" title="Google 搜索被跳转 /sorry/，出口 IP 疑似被拉黑（点顶部「🌐 媒体检测」看详情）">🚫Google拉黑</span>';
 if(m.youtube&&m.youtube.blocked)return ' <span class="badge b-bad" style="font-size:10px" title="YouTube 提示异常流量，出口 IP 疑似被拉黑">🚫YT异常</span>';
 return '';
}
function dupItemHtml(n){return esc(n.ip)+' · NodeID '+esc((n.info.cfg&&n.info.cfg.NodeID)||'-')+' · 连接 '+((n.info.conns)||0)+' · '+((n.info.rss_mb)||0)+'MB · agent v'+esc(n.agentVer||'-')+' · 证书 '+((n.certDays==null)?'-':n.certDays+'天')+' · 心跳 '+fmtTime(n.lastSeen)+' <button class="btn btn-ghost btn-sm dupdel" data-key="'+encodeURIComponent(n.key)+'" data-name="'+encodeURIComponent(n.name)+'">🗑 删除</button>';}
function showDups(){
 const m=dupMaps();
 const lines=[];
 const sec=function(title,groups,tip){
  if(!groups.length)return;
  lines.push('<b>'+title+'</b>');
  groups.forEach(function(e){
   lines.push('<span class="muted">'+esc(e[0])+'</span>（'+e[1].length+' 台）');
   e[1].sort(function(a,b){return (b.info.conns||0)-(a.info.conns||0);}).forEach(function(n){lines.push(dupItemHtml(n));});
  });
  if(tip)lines.push('<span class="small">'+tip+'</span>');
 };
 if(!m.realDups.length&&!m.panelDups.length&&!m.nameOnly.length){
  lines.push('<b style="color:#4ade80">✓ 未发现重复节点</b>');
  lines.push('<span class="muted">同名同面板、同面板同 NodeID 落在多台机器的情况都不存在</span>');
 } else {
  sec('⚠ 疑似真重复（同名 + 同面板）',m.realDups,'同一面板节点被两台机器服务：保留在服役的那台，另一台请先停 V2bX 再删记录');
  sec('⚠ 疑似真重复（同面板 + 同 NodeID）',m.panelDups,'面板里同一个节点号被两台机器占用：保留在服役的那台，或给另一台在面板里分配新 NodeID');
  sec('ℹ 仅重名（同名但面板不同）',m.nameOnly,'各自服务各自面板，业务无冲突；仅显示上易混淆，可双击名称改成更易区分的名字');
 }
 showModal('🔍 重复节点检查',lines,'保留「有连接数 / 心跳最新」的那台，删除僵尸记录即可（删除只影响云控记录，不动节点上的 V2bX）；本地面板(127.0.0.1)的多机同号不算重复');
}
let SORT={col:'',dir:1};
// ---------- 媒体解锁检测（YouTube / ChatGPT / Netflix / Google 拉黑判定） ----------
function mediaCell(m){
 if(!m||!m.at)return '<span class="muted">未检测</span>';
 const yt=m.youtube&&m.youtube.blocked?'<b style="color:#f87171" title="YouTube 提示异常流量，出口 IP 疑似被拉黑">🚫 异常流量</b>'
  :(m.youtube&&m.youtube.region?('<b style="color:#4ade80">✅ '+esc(m.youtube.region)+'</b>'):'<b style="color:#f87171">⛔ 不可用</b>');
 let g;
 if(m.google&&m.google.blocked)g='<b style="color:#f87171" title="搜索被跳转 /sorry/，IP 被判定异常流量">🚫 被拉黑</b>';
 else if(m.google&&m.google.ok)g='<b style="color:#4ade80">✅ 正常</b>';
 else g='<b style="color:#fbbf24" title="HTTP 状态: '+esc(m.google&&m.google.code)+'">⚠ 不通</b>';
 const nf=m.netflix&&m.netflix.ok?'<b style="color:#4ade80">✅ 可看</b>':'<b style="color:#fbbf24" title="HTTP 状态: '+esc(m.netflix&&m.netflix.code)+'">⛔ 受限</b>';
 let gpt;
 if(m.chatgpt&&m.chatgpt.ok)gpt='<b style="color:#4ade80">✅ 可用</b>';
 else if(String(m.chatgpt&&m.chatgpt.code)==='403')gpt='<b style="color:#fbbf24" title="403：可能要求登录或该出口被拒">⚠ 403</b>';
 else gpt='<b style="color:#f87171" title="HTTP 状态: '+esc(m.chatgpt&&m.chatgpt.code)+'">⛔ 不可用</b>';
 return {yt:yt,g:g,nf:nf,gpt:gpt,ip:esc(m.ip||'-'),loc:esc(m.loc||'-'),src:esc(m.src||''),at:fmtTime(m.at)};
}
function renderMediaModal(list,q,all){
 const tb=document.getElementById('mediaTb');if(!tb)return true;
 const sel=NODES.filter(function(n){return list.indexOf(n.key)>=0;});
 let pending=0;
 tb.innerHTML=sel.map(function(n){
  const m=n.media;
  const fresh=m&&m.at&&m.at>=q;
  if(!fresh)pending++;
  if(!m||!m.at)return '<tr><td>'+esc(n.name)+'</td><td colspan="3" class="muted">等待节点回传…（离线节点不会回传）</td></tr>';
  const c=mediaCell(m);
  const g4on=String((n.info&&n.info.cfg&&n.info.cfg.GoogleV4)||'')==='on';
  if(!fresh)return '<tr><td>'+esc(n.name)+'</td><td colspan="3" class="muted">检测中…（上次结果：'+esc(c.ip)+' · '+c.at+'）</td></tr>';
  return '<tr><td>'+esc(n.name)+'</td><td>'+c.ip+' <span class="muted">'+c.loc+'</span>'+(m.src?' <span class="badge b-mut" style="font-size:10px" title="本行探测绑定到该节点自己的出口 IP（同进同出绑定 SendIP），不是本机默认出口">绑定 '+esc(m.src)+'</span>':'')+(g4on?' <span class="badge b-mut" style="font-size:10px" title="节点侧 sing-box 已把 Google/YouTube 路由到 IPv4 直连出站（本行探测也为 IPv4）">Google走v4</span>':'')+'</td><td>'+mediaChips(n)+'</td><td class="muted">'+esc(c.at)+'</td></tr>';
 }).join('');
 const st=document.getElementById('mediaStatus');
 if(st)st.textContent=(all?'未勾选节点，已检测全部 ':'已检测 ')+sel.length+' 台 · '+(pending?('等待 '+pending+' 台回传…'):'✓ 全部已回传');
 return pending===0;
}
async function showMedia(){
 const keys=[...new Set([...document.querySelectorAll('.sel:checked')].map(function(x){return decodeURIComponent(x.value);}))];
 const all=keys.length===0;
 const list=all?NODES.map(function(n){return n.key;}):keys;
 if(!list.length){show('暂无节点');return;}
 const d=await api('/api/media_query',{targets:list});
 if(d.error){show('被拒绝: '+d.error);return;}
 const q=d.queryAt||Date.now();
 document.getElementById('modalBox').innerHTML='<h3>🌐 媒体解锁检测</h3>'
  +'<div class="muted small" style="margin-bottom:6px">图标：<span style="color:#FF0000">▶</span> YouTube · <span style="color:#4285F4">G</span> Google · <span style="color:#10A37F">AI</span> ChatGPT · <span style="color:#E50914">N</span> Netflix　（✓ 可用 · ✗ 不可用 · ? 受限/需登录）· 每 12 小时自动检测一次 · 图标下 v4/v6 为探测出口协议（节点开了「Google/YT 强制 IPv4」时探测也走 IPv4）</div>'
  +'<div style="max-height:52vh;overflow:auto"><table style="min-width:620px"><thead><tr><th>节点</th><th>出口 IP</th><th>流媒体</th><th>检测时间</th></tr></thead><tbody id="mediaTb"></tbody></table></div>'
  +'<div class="foot" id="mediaStatus" style="margin-top:6px"></div>'
  +'<div style="margin-top:10px;display:flex;gap:8px"><button class="btn btn-outline btn-sm" id="mediaAgain">重新检测</button>'
  +'<button class="btn btn-primary btn-sm" id="mediaClose">关闭</button></div>';
 document.getElementById('modal').classList.add('show');
 document.getElementById('mediaAgain').onclick=function(){showMedia();};
 document.getElementById('mediaClose').onclick=function(){closeModal();};
 renderMediaModal(list,q,all);
 for(let i=0;i<24;i++){ // 每台约 10 秒，最多等 ~36 秒
  await new Promise(function(r){setTimeout(r,1500);});
  await refresh();
  if(renderMediaModal(list,q,all))break;
 }
}
let LOGTIMER=null,LOGKEY='',LOGSEQ=0;
function stopLog(){if(LOGTIMER){clearInterval(LOGTIMER);LOGTIMER=null;}
 if(LOGKEY){api('/api/log_stop',{targets:[LOGKEY]});LOGKEY='';}}
function startLogPoll(key){
 if(LOGTIMER)clearInterval(LOGTIMER);
 const tick=async function(){
  if(LOGKEY!==key)return;
  const d=await api('/api/log_fetch?key='+encodeURIComponent(key)+'&since='+LOGSEQ);
  const box=document.getElementById('logBox');
  if(!box||d.error){if(!box)stopLog();return;}
  if(d.dropped&&LOGSEQ){box.textContent='（日志滚动过快，已重新载入）\\n';LOGSEQ=0;} // 缓冲被裁剪
  const add=(d.lines||[]).map(function(l){return l.text;}).join('\\n');
  if(add){box.textContent+=(box.textContent?'\\n':'')+add;LOGSEQ=d.seq||LOGSEQ;}
  // 控制 DOM 体量: 超过 500 行只保留尾部
  const lines=box.textContent.split('\\n');
  if(lines.length>500)box.textContent=lines.slice(-400).join('\\n');
  box.scrollTop=box.scrollHeight;
  const st=document.getElementById('logStatus');
  if(st){const left=d.active?Math.max(0,Math.round((d.until-Date.now())/1000)):0;
   st.textContent=(d.active?('订阅中 · 剩余 '+left+'s'):'订阅已结束（可点「重新订阅」）')
    +' · 已接收 '+LOGSEQ+' 行 · 节点最后回传 '+(d.at?fmtTime(d.at):'尚未回传')
    +(d.active?'':' · 注意：节点离线时不会有日志') ;}
 };
 tick();LOGTIMER=setInterval(tick,1500);
}
async function showLog(keyEnc,nameEnc){
 const key=decodeURIComponent(keyEnc),name=decodeURIComponent(nameEnc);
 stopLog();
 const d=await api('/api/log_start',{targets:[key],seconds:60});
 if(d.error){show('被拒绝: '+d.error);return;}
 LOGKEY=key;LOGSEQ=0;
 document.getElementById('modalBox').innerHTML='<h3>📜 实时日志</h3>'
  +'<div class="muted small" style="margin-bottom:6px">'+esc(name)+' · '+esc(key.split('|')[1]||'')+'</div>'
  +'<pre id="logBox" style="max-height:52vh;overflow:auto;background:#0b1020;color:#cfe3ff;font-size:12px;line-height:1.5;padding:10px;border-radius:8px;border:1px solid hsl(var(--border));white-space:pre-wrap;word-break:break-all;margin:0"></pre>'
  +'<div class="foot" id="logStatus" style="margin-top:6px">已订阅 60 秒 · 正在获取…</div>'
  +'<div style="margin-top:10px;display:flex;gap:8px"><button class="btn btn-outline btn-sm" id="logRestart">重新订阅 60s</button>'
  +'<button class="btn btn-ghost btn-sm" id="logStop">停止</button>'
  +'<button class="btn btn-primary btn-sm" id="logClose">关闭</button></div>';
 document.getElementById('modal').classList.add('show');
 document.getElementById('logRestart').onclick=function(){showLog(keyEnc,nameEnc);};
 document.getElementById('logStop').onclick=function(){stopLog();closeModal();};
 document.getElementById('logClose').onclick=function(){stopLog();closeModal();};
 startLogPoll(key);
}
function toggleSort(col){ // 点击表头循环: 升序 → 降序 → 恢复默认
 if(SORT.col===col){if(SORT.dir>0)SORT.dir=-1;else{SORT.col='';SORT.dir=1;}}else{SORT.col=col;SORT.dir=1;}
 render();}
function setSortFromSelect(){const el=document.getElementById('sortSel');SORT.col=el?el.value:'';SORT.dir=1;render();}
function toggleSortDir(){if(!SORT.col){const el=document.getElementById('sortSel');if(el&&el.value){SORT.col=el.value;}}if(!SORT.col)return;SORT.dir=-SORT.dir;render();}
function render(){const keepSel=new Set([...document.querySelectorAll('.sel:checked')].map(x=>decodeURIComponent(x.value)));
 const list=visibleNodes();
 // 表头排序（点击列头循环: 升序→降序→恢复默认"在线优先+名称"）
 if(SORT.col){
  const D=SORT.dir;
  const cmpStr=(x,y)=>String(x==null?'':x).localeCompare(String(y==null?'':y),undefined,{numeric:true});
  list.sort((a,b)=>{
   const ac=(a.info&&a.info.cfg)||{},bc=(b.info&&b.info.cfg)||{};
   switch(SORT.col){
    case 'name':return D*cmpStr(a.name,b.name);
    case 'group':return D*cmpStr(a.group||'',b.group||'');
    case 'media':return D*(mediaScore(a)-mediaScore(b)); // 未检测(-1)排最后
    case 'ip':{ // IP 排序: 同 IP 的节点自动聚在一起，再按 NodeID、名称细分
     const c=cmpStr(a.ip,b.ip);if(c)return D*c;
     const an=((a.info.cfg&&a.info.cfg.NodeID)||0),bn=((b.info.cfg&&b.info.cfg.NodeID)||0);
     if(an!==bn)return D*(an-bn);
     return D*cmpStr(a.name,b.name);}
    case 'nodeid':{const an=((a.info.cfg&&a.info.cfg.NodeID)||0),bn=((b.info.cfg&&b.info.cfg.NodeID)||0);
     if(an!==bn)return D*(an-bn);return D*cmpStr(a.name,b.name);}
    case 'ver':return D*cmpStr(a.info.version,b.info.version);
    case 'rss':return D*((a.info.rss_mb||0)-(b.info.rss_mb||0));
    case 'conns':return D*((a.info.conns||0)-(b.info.conns||0));
    case 'warp':return D*cmpStr(a.info.warp,b.info.warp);
    case 'cert':{const av=(a.certDays==null?Infinity:a.certDays),bv=(b.certDays==null?Infinity:b.certDays);return D*(av-bv);}
    case 'panel':{const h=cmpStr(ac.ApiHost,bc.ApiHost);if(h)return D*h;return D*((ac.NodeID||0)-(bc.NodeID||0));}
    case 'seen':return D*((a.lastSeen||0)-(b.lastSeen||0));
    case 'online':return D*((a.online?1:0)-(b.online?1:0));
    case 'desired':{const av=a.desired?1:0,bv=b.desired?1:0;if(av!==bv)return D*(av-bv);return D*cmpStr(a.name,b.name);}
    case 'action':{const as=a.action?1:0,bs=b.action?1:0;if(as!==bs)return D*(bs-as);
     if(a.action&&b.action)return D*((b.action.queuedAt||0)-(a.action.queuedAt||0));return 0;}
   }
   return 0;});
 }
 const online=NODES.filter(n=>n.online).length;
 const DUPS=dupMaps(); // 重复节点标记（同名不同机 / 同面板同 NodeID 多机）
 const dupTag=function(n){const d=dupInfo(n,DUPS);if(!d)return '';
  return d.kind==='dup'
   ? ' '+badge('b-warn','重复')+'<span class="small" style="color:hsl(var(--warn))"> 与 '+esc(d.ips.join(', '))+' 重复</span>'
   : ' '+badge('b-mut','同名')+'<span class="small muted"> 与 '+esc(d.ips.join(', '))+' 同名（面板不同）</span>';};
 document.getElementById('cnt').textContent='· '+online+'/'+NODES.length+' 在线';
 document.getElementById('cnt2').textContent='(显示 '+list.length+'/'+NODES.length+')';
 // 分组下拉选项
 const gf=document.getElementById('groupFilter');const cur=gf.value;
 const groups=[...new Set(NODES.map(n=>n.group).filter(Boolean))].sort();
 if(gf.dataset.sig!==groups.join('|')){gf.dataset.sig=groups.join('|');gf.innerHTML='<option value="">全部分组</option>'+groups.map(g=>'<option value="'+g+'">'+g+'</option>').join('');gf.value=groups.includes(cur)?cur:'';}
 // 面板域名下拉选项（带各来源节点数，方便区分）
 const hf=document.getElementById('hostFilter');const curH=hf.value;
 const hosts=[...new Set(NODES.map(n=>(n.info.cfg&&n.info.cfg.ApiHost)||'').filter(Boolean))].sort();
 const hc={};NODES.forEach(n=>{const h=(n.info.cfg&&n.info.cfg.ApiHost)||'';if(h)hc[h]=(hc[h]||0)+1;});
 const hostSig=hosts.map(h=>h+':'+hc[h]).join('|');
 if(hf.dataset.sig!==hostSig){hf.dataset.sig=hostSig;hf.innerHTML='<option value="">全部面板域名</option>'+hosts.map(h=>'<option value="'+h+'">'+escAttr(h.replace(/^https?:[/][/]/,''))+' · '+hc[h]+'台</option>').join('');hf.value=hosts.includes(curH)?curH:'';}
 document.getElementById('tb').innerHTML=list.map(n=>'<tr>'+
 '<td><input type="checkbox" class="sel" value="'+encodeURIComponent(n.key)+'" style="width:14px;height:14px;padding:0"></td>'+
 '<td>'+(n.online?badge('b-ok','在线'):badge('b-bad','离线'))+((n.online&&n.info.svc&&n.info.svc!=='active')?' '+(n.info.svc==='activating'?badge('b-info','启动中'):badge('b-warn',n.info.svc==='absent'?'未安装':'服务停止')):'')+'</td>'+
 '<td style="font-weight:500"><a href="#" class="nlink" data-key="'+encodeURIComponent(n.key)+'" data-name="'+encodeURIComponent(n.name)+'" style="color:hsl(var(--info));text-decoration:none" title="单击查看详情 / 双击重命名">'+esc(n.name)+'</a>'+(n.renaming?' '+badge('b-info','✏ → '+esc(n.renaming)):'')+(n.pendingRename?' '+badge('b-warn','→ '+esc(n.pendingRename)):'')+((n.nodeCount>1)?' '+badge('b-mut','多节点 '+n.nodeCount):'')+dupTag(n)+' <button class="btn btn-ghost btn-sm logbtn" data-key="'+encodeURIComponent(n.key)+'" data-name="'+encodeURIComponent(n.name)+'" title="查看实时日志">📜</button></td>'+
 '<td>'+(n.group?badge('b-mut',esc(n.group)):'-')+'</td>'+
 '<td class="small">'+mediaChips(n)+'</td>'+
 '<td class="small">'+esc(n.ip)+'</td>'+
 '<td>'+(n.info.version?badge('b-mut',esc(n.info.version)):'-')+'</td>'+
 '<td>'+(n.info.rss_mb||0)+' MB</td><td>'+(n.info.conns||0)+'</td>'+
 '<td>'+esc(n.info.warp||'-')+'</td>'+
 '<td>'+fmtCert(n.certDays)+'</td>'+
 '<td class="small"><div class="ellip">'+panelTag(n)+'<b style="font-size:12px">#'+((n.info.cfg&&n.info.cfg.NodeID)||'-')+'</b> '+typeTag(n)+mediaTag(n)+'</div></td>'+
 '<td class="small" style="white-space:nowrap">'+fmtTime(n.lastSeen)+'</td>'+
 '<td class="small">'+(n.desired?badge('b-warn','待应用'):'-')+'</td>'+
 '<td>'+fmtAct(n.action)+'</td></tr>').join('');
 document.getElementById('mc').innerHTML=list.map(n=>'<div class="ncard">'+
 '<div class="nrow"><div style="display:flex;align-items:center;gap:8px;flex-wrap:wrap;min-width:0">'+
 '<input type="checkbox" class="sel" value="'+encodeURIComponent(n.key)+'" style="width:14px;height:14px;padding:0">'+
 (n.online?badge('b-ok','在线'):badge('b-bad','离线'))+((n.online&&n.info.svc&&n.info.svc!=='active')?' '+(n.info.svc==='activating'?badge('b-info','启动中'):badge('b-warn',n.info.svc==='absent'?'未安装':'服务停止')):'')+'<a href="#" class="nlink" data-key="'+encodeURIComponent(n.key)+'" data-name="'+encodeURIComponent(n.name)+'" style="color:inherit;text-decoration:none;font-weight:600;overflow-wrap:anywhere">'+esc(n.name)+'</a>'+(n.group?' '+badge('b-mut',esc(n.group)):'')+
 (n.renaming?' '+badge('b-info','✏ → '+n.renaming):'')+(n.pendingRename?' '+badge('b-warn','→ '+n.pendingRename):'')+
 '<button class="btn btn-ghost btn-sm renbtn" data-key="'+encodeURIComponent(n.key)+'" data-name="'+encodeURIComponent(n.name)+'" title="重命名">改名</button>'+
 '<button class="btn btn-ghost btn-sm logbtn" data-key="'+encodeURIComponent(n.key)+'" data-name="'+encodeURIComponent(n.name)+'" title="查看实时日志">📜</button></div>'+fmtAct(n.action)+'</div>'+
 '<div class="ngrid"><span class="k">IP</span><span>'+esc(n.ip)+'</span>'+
 '<span class="k">版本</span><span>'+(n.info.version||'-')+'</span>'+
 '<span class="k">内存</span><span>'+(n.info.rss_mb||0)+' MB</span>'+
 '<span class="k">连接</span><span>'+(n.info.conns||0)+'</span>'+
 '<span class="k">流媒体</span><span>'+mediaChips(n)+'</span>'+
 '<span class="k">WARP</span><span>'+esc(n.info.warp||'-')+'</span>'+
 '<span class="k">服务</span><span>'+(n.info.svc==='active'?'运行中':(n.info.svc==='activating'?'启动中':(n.info.svc==='absent'?'未安装':(n.info.svc==='inactive'?'已停止':'-'))))+'</span>'+
 '<span class="k">证书</span><span>'+fmtCert(n.certDays)+'</span>'+
 '<span class="k">面板</span><span class="ellip">'+(((n.info.cfg&&n.info.cfg.ApiHost)?panelTag(n)+'#'+(n.info.cfg.NodeID||'-')+' '+typeTag(n):'-'))+'</span>'+
 '<span class="k">NodeID</span><span>'+((n.info.cfg&&n.info.cfg.NodeID)||'-')+'</span>'+
 '<span class="k">最后心跳</span><span>'+fmtTime(n.lastSeen)+'</span></div>'+
 (n.desired?'<div class="small" style="margin-top:6px">待下发: '+esc(JSON.stringify(n.desired))+'</div>':'')+
 '</div>').join('');
 document.querySelectorAll('.sel').forEach(x=>{x.checked=keepSel.has(decodeURIComponent(x.value));});
 const all=[...document.querySelectorAll('.sel')];
 const sa=document.getElementById('selAll');if(sa)sa.checked=all.length>0&&all.every(x=>x.checked);
 // 表头排序指示符（▲/▼，未激活时显示淡色 ⇅ 提示可点）
 document.querySelectorAll('#tbhead th.sortable').forEach(function(th){
  const si=th.querySelector('.si');if(!si)return;
  const on=(SORT.col===th.dataset.col);
  si.textContent=on?(SORT.dir>0?'▲':'▼'):'⇅';
  si.style.opacity=on?'1':'.3';
 });
 // 排序下拉与方向按钮同步
 const ss=document.getElementById('sortSel');
 if(ss&&ss.value!==SORT.col)ss.value=SORT.col;
 const sd=document.getElementById('sortDirBtn');
 if(sd)sd.textContent=SORT.col?(SORT.dir>0?'↑ 升序':'↓ 降序'):'↑ 升序';
}
let AUTO=true;let pollTimer=null;
function pollMs(){const inflight=NODES.some(n=>n.action&&(n.action.status==='queued'||n.action.status==='delivered'));return inflight?3000:5000;}
async function refresh(){try{const d=await api('/api/nodes');if(!d.nodes)return;NODES=d.nodes||[];
 SETTINGS={nodeToken:d.nodeToken||'',
  joinCmd:'bash <(curl -fsSL https://raw.githubusercontent.com/4kercc/V2BX-malio/main/cloud-join.sh) "'+location.origin+'" "'+(d.nodeToken||'')+'"',
  updateVersion:d.updateVersion||'',agentVersion:d.agentVersion||'',tgBotToken:d.tgBotToken||'',tgChatId:d.tgChatId||'',webhookUrl:d.webhookUrl||''};
 syncSettingsForm(); // 设置弹窗若已打开，同步最新值（不覆盖正在编辑的字段）
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
 const evs=(d.events||[]).map(e=>'<li><span class="muted">'+new Date(e.t).toLocaleString()+'</span> — '+esc(e.text)+'</li>').join('');
 showModal('📊 '+esc(d.name)+(d.group?' ['+esc(d.group)+']':''), [
  'IP '+esc(d.ip)+' · 类型 '+esc((d.info.cfg&&d.info.cfg.NodeType)||'-')+' · 版本 '+esc(d.info.version||'-')+' · Agent v'+esc(d.agentVer||'-')+' · 证书 '+fmtCert(d.certDays)+' · 服务 '+(d.info.svc==='active'?'运行中':(d.info.svc==='absent'?'未安装':(d.info.svc==='inactive'?'已停止':'未知'))),
  '<b>内存趋势（近 3 小时）</b>'+sparkline(recent,'hsl(217 91% 60%)'),
  '<b>连接数趋势</b>'+sparkline(conns,'hsl(142 76% 44%)'),
  (evs?'<b>近期事件</b><ul style="margin:4px 0">'+evs+'</ul>':'<div class="muted">暂无事件</div>')
 ], '指标每 2 分钟采集一次：近 3 小时明细 + 7 天降采样');}
function certDaysHtml(d){if(d===null||d===undefined||d==='')return '<span class="muted">未知</span>';
 if(d<=7)return '<b style="color:#f87171">'+d+' 天 · 紧急</b>';
 if(d<=14)return '<b style="color:#fbbf24">'+d+' 天 · 尽快续期</b>';
 if(d<=30)return '<b style="color:#60a5fa">'+d+' 天</b>';
 return '<b style="color:#4ade80">'+d+' 天</b>';}
function fmtCertEnd(s){if(!s)return '-';const d=new Date(s);return isNaN(d.getTime())?s:d.toLocaleDateString();}
function certLine(n,q){
 const c=n.cert;
 if(c&&c.checkedAt&&c.checkedAt>=q){
  if(!c.path)return esc(n.name)+' — <span class="muted">未找到证书文件</span>';
  return esc(n.name)+' — '+esc(c.domain||'-')+(c.selfSigned?' <span class="muted">(自签)</span>':'')+' · 到期 '+esc(fmtCertEnd(c.end))+' · '+certDaysHtml(c.days);
 }
 if(c&&c.path)return esc(n.name)+' — '+esc(c.domain||'-')+' · '+certDaysHtml(c.days)+' <span class="muted">(上次结果)</span>';
 if(n.certDays!==null&&n.certDays!==undefined)return esc(n.name)+' — 剩余 '+certDaysHtml(n.certDays)+' <span class="muted">(agent 待升级，无详情)</span>';
 if(!n.agentVer)return esc(n.name)+' — <span class="muted">agent 版本过旧，未上报证书（重跑对接脚本即可升级）</span>';
 return esc(n.name)+' — <span class="muted">查询中…</span>';}
function renderCertModal(list,q,all,panelCert){
 const ul=document.getElementById('certList');if(!ul)return true;
 const sel=NODES.filter(n=>list.indexOf(n.key)>=0);
 ul.innerHTML=sel.map(n=>'<li>'+certLine(n,q)+'</li>').join('');
 const pending=sel.filter(n=>!(n.cert&&n.cert.checkedAt>=q)).length;
 const foot=document.getElementById('certFoot');
 if(foot){
  const pc=panelCert&&!panelCert.error?('控制面板证书 '+esc(panelCert.cn)+'：剩余 '+panelCert.days+' 天'):'';
  foot.innerHTML=(all?'未勾选节点，已查询全部 ':'已查询 ')+sel.length+' 台 · '+(pending?('等待 '+pending+' 台回报…'):'✓ 全部已回报')
   +'<br>节点证书由各节点 agent 就地读取（自签 / ACME / 自定义 CertFile 均支持）；剩余 ≤21 天自动告警'
   +(pc?('<br>'+pc):'');
 }
 return pending===0;}
async function showCert(){
 const keys=[...document.querySelectorAll('.sel:checked')].map(x=>decodeURIComponent(x.value));
 const all=keys.length===0;
 const list=all?NODES.map(n=>n.key):keys;
 if(!list.length){show('暂无节点');return;}
 const d=await api('/api/cert_query',{targets:list});
 if(d.error){show('被拒绝: '+d.error);return;}
 const q=d.queryAt||Date.now();
 const pc=await api('/api/cert').catch(function(){return null;});
 document.getElementById('modalBox').innerHTML='<h3>🔐 节点证书到期时间</h3><ul id="certList"></ul><div class="foot" id="certFoot"></div><button class="btn btn-primary" id="modalOk" style="margin-top:12px">知道了</button>';
 document.getElementById('modalOk').onclick=closeModal;
 document.getElementById('modal').classList.add('show');
 renderCertModal(list,q,all,pc);
 for(let i=0;i<8;i++){ // 轮询等节点回报（长轮询已即时唤醒，通常 1~3 秒）
  await new Promise(function(r){setTimeout(r,1500);});
  await refresh();
  if(renderCertModal(list,q,all,pc))break;
 }
}
async function showAudit(){const d=await api('/api/audit');
 const aud=(d.audit||[]).map(a=>'<li><span class="muted">'+new Date(a.t).toLocaleString()+'</span> — <b>'+esc(a.act)+'</b> '+esc(a.detail)+'</li>').join('');
 const evs=(d.events||[]).map(e=>'<li><span class="muted">'+new Date(e.t).toLocaleString()+'</span> — '+esc(e.text)+'</li>').join('');
 showModal('📜 审计与事件', [
  '<b>管理操作审计</b>'+(aud?'<ul style="margin:4px 0">'+aud+'</ul>':'<div class="muted">暂无</div>'),
  '<b>节点事件</b>'+(evs?'<ul style="margin:4px 0">'+evs+'</ul>':'<div class="muted">暂无</div>')
 ], '审计记录管理端全部下发操作；事件记录上下线/证书告警');}
async function setGroup(){const t=targets();if(!t)return;const g=document.getElementById('fGroup').value.trim();
 const d=await api('/api/groups',{targets:t,group:g});show(d.error?('被拒绝: '+d.error):('✓ 已将 '+d.applied+' 台节点分组设为 ['+(d.group||'无')+']'));}
function scheduleRefresh(){if(pollTimer)clearTimeout(pollTimer);pollTimer=setTimeout(()=>{if(AUTO)refresh();scheduleRefresh();},pollMs());}
function toggleAuto(){AUTO=!AUTO;const b=document.getElementById('autoBtn');b.textContent='自动刷新: '+(AUTO?'开':'关');if(AUTO)refresh();}
// 勾选目标去重: 桌面表格与移动卡片各有一套 checkbox，同一节点可能被勾两次
// （不去重会导致"只选 1 台"被误判成批量下发，从而拦掉 NodeID 这类差异化字段）
function targets(){const s=[...new Set([...document.querySelectorAll('.sel:checked')].map(x=>decodeURIComponent(x.value)))];if(!s.length){show('请先勾选节点');return null;}return s;}
function gather(){const f={};for(const [id,k] of [['fApiHost','ApiHost'],['fApiKey','ApiKey'],['fNodeId','NodeID'],['fDomain','CertDomain'],['fWarp','Warp'],['fType','NodeType'],['fG4','GoogleV4']]){const v=document.getElementById(id).value.trim();if(v)f[k]=v;}
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
 const ver=(SETTINGS.updateVersion||'').trim(); // 设置弹窗可能未打开，读缓存
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
function deleteNodes(){const t=targets();if(!t)return;
 const names=NODES.filter(n=>t.indexOf(n.key)>=0).map(n=>n.name);
 uiConfirm('删除 '+names.length+' 条节点记录？['+names.join('、')+'] —— 仅删除云控里的记录与历史，不影响节点上的 V2bX 服务；若该节点仍在心跳，记录会被重新创建',function(ok){
  if(!ok)return;
  api('/api/node_delete',{targets:t}).then(function(d){
   if(d.error){show('被拒绝: '+d.error);return;}
   show('✓ 已删除 '+d.deleted+' 条节点记录');refresh();});});}
async function saveSettings(){const v=document.getElementById('sUpdateVer').value.trim();
 const av=document.getElementById('sAgentVer').value.trim();
 const d=await api('/api/settings',{updateVersion:v,
  agentVersion:av,
  tgBotToken:document.getElementById('sTgBot').value.trim(),
  tgChatId:document.getElementById('sTgChat').value.trim(),
  webhookUrl:document.getElementById('sWebhook').value.trim()});
 // 结果写在弹窗内（弹窗关闭时回退到页头提示）
 const el=document.getElementById('setMsg');
 const msg=d.error?('被拒绝: '+d.error):('✓ 已保存（'+(v?'版本锁定 '+v:'最新版')+' / Agent '+(av||'关闭自更新')+' / 告警通道已更新）');
 if(el)el.textContent=msg;else show(msg);
 refresh();}
function copyJoin(){const i=document.getElementById('joinCmd');if(!i)return;const v=i.value;
 const done=function(ok){const el=document.getElementById('setMsg');const m=ok?'✓ 对接脚本已复制到剪贴板':'复制失败，请手动选中后复制';
  if(el)el.textContent=m;else show(m);};
 if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(v).then(function(){done(true);}).catch(function(){done(fallbackCopy(v));});}
 else{done(fallbackCopy(v));}}
function fallbackCopy(v){const i=document.getElementById('joinCmd');if(!i)return false;i.focus();i.select();
 try{return document.execCommand('copy');}catch(e){return false;}}
// ---------- 全局设置弹窗（右上角入口；字段不再常驻页面） ----------
function escAttr(v){return String(v==null?'':v).split('&').join('&amp;').split('"').join('&quot;').split('<').join('&lt;');}
function closeModal(){document.getElementById('modal').classList.remove('show');}
function syncSettingsForm(){ // 弹窗未打开时直接返回
 if(!document.getElementById('sUpdateVer'))return;
 const pair=[['sUpdateVer','updateVersion'],['sAgentVer','agentVersion'],['sTgBot','tgBotToken'],['sTgChat','tgChatId'],['sWebhook','webhookUrl']];
 for(const p of pair){const el=document.getElementById(p[0]);if(el&&el!==document.activeElement)el.value=SETTINGS[p[1]]||'';}
 const nt=document.getElementById('sNodeToken');if(nt)nt.value=SETTINGS.nodeToken||'';
 const jc=document.getElementById('joinCmd');if(jc)jc.value=SETTINGS.joinCmd||'';}
function showSettings(){
 const f=function(label,hint,id,ph,val){return '<div class="sect"><div class="muted">'+label+(hint?' <span>（'+hint+'）</span>':'')+'</div>'
  +'<input id="'+id+'" placeholder="'+ph+'" value="'+escAttr(val)+'"></div>';};
 document.getElementById('modalBox').innerHTML='<h3>⚙ 全局设置</h3>'
  +'<div class="sect"><div class="muted">节点接入 Token <span>（cloud-join.sh / agent 心跳专用，与管理 Token 分离）</span></div>'
  +'<input id="sNodeToken" readonly value="'+escAttr(SETTINGS.nodeToken)+'"></div>'
  +'<div class="sect"><div class="muted">一键对接脚本 <span>（粘贴到节点服务器以 root 执行即完成接入）</span></div>'
  +'<div style="display:flex;gap:8px"><input id="joinCmd" readonly style="flex:1;min-width:0;font-family:ui-monospace,Consolas,monospace;font-size:12px" value="'+escAttr(SETTINGS.joinCmd)+'">'
  +'<button class="btn btn-outline" style="flex:0 0 auto" onclick="copyJoin()">复制</button></div></div>'
  +f('升级版本锁定','留空 = 最新 Release','sUpdateVer','如 v1.0.9',SETTINGS.updateVersion)
  +f('Agent 目标版本','与节点上报不一致时自动自更新；留空关闭','sAgentVer','如 8',SETTINGS.agentVersion)
  +f('Telegram Bot Token','告警推送，可留空','sTgBot','123456:ABC-DEF...',SETTINGS.tgBotToken)
  +f('Telegram Chat ID','','sTgChat','-100123456789',SETTINGS.tgChatId)
  +f('Webhook URL','备选告警通道','sWebhook','https://...',SETTINGS.webhookUrl)
  +'<div class="sect" style="display:flex;gap:8px"><button class="btn btn-primary" onclick="saveSettings()">保存全部设置</button>'
  +'<button class="btn btn-ghost" onclick="closeModal()">关闭</button></div>'
  +'<div class="foot" id="setMsg"></div>';
 document.getElementById('modal').classList.add('show');}
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
  if(b){renameNode(b.dataset.key,decodeURIComponent(b.dataset.name));return;}
  var g=e.target.closest('button.logbtn');
  if(g){showLog(g.dataset.key,g.dataset.name);}});
 el.addEventListener('dblclick',function(e){
  var a=e.target.closest('a.nlink');
  if(a){e.preventDefault();if(tmr){clearTimeout(tmr);tmr=null;}
   renameNode(a.dataset.key,decodeURIComponent(a.dataset.name));}});}
wireNodeList('tb');wireNodeList('mc');
// 重复检查弹窗里的删除按钮（事件委托，避免内联拼接用户数据）
document.getElementById('modalBox').addEventListener('click',function(e){
 const b=e.target.closest('button.dupdel');if(!b)return;
 const key=decodeURIComponent(b.dataset.key),nm=decodeURIComponent(b.dataset.name||'');
 uiConfirm('删除节点记录「'+nm+'」？仅删除云控里的记录与历史，不影响节点上的 V2bX 服务',function(ok){
  if(!ok)return;
  api('/api/node_delete',{targets:[key]}).then(function(d){
   if(d.error){show('被拒绝: '+d.error);return;}
   show('✓ 已删除 1 条记录');closeModal();refresh();});
 });
});
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
<form class="box" id="f" name="login">
 <h1>V2bX 云控中心</h1>
 <p class="sub">请输入管理 Token 登录</p>
 <label for="u">账号</label>
 <input id="u" name="username" type="text" autocomplete="username" value="admin" spellcheck="false" autocapitalize="off">
 <label for="t" style="margin-top:10px">管理 Token</label>
 <input id="t" name="password" type="password" autocomplete="current-password" autofocus>
 <button id="b" type="submit">登 录</button>
 <div id="err"></div>
 <p class="sub" style="margin:10px 0 0">账号仅用于密码管理器识别，实际校验的是管理 Token</p>
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

// 长轮询等待表: 节点身份键 -> { res, timer }（下发命令时立即唤醒，无需等下一轮心跳）
const WAITERS = new Map();
const lastWakeAt = new Map(); // 节点身份键 -> 上次立即唤醒时间（防空转）
const WAIT_MS = 50000; // 单次挂起上限；节点侧 curl --max-time 58s，超时后自动重挂
const WAITERS_MAX = 500; // 容量上限：防止异常客户端撑爆内存（满载时立即返回，节点按退避重试）
function waitForNode(key, res) {
  const prev = WAITERS.get(key); // 同一节点重复挂起（进程重启等）时先收掉旧连接
  if (prev) {
    clearTimeout(prev.timer);
    WAITERS.delete(key);
    try { json(prev.res, 200, { wake: 0 }); } catch (e) { /* 连接已断 */ }
  }
  const timer = setTimeout(() => {
    const w = WAITERS.get(key);
    if (w && w.res === res) WAITERS.delete(key);
    try { json(res, 200, { wake: 0, idle: 1 }); } catch (e) { /* 连接已断 */ }
  }, WAIT_MS);
  WAITERS.set(key, { res, timer });
  res.on('close', () => {
    const w = WAITERS.get(key);
    if (w && w.res === res) { clearTimeout(w.timer); WAITERS.delete(key); }
  });
}
function flushNode(key) {
  const w = WAITERS.get(key);
  if (!w) return;
  clearTimeout(w.timer);
  WAITERS.delete(key);
  try { json(w.res, 200, { wake: 1 }); } catch (e) { /* 连接已断 */ }
}
function flushWaiters(keys) { // keys 省略 = 全部唤醒（用于全局设置变更）
  if (!keys) { for (const k of [...WAITERS.keys()]) flushNode(k); return; }
  for (const k of keys) flushNode(k);
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
  for (const k of ['ApiHost', 'ApiKey', 'NodeID', 'CertDomain', 'Warp', 'NodeType', 'GoogleV4']) {
    if (cfg && cfg[k] !== undefined && cfg[k] !== null && cfg[k] !== '') out[k] = cfg[k];
  }
  return out;
}
// 支持的节点类型（与 V2bX / V2bX.sh 一致）
const NODE_TYPES = ['anytls', 'vless', 'vmess', 'trojan', 'shadowsocks', 'hysteria', 'hysteria2', 'tuic'];
const PER_NODE_FIELDS = ['NodeID', 'NodeType']; // 差异化字段：禁止多目标批量下发
// 实时日志: 订阅窗口内节点持续推送 journalctl 输出，UI 按序拉取增量
function appendLog(rec, lines) {
  rec.logBuf = rec.logBuf || [];
  rec.logSeq = rec.logSeq || 0;
  if (!Array.isArray(lines) || !lines.length) return 0;
  // 与已有缓冲区尾部做最大重叠匹配，避免重复追加（节点每次发的是"最后 N 行"）
  const max = Math.min(rec.logBuf.length, lines.length);
  let overlap = 0;
  for (let k = max; k > 0; k--) {
    let ok = true;
    for (let i = 0; i < k; i++) {
      if (rec.logBuf[rec.logBuf.length - k + i].text !== String(lines[i])) { ok = false; break; }
    }
    if (ok) { overlap = k; break; }
  }
  let added = 0;
  for (let i = overlap; i < lines.length; i++) {
    rec.logBuf.push({ seq: ++rec.logSeq, t: Date.now(), text: String(lines[i]).slice(0, 2000) });
    added++;
  }
  if (rec.logBuf.length > 400) rec.logBuf = rec.logBuf.slice(-400);
  return added;
}
// 目标列表归一化: 去重，避免同一节点被重复计入导致误判为批量下发
function targetList(t) { return Array.isArray(t) ? [...new Set(t.map(String))] : t; }

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
  // 限速说明: 一台机器可能有多个节点条目（单机多节点），每次 agent 运行会发 N 个心跳，
  // 因此按「节点」限速（20/分）而不是按 IP；另设 IP 上限做 DoS 兜底
  if (url === '/api/heartbeat' && req.method === 'POST') {
    if (!rateLimit('hbip:' + ip, 150, 60000)) return json(res, 429, { error: 'rate limited' });
    if (!safeEqual(req.headers['x-token'], data.nodeToken)) {
      rateLimit('fail:' + ip, 10, 60000);
      return json(res, 401, { error: 'bad token' });
    }
    if (defaultTokenBlocked()) return json(res, 403, { error: '默认 nodeToken 禁止使用，请在服务端 cloud-data.json 修改 nodeToken 后重启' });
    const raw = await new Promise((resolve) => {
      let b = '';
      req.on('data', (c) => { b += c; if (b.length > 1e6) req.destroy(); });
      req.on('end', () => resolve(b));
    });
    let body = {};
    let parseErr = '';
    if (raw) { try { body = JSON.parse(raw); } catch (e) { parseErr = e.message; body = {}; } }
    // 诊断: 心跳体无法解析或缺少名称时记日志（限频），用于定位节点上的异常 agent
    if ((parseErr || !String(body.name || '').trim()) && rateLimit('hblog:' + ip, 1, 10 * 60 * 1000)) {
      console.log('[heartbeat-anomaly] ip=' + ip + ' ua=' + (req.headers['user-agent'] || '-')
        + ' bytes=' + raw.length + (parseErr ? (' parseErr=' + parseErr) : '')
        + ' raw=' + raw.slice(0, 700).replace(/\s+/g, ' '));
    }
    const rawName = String(body.name || '').replace(/[\u0000-\u001f\u007f]/g, '').trim();
    const name = (rawName || 'unknown').slice(0, 64);
    // 按节点限速（多节点机器一次运行发 N 个心跳，按 IP 限速会误伤）
    if (!rateLimit('hb:' + name + '|' + ip, 20, 60000)) return json(res, 429, { error: 'rate limited' });
    // 空名称心跳: 正常 agent 一定带 NODE_NAME，出现说明该节点有旧版/残留脚本（会导致重复记录）
    if (!rawName && rateLimit('noname:' + ip, 1, 30 * 60 * 1000)) {
      const ev = addEvent('unknown', 'warn', '收到无名称心跳（来自 ' + ip + '）——该节点可能存在旧版 agent 或残留定时任务，请在节点上重跑 cloud-agent-update.sh');
      notify('⚠️ ' + ev.text);
    }
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
    // 期望配置收敛判定: 节点上报的实际配置已与期望一致 → 清除「待应用」标记
    // （agent 应用后不会主动回报 desired，由服务端比对上报值判定；否则徽章常亮、长轮询也会一直认为有任务）
    if (rec.desired) {
      const want = rec.desired, cur = rec.info.cfg || {};
      const norm = (v) => String(v === undefined || v === null ? '' : v).trim();
      const same = (k, actual) => !(k in want) || norm(want[k]) === norm(actual);
      if (same('ApiHost', cur.ApiHost) && same('ApiKey', cur.ApiKey) && same('NodeID', cur.NodeID)
          && same('CertDomain', cur.CertDomain) && same('Warp', rec.info.warp)
          && same('NodeType', cur.NodeType) && same('GoogleV4', cur.GoogleV4)) { // 注意: 所有可下发字段都必须参与判定，漏一个会导致下发被提前清空
        rec.desired = null;
        addEvent(rec.name, 'desired', '期望配置已生效');
      }
    }
    // 服务健康告警: agent 在线但 V2bX 未运行/未安装（agent v8 起上报 svc）
    // 注意: activating 多为 systemd 单元类型(如 Type=notify)导致的"启动中"假象，不计入故障告警
    const svc = rec.info.svc;
    const svcBad = svc && svc !== 'active' && svc !== 'activating';
    if (svcBad) {
      if (rec.svcWarn !== svc) {
        rec.svcWarn = svc;
        const txt = svc === 'absent' ? 'V2bX 未安装（仅 agent 在线）' : 'V2bX 服务未运行（agent 在线）';
        const ev = addEvent(rec.name, 'service', txt);
        notify('🔴 [' + rec.name + '] ' + ev.text);
      }
    } else if ((svc === 'active' || svc === 'activating') && rec.svcWarn) {
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
    // 单机多节点: 该 agent 管理的节点条目数（面板据此提示"重启影响整机"）
    rec.nodeCount = Number(body.nodeCount) > 0 ? Number(body.nodeCount) : 1;
    rec.nodeId = Number(body.nodeId) > 0 ? Number(body.nodeId) : null;
    // agent 版本 + 证书剩余天数
    rec.agentVer = String(body.agentVer || '');
    // 证书详情（agent v9+）: 一键查询的返回落库，并清除待查询标记
    if (body.cert && typeof body.cert === 'object') {
      const cd = body.cert.days === null || body.cert.days === undefined || body.cert.days === '' ? NaN : Number(body.cert.days);
      rec.cert = {
        path: String(body.cert.path || ''), domain: String(body.cert.domain || ''),
        end: String(body.cert.end || ''), days: Number.isFinite(cd) ? cd : null,
        selfSigned: !!body.cert.selfSigned, checkedAt: Date.now()
      };
      if (Number.isFinite(cd)) rec.certDays = cd;
      if (rec.certQuery) rec.certQuery = null;
    }
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
    // 实时日志订阅: 窗口内要求节点回传 journalctl 最新输出
    if (rec.logUntil && rec.logUntil > Date.now()) reply.log = 1;
    // 媒体检测: 面板手动触发，或结果过期(>12h)/从未检测时自动补测（每 10 分钟最多重试一次，避免失败空转）
    const MEDIA_TTL = 12 * 3600 * 1000, MEDIA_RETRY = 10 * 60 * 1000;
    if (rec.mediaQuery) reply.media = 1;
    else if (!rec.media || (Date.now() - (rec.media.at || 0) > MEDIA_TTL)) {
      if (Date.now() - (rec.mediaAttempt || 0) > MEDIA_RETRY) { rec.mediaAttempt = Date.now(); reply.media = 1; }
    }
    if (pending === 'update') reply.version = data.updateVersion || '';
    // 重命名下发: pendingRename 携带新名，agent 应用后以 appliedRename 确认
    if (rec.pendingRename && rec.pendingRename.newName) reply.desiredName = rec.pendingRename.newName;
    // agent 自更新: 服务端设定版本与节点上报版本不一致时下发
    rec.agentVer = String(body.agentVer || '');
    // 只在节点版本低于目标版本时下发自更新（避免新版被旧目标"降级"）
    if (data.agentVersion) {
      const tgt = Number(data.agentVersion), cur = Number(rec.agentVer);
      if (Number.isFinite(tgt) && Number.isFinite(cur)) {
        if (cur < tgt) reply.agentUpdate = '1';
      } else if (String(rec.agentVer) !== String(data.agentVersion)) {
        reply.agentUpdate = '1'; // 老 agent 不上报版本号，无法比较时按原逻辑处理
      }
    }
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

  // ---------- 节点自查询：按调用方 IP 匹配已有记录，供重新对接时复用身份，避免产生重复节点 ----------
  if (url === '/api/whoami' && req.method === 'POST') {
    if (!rateLimit('hb:' + ip, 10, 60000)) return json(res, 429, { error: 'rate limited' });
    if (!safeEqual(req.headers['x-token'], data.nodeToken)) {
      rateLimit('fail:' + ip, 10, 60000);
      return json(res, 401, { error: 'bad token' });
    }
    if (defaultTokenBlocked()) return json(res, 403, { error: '默认 nodeToken 禁止使用，请在服务端 cloud-data.json 修改 nodeToken 后重启' });
    const now = Date.now();
    const list = Object.entries(data.nodes)
      .filter(([, n]) => n.ip === ip)
      .map(([key, n]) => ({
        key, name: n.name,
        online: now - (n.lastSeen || 0) < 5 * 60 * 1000,
        lastSeen: n.lastSeen || 0, agentVer: n.agentVer || '',
        nodeId: (n.info && n.info.cfg && n.info.cfg.NodeID) || null
      }))
      .sort((a, b) => (b.online - a.online) || (b.lastSeen - a.lastSeen)); // 在线优先，其次最近心跳
    // 推荐身份: 跳过异常记录（历史遗留的 unknown 空报文记录），避免把节点身份带偏
    const good = list.filter((n) => n.name && n.name !== 'unknown');
    return json(res, 200, { ip, nodes: list, recommend: good.length ? good[0].name : '' });
  }

  // ---------- 实时日志: 节点回传 journalctl 输出（nodeToken 鉴权） ----------
  if (url === '/api/log_push' && req.method === 'POST') {
    if (!rateLimit('logpush:' + ip, 100, 60000)) return json(res, 429, { error: 'rate limited' });
    if (!safeEqual(req.headers['x-token'], data.nodeToken)) {
      rateLimit('fail:' + ip, 10, 60000);
      return json(res, 401, { error: 'bad token' });
    }
    if (defaultTokenBlocked()) return json(res, 403, { error: '默认 nodeToken 禁止使用' });
    const body = await readBody(req);
    const name = String(body.name || '').replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 64);
    const key = name + '|' + ip;
    const rec = data.nodes[key];
    if (!rec) return json(res, 404, { error: '节点不存在' });
    if (!(rec.logUntil && rec.logUntil > Date.now())) return json(res, 200, { ok: true, skipped: 1 }); // 未订阅则忽略
    const added = appendLog(rec, (body.lines || []).map((x) => String(x)));
    rec.logAt = Date.now();
    saveData(data);
    return json(res, 200, { ok: true, added, seq: rec.logSeq });
  }

  // ---------- 媒体解锁检测: 节点回传结果（nodeToken 鉴权） ----------
  if (url === '/api/media_push' && req.method === 'POST') {
    if (!rateLimit('mediapush:' + ip, 20, 60000)) return json(res, 429, { error: 'rate limited' });
    if (!safeEqual(req.headers['x-token'], data.nodeToken)) {
      rateLimit('fail:' + ip, 10, 60000);
      return json(res, 401, { error: 'bad token' });
    }
    if (defaultTokenBlocked()) return json(res, 403, { error: '默认 nodeToken 禁止使用' });
    const body = await readBody(req);
    const m = body.media && typeof body.media === 'object' ? body.media : body;
    const name = String(m.name || '').replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, 64);
    const key = name + '|' + ip;
    const rec = data.nodes[key];
    if (!rec) return json(res, 404, { error: '节点不存在' });
    const clip = (v) => String(v == null ? '' : v).slice(0, 64);
    rec.media = {
      at: Date.now(),
      ip: clip(m.ip), loc: clip(m.loc), ms: Number(m.ms) || 0,
      youtube: { ok: !!(m.youtube && m.youtube.ok), region: clip(m.youtube && m.youtube.region), blocked: !!(m.youtube && m.youtube.blocked) },
      google: { ok: !!(m.google && m.google.ok), blocked: !!(m.google && m.google.blocked), code: clip(m.google && m.google.code), search: clip(m.google && m.google.search) },
      netflix: { ok: !!(m.netflix && m.netflix.ok), code: clip(m.netflix && m.netflix.code) },
      chatgpt: { ok: !!(m.chatgpt && m.chatgpt.ok), code: clip(m.chatgpt && m.chatgpt.code), loc: clip(m.chatgpt && m.chatgpt.loc) }
    };
    if (rec.media.google.blocked || rec.media.youtube.blocked) {
      const why = rec.media.google.blocked ? 'Google 搜索跳转 /sorry/' : 'YouTube 提示异常流量';
      const ev = addEvent(rec.name, 'media', '⚠ ' + why + '：出口 IP ' + (rec.media.ip || '?') + ' 疑似被拉黑，建议更换出口');
      notify('⚠️ [' + rec.name + '] ' + ev.text);
    }
    rec.mediaQuery = null;
    saveData(data);
    return json(res, 200, { ok: true });
  }

  // ---------- 节点长轮询：挂起连接等待任务，管理端下发命令时立即唤醒（秒级送达） ----------
  // 只做「有没有活」的判断，不改任何节点记录；被唤醒后节点会立刻跑一轮完整心跳来领取任务
  if (url === '/api/wait' && req.method === 'POST') {
    // 长轮询是常驻连接：按 IP 给足额度（订阅期间节奏快），另由下方节流控制空转
    if (!rateLimit('waitip:' + ip, 150, 60000)) return json(res, 429, { error: 'rate limited' });
    if (!safeEqual(req.headers['x-token'], data.nodeToken)) {
      rateLimit('fail:' + ip, 10, 60000);
      return json(res, 401, { error: 'bad token' });
    }
    if (defaultTokenBlocked()) return json(res, 403, { error: '默认 nodeToken 禁止使用，请在服务端 cloud-data.json 修改 nodeToken 后重启' });
    const body = await readBody(req);
    const key = String(body.name || 'unknown').slice(0, 64) + '|' + ip;
    const rec = data.nodes[key];
    const hasWork = !!(rec && (rec.desired || rec.pendingAction || rec.certQuery || rec.mediaQuery || (rec.pendingRename && rec.pendingRename.newName)));
    const hasAgentUpdate = !!(data.agentVersion && rec && String(rec.agentVer || '') !== String(data.agentVersion));
    // 日志订阅: 节流到 2.5s 一次（近似 tail -f，同时避免 agent 高频循环打爆心跳限速）
    if (rec && rec.logUntil && rec.logUntil > Date.now()) {
      const now = Date.now();
      if (now - (lastWakeAt.get('log:' + key) || 0) > 2500) {
        lastWakeAt.set('log:' + key, now);
        return json(res, 200, { wake: 1 });
      }
      return waitForNode(key, res);
    }
    if (hasWork || hasAgentUpdate) {
      // 同一节点 15s 内只立即唤醒一次：避免任务长期无法收敛（如 WARP 模板缺失）时守护进程空转
      const now = Date.now();
      if (now - (lastWakeAt.get(key) || 0) > 15000) {
        lastWakeAt.set(key, now);
        return json(res, 200, { wake: 1 });
      }
    }
    if (WAITERS.size >= WAITERS_MAX) return json(res, 200, { wake: 0, busy: 1 });
    return waitForNode(key, res);
  }


  if (!isAuthed(req)) {
    if (!rateLimit('fail:' + ip, 10, 60000)) return json(res, 429, { error: 'rate limited' });
    return json(res, 401, { error: 'unauthorized' });
  }
  if (defaultTokenBlocked()) {
    return json(res, 403, { error: '默认管理 Token 禁止使用：请编辑 cloud-data.json 将 token 与 nodeToken 改为随机强串后重启本进程（开发调试可用 ALLOW_INSECURE_TOKEN=1 临时绕过）' });
  }

  // 面板自身 HTTPS 证书信息（读 TLS_CERT，零依赖解析）
  if (url === '/api/cert' && req.method === 'GET') {
    if (!TLS_CERT || !fs.existsSync(TLS_CERT)) {
      return json(res, 200, { error: '当前为 HTTP 模式（未配置 TLS_CERT），面板没有证书' });
    }
    try {
      const x = new crypto.X509Certificate(fs.readFileSync(TLS_CERT));
      // Node 的 subject/issuer 是换行分隔的 RDN 列表，逐行解析更可靠
      const parts = (s) => String(s || '').split('\n').map(v => v.trim()).filter(Boolean);
      const pick = (list, key) => { const l = list.find(v => v.startsWith(key + '=')); return l ? l.slice(key.length + 1) : ''; };
      const subjL = parts(x.subject), issL = parts(x.issuer);
      const subj = subjL.join(', '), iss = issL.join(', ');
      const cn = pick(subjL, 'CN') || subj;
      const issO = pick(issL, 'O') || iss;
      const days = Math.floor((new Date(x.validTo).getTime() - Date.now()) / 86400000);
      return json(res, 200, {
        cn, issuer: issO, subject: subj, validFrom: x.validFrom, validTo: x.validTo,
        days, selfSigned: subj === iss, path: TLS_CERT,
        san: String(x.subjectAltName || '')
      });
    } catch (e) {
      return json(res, 500, { error: '证书解析失败: ' + e.message });
    }
  }

  // 实时日志订阅: 开始/停止（订阅窗口内节点会持续回传日志）
  // 媒体解锁检测: 面板触发（选中节点或全部），节点下一次心跳立即执行并回传
  if (url === '/api/media_query' && req.method === 'POST') {
    const body = await readBody(req);
    const tgts = targetList(body.targets);
    const hit = [];
    for (const [key, n] of Object.entries(data.nodes)) {
      if (tgts === 'all' || (tgts || []).includes(key)) { n.mediaQuery = Date.now(); hit.push(key); }
    }
    if (!hit.length) return json(res, 400, { error: '未匹配到节点' });
    audit('media-query', '媒体解锁检测 ' + hit.length + ' 台');
    saveData(data);
    flushWaiters(hit);
    return json(res, 200, { ok: true, queried: hit.length, queryAt: Date.now() });
  }

  if (url === '/api/log_start' && req.method === 'POST') {
    const body = await readBody(req);
    const sec = Math.min(Math.max(Number(body.seconds) || 60, 10), 300);
    const tgts = targetList(body.targets);
    const hit = [];
    for (const [key, n] of Object.entries(data.nodes)) {
      if (tgts === 'all' || (tgts || []).includes(key)) {
        n.logUntil = Date.now() + sec * 1000;
        n.logBuf = []; n.logSeq = 0; n.logAt = 0; // 每次订阅从干净缓冲开始
        hit.push(key);
      }
    }
    if (!hit.length) return json(res, 400, { error: '未匹配到节点' });
    audit('log-start', '实时日志订阅 ' + sec + 's × ' + hit.length + ' 台');
    saveData(data);
    flushWaiters(hit);
    return json(res, 200, { ok: true, nodes: hit.length, seconds: sec });
  }
  if (url === '/api/log_stop' && req.method === 'POST') {
    const body = await readBody(req);
    const tgts = targetList(body.targets);
    let count = 0;
    for (const [key, n] of Object.entries(data.nodes)) {
      if (tgts === 'all' || (tgts || []).includes(key)) { n.logUntil = 0; count++; }
    }
    saveData(data);
    return json(res, 200, { ok: true, stopped: count });
  }
  if (url === '/api/log_fetch' && req.method === 'GET') {
    const q = new URLSearchParams(req.url.split('?')[1] || '');
    const key = q.get('key') || '';
    const since = Number(q.get('since') || 0);
    const n = data.nodes[key];
    if (!n) return json(res, 404, { error: '节点不存在' });
    const buf = n.logBuf || [];
    const lines = buf.filter((x) => x.seq > since);
    const dropped = buf.length && buf[0].seq > since + 1 && since > 0; // 增量超出缓冲范围（被裁剪）
    return json(res, 200, {
      seq: n.logSeq || 0, active: !!(n.logUntil && n.logUntil > Date.now()),
      until: n.logUntil || 0, at: n.logAt || 0, dropped: !!dropped,
      lines: lines.slice(-200)
    });
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
      desired: n.desired || null, action: effAction(n),
      cert: n.cert || null, certQuery: n.certQuery || null,
      media: n.media || null, mediaQuery: n.mediaQuery || null,
      nodeCount: n.nodeCount || 1, nodeId: n.nodeId || null
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
    // 白名单校验: 该名称会进入 agent 的 shell 流程，只允许字母/数字/中文/空格/._-
    if (!/^[\p{L}\p{N}][\p{L}\p{N} _.-]{0,63}$/u.test(newName)) {
      return json(res, 400, { error: '名称只能包含中文、字母、数字、空格和 . _ -' });
    }
    if (newName === n.name) return json(res, 400, { error: '名称未变化' });
    const newKey = newName + '|' + n.ip;
    if (data.nodes[newKey]) return json(res, 400, { error: '该名称已被同 IP 节点使用' });
    // 身份键迁移: 心跳键是 name|ip，直接改名会分裂记录 —— 走 pendingRename 流程
    // agent 收到 desiredName 应用后，下次心跳以新名上报，服务端凭 appliedRename 迁移全部历史
    n.pendingRename = { oldKey: key, newName, requestedAt: Date.now() };
    audit('rename', '节点重命名: ' + n.name + ' → ' + newName + '（等 agent 应用）');
    saveData(data);
    flushNode(key); // 立即唤醒该节点的长轮询，秒级应用
    return json(res, 200, { ok: true, newName });
  }

  // 一键查询选中节点的证书到期时间（写入待查询标记 → 长轮询即时唤醒 → 节点回报 cert 详情）
  // 删除节点记录（清理重复/孤儿记录；只删云控侧数据，不影响节点上的服务）
  if (url === '/api/node_delete' && req.method === 'POST') {
    const body = await readBody(req);
    const keys = Array.isArray(body.targets) ? body.targets : [];
    const names = [];
    for (const key of keys) {
      const n = data.nodes[key];
      if (!n) continue;
      names.push(n.name);
      delete data.nodes[key];
    }
    if (!names.length) return json(res, 400, { error: '未匹配到可删除的节点记录' });
    audit('node-delete', '删除节点记录 ' + names.length + ' 条: ' + names.join(', '));
    saveData(data);
    return json(res, 200, { ok: true, deleted: names.length, names });
  }

  if (url === '/api/cert_query' && req.method === 'POST') {
    const body = await readBody(req);
    const hit = [];
    for (const [key, n] of Object.entries(data.nodes)) {
      if (body.targets === 'all' || (body.targets || []).includes(key)) { n.certQuery = Date.now(); hit.push(key); }
    }
    audit('cert-query', '一键查询 ' + hit.length + ' 台节点的证书到期时间');
    saveData(data);
    flushWaiters(hit); // 秒级唤醒，无需等下一轮心跳
    return json(res, 200, { ok: true, queried: hit.length, queryAt: Date.now() });
  }

  if (url === '/api/desired' && req.method === 'POST') {
    const body = await readBody(req);
    const fields = pickCfg(body.fields);
    if (!Object.keys(fields).length) return json(res, 400, { error: 'no fields' });
    // 下发的值最终会进入节点 agent 的 shell/jq 流程，必须在源头限制字符集
    const RE_HOST = /^https?:\/\/[A-Za-z0-9._-]+(:[0-9]{1,5})?([/?][\w./~%-]*)?$/;
    const RE_KEY = /^[A-Za-z0-9_\-!$+=.@:/]{1,128}$/;
    const RE_DOMAIN = /^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$/;
    if (fields.ApiHost !== undefined && !RE_HOST.test(fields.ApiHost)) {
      return json(res, 400, { error: 'ApiHost 格式非法（应为 http(s)://域名或IP[:端口]）' });
    }
    if (fields.ApiKey !== undefined && !RE_KEY.test(fields.ApiKey)) {
      return json(res, 400, { error: 'ApiKey 含不允许的字符（引号/反引号/空格/分号等）' });
    }
    if (fields.NodeID !== undefined && !/^[0-9]{1,9}$/.test(String(fields.NodeID))) {
      return json(res, 400, { error: 'NodeID 必须为数字' });
    }
    if (fields.CertDomain !== undefined && !RE_DOMAIN.test(fields.CertDomain)) {
      return json(res, 400, { error: 'CertDomain 格式非法（只能包含字母/数字/点/连字符）' });
    }
    if (fields.Warp !== undefined && !['on', 'off'].includes(String(fields.Warp))) {
      return json(res, 400, { error: 'Warp 只能为 on 或 off' });
    }
    if (fields.NodeType !== undefined && !NODE_TYPES.includes(String(fields.NodeType))) {
      return json(res, 400, { error: 'NodeType 非法（支持: ' + NODE_TYPES.join(' / ') + '）' });
    }
    if (fields.GoogleV4 !== undefined && !['on', 'off'].includes(String(fields.GoogleV4))) {
      return json(res, 400, { error: 'GoogleV4 只能为 on（强制 IPv4）或 off（恢复默认）' });
    }
    const tgts = targetList(body.targets); // 去重后判定，避免同一节点重复提交被误判为批量
    const isBatch = tgts === 'all' || (Array.isArray(tgts) && tgts.length > 1);
    if (isBatch) {
      const bad = Object.keys(fields).filter((k) => PER_NODE_FIELDS.includes(k));
      if (bad.length) {
        return json(res, 400, { error: `字段 ${bad.join(',')} 是每台节点不同的差异化配置，禁止批量下发（当前选中 ${tgts === 'all' ? '全部' : tgts.length + ' 台'}），请只勾选 1 台再下发` });
      }
    }
    let count = 0;
    const hit = [];
    for (const [key, n] of Object.entries(data.nodes)) {
      if (body.targets === 'all' || (body.targets || []).includes(key)) {
        n.desired = Object.assign({}, n.desired || {}, fields);
        hit.push(key);
        count++;
      }
    }
    audit('desired', '下发配置 ' + JSON.stringify(fields) + ' 到 ' + count + ' 台节点');
    saveData(data);
    flushWaiters(hit); // 立即唤醒目标节点的长轮询
    return json(res, 200, { ok: true, applied: count, fields });
  }

  if (url === '/api/desired/clear' && req.method === 'POST') {
    const body = await readBody(req);
    const tgts = targetList(body.targets);
    let count = 0;
    const hit = [];
    for (const [key, n] of Object.entries(data.nodes)) {
      if (tgts === 'all' || (tgts || []).includes(key)) { n.desired = null; hit.push(key); count++; }
    }
    audit('desired-clear', '清除 ' + count + ' 台节点的期望配置');
    saveData(data);
    flushWaiters(hit);
    return json(res, 200, { ok: true, cleared: count });
  }

  if (url === '/api/action' && req.method === 'POST') {
    const body = await readBody(req);
    const act = body.action === 'update' ? 'update' : 'restart';
    const tgts = targetList(body.targets);
    let count = 0;
    const hit = [];
    for (const [key, n] of Object.entries(data.nodes)) {
      if (tgts === 'all' || (tgts || []).includes(key)) {
        n.pendingAction = act;
        n.action = {
          type: act,
          version: act === 'update' ? (data.updateVersion || '') : '',
          queuedAt: Date.now(),
          status: 'queued'
        };
        hit.push(key);
        count++;
      }
    }
    audit('action', '排队动作 [' + act + (act === 'update' && data.updateVersion ? ' ' + data.updateVersion : '') + '] 到 ' + count + ' 台节点');
    saveData(data);
    flushWaiters(hit); // 立即唤醒目标节点，命令秒级送达
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
    flushWaiters(); // 设置可能影响所有节点（版本锁定/agent 自更新），全部唤醒重取
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
