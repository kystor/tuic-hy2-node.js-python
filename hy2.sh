#!/usr/bin/env bash
# -*- coding: utf-8 -*-
# Hysteria2 极简部署脚本（带TCP出站代理，完美绕过UDP限制）
# 适用于超低内存环境（32-64MB）

set -e

# ---------- 默认配置 ----------
HYSTERIA_VERSION="v2.6.5"
DEFAULT_PORT=22222            # 默认监听端口
AUTH_PASSWORD="ieshare2025"   # 默认连接密码
CERT_FILE="cert.pem"          # 证书文件路径
KEY_FILE="key.pem"            # 私钥文件路径
SNI="www.bing.com"            # 伪装域名
ALPN="h3"
# ------------------------------

echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
echo "Hysteria2 极简部署脚本（带出站代理与TCP/UDP智能分流）"
echo "支持命令行端口参数，如：bash hy2.sh 443"
echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"

# ---------- 获取端口 ----------
# 检测你是否在 start 文件里传递了端口参数
if [[ $# -ge 1 && -n "${1:-}" ]]; then
    SERVER_PORT="$1"
    echo "✅ 使用命令行指定端口: $SERVER_PORT"
else
    SERVER_PORT="${SERVER_PORT:-$DEFAULT_PORT}"
    echo "⚙️ 未提供端口参数，使用默认端口: $SERVER_PORT"
fi

# ---------- 检测架构 ----------
# 自动检测面板所在服务器的 CPU 架构，以决定下载哪个版本的内核
arch_name() {
    local machine
    machine=$(uname -m | tr '[:upper:]' '[:lower:]')
    if [[ "$machine" == *"arm64"* ]] || [[ "$machine" == *"aarch64"* ]]; then
        echo "arm64"
    elif [[ "$machine" == *"x86_64"* ]] || [[ "$machine" == *"amd64"* ]]; then
        echo "amd64"
    else
        echo ""
    fi
}

ARCH=$(arch_name)
if [ -z "$ARCH" ]; then
  echo "❌ 无法识别 CPU 架构: $(uname -m)"
  exit 1
fi

BIN_NAME="hysteria-linux-${ARCH}"
BIN_PATH="./${BIN_NAME}"

# ---------- 下载二进制 ----------
# 下载主程序。这里的 curl 命令没有屏蔽输出，你可以在控制台看到下载进度条
download_binary() {
    if [ -f "$BIN_PATH" ]; then
        echo "✅ 二进制已存在，跳过下载。"
        return
    fi
    URL="https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/${BIN_NAME}"
    echo "⏳ 下载: $URL"
    curl -L --retry 3 --connect-timeout 30 -o "$BIN_PATH" "$URL"
    chmod +x "$BIN_PATH"
    echo "✅ 下载完成并设置可执行: $BIN_PATH"
}

# ---------- 生成证书 ----------
# 调用 openssl 生成自签名证书。此过程也会在控制台打印生成日志
ensure_cert() {
    if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
        echo "✅ 发现证书，使用现有 cert/key。"
        return
    fi
    echo "🔑 未发现证书，使用 openssl 生成自签证书（prime256v1）..."
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=${SNI}"
    echo "✅ 证书生成成功。"
}

# ---------- 写配置文件 ----------
# 生成核心的 YAML 配置文件
write_config() {
cat > server.yaml <<EOF
listen: ":${SERVER_PORT}"
tls:
  cert: "$(pwd)/${CERT_FILE}"
  key: "$(pwd)/${KEY_FILE}"
  alpn:
    - "${ALPN}"
auth:
  type: "password"
  password: "${AUTH_PASSWORD}"
bandwidth:
  up: "200mbps"
  down: "200mbps"
quic:
  max_idle_timeout: "10s"
  max_concurrent_streams: 4
  initial_stream_receive_window: 65536
  max_stream_receive_window: 131072
  initial_conn_receive_window: 131072
  max_conn_receive_window: 262144

# === 出站代理出口配置 ===
# 定义名为 custom_proxy 的 SOCKS5 出站服务器
outbounds:
  - name: custom_proxy
    type: socks5
    socks5:
      addr: "66.181.36.237:25556"

# === 智能分流规则 (ACL) ===
# 让网页浏览等 TCP 请求走你指定的 66.181.36.237，
# 让 DNS 解析等 UDP 请求绕过代理直接连接，防止代理不支持 UDP 导致断网。
acl:
  inline:
    - custom_proxy(network:tcp)
    - direct(network:udp)
EOF
    echo "✅ 写入配置 server.yaml 成功（TCP 走 SOCKS5，UDP 直连）。"
}

# ---------- 获取服务器 IP ----------
# 尝试获取面板的真实外网 IP，用来生成最终给客户端导入的连接
get_server_ip() {
    IP=$(curl --max-time 10 https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")
    echo "$IP"
}

# ---------- 打印连接信息 ----------
# 在控制台打印 Hysteria2 的连接地址，方便你复制到 V2rayN / Nekoray 等客户端软件中
print_connection_info() {
    local IP="$1"
    echo "🎉 Hysteria2 部署成功！（含智能出站代理）"
    echo "=========================================================================="
    echo "📋 服务器信息:"
    echo "   🌐 你的面板IP: $IP"
    echo "   🔌 面板监听端口: $SERVER_PORT"
    echo "   🔑 连接密码: $AUTH_PASSWORD"
    echo ""
    echo "📱 节点链接（SNI=${SNI}, ALPN=${ALPN}, 跳过证书验证）:"
    echo "hysteria2://${AUTH_PASSWORD}@${IP}:${SERVER_PORT}?sni=${SNI}&alpn=${ALPN}&insecure=1#Hy2-Proxy"
    echo ""
    echo "⚠️ 提醒：客户端连上此节点后，网页浏览的实际 IP 将显示为 66.181.36.237"
    echo "=========================================================================="
}

# ---------- 主逻辑 ----------
main() {
    download_binary
    ensure_cert
    write_config
    SERVER_IP=$(get_server_ip)
    print_connection_info "$SERVER_IP"
    echo "🚀 启动 Hysteria2 服务器..."
    # 启动 Hysteria2 主程序，保留所有运行输出，排错清晰可见
    exec "$BIN_PATH" server -c server.yaml
}

main "$@"
