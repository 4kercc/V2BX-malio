#!/bin/bash
############################################
# V2BX-malio 一键强制更新脚本
# 用途：强制刷新管理脚本到最新（纠正更新源），再拉取最新程序版本
# 用法：bash <(curl -fsSL https://raw.githubusercontent.com/4kercc/V2BX-malio/main/update-v2bx.sh)
############################################

set -e

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${red}错误：必须使用 root 用户运行此脚本！${plain}" && exit 1

REPO_RAW="https://raw.githubusercontent.com/4kercc/V2BX-malio/main"

############################################
# 第 1 步：强制刷新管理脚本
# 先下载到临时文件并校验语法，再原子替换，
# 避免下载中断把 /usr/bin/V2bX 写坏导致管理命令不可用
############################################
echo -e "${green}==== 第 1 步：强制刷新管理脚本 ====${plain}"
if ! curl -fsSL -o /tmp/V2bX.sh.new "${REPO_RAW}/V2bX.sh"; then
    echo -e "${red}下载管理脚本失败，请检查服务器能否访问 GitHub。未做任何更改。${plain}"
    exit 1
fi
if [[ ! -s /tmp/V2bX.sh.new ]] || ! bash -n /tmp/V2bX.sh.new 2>/dev/null; then
    echo -e "${red}下载的管理脚本校验失败。未做任何更改。${plain}"
    rm -f /tmp/V2bX.sh.new
    exit 1
fi
mv -f /tmp/V2bX.sh.new /usr/bin/V2bX
chmod +x /usr/bin/V2bX
ln -sf /usr/bin/V2bX /usr/bin/v2bx
echo -e "${green}✓ 管理脚本已刷新到最新${plain}"

############################################
# 第 2 步：对齐内存与系统调优（幂等，已配置的自动跳过）
############################################
echo -e "${green}==== 第 2 步：对齐内存与系统调优 ====${plain}"
if ! grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
    echo "vm.swappiness=10" >> /etc/sysctl.conf
fi
sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true

if [[ ! -f /etc/systemd/system/V2bX.service.d/override.conf ]]; then
    mkdir -p /etc/systemd/system/V2bX.service.d
    cat > /etc/systemd/system/V2bX.service.d/override.conf <<EOF
[Service]
Environment="GOMEMLIMIT=150MiB"
Environment="GODEBUG=madvdontneed=1"
EOF
    echo -e "${green}✓ 已注入 Go 运行时内存调优 (GOMEMLIMIT/madvdontneed)${plain}"
else
    echo "内存调优已配置，跳过"
fi

if ! crontab -l 2>/dev/null | grep -q "systemctl restart V2bX"; then
    (crontab -l 2>/dev/null; echo "0 3 */5 * * systemctl restart V2bX") | crontab - || true
    echo -e "${green}✓ 已添加每 5 天凌晨 3 点定时重启任务${plain}"
else
    echo "定时重启任务已存在，跳过"
fi

############################################
# 第 3 步：拉取最新程序版本
# v2bx update 会自动：检测并卸载外部 WARP 组件 →
# 下载最新 Release 二进制（保留全部配置）→ 重启服务
############################################
echo -e "${green}==== 第 3 步：拉取最新程序版本 ====${plain}"
systemctl daemon-reload

if [[ -f /usr/local/V2bX/V2bX ]]; then
    v2bx update
else
    echo -e "${yellow}未检测到已安装的程序，转为全新安装...${plain}"
    v2bx install
fi

############################################
# 第 4 步：校验运行状态
############################################
echo -e "${green}==== 第 4 步：校验运行状态 ====${plain}"
sleep 2
if systemctl is-active --quiet V2bX; then
    echo -e "${green}✓ 更新完成，V2bX 运行正常${plain}"
    echo -e "当前配置：$(grep -oP '\"ApiHost\"\s*:\s*\"\K[^\"]+' /etc/V2bX/config.json 2>/dev/null | head -n 1) / NodeID $(grep -oP '\"NodeID\"\s*:\s*\K[0-9]+' /etc/V2bX/config.json 2>/dev/null | head -n 1)"
else
    echo -e "${red}✗ V2bX 未运行，请执行 v2bx log 查看日志排查${plain}"
    exit 1
fi
