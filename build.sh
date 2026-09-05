#!/bin/bash

set -e

# 版本号：可通过第一个参数指定，如 ./build.sh v1.0.9；默认用 git tag 或 dev
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null || echo dev)}"
echo "开始构建 V2bX ${VERSION}（AnyTLS-only 精简版，sing-box 内核）..."

LDFLAGS="-s -w -X 'github.com/InazumaV/V2bX/cmd.version=${VERSION}'"
# sing-only：不含 xray/hysteria2/quic/dhcp/clash-api
# with_gvisor：WireGuard(WARP) 出站的用户态网络栈必需；with_wireguard：WARP 出站必需
TAGS="sing,with_gvisor,with_wireguard"

# 清理旧文件
rm -rf build
mkdir -p build

# 编译 amd64 版本
echo "编译 Linux amd64 版本..."
GOOS=linux GOARCH=amd64 go build -tags "${TAGS}" -o build/V2bX-amd64 -ldflags="${LDFLAGS}" main.go

# 编译 arm64 版本
echo "编译 Linux arm64 版本..."
GOOS=linux GOARCH=arm64 go build -tags "${TAGS}" -o build/V2bX-arm64 -ldflags="${LDFLAGS}" main.go

# 下载 geoip 和 geosite 数据文件（如果不存在）
if [ ! -f "geoip.dat" ]; then
    echo "下载 geoip.dat..."
    curl -L -o geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
fi

if [ ! -f "geosite.dat" ]; then
    echo "下载 geosite.dat..."
    curl -L -o geosite.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat
fi

# 复制示例配置文件
echo "复制示例配置文件..."
cd build
cp ../geoip.dat .
cp ../geosite.dat .
cp ../example/geoip.db .
cp ../example/geosite.db .
cp ../example/config.json .
cp ../example/custom_inbound.json .
cp ../example/custom_outbound.json .
cp ../example/dns.json .
cp ../example/route.json .

# 打包 amd64 版本
echo "打包 amd64 版本..."
cp V2bX-amd64 V2bX
zip -q V2bX-linux-64.zip V2bX geoip.dat geosite.dat geoip.db geosite.db config.json custom_inbound.json custom_outbound.json dns.json route.json
rm V2bX

# 打包 arm64 版本
echo "打包 arm64 版本..."
cp V2bX-arm64 V2bX
zip -q V2bX-linux-arm64-v8a.zip V2bX geoip.dat geosite.dat geoip.db geosite.db config.json custom_inbound.json custom_outbound.json dns.json route.json
rm V2bX

# 清理临时文件
rm geoip.dat geosite.dat geoip.db geosite.db config.json custom_inbound.json custom_outbound.json dns.json route.json

cd ..

echo "构建完成！"
echo "文件位置："
ls -lh build/*.zip
